import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

enum PermissionState: Equatable {
    case granted
    case missing
    case notAsked
    /// Automation can only be checked while the target app runs.
    case appClosed
    case appNotInstalled
}

/// Apps islo. controls through Apple Events.
enum AutomationTarget: String, CaseIterable, Identifiable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case liquidGlass

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .system: language.value(turkish: "Sistem", english: "System")
        case .light: language.value(turkish: "Beyaz", english: "Light")
        case .dark: language.value(turkish: "Siyah", english: "Dark")
        case .liquidGlass: "Liquid Glass"
        }
    }

    func subtitle(language: AppLanguage) -> String {
        switch self {
        case .system:
            language.value(
                turkish: "macOS görünümünü izler",
                english: "Follows macOS appearance"
            )
        case .light:
            language.value(
                turkish: "Aydınlık beyaz kontroller",
                english: "Bright white controls"
            )
        case .dark:
            language.value(
                turkish: "Derin siyah kontroller",
                english: "Deep black controls"
            )
        case .liquidGlass:
            language.value(
                turkish: "Sistem camı ve canlı yansımalar",
                english: "System glass and live reflections"
            )
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        case .liquidGlass: "sparkles"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        case .liquidGlass: nil
        }
    }

    var isAvailable: Bool {
        switch self {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                return true
            }
            return false
        default:
            return true
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case turkish
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turkish: "Türkçe"
        case .english: "English"
        }
    }

    func value(turkish: String, english: String) -> String {
        switch self {
        case .turkish: turkish
        case .english: english
        }
    }
}

enum NotchIdleMode: String, CaseIterable, Identifiable {
    case visibleIsland
    case hiddenMini

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .visibleIsland:
            language.value(
                turkish: "Görünür Ada",
                english: "Visible Island"
            )
        case .hiddenMini:
            language.value(
                turkish: "Gizli Mini",
                english: "Hidden Mini"
            )
        }
    }

    func subtitle(language: AppLanguage) -> String {
        switch self {
        case .visibleIsland:
            language.value(
                turkish: "Müzik çalarken kapak ve dalga çentiğin yanında belirir; çalmadığında standart çentiğe döner.",
                english: "Artwork and the wave appear beside the notch while music plays; otherwise it returns to the standard notch."
            )
        case .hiddenMini:
            language.value(
                turkish: "Boştayken kamera çentiğinin içinde tamamen kaybolur.",
                english: "Disappears completely into the camera notch while idle."
            )
        }
    }

    var symbolName: String {
        switch self {
        case .visibleIsland: "rectangle.expand.vertical"
        case .hiddenMini: "eye.slash.fill"
        }
    }
}

enum NotchActivationMode: String, CaseIterable, Identifiable {
    case hover
    case click
    case activationZone

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .hover:
            language.value(
                turkish: "Üzerine gelince",
                english: "On hover"
            )
        case .click:
            language.value(
                turkish: "Yalnızca tıklayınca",
                english: "Only on click"
            )
        case .activationZone:
            language.value(
                turkish: "Orta etkin alana gelince",
                english: "On center activation zone"
            )
        }
    }

    func subtitle(language: AppLanguage) -> String {
        switch self {
        case .hover:
            language.value(
                turkish: "İşaretçi islo.'nun herhangi bir yerine geldiğinde açılır.",
                english: "Opens when the pointer reaches any part of islo.."
            )
        case .click:
            language.value(
                turkish: "Kendiliğinden açılmaz; kompakt görünüme tıklamanız gerekir.",
                english: "Never opens automatically; click the compact island to open it."
            )
        case .activationZone:
            language.value(
                turkish: "Yalnızca çentiğin üst-orta bölümüne geldiğinizde açılır.",
                english: "Opens only when the pointer reaches the top-center notch area."
            )
        }
    }
}

