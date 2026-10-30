import SwiftUI

@main
struct IsloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        Settings {
            SettingsView(settings: settings) {
                NotificationCenter.default.post(
                    name: .isloShowOnboarding,
                    object: nil
                )
            }
        }
    }
}

extension Notification.Name {
    static let isloShowOnboarding = Notification.Name(
        "islo.showOnboarding"
    )

    static let isloShowSettings = Notification.Name(
        "islo.showSettings"
    )

    static let isloExpand = Notification.Name(
        "islo.expand"
    )

    static let isloCollapse = Notification.Name(
        "islo.collapse"
    )
}
