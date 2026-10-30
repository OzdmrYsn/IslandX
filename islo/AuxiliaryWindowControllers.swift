import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let router = SettingsRouter()

    init(settings: AppSettings, onShowOnboarding: @escaping () -> Void) {
        let rootView = SettingsView(
            settings: settings,
            router: router,
            onShowOnboarding: onShowOnboarding
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 690),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = settings.language.value(
            turkish: "islo. Ayarları",
            english: "islo. Settings"
        )
        window.contentViewController = NSHostingController(rootView: rootView)
        window.isReleasedWhenClosed = false
        centerOnPrimaryDisplay(
            window,
            contentSize: NSSize(width: 940, height: 690)
        )

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present(destination: SettingsDestination? = nil) {
        if let destination {
            router.requestedDestination = destination
        }
        router.isWindowVisible = true
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // NSWindowController may apply its cascade position after showWindow.
        // Center on the next run-loop pass so our final geometry wins.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            centerOnPrimaryDisplay(
                window,
                contentSize: NSSize(width: 940, height: 690)
            )
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(settings: AppSettings, onComplete: @escaping () -> Void) {
        let rootView = OnboardingView(
            settings: settings,
            onComplete: onComplete
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = settings.language.value(
            turkish: "islo.'ya Hoş Geldiniz",
            english: "Welcome to islo."
        )
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentViewController = NSHostingController(rootView: rootView)
        window.isReleasedWhenClosed = false
        centerOnPrimaryDisplay(
            window,
            contentSize: NSSize(width: 1040, height: 680)
        )

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)


        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            centerOnPrimaryDisplay(
                window,
                contentSize: NSSize(width: 1040, height: 680)
            )
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
private func centerOnPrimaryDisplay(
    _ window: NSWindow,
    contentSize: NSSize
) {
    guard let screen = NSScreen.screens.first ?? NSScreen.main else {
        window.center()
        return
    }

    window.setContentSize(contentSize)
    let visibleFrame = screen.visibleFrame
    let windowSize = window.frame.size
    window.setFrameOrigin(
        NSPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2
        )
    )
}

extension SettingsWindowController: NSWindowDelegate {
    /// The window is only hidden on close, so its views keep running;
    /// this stops their once-a-second permission checks.
    func windowWillClose(_ notification: Notification) {
        router.isWindowVisible = false
    }
}
