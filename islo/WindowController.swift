import AppKit
import Combine
import Darwin
import QuartzCore
import SwiftUI

/// A non-activating panel keeps media controls interactive without taking focus
/// away from the application the user is currently working in.
private final class FloatingNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingNotchWindowController: NSWindowController {
    private let mediaManager: MediaManager
    private let settings: AppSettings
    private let commandEchoManager: CommandEchoManager
    private let focusTimerManager: FocusTimerManager
    private let keepAwakeManager: KeepAwakeManager
    private let fileShelfManager: FileShelfManager
    private let clipboardHistoryManager: ClipboardHistoryManager
    private let notificationMonitor: NotificationMonitor
    private var layout: NotchLayout
    private var currentSize: CGSize
    private var visibilityTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        mediaManager: MediaManager,
        settings: AppSettings,
        commandEchoManager: CommandEchoManager,
        focusTimerManager: FocusTimerManager,
        keepAwakeManager: KeepAwakeManager,
        fileShelfManager: FileShelfManager,
        clipboardHistoryManager: ClipboardHistoryManager,
        notificationMonitor: NotificationMonitor
    ) {
        self.mediaManager = mediaManager
        self.settings = settings
        self.commandEchoManager = commandEchoManager
        self.focusTimerManager = focusTimerManager
        self.keepAwakeManager = keepAwakeManager
        self.fileShelfManager = fileShelfManager
        self.clipboardHistoryManager = clipboardHistoryManager
        self.notificationMonitor = notificationMonitor

        let targetScreen = NSScreen.screens.first ?? NSScreen.main
        let layout = NotchLayout(screen: targetScreen)
        self.layout = layout
        currentSize = layout.size(
            for: .idle,
            idleMode: settings.notchIdleMode
        )

        let panel = FloatingNotchPanel(
            contentRect: NSRect(origin: .zero, size: currentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        configure(panel)
        installRootView(in: panel)
        reposition(animated: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceContextDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceContextDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        settings.$hideInFullScreen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleVisibilityRefresh()
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        visibilityTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshLayoutIfNeeded()
        reposition(animated: false)
        refreshVisibility()
    }

    private func configure(_ panel: FloatingNotchPanel) {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.identifier = NSUserInterfaceItemIdentifier("isloFloatingNotch")

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true

        // .statusBar is high enough for normal Spaces while remaining less
        // intrusive than .screenSaver. The latter can be chosen for a kiosk-like
        // build that must cover every possible full-screen window.
        panel.level = .statusBar

        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        behavior.remove(.managed)
        panel.collectionBehavior = behavior
    }

    private func installRootView(in panel: FloatingNotchPanel) {
        let rootView = DynamicNotchView(
            mediaManager: mediaManager,
            settings: settings,
            commandEchoManager: commandEchoManager,
            focusTimerManager: focusTimerManager,
            keepAwakeManager: keepAwakeManager,
            fileShelfManager: fileShelfManager,
            clipboardHistoryManager: clipboardHistoryManager,
            notificationMonitor: notificationMonitor,
            layout: layout
        ) { [weak self] preferredSize, animated in
            self?.resizeWindow(to: preferredSize, animated: animated)
        }

        // Keep the hosting view out of the window's content-view slot. When it
        // is the content view, SwiftUI also resizes the panel during layout
        // while this controller animates the frame; near the notch every
        // resize changes the safe area, and the loop makes AppKit abort.
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]

        let container = NSView(frame: NSRect(origin: .zero, size: currentSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = container.bounds
        container.addSubview(hostingView)
        panel.contentView = container
    }

    private func resizeWindow(to size: CGSize, animated: Bool) {
        currentSize = size
        reposition(animated: animated)
    }

    /// Recomputing both axes keeps the top edge and horizontal center fixed while
    /// the SwiftUI content changes between compact and expanded states.
    private func reposition(animated: Bool) {
        guard let window, let screen = preferredScreen else { return }

        let topGap: CGFloat = screen.safeAreaInsets.top > 0 ? 0 : 6
        let targetFrame = NSRect(
            x: screen.frame.midX - currentSize.width / 2,
            y: screen.frame.maxY - topGap - currentSize.height,
            width: currentSize.width,
            height: currentSize.height
        )

        guard animated else {
            window.setFrame(targetFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                0.8,
                0.2,
                1
            )
            context.allowsImplicitAnimation = true
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    /// `NSScreen.screens.first` is the display that owns the menu bar, which is a
    /// better stable target for a top-center utility than `NSScreen.main` (the
    /// latter follows keyboard focus).
    private var preferredScreen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    /// Screen safe-area values can change when the menu-bar display changes,
    /// an external monitor is attached, or the display configuration is restored
    /// after sleep. Rebuilding the root view also prevents stale notch geometry
    /// from being carried from one display to another.
    private func refreshLayoutIfNeeded() {
        let updatedLayout = NotchLayout(screen: preferredScreen)
        guard updatedLayout != layout else { return }

        layout = updatedLayout
        currentSize = updatedLayout.size(
            for: .idle,
            idleMode: settings.notchIdleMode
        )

        if let panel = window as? FloatingNotchPanel {
            installRootView(in: panel)
        }
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        refreshLayoutIfNeeded()
        reposition(animated: false)
        scheduleVisibilityRefresh()
    }

    @objc
    private func workspaceContextDidChange(_ notification: Notification) {
        scheduleVisibilityRefresh()
    }

    private func scheduleVisibilityRefresh() {
        visibilityTask?.cancel()
        visibilityTask = Task { @MainActor [weak self] in
            do {
                try await Task<Never, Never>.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            self?.refreshVisibility()
        }
    }

    private func refreshVisibility() {
        guard let window else { return }

        if settings.hideInFullScreen, frontmostAppOccupiesEntireScreen {
            NotificationCenter.default.post(
                name: .isloCollapse,
                object: nil
            )
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    private var frontmostAppOccupiesEntireScreen: Bool {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let screen = preferredScreen,
              let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            return false
        }

        let displayBounds = CGDisplayBounds(
            CGDirectDisplayID(screenNumber.uint32Value)
        )
        let targetPID = frontmostApplication.processIdentifier

        if let spaceResult = FullScreenSpaceDetector.isFullScreenSpace(
            processIdentifier: targetPID,
            displayID: CGDirectDisplayID(screenNumber.uint32Value)
        ) {
            return spaceResult
        }

        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]

        guard let windows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let tolerance: CGFloat = 4
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == targetPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.05,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary
                  ) else {
                return false
            }

            return abs(bounds.minX - displayBounds.minX) <= tolerance &&
                abs(bounds.minY - displayBounds.minY) <= tolerance &&
                bounds.width >= displayBounds.width - tolerance &&
                bounds.height >= displayBounds.height - tolerance
        }
    }
}

/// AppKit reports screen geometry but doesn't expose whether another app owns
/// the active full-screen Space. The dynamically resolved WindowServer symbols
/// provide that missing bit without adding a private-framework link dependency.
/// If macOS ever removes them, the controller falls back to window geometry.
private enum FullScreenSpaceDetector {
    private typealias ConnectionFunction = @convention(c) () -> UInt32
    private typealias ManagedSpacesFunction = @convention(c) (
        UInt32
    ) -> Unmanaged<CFArray>

    static func isFullScreenSpace(
        processIdentifier: pid_t,
        displayID: CGDirectDisplayID
    ) -> Bool? {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let connectionSymbol = dlsym(
                handle,
                "CGSMainConnectionID"
              ),
              let spacesSymbol = dlsym(
                handle,
                "CGSCopyManagedDisplaySpaces"
              ) else {
            return nil
        }

        let connectionFunction = unsafeBitCast(
            connectionSymbol,
            to: ConnectionFunction.self
        )
        let spacesFunction = unsafeBitCast(
            spacesSymbol,
            to: ManagedSpacesFunction.self
        )
        let managedSpaces = spacesFunction(
            connectionFunction()
        ).takeRetainedValue()

        guard let displays = managedSpaces as? [[String: Any]] else {
            return nil
        }

        let displayUUID = CGDisplayCreateUUIDFromDisplayID(
            displayID
        ).takeRetainedValue()
        let displayIdentifier = CFUUIDCreateString(
            nil,
            displayUUID
        ) as String

        guard let display = displays.first(where: {
            ($0["Display Identifier"] as? String) == displayIdentifier
        }), let currentSpace = display["Current Space"] as? [String: Any]
        else {
            return nil
        }

        let type = (currentSpace["type"] as? NSNumber)?.intValue
        let ownerPID = (currentSpace["pid"] as? NSNumber)?.int32Value
        return type == 4 && ownerPID == processIdentifier
    }
}
