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

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let theme = "appearance.theme"
        static let language = "general.language"
        static let notchIdleMode = "appearance.notchIdleMode"
        static let expandOnHover = "interaction.expandOnHover"
        static let collapseDelay = "interaction.collapseDelay"
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

    @Published var expandOnHover: Bool {
        didSet {
            defaults.set(expandOnHover, forKey: Key.expandOnHover)
        }
    }

    @Published var collapseDelay: Double {
        didSet {
            let clampedValue = min(max(collapseDelay, 0.15), 1.2)
            defaults.set(clampedValue, forKey: Key.collapseDelay)
        }
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

        if defaults.object(forKey: Key.expandOnHover) == nil {
            expandOnHover = true
        } else {
            expandOnHover = defaults.bool(forKey: Key.expandOnHover)
        }

        if defaults.object(forKey: Key.collapseDelay) == nil {
            collapseDelay = 0.28
        } else {
            collapseDelay = min(
                max(defaults.double(forKey: Key.collapseDelay), 0.15),
                1.2
            )
        }

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
        expandOnHover = true
        collapseDelay = 0.28
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
