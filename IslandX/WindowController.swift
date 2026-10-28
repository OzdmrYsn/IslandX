import AppKit
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
    private var layout: NotchLayout
    private var currentSize: CGSize

    init(mediaManager: MediaManager, settings: AppSettings) {
        self.mediaManager = mediaManager
        self.settings = settings

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshLayoutIfNeeded()
        reposition(animated: false)
        window?.orderFrontRegardless()
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
            layout: layout
        ) { [weak self] preferredSize, animated in
            self?.resizeWindow(to: preferredSize, animated: animated)
        }

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hostingController
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
            context.duration = 0.4
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
    }
}