enum HomeWidgetStyle: String, CaseIterable, Identifiable {
    case balanced
    case media
    case focus
    case day

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .balanced: language.value(turkish: "Dengeli", english: "Balanced")
        case .media: language.value(turkish: "Müzik", english: "Music")
        case .focus: language.value(turkish: "Odak", english: "Focus")
        case .day: language.value(turkish: "Günüm", english: "My Day")
        }
    }
}

/// The theme colour used across the notch and islo.'s windows.
enum AccentTheme: String, CaseIterable, Identifiable {
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case graphite

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: Color(red: 0.27, green: 0.55, blue: 1.0)
        case .purple: Color(red: 0.68, green: 0.42, blue: 1.0)
        case .pink: Color(red: 1.0, green: 0.38, blue: 0.62)
        case .red: Color(red: 1.0, green: 0.33, blue: 0.31)
        case .orange: Color(red: 1.0, green: 0.58, blue: 0.2)
        case .yellow: Color(red: 1.0, green: 0.8, blue: 0.2)
        case .green: Color(red: 0.25, green: 0.82, blue: 0.42)
        case .mint: Color(red: 0.3, green: 0.88, blue: 0.75)
        case .teal: Color(red: 0.2, green: 0.74, blue: 0.86)
        case .graphite: Color(white: 0.66)
        }
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .blue: language.value(turkish: "Mavi", english: "Blue")
        case .purple: language.value(turkish: "Mor", english: "Purple")
        case .pink: language.value(turkish: "Pembe", english: "Pink")
        case .red: language.value(turkish: "Kırmızı", english: "Red")
        case .orange: language.value(turkish: "Turuncu", english: "Orange")
        case .yellow: language.value(turkish: "Sarı", english: "Yellow")
        case .green: language.value(turkish: "Yeşil", english: "Green")
        case .mint: language.value(turkish: "Nane", english: "Mint")
        case .teal: language.value(turkish: "Turkuaz", english: "Teal")
        case .graphite: language.value(turkish: "Grafit", english: "Graphite")
        }
    }
}

/// What the notch shows when a notification arrives.
enum NotificationPreviewStyle: String, CaseIterable, Identifiable {
    case content
    case countOnly

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .content:
            language.value(turkish: "İçeriği göster", english: "Show content")
        case .countOnly:
            language.value(turkish: "Yalnızca \u{201C}1 yeni bildirim\u{201D}", english: "Only \u{201C}1 new notification\u{201D}")
        }
    }
}

/// How strongly the theme colour tints the dark dashboard surface.
enum SurfaceTone: String, CaseIterable, Identifiable {
    case black
    case subtle
    case medium
    case vivid

    var id: String { rawValue }

    var tintOpacity: Double {
        switch self {
        case .black: 0
        case .subtle: 0.22
        case .medium: 0.4
        case .vivid: 0.62
        }
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .black: language.value(turkish: "Saf siyah", english: "Pure black")
        case .subtle: language.value(turkish: "Hafif", english: "Subtle")
        case .medium: language.value(turkish: "Orta", english: "Medium")
        case .vivid: language.value(turkish: "Canlı", english: "Vivid")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let theme = "appearance.theme"
        static let language = "general.language"
        static let notchIdleMode = "appearance.notchIdleMode"
        static let activationMode = "interaction.activationMode"
        static let expandOnHover = "interaction.expandOnHover"
        static let collapseDelay = "interaction.collapseDelay"
        static let showOnTrackChange = "interaction.showOnTrackChange"
        static let trackChangeDisplayDuration = "interaction.trackChangeDisplayDuration"
        static let hideInFullScreen = "interaction.hideInFullScreen"
        static let dashboardCommandEchoEnabled = "dashboard.commandEcho.enabled"
        static let dashboardFocusTimerEnabled = "dashboard.focusTimer.enabled"
        static let liveTimerInNotch = "dashboard.liveTimer.enabled"
        static let calendarEnabled = "dashboard.calendar.enabled"
        static let calendarAlertsEnabled = "dashboard.calendar.alerts"
        static let devicesHUDEnabled = "dashboard.devices.enabled"
        static let privacyIndicatorEnabled = "dashboard.privacy.enabled"
        static let lyricsEnabled = "dashboard.lyrics.enabled"
        static let dashboardKeepAwakeEnabled = "dashboard.keepAwake.enabled"
        static let dashboardFileShelfEnabled = "dashboard.fileShelf.enabled"
        static let dashboardNotificationsEnabled = "dashboard.notifications.enabled"
        static let notificationPreviewStyle = "dashboard.notifications.preview"
        static let homeWidgetStyle = "dashboard.homeWidgetStyle"
        static let legacySceneStyle = "appearance.notchSceneStyle"
        static let accentTheme = "appearance.accentTheme"
        static let surfaceTone = "appearance.surfaceTone"
        static let onboardingCompleted = "onboarding.completed"
        static let permissionReminderBuild = "permissions.reminderBuild"
    }

