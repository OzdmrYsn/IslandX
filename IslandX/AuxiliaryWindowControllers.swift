import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings, onShowOnboarding: @escaping () -> Void) {
        let rootView = SettingsView(
            settings: settings,
            onShowOnboarding: onShowOnboarding
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 740),
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
            contentSize: NSSize(width: 580, height: 740)
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

        // NSWindowController may apply its cascade position after showWindow.
        // Center on the next run-loop pass so our final geometry wins.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            centerOnPrimaryDisplay(
                window,
                contentSize: NSSize(width: 580, height: 740)
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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
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
            contentSize: NSSize(width: 680, height: 600)
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
                contentSize: NSSize(width: 680, height: 600)
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
