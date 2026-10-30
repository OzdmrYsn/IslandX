import Combine
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general, appearance, interaction, modules, permissions, updates, about
    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .general: language.value(turkish: "Genel", english: "General")
        case .appearance: language.value(turkish: "Görünüm", english: "Appearance")
        case .interaction: language.value(turkish: "Çentik ve Etkileşim", english: "Notch & Interaction")
        case .modules: language.value(turkish: "Araçlar", english: "Utilities")
        case .permissions: language.value(turkish: "İzinler", english: "Permissions")
        case .updates: language.value(turkish: "Güncellemeler", english: "Updates")
        case .about: language.value(turkish: "islo. Hakkında", english: "About islo.")
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .appearance: "circle.lefthalf.filled"
        case .interaction: "macbook.and.iphone"
        case .modules: "square.grid.2x2"
        case .permissions: "lock.shield"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }
}

/// Lets the menu bar and launch reminders open Settings on a given page.
final class SettingsRouter: ObservableObject {
    @Published var requestedDestination: SettingsDestination?
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared
    var router: SettingsRouter?
    var onShowOnboarding: () -> Void = {}
    @State private var selection: SettingsDestination = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider().opacity(0.55)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageHeader
                    selectedPage
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 940, height: 690)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(settings.theme.colorScheme)
        .tint(accent)
        .onReceive(router?.$requestedDestination.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { destination in
            guard let destination else { return }
            selection = destination
            router?.requestedDestination = nil
        }
        // macOS doesn't announce permission changes; re-read them while
        // Settings is open so badges update as soon as access is granted.
        .onAppear(perform: settings.refreshPermissionState)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            settings.refreshPermissionState()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("islo.").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(text("Ayarlar", "Settings")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 24)

            VStack(spacing: 4) {
                ForEach(SettingsDestination.allCases) { destination in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { selection = destination }
                    } label: {
                        HStack(spacing: 8) {
                            Label(destination.title(settings.language), systemImage: destination.symbol)
                            Spacer(minLength: 0)
                            if destination == .permissions, settings.missingPermissionCount > 0 {
                                Text("\(settings.missingPermissionCount)")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(Capsule().fill(Color.orange))
                                    .help(text("Eksik izin var", "A permission is missing"))
                            }
                        }
                            .font(.system(size: 13, weight: selection == destination ? .semibold : .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 36)
                            .foregroundStyle(selection == destination ? accent : .primary)
                            .background(RoundedRectangle(cornerRadius: 9).fill(selection == destination ? accent.opacity(0.12) : .clear))
                            // A clear background isn't hit-testable; make the
                            // whole row clickable, not just its text.
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    // The focus ring on the first row read as a second selection.
                    .modifier(NoFocusRing())
                }
            }
            .padding(.horizontal, 12)

            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Button(text("Tanıtımı yeniden göster", "Show welcome guide")) { onShowOnboarding() }
                    .buttonStyle(.link)
                Text(versionText).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .background(.ultraThinMaterial)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selection.title(settings.language))
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(pageSubtitle).font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var selectedPage: some View {
        switch selection {
        case .general: generalPage
        case .appearance: appearancePage
        case .interaction: interactionPage
        case .modules: modulesPage
        case .permissions: permissionsPage
        case .updates: updatesPage
        case .about: aboutPage
        }
    }

    private var generalPage: some View {
        VStack(spacing: 16) {
            if settings.missingPermissionCount > 0 {
                noticeCard(symbol: "exclamationmark.triangle.fill", message: text("Bazı izinler eksik, bu yüzden bazı özellikler çalışmıyor.", "Some permissions are missing, so some features don't work."), buttonTitle: text("İzinlere git", "Go to Permissions")) {
                    withAnimation(.easeInOut(duration: 0.16)) { selection = .permissions }
                }
            }
            settingsCard(title: text("Tercihler", "Preferences")) {
                settingsRow(symbol: "globe", title: text("Dil", "Language"), subtitle: text("Uygulama arayüzünün dilini seçin.", "Choose the app interface language.")) {
                    Picker("", selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 150)
                }
                rowDivider
                settingsRow(symbol: "power", title: text("Mac açıldığında başlat", "Launch at login"), subtitle: text("islo. oturum açtığınız anda hazır olur.", "islo. is ready when you log in.")) {
                    Toggle("", isOn: launchAtLoginBinding).labelsHidden().toggleStyle(.switch)
                }
            }

            if settings.launchAtLoginRequiresApproval {
                noticeCard(symbol: "exclamationmark.triangle.fill", message: text("Başlangıç izni macOS onayı bekliyor.", "Launch permission is waiting for macOS approval."), buttonTitle: text("Giriş Öğelerini Aç", "Open Login Items"), action: settings.openLoginItemsSettings)
            } else if let error = settings.launchAtLoginError {
                noticeCard(symbol: "xmark.octagon.fill", message: error)
            }
        }
    }

    private var appearancePage: some View {
        VStack(spacing: 16) {
            notchPreview
            settingsCard(title: text("Tema", "Theme")) {
                stackedRow(symbol: "paintpalette.fill", title: text("Renk", "Color"), subtitle: text("Çentikteki simgeler, ilerleme halkası, çalma dalgası ve bu pencere bu rengi kullanır. Seçili: ", "Used by the notch icons, progress ring, playback wave, and this window. Selected: ") + settings.accentTheme.title(language: settings.language)) {
                    AccentSwatchPicker(selection: $settings.accentTheme, language: settings.language)
                }
                rowDivider
                stackedRow(symbol: "drop.halffull", title: text("Ton", "Tone"), subtitle: text("Rengin genişleyen çentiğin koyu yüzeyine ne kadar sineceği. Kamera çentiğinin yanı her zaman siyah kalır.", "How much the color tints the dark surface of the open notch. The area next to the camera always stays black.")) {
                    SurfaceTonePicker(selection: $settings.surfaceTone, accent: accent, language: settings.language)
                }
            }
            settingsCard(title: text("Ana ekran", "Home")) {
                settingsRow(symbol: "rectangle.grid.2x2", title: text("Widget düzeni", "Widget layout"), subtitle: text("Genişleyen çentikte hangi bilginin öne çıkacağını seçin.", "Choose what takes priority in the expanded notch.")) {
                    Picker("", selection: $settings.homeWidgetStyle) {
                        ForEach(HomeWidgetStyle.allCases) { style in
                            Text(style.title(language: settings.language)).tag(style)
                        }
                    }.labelsHidden().frame(width: 150)
                }
            }
            settingsCard(title: text("Pencere görünümü", "Window appearance")) {
                Text(text("Ayarlar ve tanıtım pencerelerinin açık/koyu görünümü. Liquid Glass çentiğe de cam efekti verir.", "Light or dark look for the Settings and welcome windows. Liquid Glass also gives the notch a glass finish."))
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                ThemeChoicePicker(selection: $settings.theme, language: settings.language, accent: accent).padding(.vertical, 4)
            }
        }
    }

    /// A settings row whose control is too wide to sit beside the title.
    private func stackedRow<Content: View>(symbol: String, title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                rowIcon(symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content().padding(.leading, 48)
        }
        .padding(.vertical, 10)
    }

    private var interactionPage: some View {
        VStack(spacing: 16) {
            settingsCard(title: text("Açılma davranışı", "Opening behavior")) {
                settingsRow(symbol: "cursorarrow.motionlines", title: text("Çentiği aç", "Open the notch"), subtitle: settings.activationMode.subtitle(language: settings.language)) {
                    Picker("", selection: $settings.activationMode) {
                        ForEach(NotchActivationMode.allCases) { mode in Text(mode.title(language: settings.language)).tag(mode) }
                    }.labelsHidden().frame(width: 180)
                }
                rowDivider
                toggleRow(symbol: "music.note", title: text("Şarkı değiştiğinde göster", "Show when track changes"), subtitle: text("Yeni parçayı birkaç saniye çentikte gösterir.", "Shows the new track in the notch for a few seconds."), isOn: $settings.showOnTrackChange)
                if settings.showOnTrackChange {
                    rowDivider
                    sliderRow(symbol: "timer", title: text("Gösterim süresi", "Display duration"), value: $settings.trackChangeDisplayDuration, range: 2...8, step: 0.5, valueText: String(format: "%.1f s", settings.trackChangeDisplayDuration))
                }
                rowDivider
                toggleRow(symbol: "rectangle.slash", title: text("Tam ekranda gizle", "Hide in full screen"), subtitle: text("Oyun ve sunumların üzerinde görünmez.", "Stays out of the way during games and presentations."), isOn: $settings.hideInFullScreen)
                rowDivider
                sliderRow(symbol: "arrow.down.right.and.arrow.up.left", title: text("Kapanma gecikmesi", "Collapse delay"), value: $settings.collapseDelay, range: 0.15...1.2, step: 0.05, valueText: String(format: "%.2f s", settings.collapseDelay))
            }
            HStack { Spacer(); Button(text("Etkileşim varsayılanlarını geri yükle", "Restore interaction defaults")) { settings.resetInteractionDefaults() } }
        }
    }

    private var modulesPage: some View {
        VStack(spacing: 16) {
            settingsCard(title: text("Çentik araçları", "Notch utilities")) {
                toggleRow(symbol: "waveform.path", title: "Command Echo", subtitle: text("Ses, parlaklık, kopyalama, ekran görüntüsü ve Caps Lock değişikliklerini islo. içinde gösterir.", "Shows volume, brightness, copy, screenshot, and Caps Lock changes inside islo."), isOn: $settings.dashboardCommandEchoEnabled)
                rowDivider
                toggleRow(symbol: "timer", title: text("Zamanlayıcı + Pomodoro", "Timer + Pomodoro"), subtitle: text("Odaklanma ve mola sürelerini çentikten yönetin.", "Run focus and break sessions from the notch."), isOn: $settings.dashboardFocusTimerEnabled)
                if settings.dashboardFocusTimerEnabled {
                    rowDivider
                    toggleRow(symbol: "hourglass", title: text("Kapalı çentikte geri sayım", "Countdown in the closed notch"), subtitle: text("Zamanlayıcı çalışırken kalan süre çentiğin yanlarında görünür; bitince çentik haber verir.", "While a timer runs, the time left shows beside the notch, which tells you when it ends."), isOn: $settings.liveTimerInNotch)
                }
                rowDivider
                toggleRow(symbol: "cup.and.saucer.fill", title: text("Uyanık Tut", "Keep Awake"), subtitle: text("İstediğiniz sürece Mac'in uykuya geçmesini engeller.", "Prevents your Mac from sleeping while you need it."), isOn: $settings.dashboardKeepAwakeEnabled)
                rowDivider
                toggleRow(symbol: "tray.full.fill", title: text("Dosya Rafı + AirDrop", "File Shelf + AirDrop"), subtitle: text("Dosyaları çentiğe bırakın, taşıyın veya AirDrop ile gönderin.", "Drop files on the notch, move them, or send them with AirDrop."), isOn: $settings.dashboardFileShelfEnabled)
            }
            settingsCard(title: text("Bildirimler", "Notifications")) {
                toggleRow(symbol: "bell.badge.fill", title: text("Bildirimleri çentikte göster", "Show notifications in the notch"), subtitle: text("Gelen bildirim çentiği genişletir; tıklayınca Bildirimler sekmesi açılır. Erişilebilirlik izni gerekir.", "A new notification widens the notch; click it to open the Notifications tab. Needs Accessibility access."), isOn: $settings.dashboardNotificationsEnabled)
                if settings.dashboardNotificationsEnabled {
                    rowDivider
                    settingsRow(symbol: "text.bubble.fill", title: text("Bildirim önizlemesi", "Notification preview"), subtitle: text("Çentik genişlediğinde bildirimin içeriği mi, yalnızca yeni bildirim olduğu mu görünsün?", "Show the notification's content when the notch widens, or only that one arrived?")) {
                        Picker("", selection: $settings.notificationPreviewStyle) {
                            ForEach(NotificationPreviewStyle.allCases) { style in
                                Text(style.title(language: settings.language)).tag(style)
                            }
                        }.labelsHidden().frame(width: 210)
                    }
                }
            }
            HStack { Spacer(); Button(text("Araç varsayılanlarını geri yükle", "Restore utility defaults")) { settings.resetDashboardFeatureDefaults() } }
        }
    }

    private var permissionsPage: some View {
        VStack(spacing: 16) {
            permissionSummary
            settingsCard(title: text("Sistem izinleri", "System permissions")) {
                settingsRow(symbol: "hand.raised.fill", title: text("Erişilebilirlik", "Accessibility"), subtitle: text("Bildirimleri çentikte göstermek, ses ve parlaklıkta macOS'un kendi göstergesini gizlemek, yapıştırma ve medya tuşlarını algılamak için gerekir.", "Needed to show notifications in the notch, hide macOS's own volume and brightness indicator, and detect paste and media keys.")) {
                    HStack(spacing: 10) {
                        permissionBadge(settings.isAccessibilityTrusted ? .granted : .missing)
                        if !settings.isAccessibilityTrusted {
                            Button(text("İzin ver", "Allow"), action: settings.requestAccessibilityPermission)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                if !settings.isAccessibilityTrusted {
                    accessibilitySteps
                }
                ForEach(AutomationTarget.allCases) { target in
                    rowDivider
                    automationRow(target)
                }
            }
        }
    }

    private var permissionSummary: some View {
        let missing = settings.missingPermissionCount
        return HStack(spacing: 14) {
            Image(systemName: missing == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(missing == 0 ? Color.green : Color.orange)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(missing == 0 ? text("Her şey hazır", "All set") : text("\(missing) izin eksik", missing == 1 ? "1 permission missing" : "\(missing) permissions missing"))
                    .font(.system(size: 15, weight: .semibold))
                Text(missing == 0 ? text("islo.'nun ihtiyaç duyduğu izinlerin hepsi verilmiş.", "islo. has every permission it needs.") : missingPermissionImpact)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var missingPermissionImpact: String {
        var parts: [String] = []
        if !settings.isAccessibilityTrusted {
            parts.append(text("Bildirimler çentikte görünmüyor ve ses/parlaklıkta macOS'un kendi göstergesi de çıkıyor.", "Notifications don't reach the notch, and macOS's own volume/brightness indicator still appears."))
        }
        let blocked = AutomationTarget.allCases.filter { settings.automationStates[$0] == .missing }.map(\.name)
        if !blocked.isEmpty {
            let names = blocked.joined(separator: ", ")
            parts.append(text("\(names) çalan parçası gösterilemiyor ve kontrol edilemiyor.", "\(names) playback can't be shown or controlled."))
        }
        return parts.joined(separator: " ")
    }

    private var accessibilitySteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            permissionStep(1, text("“İzin ver”e basın. macOS bir izin penceresi açar.", "Click “Allow”. macOS shows a permission prompt."))
            permissionStep(2, text("“Sistem Ayarları'nı Aç”ı seçin ve listede islo.'nun anahtarını açın.", "Choose “Open System Settings” and switch islo. on in the list."))
            permissionStep(3, text("Bu sayfa birkaç saniye içinde kendiliğinden “Verildi” olur.", "This page changes to “Allowed” by itself within seconds."))
            Text(text("Güncellemeden sonra islo. listede açık görünse bile burada “Eksik” yazıyorsa yine “İzin ver”e basın; islo. eski kaydı kendisi temizler.", "If islo. looks switched on in the list after an update but this still says “Missing”, click “Allow” anyway; islo. clears the old entry itself."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.08)))
        .padding(.leading, 48)
        .padding(.bottom, 10)
    }

    private func permissionStep(_ number: Int, _ message: String) -> some View {
        HStack(spacing: 9) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.orange))
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func automationRow(_ target: AutomationTarget) -> some View {
        let state = settings.automationStates[target] ?? .appClosed
        return settingsRow(symbol: target == .music ? "music.note" : "waveform", title: text("Otomasyon: \(target.name)", "Automation: \(target.name)"), subtitle: automationSubtitle(state)) {
            HStack(spacing: 10) {
                permissionBadge(state)
                if state == .missing || state == .notAsked {
                    Button(state == .missing ? text("Düzelt", "Fix") : text("İzin ver", "Allow")) {
                        settings.requestAutomationPermission(for: target)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func automationSubtitle(_ state: PermissionState) -> String {
        switch state {
        case .missing:
            text("Kapalı olduğu için çalan parça gösterilemiyor ve kontrol edilemiyor. “Düzelt” macOS'un yeniden sormasını sağlar.", "It's off, so the current track can't be shown or controlled. “Fix” makes macOS ask again.")
        case .appClosed:
            text("Çalan parçayı göstermek ve kontrol etmek için. Durumu, uygulama açıkken görünür.", "To show and control the current track. Its status shows while the app is open.")
        case .appNotInstalled:
            text("Bu Mac'te yüklü değil.", "Not installed on this Mac.")
        case .granted, .notAsked:
            text("Çalan parçayı göstermek ve kontrol etmek için.", "To show and control the current track.")
        }
    }

    private func permissionBadge(_ state: PermissionState) -> some View {
        let style: (title: String, symbol: String, color: Color) = switch state {
        case .granted: (text("Verildi", "Allowed"), "checkmark.circle.fill", .green)
        case .missing: (text("Eksik", "Missing"), "exclamationmark.triangle.fill", .orange)
        case .notAsked: (text("Sorulmadı", "Not asked"), "questionmark.circle.fill", .secondary)
        case .appClosed: (text("Uygulama kapalı", "App not running"), "moon.zzz.fill", .secondary)
        case .appNotInstalled: (text("Yüklü değil", "Not installed"), "minus.circle.fill", .secondary)
        }
        return Label(style.title, systemImage: style.symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(style.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(style.color.opacity(0.13)))
            .fixedSize()
    }

    private var updatesPage: some View {
        VStack(spacing: 16) {
            settingsCard(title: text("islo. güncellemeleri", "islo. updates")) {
                settingsRow(symbol: "arrow.down.circle", title: versionText, subtitle: text("İmzalı GitHub sürümlerinden güncellenir.", "Updated from signed GitHub releases.")) {
                    Button(text("Şimdi denetle", "Check now")) { updateManager.checkForUpdates() }
                        .disabled(!updateManager.canCheckForUpdates)
                }
                rowDivider
                toggleRow(symbol: "arrow.triangle.2.circlepath", title: text("Otomatik güncellemeler", "Automatic updates"), subtitle: text("Yeni sürümleri otomatik olarak indirip hazırlar.", "Automatically downloads and prepares new releases."), isOn: automaticUpdatesBinding)
            }
        }
    }

    private var aboutPage: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 112, height: 112)
                .shadow(color: accent.opacity(0.2), radius: 24)
            Text("islo.").font(.system(size: 34, weight: .bold, design: .rounded))
            Text(versionText).foregroundStyle(.secondary)
            Text(text("Mac'inizin üstünde, gününüzün yanında.", "At the top of your Mac, close to your day."))
                .font(.title3.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Link("GitHub", destination: URL(string: "https://github.com/OzdmrYsn/islo")!)
                Button(text("Tanıtımı göster", "Show welcome guide")) { onShowOnboarding() }
            }.buttonStyle(.bordered)
            Spacer(minLength: 20)
            Text("github.com/OzdmrYsn  |  Yasin Özdemir").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.top, 26)
    }

    private var notchPreview: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [accent.opacity(0.14), Color.primary.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
                ThemePreviewNotch(accent: accent, tone: settings.surfaceTone, language: settings.language)
            }
            .frame(height: 118).clipShape(RoundedRectangle(cornerRadius: 18))
            Text(text("Değişiklikleri anında çentikte göreceksiniz.", "Your changes appear in the notch immediately."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).background(cardBackground)
    }

    private var pageSubtitle: String {
        switch selection {
        case .general: text("islo.'nun Mac'inizde nasıl çalışacağını belirleyin.", "Choose how islo. works on your Mac.")
        case .appearance: text("Çentiği masaüstünüze ve tarzınıza uydurun.", "Make the notch feel at home on your desktop.")
        case .interaction: text("Ne zaman açılacağını ve nasıl kapanacağını seçin.", "Choose when it opens and how it collapses.")
        case .modules: text("Yalnızca kullanmak istediğiniz özellikleri açık tutun.", "Keep only the features you want to use.")
        case .permissions: text("islo.'nun macOS'tan istediği izinler ve durumları.", "The macOS permissions islo. uses and their status.")
        case .updates: text("Yeni sürümleri güvenli ve zahmetsiz biçimde alın.", "Receive new releases safely and effortlessly.")
        case .about: text("Yasin Özdemir tarafından geliştirildi.", "Built by Yasin Özdemir.")
        }
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 17).padding(.bottom, 8)
            content().padding(.horizontal, 20).padding(.bottom, 17)
        }
        .frame(maxWidth: .infinity, alignment: .leading).background(cardBackground)
    }

    private func settingsRow<Accessory: View>(symbol: String, title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 14) {
            rowIcon(symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18); accessory()
        }.padding(.vertical, 10)
    }

    private func toggleRow(symbol: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        settingsRow(symbol: symbol, title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private func sliderRow(symbol: String, title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String) -> some View {
        settingsRow(symbol: symbol, title: title, subtitle: valueText) {
            Slider(value: value, in: range, step: step).frame(width: 190)
        }
    }

    private func rowIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
            .frame(width: 34, height: 34).background(Circle().fill(accent.opacity(0.11)))
    }

    private var rowDivider: some View { Divider().padding(.leading, 48) }
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func noticeCard(symbol: String, message: String, buttonTitle: String? = nil, action: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let buttonTitle { Button(buttonTitle, action: action) }
        }.padding(14).background(cardBackground)
    }

    private func text(_ turkish: String, _ english: String) -> String { settings.language.value(turkish: turkish, english: english) }
    private var accent: Color { settings.accentTheme.color }
    private var launchAtLoginBinding: Binding<Bool> { Binding(get: { settings.launchAtLogin }, set: settings.setLaunchAtLogin) }
    private var automaticUpdatesBinding: Binding<Bool> { Binding(get: { updateManager.automaticUpdatesEnabled }, set: updateManager.setAutomaticUpdates) }
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return "islo. \(version)"
    }
}

struct ThemeChoicePicker: View {
    @Binding var selection: AppTheme
    let language: AppLanguage
    var accent: Color = .accentColor
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    guard theme.isAvailable else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { selection = theme }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: theme.symbolName).font(.system(size: 21, weight: .semibold))
                        Text(theme.title(language: language)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 82)
                    .background(RoundedRectangle(cornerRadius: 14).fill(cardBackground(for: theme)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(selection == theme ? accent : Color.primary.opacity(0.08), lineWidth: selection == theme ? 2 : 1))
                    .foregroundStyle(cardForegroundColor(for: theme))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain).disabled(!theme.isAvailable).opacity(theme.isAvailable ? 1 : 0.45)
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
        }
    }

    private func cardBackground(for theme: AppTheme) -> Color {
        switch theme {
        case .system: Color(nsColor: .windowBackgroundColor)
        case .light: .white
        case .dark: Color(red: 0.06, green: 0.065, blue: 0.08)
        case .liquidGlass: accent.opacity(0.12)
        }
    }

    private func cardForegroundColor(for theme: AppTheme) -> Color {
        switch theme { case .light: .black; case .dark: .white; case .system, .liquidGlass: .primary }
    }
}

private struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

/// A row of colour swatches for the theme colour.
struct AccentSwatchPicker: View {
    @Binding var selection: AccentTheme
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AccentTheme.allCases) { theme in
                let isSelected = selection == theme
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = theme }
                } label: {
                    Circle()
                        .fill(theme.color)
                        .frame(width: 24, height: 24)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(theme == .yellow || theme == .mint ? Color.black : Color.white)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().stroke(isSelected ? theme.color : Color.clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(theme.title(language: language))
                .accessibilityLabel(Text(theme.title(language: language)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// Cards that preview each tone with the current theme colour.
struct SurfaceTonePicker: View {
    @Binding var selection: SurfaceTone
    let accent: Color
    let language: AppLanguage
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(SurfaceTone.allCases) { tone in
                let isSelected = selection == tone
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = tone }
                } label: {
                    VStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.black)
                            .overlay {
                                LinearGradient(
                                    colors: [accent.opacity(tone.tintOpacity), accent.opacity(tone.tintOpacity * 0.35), .black],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .frame(height: 40)
                        Text(tone.title(language: language))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? accent : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// A small open-notch mock that shows the theme colour and tone live.
private struct ThemePreviewNotch: View {
    let accent: Color
    let tone: SurfaceTone
    let language: AppLanguage

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            LinearGradient(
                colors: [accent.opacity(tone.tintOpacity), accent.opacity(tone.tintOpacity * 0.35), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .mask {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.2), .init(color: .black, location: 0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Label(language.value(turkish: "Ana", english: "Home"), systemImage: "house.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                    ForEach(["calendar", "timer", "tray.full.fill"], id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 22, height: 22)
                    }
                }
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.85))
                        .frame(width: 34, height: 34)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: 96, height: 6)
                        Capsule().fill(Color.white.opacity(0.35)).frame(width: 64, height: 5)
                    }
                    Spacer(minLength: 8)
                    HStack(alignment: .center, spacing: 2.5) {
                        ForEach([8.0, 15, 10, 13], id: \.self) { height in
                            Capsule().fill(accent).frame(width: 2.5, height: height)
                        }
                    }
                    Circle()
                        .trim(from: 0, to: 0.68)
                        .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22, height: 22)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 34)
        }
        .frame(width: 330, height: 118 + 22)
        // Only the lower corners show; the top runs under the card's edge
        // like the notch under the display edge.
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .offset(y: -22)
        .animation(.easeInOut(duration: 0.2), value: tone)
    }
}