    private let defaults: UserDefaults

    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            applyApplicationAppearance()
        }
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
        }
    }

    @Published var notchIdleMode: NotchIdleMode {
        didSet {
            defaults.set(notchIdleMode.rawValue, forKey: Key.notchIdleMode)
        }
    }

    @Published var activationMode: NotchActivationMode {
        didSet {
            defaults.set(activationMode.rawValue, forKey: Key.activationMode)
        }
    }

    @Published var collapseDelay: Double {
        didSet {
            let clampedValue = min(max(collapseDelay, 0.15), 1.2)
            defaults.set(clampedValue, forKey: Key.collapseDelay)
        }
    }

    @Published var showOnTrackChange: Bool {
        didSet {
            defaults.set(showOnTrackChange, forKey: Key.showOnTrackChange)
        }
    }

    @Published var trackChangeDisplayDuration: Double {
        didSet {
            let clampedValue = min(max(trackChangeDisplayDuration, 2), 8)
            defaults.set(
                clampedValue,
                forKey: Key.trackChangeDisplayDuration
            )
        }
    }

    @Published var hideInFullScreen: Bool {
        didSet {
            defaults.set(hideInFullScreen, forKey: Key.hideInFullScreen)
        }
    }

    @Published var dashboardCommandEchoEnabled: Bool {
        didSet { defaults.set(dashboardCommandEchoEnabled, forKey: Key.dashboardCommandEchoEnabled) }
    }

    @Published var dashboardFocusTimerEnabled: Bool {
        didSet { defaults.set(dashboardFocusTimerEnabled, forKey: Key.dashboardFocusTimerEnabled) }
    }

    /// Reads the user's calendars for the next event.
    @Published var calendarEnabled: Bool {
        didSet { defaults.set(calendarEnabled, forKey: Key.calendarEnabled) }
    }

    /// Widens the notch shortly before a meeting starts.
    @Published var calendarAlertsEnabled: Bool {
        didSet { defaults.set(calendarAlertsEnabled, forKey: Key.calendarAlertsEnabled) }
    }

    /// Charger plugged in or out, low battery, and headphone batteries.
    @Published var devicesHUDEnabled: Bool {
        didSet { defaults.set(devicesHUDEnabled, forKey: Key.devicesHUDEnabled) }
    }

    /// Synced lyrics in the song card, fetched from LRCLIB.
    @Published var lyricsEnabled: Bool {
        didSet { defaults.set(lyricsEnabled, forKey: Key.lyricsEnabled) }
    }

    /// A dot and the app's name while the camera or microphone is in use.
    @Published var privacyIndicatorEnabled: Bool {
        didSet { defaults.set(privacyIndicatorEnabled, forKey: Key.privacyIndicatorEnabled) }
    }

    /// Shows a running countdown in the closed notch's wings.
    @Published var liveTimerInNotch: Bool {
        didSet { defaults.set(liveTimerInNotch, forKey: Key.liveTimerInNotch) }
    }

    @Published var dashboardKeepAwakeEnabled: Bool {
        didSet { defaults.set(dashboardKeepAwakeEnabled, forKey: Key.dashboardKeepAwakeEnabled) }
    }

    @Published var dashboardFileShelfEnabled: Bool {
        didSet { defaults.set(dashboardFileShelfEnabled, forKey: Key.dashboardFileShelfEnabled) }
    }

    @Published var dashboardNotificationsEnabled: Bool {
        didSet { defaults.set(dashboardNotificationsEnabled, forKey: Key.dashboardNotificationsEnabled) }
    }

    @Published var notificationPreviewStyle: NotificationPreviewStyle {
        didSet { defaults.set(notificationPreviewStyle.rawValue, forKey: Key.notificationPreviewStyle) }
    }

    @Published var homeWidgetStyle: HomeWidgetStyle {
        didSet { defaults.set(homeWidgetStyle.rawValue, forKey: Key.homeWidgetStyle) }
    }

    @Published var accentTheme: AccentTheme {
        didSet { defaults.set(accentTheme.rawValue, forKey: Key.accentTheme) }
    }

    @Published var surfaceTone: SurfaceTone {
        didSet { defaults.set(surfaceTone.rawValue, forKey: Key.surfaceTone) }
    }

    @Published private(set) var onboardingCompleted: Bool
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginRequiresApproval: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var automationStates: [AutomationTarget: PermissionState] = [:]
    private var isCheckingAutomation = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let savedTheme = AppTheme(
            rawValue: defaults.string(forKey: Key.theme) ?? ""
        ) ?? .system
        theme = savedTheme.isAvailable ? savedTheme : .system

        language = AppLanguage(
            rawValue: defaults.string(forKey: Key.language) ?? ""
        ) ?? .turkish

        notchIdleMode = NotchIdleMode(
            rawValue: defaults.string(forKey: Key.notchIdleMode) ?? ""
        ) ?? .visibleIsland

        if let savedMode = NotchActivationMode(
            rawValue: defaults.string(forKey: Key.activationMode) ?? ""
        ) {
            activationMode = savedMode
        } else {
            // Preserve the behavior selected in islo 1.5.
            let legacyHoverEnabled = defaults.object(
                forKey: Key.expandOnHover
            ) == nil || defaults.bool(forKey: Key.expandOnHover)
            activationMode = legacyHoverEnabled ? .hover : .click
        }

        if defaults.object(forKey: Key.collapseDelay) == nil {
            collapseDelay = 0.28
        } else {
            collapseDelay = min(
                max(defaults.double(forKey: Key.collapseDelay), 0.15),
                1.2
            )
        }


        if defaults.object(forKey: Key.showOnTrackChange) == nil {
            showOnTrackChange = true
        } else {
            showOnTrackChange = defaults.bool(forKey: Key.showOnTrackChange)
        }

        if defaults.object(forKey: Key.trackChangeDisplayDuration) == nil {
            trackChangeDisplayDuration = 3.5
        } else {
            trackChangeDisplayDuration = min(
                max(
                    defaults.double(forKey: Key.trackChangeDisplayDuration),
                    2
                ),
                8
            )
        }

        hideInFullScreen = defaults.bool(forKey: Key.hideInFullScreen)

        dashboardCommandEchoEnabled = Self.bool(
            forKey: Key.dashboardCommandEchoEnabled,
            defaults: defaults,
            fallback: true
        )
        dashboardFocusTimerEnabled = Self.bool(
            forKey: Key.dashboardFocusTimerEnabled,
            defaults: defaults,
            fallback: true
        )
        liveTimerInNotch = Self.bool(
            forKey: Key.liveTimerInNotch,
            defaults: defaults,
            fallback: true
        )
        calendarEnabled = Self.bool(forKey: Key.calendarEnabled, defaults: defaults, fallback: true)
        calendarAlertsEnabled = Self.bool(forKey: Key.calendarAlertsEnabled, defaults: defaults, fallback: true)
        devicesHUDEnabled = Self.bool(forKey: Key.devicesHUDEnabled, defaults: defaults, fallback: true)
        privacyIndicatorEnabled = Self.bool(forKey: Key.privacyIndicatorEnabled, defaults: defaults, fallback: true)
        lyricsEnabled = Self.bool(forKey: Key.lyricsEnabled, defaults: defaults, fallback: true)
        dashboardKeepAwakeEnabled = Self.bool(
            forKey: Key.dashboardKeepAwakeEnabled,
            defaults: defaults,
            fallback: true
        )
        dashboardFileShelfEnabled = Self.bool(
            forKey: Key.dashboardFileShelfEnabled,
            defaults: defaults,
            fallback: true
        )
        dashboardNotificationsEnabled = Self.bool(
            forKey: Key.dashboardNotificationsEnabled,
            defaults: defaults,
            fallback: true
        )
        notificationPreviewStyle = NotificationPreviewStyle(
            rawValue: defaults.string(forKey: Key.notificationPreviewStyle) ?? ""
        ) ?? .content
        homeWidgetStyle = HomeWidgetStyle(
            rawValue: defaults.string(forKey: Key.homeWidgetStyle) ?? ""
        ) ?? .balanced
        // The colour + tone theme replaces the old fixed scenes; carry an
        // existing scene over to its closest colour and tone.
        let legacyScene: (AccentTheme, SurfaceTone)? = switch defaults.string(
            forKey: Key.legacySceneStyle
        ) {
        case "graphite": (.graphite, .subtle)
        case "ember": (.orange, .medium)
        case "aurora": (.teal, .medium)
        case "album": (.pink, .medium)
        default: nil
        }
        accentTheme = AccentTheme(
            rawValue: defaults.string(forKey: Key.accentTheme) ?? ""
        ) ?? legacyScene?.0 ?? .blue
        surfaceTone = SurfaceTone(
            rawValue: defaults.string(forKey: Key.surfaceTone) ?? ""
        ) ?? legacyScene?.1 ?? .subtle

        onboardingCompleted = defaults.bool(
            forKey: Key.onboardingCompleted
        )

        let loginItemStatus = SMAppService.mainApp.status
        launchAtLogin = Self.isLoginItemRequested(loginItemStatus)
        launchAtLoginRequiresApproval = loginItemStatus == .requiresApproval
        launchAtLoginError = nil
    }

    func completeOnboarding() {
        onboardingCompleted = true
        defaults.set(true, forKey: Key.onboardingCompleted)
    }

    func applyApplicationAppearance() {
        switch theme {
        case .system, .liquidGlass:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func resetInteractionDefaults() {
        activationMode = .hover
        collapseDelay = 0.28
        showOnTrackChange = true
        trackChangeDisplayDuration = 3.5
        hideInFullScreen = false
    }

    func resetDashboardFeatureDefaults() {
        dashboardCommandEchoEnabled = true
        dashboardFocusTimerEnabled = true
        liveTimerInNotch = true
        calendarEnabled = true
        calendarAlertsEnabled = true
        devicesHUDEnabled = true
        privacyIndicatorEnabled = true
        lyricsEnabled = true
        dashboardKeepAwakeEnabled = true
        dashboardFileShelfEnabled = true
        dashboardNotificationsEnabled = true
        notificationPreviewStyle = .content
    }

    private static func bool(
        forKey key: String,
        defaults: UserDefaults,
        fallback: Bool
    ) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp

        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval:
                    break
                case .notRegistered, .notFound:
                    try service.register()
                @unknown default:
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }

            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }

        refreshLaunchAtLoginState()
    }

    func refreshLaunchAtLoginState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = Self.isLoginItemRequested(status)
        launchAtLoginRequiresApproval = status == .requiresApproval
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Permissions that are missing and break a feature (not ones macOS
    /// simply hasn't asked about yet).
    var missingPermissionCount: Int {
        (isAccessibilityTrusted ? 0 : 1)
            + automationStates.values.filter { $0 == .missing }.count
            + (calendarEnabled && CalendarManager.shared.authorization == .missing ? 1 : 0)
    }

    /// macOS doesn't notify apps when permissions change, so Settings and
    /// app activation re-read them.
    func refreshPermissionState() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
        }
        CalendarManager.shared.refreshAuthorization()
        refreshAutomationStates()
    }

    func requestAccessibilityPermission() {
        let wasTrusted = AXIsProcessTrusted()
        DispatchQueue.global(qos: .userInitiated).async {
            // After an update macOS can keep an old islo. entry that still
            // looks switched on but no longer matches this copy, and then it
            // never asks again. Clearing islo.'s own entry lets it ask afresh.
            if !wasTrusted {
                Self.resetPermission(service: "Accessibility")
            }
            DispatchQueue.main.async { [weak self] in
                let options = [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                self?.refreshPermissionState()
            }
            // Open the list too, in case macOS shows no prompt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard self?.isAccessibilityTrusted == false else { return }
                self?.openAccessibilitySettings()
            }
        }
    }

    func requestAutomationPermission(for target: AutomationTarget) {
        let previous = automationStates[target]
        DispatchQueue.global(qos: .userInitiated).async {
            // macOS never asks again once access was turned off; resetting
            // islo.'s Automation entries brings the prompt back.
            if previous == .missing {
                Self.resetPermission(service: "AppleEvents")
            }
            let state = Self.automationState(for: target, askUser: true)
            DispatchQueue.main.async { [weak self] in
                self?.refreshPermissionState()
                if state == .missing { self?.openAutomationSettings() }
            }
        }
    }

    func openAccessibilitySettings() {
        openPrivacySettings("Privacy_Accessibility")
    }

    func openAutomationSettings() {
        openPrivacySettings("Privacy_Automation")
    }

    /// Opens Permissions once per version when an update left islo. without
    /// Accessibility; nothing else would tell the user why features stopped.
    func takePermissionReminder() -> Bool {
        guard onboardingCompleted,
              !AXIsProcessTrusted(),
              dashboardCommandEchoEnabled || dashboardNotificationsEnabled else {
            return false
        }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard defaults.string(forKey: Key.permissionReminderBuild) != build else {
            return false
        }
        defaults.set(build, forKey: Key.permissionReminderBuild)
        return true
    }

    private func openPrivacySettings(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshAutomationStates() {
        guard !isCheckingAutomation else { return }
        isCheckingAutomation = true
        DispatchQueue.global(qos: .utility).async {
            var states: [AutomationTarget: PermissionState] = [:]
            for target in AutomationTarget.allCases {
                states[target] = Self.automationState(for: target, askUser: false)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isCheckingAutomation = false
                if states != automationStates { automationStates = states }
            }
        }
    }

    /// Blocks while macOS shows its prompt, so never call it on the main thread.
    nonisolated private static func automationState(
        for target: AutomationTarget,
        askUser: Bool
    ) -> PermissionState {
        guard NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: target.rawValue
        ) != nil else {
            return .appNotInstalled
        }

        var address = AEAddressDesc()
        let status: OSStatus = target.rawValue.withCString { bundleID in
            guard AECreateDesc(
                DescType(typeApplicationBundleID),
                bundleID,
                strlen(bundleID),
                &address
            ) == noErr else {
                return OSStatus(procNotFound)
            }
            defer { AEDisposeDesc(&address) }
            return AEDeterminePermissionToAutomateTarget(
                &address,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                askUser
            )
        }

        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .missing
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .appClosed  // procNotFound: macOS only answers while it runs
        }
    }

    /// Removes islo.'s own entry for a privacy service.
    nonisolated private static func resetPermission(service: String) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private static func isLoginItemRequested(
        _ status: SMAppService.Status
    ) -> Bool {
        status == .enabled || status == .requiresApproval
    }
}
