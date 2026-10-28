import SwiftUI

@main
struct IslandXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        Settings {
            SettingsView(settings: settings) {
                NotificationCenter.default.post(
                    name: .islandXShowOnboarding,
                    object: nil
                )
            }
        }
    }
}

extension Notification.Name {
    static let islandXShowOnboarding = Notification.Name(
        "IslandX.showOnboarding"
    )

    static let islandXShowSettings = Notification.Name(
        "IslandX.showSettings"
    )

    static let islandXExpand = Notification.Name(
        "IslandX.expand"
    )

    static let islandXCollapse = Notification.Name(
        "IslandX.collapse"
    )
}
