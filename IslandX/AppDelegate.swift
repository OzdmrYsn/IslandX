import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let updateManager = UpdateManager.shared
    private let powerMonitor = PowerMonitor()

    private var mediaManager: MediaManager?
    private var notchWindowController: FloatingNotchWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var statusItem: NSStatusItem?
    private var themeMenuItems: [AppTheme: NSMenuItem] = [:]
    private var notchModeMenuItems: [NotchIdleMode: NSMenuItem] = [:]
    private var activationModeMenuItems: [NotchActivationMode: NSMenuItem] = [:]
    private var launchAtLoginMenuItem: NSMenuItem?
    private var checkForUpdatesMenuItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular activation policy keeps the custom app icon visible in Dock.
        // The floating panel itself remains borderless and non-activating.
        NSApp.setActivationPolicy(.regular)
        applyDockIcon()
        settings.applyApplicationAppearance()
        configureMenuBarItem()
        observeSettings()
        configureNotifications()

        let mediaManager = MediaManager()
        let windowController = FloatingNotchWindowController(
            mediaManager: mediaManager,
            powerMonitor: powerMonitor,
            settings: settings
        )

        self.mediaManager = mediaManager
        notchWindowController = windowController

        windowController.showWindow(nil)
        mediaManager.startMonitoring()
        powerMonitor.startMonitoring()

        if !settings.onboardingCompleted {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mediaManager?.stopMonitoring()
        powerMonitor.stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settings.refreshLaunchAtLoginState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        notchWindowController?.showWindow(nil)

        if !settings.onboardingCompleted {
            showOnboarding()
        }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for (theme, item) in themeMenuItems {
            item.state = settings.theme == theme ? .on : .off
        }
        for (mode, item) in notchModeMenuItems {
            item.state = settings.notchIdleMode == mode ? .on : .off
        }
        for (mode, item) in activationModeMenuItems {
            item.state = settings.activationMode == mode ? .on : .off
        }

        launchAtLoginMenuItem?.state = settings.launchAtLogin ? .on : .off
        checkForUpdatesMenuItem?.isEnabled = updateManager.canCheckForUpdates
    }

    private func configureNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsFromNotification),
            name: .islandXShowSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showOnboardingFromNotification),
            name: .islandXShowOnboarding,
            object: nil
        )
    }

    /// LaunchServices and Dock can keep the previous icon for a development
    /// bundle with an unchanged identifier. Applying the compiled ICNS at runtime
    /// guarantees that the current build is what Dock and onboarding display.
    private func applyDockIcon() {
        guard let iconURL = Bundle.main.url(
            forResource: "AppIcon",
            withExtension: "icns"
        ), let icon = NSImage(contentsOf: iconURL) else {
            return
        }

        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }

    private func configureMenuBarItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        themeMenuItems.removeAll()
        notchModeMenuItems.removeAll()
        activationModeMenuItems.removeAll()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "waveform.circle.fill",
                accessibilityDescription: "IslandX"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "IslandX Media Controls"
        }

        let menu = NSMenu(title: "IslandX")
        menu.delegate = self

        menu.addItem(
            menuItem(
                title: localized("IslandX'i Göster", "Show IslandX"),
                action: #selector(showIsland)
            )
        )
        menu.addItem(.separator())

        let appearanceTitle = localized("Görünüm", "Appearance")
        let appearanceItem = NSMenuItem(title: appearanceTitle, action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: appearanceTitle)
        for (index, theme) in AppTheme.allCases.enumerated() {
            let themeItem = menuItem(
                title: theme.title(language: settings.language),
                action: #selector(selectTheme(_:))
            )
            themeItem.tag = index
            themeItem.isEnabled = theme.isAvailable
            appearanceMenu.addItem(themeItem)
            themeMenuItems[theme] = themeItem
        }
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        let notchModeTitle = localized(
            "Çentik Boşta Görünümü",
            "Notch Idle Appearance"
        )
        let notchModeItem = NSMenuItem(
            title: notchModeTitle,
            action: nil,
            keyEquivalent: ""
        )
        let notchModeMenu = NSMenu(title: notchModeTitle)
        for (index, mode) in NotchIdleMode.allCases.enumerated() {
            let modeItem = menuItem(
                title: mode.title(language: settings.language),
                action: #selector(selectNotchIdleMode(_:))
            )
            modeItem.tag = index
            notchModeMenu.addItem(modeItem)
            notchModeMenuItems[mode] = modeItem
        }
        notchModeItem.submenu = notchModeMenu
        menu.addItem(notchModeItem)

        let activationTitle = localized(
            "Açılma Davranışı",
            "Opening Behavior"
        )
        let activationItem = NSMenuItem(
            title: activationTitle,
            action: nil,
            keyEquivalent: ""
        )
        let activationMenu = NSMenu(title: activationTitle)
        for (index, mode) in NotchActivationMode.allCases.enumerated() {
            let modeItem = menuItem(
                title: mode.title(language: settings.language),
                action: #selector(selectActivationMode(_:))
            )
            modeItem.tag = index
            activationMenu.addItem(modeItem)
            activationModeMenuItems[mode] = modeItem
        }
        activationItem.submenu = activationMenu
        menu.addItem(activationItem)

        let launchItem = menuItem(
            title: localized("Mac Açılışında Başlat", "Launch at Login"),
            action: #selector(toggleLaunchAtLogin(_:))
        )
        launchAtLoginMenuItem = launchItem
        menu.addItem(launchItem)

        menu.addItem(
            menuItem(
                title: localized("Ayarlar…", "Settings…"),
                action: #selector(showSettings)
            )
        )
        menu.addItem(
            menuItem(
                title: localized("Tanıtımı Göster", "Show Welcome Guide"),
                action: #selector(showOnboardingFromMenu)
            )
        )
        let updateItem = menuItem(
            title: localized("Güncellemeleri Denetle…", "Check for Updates…"),
            action: #selector(checkForUpdates)
        )
        updateItem.isEnabled = updateManager.canCheckForUpdates
        checkForUpdatesMenuItem = updateItem
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: localized("IslandX'ten Çık", "Quit IslandX"),
                action: #selector(quitApplication),
                keyEquivalent: "q"
            )
        )

        item.menu = menu
        statusItem = item
    }

    private func observeSettings() {
        settings.$language
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.configureMenuBarItem()
            }
            .store(in: &cancellables)
    }

    private func localized(_ turkish: String, _ english: String) -> String {
        settings.language.value(turkish: turkish, english: english)
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = self
        return item
    }

    @objc
    private func showIsland() {
        notchWindowController?.showWindow(nil)
        NotificationCenter.default.post(name: .islandXExpand, object: nil)
    }

    @objc
    private func selectTheme(_ sender: NSMenuItem) {
        guard AppTheme.allCases.indices.contains(sender.tag) else { return }
        let theme = AppTheme.allCases[sender.tag]
        guard theme.isAvailable else { return }
        settings.theme = theme
    }

    @objc
    private func selectActivationMode(_ sender: NSMenuItem) {
        guard NotchActivationMode.allCases.indices.contains(sender.tag) else {
            return
        }
        settings.activationMode = NotchActivationMode.allCases[sender.tag]
    }

    @objc
    private func selectNotchIdleMode(_ sender: NSMenuItem) {
        guard NotchIdleMode.allCases.indices.contains(sender.tag) else {
            return
        }
        settings.notchIdleMode = NotchIdleMode.allCases[sender.tag]
    }

    @objc
    private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        settings.setLaunchAtLogin(!settings.launchAtLogin)
    }

    @objc
    private func checkForUpdates() {
        updateManager.checkForUpdates()
    }

    @objc
    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                onShowOnboarding: { [weak self] in
                    self?.showOnboarding()
                }
            )
        }

        settingsWindowController?.present()
    }

    private func showOnboarding() {
        if onboardingWindowController?.window?.isVisible == true {
            onboardingWindowController?.present()
            return
        }

        let controller = OnboardingWindowController(
            settings: settings,
            onComplete: { [weak self] in
                self?.onboardingWindowController?.close()
                self?.onboardingWindowController = nil
            }
        )
        onboardingWindowController = controller
        controller.present()
    }

    @objc
    private func showSettingsFromNotification() {
        showSettings()
    }

    @objc
    private func showOnboardingFromNotification() {
        showOnboarding()
    }

    @objc
    private func showOnboardingFromMenu() {
        showOnboarding()
    }

    @objc
    private func quitApplication() {
        NSApp.terminate(nil)
    }
}
