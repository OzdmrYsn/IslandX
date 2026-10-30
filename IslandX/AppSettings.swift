import AppKit
import ServiceManagement
import SwiftUI

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
                turkish: "Kapak ve oynatma dalgası çentiğin yanında kalır.",
                english: "Artwork and the playback wave remain beside the notch."
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

enum IslandContentMode: String, CaseIterable, Identifiable {
    case music
    case dashboard

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .music:
            language.value(turkish: "Yalnızca Müzik", english: "Music Only")
        case .dashboard:
            language.value(turkish: "Genel", english: "General")
        }
    }

    func subtitle(language: AppLanguage) -> String {
        switch self {
        case .music:
            language.value(
                turkish: "Kompakt medya denetimleri ve daha sade bir görünüm.",
                english: "Compact media controls with a simpler layout."
            )
        case .dashboard:
            language.value(
                turkish: "Müzik, tarih, saat ve günlük özeti tek geniş görünümde birleştirir.",
                english: "Combines music, date, time, and a daily summary in one wide view."
            )
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
        static let contentMode = "appearance.contentMode"
        static let expandOnHover = "interaction.expandOnHover"
        static let collapseDelay = "interaction.collapseDelay"
        static let showOnTrackChange = "interaction.showOnTrackChange"
        static let trackChangeDisplayDuration = "interaction.trackChangeDisplayDuration"
        static let hideInFullScreen = "interaction.hideInFullScreen"
        static let dashboardCommandEchoEnabled = "dashboard.commandEcho.enabled"
        static let dashboardFocusTimerEnabled = "dashboard.focusTimer.enabled"
        static let dashboardKeepAwakeEnabled = "dashboard.keepAwake.enabled"
        static let dashboardFileShelfEnabled = "dashboard.fileShelf.enabled"
        static let onboardingCompleted = "onboarding.completed"
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

    @Published var contentMode: IslandContentMode {
        didSet {
            defaults.set(contentMode.rawValue, forKey: Key.contentMode)
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

    @Published var dashboardKeepAwakeEnabled: Bool {
        didSet { defaults.set(dashboardKeepAwakeEnabled, forKey: Key.dashboardKeepAwakeEnabled) }
    }

    @Published var dashboardFileShelfEnabled: Bool {
        didSet { defaults.set(dashboardFileShelfEnabled, forKey: Key.dashboardFileShelfEnabled) }
    }

    @Published private(set) var onboardingCompleted: Bool
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginRequiresApproval: Bool
    @Published private(set) var launchAtLoginError: String?

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
            // Preserve the behavior selected in IslandX 1.5.
            let legacyHoverEnabled = defaults.object(
                forKey: Key.expandOnHover
            ) == nil || defaults.bool(forKey: Key.expandOnHover)
            activationMode = legacyHoverEnabled ? .hover : .click
        }

        contentMode = IslandContentMode(
            rawValue: defaults.string(forKey: Key.contentMode) ?? ""
        ) ?? .music

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
        dashboardKeepAwakeEnabled = true
        dashboardFileShelfEnabled = true
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

    private static func isLoginItemRequested(
        _ status: SMAppService.Status
    ) -> Bool {
        status == .enabled || status == .requiresApproval
    }
}
