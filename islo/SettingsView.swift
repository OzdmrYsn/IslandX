import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general, appearance, interaction, modules, updates, about
    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .general: language.value(turkish: "Genel", english: "General")
        case .appearance: language.value(turkish: "Görünüm", english: "Appearance")
        case .interaction: language.value(turkish: "Çentik ve Etkileşim", english: "Notch & Interaction")
        case .modules: language.value(turkish: "Araçlar", english: "Utilities")
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
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared
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
        .tint(.accentColor)
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
                        Label(destination.title(settings.language), systemImage: destination.symbol)
                            .font(.system(size: 13, weight: selection == destination ? .semibold : .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 36)
                            .foregroundStyle(selection == destination ? Color.accentColor : .primary)
                            .background(RoundedRectangle(cornerRadius: 9).fill(selection == destination ? Color.accentColor.opacity(0.12) : .clear))
                    }
                    .buttonStyle(.plain)
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
        case .updates: updatesPage
        case .about: aboutPage
        }
    }

    private var generalPage: some View {
        VStack(spacing: 16) {
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

            settingsCard(title: text("Varsayılan düzen", "Default layout")) {
                settingsRow(symbol: "rectangle.split.2x1", title: text("islo. düzeni", "islo. layout"), subtitle: settings.contentMode.subtitle(language: settings.language)) {
                    Picker("", selection: $settings.contentMode) {
                        ForEach(IslandContentMode.allCases) { mode in Text(mode.title(language: settings.language)).tag(mode) }
                    }.labelsHidden().frame(width: 180)
                }
            }
        }
    }

    private var appearancePage: some View {
        VStack(spacing: 16) {
            notchPreview
            settingsCard(title: text("Ana ekran", "Home")) {
                settingsRow(symbol: "rectangle.grid.2x2", title: text("Widget düzeni", "Widget layout"), subtitle: text("Genişleyen çentikte hangi bilginin öne çıkacağını seçin.", "Choose what takes priority in the expanded notch.")) {
                    Picker("", selection: $settings.homeWidgetStyle) {
                        ForEach(HomeWidgetStyle.allCases) { style in
                            Text(style.title(language: settings.language)).tag(style)
                        }
                    }.labelsHidden().frame(width: 150)
                }
                rowDivider
                settingsRow(symbol: "sparkles.rectangle.stack", title: text("Sahne", "Scene"), subtitle: text("Koyu yüzeyin ışık ve renk karakteri.", "The light and color character of the dark surface.")) {
                    Picker("", selection: $settings.notchSceneStyle) {
                        ForEach(NotchSceneStyle.allCases) { style in
                            Text(style.title(language: settings.language)).tag(style)
                        }
                    }.labelsHidden().frame(width: 150)
                }
            }
            settingsCard(title: text("Pencere görünümü", "Window appearance")) {
                ThemeChoicePicker(selection: $settings.theme, language: settings.language).padding(.vertical, 4)
            }
            settingsCard(title: text("Boştaki çentik", "Idle notch")) {
                settingsRow(symbol: "rectangle.tophalf.inset.filled", title: text("Boşta görünümü", "Idle appearance"), subtitle: settings.notchIdleMode.subtitle(language: settings.language)) {
                    Picker("", selection: $settings.notchIdleMode) {
                        ForEach(NotchIdleMode.allCases) { mode in Text(mode.title(language: settings.language)).tag(mode) }
                    }.labelsHidden().frame(width: 190)
                }
            }
        }
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
                rowDivider
                toggleRow(symbol: "cup.and.saucer.fill", title: text("Uyanık Tut", "Keep Awake"), subtitle: text("İstediğiniz sürece Mac'in uykuya geçmesini engeller.", "Prevents your Mac from sleeping while you need it."), isOn: $settings.dashboardKeepAwakeEnabled)
                rowDivider
                toggleRow(symbol: "tray.full.fill", title: text("Dosya Rafı + AirDrop", "File Shelf + AirDrop"), subtitle: text("Dosyaları çentiğe bırakın, taşıyın veya AirDrop ile gönderin.", "Drop files on the notch, move them, or send them with AirDrop."), isOn: $settings.dashboardFileShelfEnabled)
                rowDivider
                settingsRow(symbol: "hand.raised.fill", title: text("Klavye olayları", "Keyboard events"), subtitle: text("Yapıştırma ve medya tuşlarını algılamak için Erişilebilirlik izni gerekir.", "Accessibility permission is required to detect paste and media keys.")) {
                    Button(settings.isAccessibilityTrusted ? text("İzin verildi", "Allowed") : text("İzin ver", "Allow")) {
                        settings.requestAccessibilityPermission()
                    }
                    .disabled(settings.isAccessibilityTrusted)
                }
            }
            HStack { Spacer(); Button(text("Araç varsayılanlarını geri yükle", "Restore utility defaults")) { settings.resetDashboardFeatureDefaults() } }
        }
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
                .shadow(color: Color.accentColor.opacity(0.2), radius: 24)
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
                LinearGradient(colors: [Color.pink.opacity(0.12), Color.blue.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 8).fill(.black).frame(width: 52, height: 48).overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.85)))
                    Rectangle().fill(.black).frame(width: 118, height: 32)
                    RoundedRectangle(cornerRadius: 8).fill(.black).frame(width: 52, height: 48).overlay(Image(systemName: "waveform").foregroundStyle(.orange))
                }
            }
            .frame(height: 92).clipShape(RoundedRectangle(cornerRadius: 18))
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
        Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
            .frame(width: 34, height: 34).background(Circle().fill(Color.accentColor.opacity(0.11)))
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
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(selection == theme ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selection == theme ? 2 : 1))
                    .foregroundStyle(cardForegroundColor(for: theme))
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
        case .liquidGlass: Color.accentColor.opacity(0.12)
        }
    }

    private func cardForegroundColor(for theme: AppTheme) -> Color {
        switch theme { case .light: .black; case .dark: .white; case .system, .liquidGlass: .primary }
    }
}
