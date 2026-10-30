import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let updateManager = UpdateManager.shared

    private var mediaManager: MediaManager?
    private let commandEchoManager = CommandEchoManager()
    private let focusTimerManager = FocusTimerManager()
    private let keepAwakeManager = KeepAwakeManager()
    private let fileShelfManager = FileShelfManager()
    private let clipboardHistoryManager = ClipboardHistoryManager()
    private let notificationMonitor = NotificationMonitor()
    private lazy var systemHUDInterceptor = SystemHUDInterceptor(
        onVolume: { [weak self] value in
            self?.commandEchoManager.showHandledVolume(value)
        },
        onBrightness: { [weak self] value in
            self?.commandEchoManager.showHandledBrightness(value)
        }
    )
    private var notchWindowController: FloatingNotchWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var statusItem: NSStatusItem?
    private var themeMenuItems: [AppTheme: NSMenuItem] = [:]
    private var notchModeMenuItems: [NotchIdleMode: NSMenuItem] = [:]
    private var activationModeMenuItems: [NotchActivationMode: NSMenuItem] = [:]
    private var launchAtLoginMenuItem: NSMenuItem?
    private var checkForUpdatesMenuItem: NSMenuItem?
    private var missingPermissionMenuItems: [NSMenuItem] = []
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app lives in the menu bar and notch without occupying the Dock.
        NSApp.setActivationPolicy(.accessory)
        applyDockIcon()
        settings.applyApplicationAppearance()
        configureMenuBarItem()
        observeSettings()
        configureNotifications()

        let mediaManager = MediaManager()
        let windowController = FloatingNotchWindowController(
            mediaManager: mediaManager,
            settings: settings,
            commandEchoManager: commandEchoManager,
            focusTimerManager: focusTimerManager,
            keepAwakeManager: keepAwakeManager,
            fileShelfManager: fileShelfManager,
            clipboardHistoryManager: clipboardHistoryManager,
            notificationMonitor: notificationMonitor
        )

        self.mediaManager = mediaManager
        notchWindowController = windowController

        windowController.showWindow(nil)
        mediaManager.startMonitoring()
        commandEchoManager.startMonitoring()
        clipboardHistoryManager.startMonitoring()
        fileShelfManager.startDragMonitoring()

        if !settings.onboardingCompleted {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        } else if settings.takePermissionReminder() {
            // An update can cost islo. its Accessibility access; show the
            // user where to restore it instead of features silently failing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.presentSettings(destination: .permissions)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mediaManager?.stopMonitoring()
        commandEchoManager.stopMonitoring()
        clipboardHistoryManager.stopMonitoring()
        fileShelfManager.stopDragMonitoring()
        notificationMonitor.setEnabled(false)
        keepAwakeManager.setActive(false)
        systemHUDInterceptor.setEnabled(false)
        NotificationCenter.default.removeObserver(self)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        CalendarManager.shared.refresh()
        settings.refreshLaunchAtLoginState()
        settings.refreshPermissionState()
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
        settings.refreshPermissionState()
        updateMissingPermissionMenuItems()
    }

    private func updateMissingPermissionMenuItems() {
        let isHidden = settings.missingPermissionCount == 0
        missingPermissionMenuItems.forEach { $0.isHidden = isHidden }
    }

    private func configureNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsFromNotification),
            name: .isloShowSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showOnboardingFromNotification),
            name: .isloShowOnboarding,
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
            if let iconURL = Bundle.main.url(
                forResource: "AppIcon",
                withExtension: "icns"
            ), let image = NSImage(contentsOf: iconURL) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = false
                image.accessibilityDescription = "islo."
                button.image = image
            }
            button.toolTip = "islo."
        }

        let menu = NSMenu(title: "islo.")
        menu.delegate = self

        let permissionItem = menuItem(
            title: localized("İzin eksik — Düzelt…", "Permission missing — Fix…"),
            action: #selector(showPermissionSettings)
        )
        permissionItem.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        let permissionSeparator = NSMenuItem.separator()
        missingPermissionMenuItems = [permissionItem, permissionSeparator]
        menu.addItem(permissionItem)
        menu.addItem(permissionSeparator)
        updateMissingPermissionMenuItems()

        menu.addItem(
            menuItem(
                title: localized("islo.'yu Göster", "Show islo."),
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
                title: localized("islo.'dan Çık", "Quit islo."),
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

        settings.$calendarEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { enabled in CalendarManager.shared.setEnabled(enabled) }
            .store(in: &cancellables)

        settings.$calendarAlertsEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { enabled in CalendarManager.shared.alertsEnabled = enabled }
            .store(in: &cancellables)

        // islo. only takes the volume and brightness keys over while it has
        // its own HUD to show in place of the macOS one.
        settings.$dashboardCommandEchoEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.systemHUDInterceptor.setEnabled(enabled)
            }
            .store(in: &cancellables)

        settings.$dashboardNotificationsEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.notificationMonitor.setEnabled(enabled)
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
        NotificationCenter.default.post(name: .isloExpand, object: nil)
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
    private func showPermissionSettings() {
        presentSettings(destination: .permissions)
    }

    @objc
    private func showSettings() {
        presentSettings(destination: nil)
    }

    private func presentSettings(destination: SettingsDestination?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                onShowOnboarding: { [weak self] in
                    self?.showOnboarding()
                }
            )
        }

        settingsWindowController?.present(destination: destination)
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
