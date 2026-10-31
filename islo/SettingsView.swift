import Carbon.HIToolbox
import Combine
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general, appearance, features, permissions, about
    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .general: language.value(turkish: "Genel", english: "General")
        case .appearance: language.value(turkish: "Görünüm", english: "Appearance")
        case .features: language.value(turkish: "Özellikler", english: "Features")
        case .permissions: language.value(turkish: "İzinler", english: "Permissions")
        case .about: language.value(turkish: "Hakkında", english: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .features: "square.grid.2x2.fill"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }
}

/// Lets the menu bar and launch reminders open Settings on a given page.
final class SettingsRouter: ObservableObject {
    @Published var requestedDestination: SettingsDestination?
    /// A feature's detail page to open, by its identifier (e.g. "timer").
    @Published var requestedFeature: String?
    @Published var isWindowVisible = false
}

// MARK: - islo. look

/// The look islo.'s windows share with the notch and the website: near
/// black, white text at a few strengths, soft glass cards.
enum IsloStyle {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let text = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let muted = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.36)
    static let line = Color.white.opacity(0.08)
    static let cardRadius: CGFloat = 20

    static var cardFill: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.075), Color.white.opacity(0.03)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Black with the theme colour glowing in at the chosen tone, like the
/// open notch.
struct IsloWindowBackground: View {
    let accent: Color
    let tone: SurfaceTone

    var body: some View {
        ZStack {
            IsloStyle.background
            RadialGradient(
                colors: [accent.opacity(0.04 + tone.tintOpacity * 0.34), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 640
            )
            RadialGradient(
                colors: [accent.opacity(tone.tintOpacity * 0.12), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: tone)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Two-colour fills for icon tiles.
private enum Tint {
    static let red = [Color(hex: 0xFF5A50), Color(hex: 0xC9221A)]
    static let indigo = [Color(hex: 0x8A87FF), Color(hex: 0x4B48D6)]
    static let pink = [Color(hex: 0xFF5C93), Color(hex: 0xD3245F)]
    static let green = [Color(hex: 0x3ED667), Color(hex: 0x1E9E45)]
    static let cyan = [Color(hex: 0x6AD6FF), Color(hex: 0x1597D6)]
    static let purple = [Color(hex: 0xC56BF5), Color(hex: 0x8A2BD6)]
    static let mint = [Color(hex: 0x36DDB0), Color(hex: 0x0E9F7A)]
    static let orange = [Color(hex: 0xFFA826), Color(hex: 0xE86A00)]
    static let blue = [Color(hex: 0x3D9BFF), Color(hex: 0x0059D6)]
    static let shortcuts = [Color(hex: 0xFF5E9C), Color(hex: 0x7B61FF)]
    static let coffee = [Color(hex: 0xB8946A), Color(hex: 0x7A5C3A)]
    static let sky = [Color(hex: 0x5BC8F5), Color(hex: 0x2A6FFF)]
    static let magenta = [Color(hex: 0xFF72DA), Color(hex: 0xB233C2)]
    static let gray = [Color(hex: 0x9A9AA2), Color(hex: 0x5A5A62)]
    static let teal = [Color(hex: 0x4FD1D9), Color(hex: 0x16939E)]
    static let sunset = [Color(hex: 0xFF6B9A), Color(hex: 0xFF9F45)]
}

/// A rounded, coloured icon tile, like the notch's Shortcuts tiles.
private struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 30
    var isOn = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        shape
            .fill(LinearGradient(
                colors: isOn ? colors : [Color.white.opacity(0.15), Color.white.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(isOn ? 1 : 0.5))
            )
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: (isOn ? colors.last ?? .clear : .clear).opacity(0.35), radius: size * 0.22, y: size * 0.08)
            .accessibilityHidden(true)
    }
}

/// Capsule buttons: filled with the theme colour, or a quiet glass one.
private struct IsloButtonStyle: ButtonStyle {
    var prominent = false
    var accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : IsloStyle.text)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(
                Capsule().fill(prominent ? accent : Color.white.opacity(configuration.isPressed ? 0.16 : 0.09))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0.18 : 0.08), lineWidth: 0.5))
            .opacity(configuration.isPressed && prominent ? 0.85 : 1)
            .contentShape(Capsule())
    }
}

/// A row of capsule choices, the notch's tab-chip look as a picker.
private struct ChipPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    let accent: Color
    var fillsWidth = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white : IsloStyle.text.opacity(0.72))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                        .frame(height: 26)
                        .background {
                            if isSelected {
                                Capsule().fill(accent)
                                    .shadow(color: accent.opacity(0.4), radius: 6, y: 2)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        .fixedSize(horizontal: !fillsWidth, vertical: true)
    }
}

// MARK: - Features

/// Everything islo. can do that has an on/off switch.
private enum Feature: String, CaseIterable, Identifiable {
    case notifications, commandEcho, calendar, devices, privacy, screenshots, downloads
    case timer, shelf, shortcuts, keepAwake, weather, lyrics

    var id: String { rawValue }

    /// Things the notch tells you about on its own (after notifications,
    /// which lead the page as a wide tile).
    static let alerts: [Feature] = [.commandEcho, .calendar, .devices, .privacy, .screenshots, .downloads]
    /// Tools that live in the open notch.
    static let panel: [Feature] = [.timer, .shelf, .shortcuts, .keepAwake, .weather, .lyrics]

    var symbol: String {
        switch self {
        case .notifications: "bell.badge.fill"
        case .commandEcho: "speaker.wave.2.fill"
        case .calendar: "calendar"
        case .devices: "battery.100percent.bolt"
        case .privacy: "video.fill"
        case .screenshots: "camera.viewfinder"
        case .downloads: "arrow.down.circle.fill"
        case .timer: "timer"
        case .shelf: "tray.full.fill"
        case .shortcuts: "bolt.fill"
        case .keepAwake: "cup.and.saucer.fill"
        case .weather: "cloud.sun.fill"
        case .lyrics: "quote.bubble.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .notifications: Tint.red
        case .commandEcho: Tint.indigo
        case .calendar: Tint.pink
        case .devices: Tint.green
        case .privacy: Tint.cyan
        case .screenshots: Tint.purple
        case .downloads: Tint.mint
        case .timer: Tint.orange
        case .shelf: Tint.blue
        case .shortcuts: Tint.shortcuts
        case .keepAwake: Tint.coffee
        case .weather: Tint.sky
        case .lyrics: Tint.magenta
        }
    }
}

/// The macOS permission a feature depends on.
private enum FeaturePermission {
    case accessibility
    case calendar
    case folder(ProtectedFolder)
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var shortcutsManager = ShortcutsManager.shared
    var router: SettingsRouter?
    var onShowOnboarding: () -> Void = {}
    @State private var selection: SettingsDestination = .general
    @State private var openFeature: Feature?
    @State private var weatherQuery = ""
    @State private var weatherResults: [WeatherLocation] = []
    @State private var isSearchingWeather = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 214)
            Rectangle().fill(IsloStyle.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if selection == .features, let feature = openFeature {
                        featureDetail(feature)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                    } else {
                        pageHeader
                        selectedPage
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .foregroundStyle(IsloStyle.text)
        .frame(minWidth: 940, maxWidth: .infinity, minHeight: 690, maxHeight: .infinity)
        .background(IsloWindowBackground(accent: accent, tone: settings.surfaceTone))
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(accent)
        .onReceive(router?.$requestedDestination.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { destination in
            guard let destination else { return }
            select(destination)
            router?.requestedDestination = nil
        }
        .onReceive(router?.$requestedFeature.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { identifier in
            guard let identifier, let feature = Feature(rawValue: identifier) else { return }
            selection = .features
            openFeature = feature
            router?.requestedFeature = nil
        }
        // macOS doesn't announce permission changes; re-read them while
        // Settings is open so badges update as soon as access is granted.
        .onAppear(perform: settings.refreshPermissionState)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Only while the window is on screen (no router: the standard
            // Settings scene, which closes for real).
            guard router?.isWindowVisible ?? true else { return }
            settings.refreshPermissionState()
        }
    }

    private func select(_ destination: SettingsDestination) {
        withAnimation(.easeInOut(duration: 0.18)) {
            selection = destination
            openFeature = nil
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: accent.opacity(0.35), radius: 10, y: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text("islo.").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(text("Ayarlar", "Settings")).font(.system(size: 11.5, weight: .medium)).foregroundStyle(IsloStyle.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 50)
            .padding(.bottom, 22)

            VStack(spacing: 3) {
                ForEach(SettingsDestination.allCases) { destination in
                    sidebarItem(destination)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
            Text(versionText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(IsloStyle.faint)
                .padding(20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.32))
    }

    private func sidebarItem(_ destination: SettingsDestination) -> some View {
        let isSelected = selection == destination
        return Button { select(destination) } label: {
            HStack(spacing: 10) {
                IconTile(symbol: destination.symbol, colors: sidebarColors(destination), size: 24)
                Text(destination.title(settings.language))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? IsloStyle.text : IsloStyle.text.opacity(0.78))
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
            .padding(.horizontal, 9)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : .clear)
            )
            // A clear background isn't hit-testable; make the whole row
            // clickable, not just its text.
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // The focus ring on the first row read as a second selection.
        .modifier(NoFocusRing())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sidebarColors(_ destination: SettingsDestination) -> [Color] {
        switch destination {
        case .general: Tint.gray
        case .appearance: Tint.sunset
        case .features: Tint.blue
        case .permissions: settings.missingPermissionCount > 0 ? Tint.orange : Tint.green
        case .about: Tint.indigo
        }
    }

    // MARK: Page frame

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selection.title(settings.language))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .tracking(-0.4)
            Text(pageSubtitle).font(.system(size: 13.5)).foregroundStyle(IsloStyle.muted)
        }
        .padding(.bottom, 2)
    }

    private var pageSubtitle: String {
        switch selection {
        case .general: text("Dil, açılış ve çentiğin nasıl davranacağı.", "Language, startup and how the notch behaves.")
        case .appearance: text("Çentiği kendi rengine boya.", "Paint the notch in your own colour.")
        case .features: text("Bir özelliği açıp kapatmak için anahtarı, ayrıntıları için kutucuğu kullan.", "Use the switch to turn a feature on or off, and the tile for its details.")
        case .permissions: text("islo.'nun macOS'tan istediği izinler ve durumları.", "The macOS permissions islo. uses and their status.")
        case .about: text("Sürüm, güncellemeler ve bağlantılar.", "Version, updates and links.")
        }
    }

    @ViewBuilder private var selectedPage: some View {
        switch selection {
        case .general: generalPage
        case .appearance: appearancePage
        case .features: featuresPage
        case .permissions: permissionsPage
        case .about: aboutPage
        }
    }

    // MARK: General

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            if settings.missingPermissionCount > 0 {
                noticeCard(
                    message: text("Bazı izinler eksik, bu yüzden bazı özellikler çalışmıyor.", "Some permissions are missing, so some features don't work."),
                    buttonTitle: text("İzinlere git", "Go to Permissions")
                ) { select(.permissions) }
            }

            section(text("Temel", "Basics")) {
                row(symbol: "globe", colors: Tint.blue, title: text("Dil", "Language"), subtitle: text("Uygulamanın dili.", "The app's language.")) {
                    ChipPicker(selection: $settings.language, options: AppLanguage.allCases.map { ($0, $0.title) }, accent: accent)
                }
                divider
                row(symbol: "power", colors: Tint.green, title: text("Mac açılınca başlat", "Launch at login"), subtitle: text("islo. oturum açtığın anda hazır olur.", "islo. is ready as soon as you log in.")) {
                    switchControl(launchAtLoginBinding)
                }
                if settings.launchAtLoginRequiresApproval {
                    inlineNotice(text("Başlangıç izni macOS onayı bekliyor.", "Launch at login is waiting for macOS approval."), buttonTitle: text("Giriş Öğelerini Aç", "Open Login Items"), action: settings.openLoginItemsSettings)
                } else if let error = settings.launchAtLoginError {
                    inlineNotice(error)
                }
            }

            section(text("Çentik", "Notch")) {
                stackedRow(symbol: "cursorarrow.rays", colors: Tint.indigo, title: text("Açılma", "Opening"), subtitle: settings.activationMode.subtitle(language: settings.language)) {
                    ChipPicker(selection: $settings.activationMode, options: NotchActivationMode.allCases.map { ($0, $0.title(language: settings.language)) }, accent: accent, fillsWidth: true)
                }
                divider
                row(symbol: "music.note", colors: Tint.pink, title: text("Şarkı değişince göster", "Show when the song changes"), subtitle: text("Yeni şarkı birkaç saniye çentikte görünür.", "The new song shows in the notch for a few seconds.")) {
                    switchControl($settings.showOnTrackChange)
                }
                if settings.showOnTrackChange {
                    divider
                    sliderRow(symbol: "clock.fill", colors: Tint.pink, title: text("Gösterim süresi", "How long"), value: $settings.trackChangeDisplayDuration, range: 2...8, step: 0.5, valueText: String(format: text("%.1f sn", "%.1f s"), settings.trackChangeDisplayDuration))
                }
                divider
                row(symbol: "arrow.up.left.and.arrow.down.right", colors: Tint.gray, title: text("Tam ekranda gizle", "Hide in full screen"), subtitle: text("Oyun, film ve sunumların üstünde görünmez.", "Stays out of games, films and presentations.")) {
                    switchControl($settings.hideInFullScreen)
                }
                divider
                sliderRow(symbol: "arrow.down.right.and.arrow.up.left", colors: Tint.orange, title: text("Kapanma gecikmesi", "Collapse delay"), value: $settings.collapseDelay, range: 0.15...1.2, step: 0.05, valueText: String(format: text("%.2f sn", "%.2f s"), settings.collapseDelay))
            }

            section(text("Kısayol tuşu", "Keyboard shortcut")) {
                row(symbol: "command", colors: Tint.gray, title: text("Kısayolla aç ve kapat", "Open and close with a shortcut"), subtitle: text("Hangi uygulamada olursan ol, bu tuşlar çentiği açar; tekrar basınca kapanır.", "In any app, these keys open the notch; press again to close it.")) {
                    switchControl($settings.hotKeyEnabled)
                }
                if settings.hotKeyEnabled {
                    divider
                    row(symbol: "keyboard.fill", colors: Tint.gray, title: text("Tuşlar", "Keys"), subtitle: settings.isHotKeyTaken
                        ? text("Bu kısayolu başka bir uygulama kullanıyor; başka bir tane seç.", "Another app uses this shortcut; pick a different one.")
                        : text("Tıkla ve yeni tuşlara bas: ⌘ ya da ⌃ ile, veya ⌥ ile Boşluk, ok ya da F tuşu. Esc vazgeçer.", "Click, then press the new keys: with ⌘ or ⌃, or ⌥ with Space, an arrow or an F-key. Esc cancels.")) {
                        HStack(spacing: 8) {
                            if settings.isHotKeyTaken {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            if settings.toggleHotKey != .defaultToggle {
                                Button(text("Varsayılan", "Default")) { settings.toggleHotKey = .defaultToggle }
                                    .buttonStyle(IsloButtonStyle(accent: accent))
                            }
                            ShortcutRecorder(hotKey: $settings.toggleHotKey, language: settings.language, accent: accent)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(text("Varsayılanlara dön", "Restore defaults")) { settings.resetInteractionDefaults() }
                    .buttonStyle(IsloButtonStyle(accent: accent))
            }
        }
    }

    // MARK: Appearance

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            notchPreview

            section(text("Renk", "Colour")) {
                stackedRow(symbol: "paintpalette.fill", colors: [accent, accent.opacity(0.65)], title: settings.accentTheme.title(language: settings.language), subtitle: text("Çentikteki simgeler, ilerleme halkası, müzik dalgası ve bu pencere bu rengi kullanır.", "Used by the notch's icons, progress ring, music wave and this window.")) {
                    AccentSwatchPicker(selection: $settings.accentTheme, language: settings.language)
                }
            }

            section(text("Ton", "Tone")) {
                stackedRow(symbol: "drop.halffull", colors: [accent, accent.opacity(0.65)], title: settings.surfaceTone.title(language: settings.language), subtitle: text("Rengin açılan çentiğe ve islo. pencerelerine ne kadar sineceği. Kamera çentiğinin yanı her zaman siyah kalır.", "How much the colour tints the open notch and islo.'s windows. Beside the camera it always stays black.")) {
                    SurfaceTonePicker(selection: $settings.surfaceTone, accent: accent, language: settings.language)
                }
            }

            section(text("Ana sayfa", "Home")) {
                stackedRow(symbol: "rectangle.grid.2x2.fill", colors: Tint.blue, title: text("Öne çıkan", "In front"), subtitle: text("Açılan çentiğin ana sayfasında hangi bilgi öne çıksın?", "What should lead on the open notch's Home?")) {
                    ChipPicker(selection: $settings.homeWidgetStyle, options: HomeWidgetStyle.allCases.map { ($0, $0.title(language: settings.language)) }, accent: accent, fillsWidth: true)
                }
            }
        }
    }

    private var notchPreview: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [accent.opacity(0.22), Color.white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ThemePreviewNotch(accent: accent, tone: settings.surfaceTone, language: settings.language)
            VStack {
                Spacer()
                Text(text("Değişiklikler çentikte anında görünür.", "Changes show in the notch right away."))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(IsloStyle.muted)
                    .padding(.bottom, 12)
            }
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: IsloStyle.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: IsloStyle.cardRadius, style: .continuous).strokeBorder(IsloStyle.line, lineWidth: 1))
    }

    // MARK: Features

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            featureGroup(text("Çentik haber verir", "The notch tells you"), Feature.alerts, leading: .notifications)
            featureGroup(text("Açılan çentikte", "In the open notch"), Feature.panel)
            HStack {
                Spacer()
                Button(text("Varsayılanlara dön", "Restore defaults")) { settings.resetDashboardFeatureDefaults() }
                    .buttonStyle(IsloButtonStyle(accent: accent))
            }
        }
        .onAppear { if shortcutsManager.available.isEmpty { shortcutsManager.reload() } }
    }

    private func featureGroup(_ title: String, _ features: [Feature], leading: Feature? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(title)
            if let leading { featureTile(leading, isWide: true) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(features) { featureTile($0) }
            }
        }
    }

    private func featureTile(_ feature: Feature, isWide: Bool = false) -> some View {
        let isOn = isEnabled(feature).wrappedValue
        return ZStack(alignment: isWide ? .trailing : .topTrailing) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { openFeature = feature }
            } label: {
                Group {
                    if isWide {
                        HStack(spacing: 16) {
                            IconTile(symbol: feature.symbol, colors: feature.colors, size: 48, isOn: isOn)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title(feature)).font(.system(size: 15, weight: .semibold))
                                Text(summary(feature))
                                    .font(.system(size: 12))
                                    .foregroundStyle(IsloStyle.muted)
                                    .lineLimit(1)
                                tileStatus(feature, isOn: isOn)
                                    .padding(.top, 2)
                            }
                            Spacer(minLength: 70)
                        }
                        .padding(16)
                    } else {
                        VStack(alignment: .leading, spacing: 11) {
                            IconTile(symbol: feature.symbol, colors: feature.colors, size: 36, isOn: isOn)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title(feature))
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .lineLimit(1)
                                Text(summary(feature))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(IsloStyle.muted)
                                    .lineLimit(2, reservesSpace: true)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 5) {
                                tileStatus(feature, isOn: isOn)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(IsloStyle.faint)
                            }
                        }
                        .padding(14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground(highlighted: isOn))
                .contentShape(RoundedRectangle(cornerRadius: IsloStyle.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .modifier(NoFocusRing())
            .accessibilityLabel(Text(title(feature)))
            .accessibilityHint(Text(text("Ayrıntıları açar", "Opens its details")))

            // On top of the tile, so switching doesn't open the details.
            HStack(spacing: 12) {
                switchControl(isEnabled(feature))
                    .controlSize(isWide ? .regular : .small)
                    .accessibilityLabel(Text(title(feature)))
                if isWide {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(IsloStyle.faint)
                        .allowsHitTesting(false)
                }
            }
            .padding(isWide ? 18 : 14)
        }
    }

    /// "On", "Off" or a permission warning, always the same height.
    private func tileStatus(_ feature: Feature, isOn: Bool) -> some View {
        Group {
            if needsPermission(feature) {
                Label(text("İzin gerekli", "Needs permission"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            } else {
                Text(isOn ? text("Açık", "On") : text("Kapalı", "Off"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isOn ? accent : IsloStyle.faint)
                    .frame(height: 20)
            }
        }
    }

    private func featureDetail(_ feature: Feature) -> some View {
        let isOn = isEnabled(feature)
        return VStack(alignment: .leading, spacing: 22) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { openFeature = nil }
            } label: {
                Label(text("Özellikler", "Features"), systemImage: "chevron.left")
            }
            .buttonStyle(IsloButtonStyle(accent: accent))
            .keyboardShortcut(.cancelAction)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    IconTile(symbol: feature.symbol, colors: feature.colors, size: 56, isOn: isOn.wrappedValue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(feature))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text(summary(feature))
                            .font(.system(size: 13))
                            .foregroundStyle(IsloStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    switchControl(isOn)
                        .controlSize(.large)
                        .accessibilityLabel(Text(title(feature)))
                }
                Text(details(feature))
                    .font(.system(size: 13))
                    .foregroundStyle(IsloStyle.text.opacity(0.8))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .background(cardBackground(highlighted: isOn.wrappedValue))

            if let permission = permission(for: feature) {
                section(text("İzin", "Permission")) {
                    permissionRow(permission)
                }
            }

            featureOptions(feature)
        }
    }

    @ViewBuilder
    private func featureOptions(_ feature: Feature) -> some View {
        switch feature {
        case .notifications:
            section(text("Seçenekler", "Options")) {
                row(symbol: "rectangle.on.rectangle.slash", colors: Tint.red, title: text("macOS'un bildirimini gizle", "Hide macOS's banner"), subtitle: text("Bildirim yalnızca çentikte görünür; köşedeki baloncuk gizlenir ama bildirim Bildirim Merkezi'nde kalır. Yanıt bekleyen uyarılar (ör. Takvim) birkaç saniye sonra yine görünür.", "The notification shows only in the notch; the corner banner is hidden but stays in Notification Center. Alerts that wait for an answer (e.g. Calendar) still appear after a few seconds.")) {
                    switchControl($settings.hideSystemNotificationBanners)
                }
                divider
                stackedRow(symbol: "text.bubble.fill", colors: Tint.red, title: text("Önizleme", "Preview"), subtitle: text("Çentik genişlediğinde bildirimin içeriği mi, yalnızca yeni bildirim geldiği mi görünsün?", "When the notch widens, show the notification's content or only that one arrived?")) {
                    ChipPicker(selection: $settings.notificationPreviewStyle, options: NotificationPreviewStyle.allCases.map { ($0, $0.title(language: settings.language)) }, accent: accent, fillsWidth: true)
                }
            }
            notificationTips
        case .calendar:
            section(text("Seçenekler", "Options")) {
                row(symbol: "bell.and.waves.left.and.right.fill", colors: Tint.pink, title: text("Toplantı uyarısı", "Meeting alert"), subtitle: text("Bir etkinlik başlamadan 5 dakika önce çentik genişleyip haber verir.", "The notch widens 5 minutes before an event starts.")) {
                    switchControl($settings.calendarAlertsEnabled)
                }
            }
        case .timer:
            section(text("Seçenekler", "Options")) {
                row(symbol: "hourglass", colors: Tint.orange, title: text("Kapalı çentikte geri sayım", "Countdown in the closed notch"), subtitle: text("Zamanlayıcı çalışırken kalan süre çentiğin yanlarında görünür; bitince çentik haber verir.", "While a timer runs, the time left shows beside the notch, which tells you when it ends.")) {
                    switchControl($settings.liveTimerInNotch)
                }
            }
            section(text("Pomodoro otomasyonu", "Pomodoro automation")) {
                row(symbol: "play.fill", colors: Tint.shortcuts, title: text("Odak başlarken", "When focus starts"), subtitle: text("Örneğin Rahatsız Etme'yi açan bir kısayol.", "E.g. a shortcut that turns on Do Not Disturb.")) {
                    shortcutPicker($settings.focusStartShortcut)
                }
                divider
                row(symbol: "stop.fill", colors: Tint.shortcuts, title: text("Odak bitince", "When focus ends"), subtitle: text("Odak bittiğinde, atlandığında ya da sıfırlandığında çalışır.", "Runs when focus finishes, is skipped or is reset.")) {
                    shortcutPicker($settings.focusEndShortcut)
                }
                tip(text("Kısayollar uygulamasında \"Odak Modunu Ayarla\" eylemiyle Rahatsız Etme'yi açıp kapatan iki kısayol oluşturabilirsin.", "In the Shortcuts app, the \"Set Focus\" action can turn Do Not Disturb on and off in two shortcuts."))
            }
        case .shortcuts:
            section(text("Sekmede görünecekler", "Shown in the tab")) {
                shortcutFavoritesPicker
            }
        case .weather:
            section(text("Şehir", "City")) {
                weatherCityPicker
            }
        case .screenshots:
            section(text("Klasör", "Folder")) {
                row(symbol: "folder.fill", colors: Tint.purple, title: text("Ekran görüntülerinin kaydedildiği yer", "Where screenshots are saved"), subtitle: (settings.folderURL(.screenshots).path as NSString).abbreviatingWithTildeInPath) {
                    Button(text("Göster", "Show")) {
                        NSWorkspace.shared.open(settings.folderURL(.screenshots))
                    }
                    .buttonStyle(IsloButtonStyle(accent: accent))
                }
                tip(text("Yeri değiştirmek için ⌘⇧5 ile Ekran Görüntüsü uygulamasını açıp Seçenekler > Kaydetme Yeri'ni kullan; islo. yeni klasörü kendiliğinden izler.", "To change it, press ⌘⇧5 and use Options > Save to; islo. follows the new folder by itself."))
            }
        default:
            EmptyView()
        }
    }

    private var notificationTips: some View {
        section(text("Bildirim gelmiyor mu?", "Not seeing notifications?")) {
            VStack(alignment: .leading, spacing: 9) {
                bullet(text("islo., macOS'un ekranın köşesinde gösterdiği bildirimleri okur. Odak (Rahatsız Etme) açıkken macOS bildirim göstermez, islo. de göremez.", "islo. reads the notifications macOS shows in the corner of the screen. While a Focus (Do Not Disturb) is on, macOS shows none, so islo. can't either."))
                bullet(text("Uygulamanın bildirimleri Sistem Ayarları > Bildirimler'de açık olmalı ve uyarı stili \"Yok\" olmamalı.", "The app's notifications must be on in System Settings > Notifications, with an alert style other than \"None\"."))
                bullet(text("Bir sohbet uygulaması (ör. WhatsApp) öndeyken o sohbetin mesajları için macOS bildirim göstermez.", "While a chat app (e.g. WhatsApp) is in front, macOS doesn't show notifications for that chat."))
                HStack {
                    Spacer()
                    Button(text("Bildirim ayarlarını aç", "Open Notification settings"), action: openNotificationSettings)
                        .buttonStyle(IsloButtonStyle(accent: accent))
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 12)
        }
    }

    private func isEnabled(_ feature: Feature) -> Binding<Bool> {
        switch feature {
        case .notifications: $settings.dashboardNotificationsEnabled
        case .commandEcho: $settings.dashboardCommandEchoEnabled
        case .calendar: $settings.calendarEnabled
        case .devices: $settings.devicesHUDEnabled
        case .privacy: $settings.privacyIndicatorEnabled
        case .screenshots: $settings.screenshotPreviewEnabled
        case .downloads: $settings.downloadsEnabled
        case .timer: $settings.dashboardFocusTimerEnabled
        case .shelf: $settings.dashboardFileShelfEnabled
        case .shortcuts: $settings.shortcutsEnabled
        case .keepAwake: $settings.dashboardKeepAwakeEnabled
        case .weather: $settings.weatherEnabled
        case .lyrics: $settings.lyricsEnabled
        }
    }

    private func permission(for feature: Feature) -> FeaturePermission? {
        switch feature {
        case .notifications, .commandEcho: .accessibility
        case .calendar: .calendar
        case .screenshots:
            ProtectedFolder.privacyService(for: settings.folderURL(.screenshots)) == nil ? nil : .folder(.screenshots)
        case .downloads: .folder(.downloads)
        default: nil
        }
    }

    private func permissionState(_ permission: FeaturePermission) -> PermissionState {
        switch permission {
        case .accessibility: settings.isAccessibilityTrusted ? .granted : .missing
        case .calendar: calendarManager.authorization
        // Only checked while the feature is on; macOS asks when it starts.
        case .folder(let folder): settings.folderStates[folder] ?? .notAsked
        }
    }

    private func needsPermission(_ feature: Feature) -> Bool {
        guard isEnabled(feature).wrappedValue, let permission = permission(for: feature) else { return false }
        let state = permissionState(permission)
        if case .folder = permission { return state == .missing }
        return state == .missing || state == .notAsked
    }

    private func title(_ feature: Feature) -> String {
        switch feature {
        case .notifications: text("Bildirimler", "Notifications")
        case .commandEcho: text("Ses ve parlaklık", "Volume & brightness")
        case .calendar: text("Takvim", "Calendar")
        case .devices: text("Şarj ve kulaklık", "Charging & headphones")
        case .privacy: text("Kamera ve mikrofon", "Camera & microphone")
        case .screenshots: text("Ekran görüntüsü", "Screenshots")
        case .downloads: text("İndirmeler", "Downloads")
        case .timer: text("Zamanlayıcı", "Timer")
        case .shelf: text("Dosya Rafı", "File Shelf")
        case .shortcuts: text("Kısayollar", "Shortcuts")
        case .keepAwake: text("Uyanık Tut", "Keep Awake")
        case .weather: text("Hava durumu", "Weather")
        case .lyrics: text("Şarkı sözleri", "Lyrics")
        }
    }

    private func summary(_ feature: Feature) -> String {
        switch feature {
        case .notifications: text("WhatsApp, Mesajlar ve diğer uygulamaların bildirimleri çentikte açılır.", "Notifications from WhatsApp, Messages and other apps open in the notch.")
        case .commandEcho: text("Ses, parlaklık, kopyalama ve Caps Lock çentikte görünür.", "Volume, brightness, copy and Caps Lock show in the notch.")
        case .calendar: text("Sıradaki etkinlik ve görüşmeler için Katıl düğmesi.", "Your next event, with Join for video calls.")
        case .devices: text("Şarj, düşük pil ve AirPods pil seviyesi.", "Charging, low battery and AirPods battery.")
        case .privacy: text("Kamerayı ya da mikrofonu kullanan uygulamayı gösterir.", "Shows which app is using the camera or mic.")
        case .screenshots: text("Yeni ekran görüntüsü çentiğin altında önizlenir.", "New screenshots preview under the notch.")
        case .downloads: text("İndirme ilerlemesi kapalı çentikte bir halkayla.", "Download progress as a ring in the closed notch.")
        case .timer: text("Zamanlayıcı ve Pomodoro, geri sayımı çentikte.", "Timer and Pomodoro, counting down in the notch.")
        case .shelf: text("Dosyaları çentiğe bırak, taşı ya da AirDrop'la.", "Drop files on the notch, move or AirDrop them.")
        case .shortcuts: text("Seçtiğin kısayollar çentikte tek tıkla çalışır.", "Your picked shortcuts run in one click.")
        case .keepAwake: text("Mac'in uykuya geçmesini istediğin kadar engeller.", "Keeps your Mac awake as long as you need.")
        case .weather: text("Ana sayfada sıcaklık ve hava durumu.", "Temperature and conditions on Home.")
        case .lyrics: text("Şarkı kartında satır satır akan sözler.", "Lyrics that follow the song, line by line.")
        }
    }

    private func details(_ feature: Feature) -> String {
        switch feature {
        case .notifications:
            text("Yeni bir bildirim geldiğinde çentik genişleyip kimden geldiğini ve içeriğini gösterir; tıklayınca Bildirimler sekmesi açılır. islo. bildirimleri macOS'un ekranda gösterdiği bildirimlerden okur, bunun için Erişilebilirlik izni yeterlidir.", "When a notification arrives, the notch widens to show who it's from and what it says; click it to open the Notifications tab. islo. reads the notifications macOS shows on screen, so Accessibility access is all it needs.")
        case .commandEcho:
            text("Ses ya da parlaklığı değiştirdiğinde macOS'un kendi göstergesi yerine çentik ince bir şeritle haber verir. Kopyalama, ekran görüntüsü ve Caps Lock da aynı şekilde görünür. macOS'un göstergesini gizleyebilmek için Erişilebilirlik izni gerekir.", "When you change the volume or brightness, the notch shows a slim bar instead of macOS's own indicator. Copying, screenshots and Caps Lock show the same way. Hiding macOS's indicator needs Accessibility access.")
        case .calendar:
            text("Ana sayfada bugünün ve yarının etkinlikleri görünür; görüntülü görüşmelere tek tıkla katılırsın. Etkinlikler Mac'indeki Takvim'den okunur ve hiçbir yere gönderilmez.", "Home shows today's and tomorrow's events, and you join video calls in one click. Events are read from Calendar on your Mac and never sent anywhere.")
        case .devices:
            text("Şarj takılınca ya da pil azalınca çentik haber verir. Bluetooth kulaklık (AirPods vb.) bağlanınca pil seviyelerini gösterir; çıkış cihazını şarkı kartından değiştirebilirsin.", "The notch tells you when the charger is plugged in or the battery runs low. When Bluetooth headphones (AirPods etc.) connect, it shows their battery; you can switch the output from the song card.")
        case .privacy:
            text("Bir uygulama kamerayı ya da mikrofonu kullanırken kapalı çentiğin köşesinde renkli bir nokta belirir: yeşil kamera, turuncu mikrofon. Çentiği açınca hangi uygulama olduğu görünür.", "While an app uses the camera or microphone, a coloured dot appears at the corner of the closed notch: green for the camera, orange for the mic. Open the notch to see which app it is.")
        case .screenshots:
            text("Ekran görüntüsü aldığında küçük resmi çentiğin altında açılır. Sürükleyip istediğin yere bırak ya da Kopyala, Rafa ekle, Göster ve Sil ile tek tıkla işini gör.", "When you take a screenshot, its thumbnail opens under the notch. Drag it anywhere, or Copy, add to the Shelf, Show or Delete it in one click.")
        case .downloads:
            text("İndirilenler'e gelen dosyaların (Safari, Chrome, Firefox, AirDrop) ilerlemesi kapalı çentikte yeşil bir halkayla görünür; bitince Aç ve Göster düğmeleri çıkar.", "Files coming into Downloads (Safari, Chrome, Firefox, AirDrop) show their progress as a green ring in the closed notch, with Open and Show when they're done.")
        case .timer:
            text("Zamanlayıcı sekmesinde kadranı çevirerek ya da −/+ ile istediğin süreyi kur. Pomodoro modunda odak ve mola turları sırayla ilerler; bugünkü odak süren de orada görünür.", "In the Timer tab, turn the dial or use −/+ to set any length. Pomodoro mode alternates focus and breaks, and shows today's focus time.")
        case .shelf:
            text("Bir dosyayı çentiğe sürüklediğinde rafa eklenir. Oradan istediğin yere taşıyabilir ya da AirDrop ile gönderebilirsin. Raftan kaldırmak dosyayı silmez.", "Drag a file onto the notch to put it on the shelf. From there, move it anywhere or send it with AirDrop. Removing it from the shelf never deletes the file.")
        case .shortcuts:
            text("Kısayollar uygulamasından seçtiğin en fazla 7 kısayol, çentikteki Kısayollar sekmesinde renkli kutucuklar olarak durur ve tek tıkla çalışır.", "Up to seven shortcuts you pick from the Shortcuts app sit in the notch's Shortcuts tab as coloured tiles and run in one click.")
        case .keepAwake:
            text("Açtığında Mac, sen kapatana kadar uykuya geçmez; uzun indirmeler ve sunumlar için idealdir. Çentikten tek tıkla açıp kapatırsın.", "While it's on, your Mac won't sleep until you turn it off, handy for long downloads and presentations. Toggle it from the notch in one click.")
        case .weather:
            text("Ana sayfada sıcaklık ve hava durumu görünür. Veriler ücretsiz Open-Meteo'dan gelir ve konum izni gerekmez: şehir, Mac'in saat diliminden bulunur ya da aşağıdan seçilir.", "Home shows the temperature and conditions. Data comes from the free Open-Meteo service with no location permission: the city comes from your Mac's time zone, or pick one below.")
        case .lyrics:
            text("Şarkı kartındaki söz düğmesine basınca sözler şarkıyla birlikte satır satır akar. Sözler ücretsiz LRCLIB'den gelir; bunun için şarkının adı ve sanatçısı oraya gönderilir.", "Press the lyrics button in the song card and the lyrics follow the song line by line. They come from the free LRCLIB service, which receives the song's title and artist.")
        }
    }

    // MARK: Permissions

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            permissionSummary

            section(text("Sistem izinleri", "System permissions")) {
                permissionRow(.accessibility)
                if !settings.isAccessibilityTrusted {
                    accessibilitySteps
                }
                divider
                permissionRow(.calendar)
                ForEach(ProtectedFolder.allCases) { folder in
                    if settings.folderStates[folder] != nil {
                        divider
                        permissionRow(.folder(folder))
                    }
                }
            }

            section(text("Müzik uygulamaları", "Music apps")) {
                ForEach(Array(AutomationTarget.allCases.enumerated()), id: \.element) { index, target in
                    if index > 0 { divider }
                    automationRow(target)
                }
            }

            notificationTips
        }
    }

    private var permissionSummary: some View {
        let missing = settings.missingPermissionCount
        // Calendar is on but macOS hasn't asked yet: not broken, just waiting.
        let isCalendarWaiting = missing == 0 && settings.calendarEnabled && calendarManager.authorization == .notAsked
        let title = missing > 0
            ? text("\(missing) izin eksik", missing == 1 ? "1 permission missing" : "\(missing) permissions missing")
            : isCalendarWaiting ? text("Bir izin bekliyor", "One permission to give") : text("Her şey hazır", "All set")
        let detail = missing > 0
            ? missingPermissionImpact
            : isCalendarWaiting
                ? text("Takvim etkinliklerinin görünmesi için aşağıdan Takvim iznini ver.", "Allow Calendars below so your events can show.")
                : text("islo.'nun ihtiyaç duyduğu izinlerin hepsi verilmiş.", "islo. has every permission it needs.")
        return HStack(spacing: 16) {
            IconTile(symbol: missing > 0 ? "exclamationmark.shield.fill" : isCalendarWaiting ? "questionmark.circle.fill" : "checkmark.shield.fill", colors: missing > 0 ? Tint.orange : isCalendarWaiting ? Tint.blue : Tint.green, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(IsloStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(cardBackground(highlighted: false))
    }

    private var missingPermissionImpact: String {
        var parts: [String] = []
        if !settings.isAccessibilityTrusted {
            parts.append(text("Bildirimler çentikte görünmüyor ve ses/parlaklıkta macOS'un kendi göstergesi de çıkıyor.", "Notifications don't reach the notch, and macOS's own volume/brightness indicator still appears."))
        }
        if settings.calendarEnabled, calendarManager.authorization == .missing {
            parts.append(text("Takvim etkinlikleri gösterilemiyor.", "Calendar events can't be shown."))
        }
        if settings.folderStates[.screenshots] == .missing {
            parts.append(text("Ekran görüntüleri önizlenemiyor.", "Screenshots can't be previewed."))
        }
        if settings.folderStates[.downloads] == .missing {
            parts.append(text("Bazı indirmeler görünmüyor.", "Some downloads don't show."))
        }
        let blocked = AutomationTarget.allCases.filter { settings.automationStates[$0] == .missing }.map(\.name)
        if !blocked.isEmpty {
            let names = blocked.joined(separator: ", ")
            parts.append(text("\(names) çalan şarkısı gösterilemiyor ve kontrol edilemiyor.", "\(names) playback can't be shown or controlled."))
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private func permissionRow(_ permission: FeaturePermission) -> some View {
        let state = permissionState(permission)
        switch permission {
        case .accessibility:
            row(symbol: "hand.raised.fill", colors: Tint.blue, title: text("Erişilebilirlik", "Accessibility"), subtitle: text("Bildirimleri okumak, macOS'un ses ve parlaklık göstergesinin yerine geçmek ve kopyalamayı algılamak için. Bildirimler için başka izin gerekmez.", "To read notifications, stand in for macOS's volume and brightness indicator, and notice copying. Notifications need nothing else.")) {
                HStack(spacing: 8) {
                    permissionBadge(state)
                    if state != .granted {
                        Button(text("İzin ver", "Allow"), action: settings.requestAccessibilityPermission)
                            .buttonStyle(IsloButtonStyle(prominent: true, accent: accent))
                    }
                }
            }
        case .calendar:
            row(symbol: "calendar", colors: Tint.pink, title: text("Takvim", "Calendars"), subtitle: text("Sıradaki etkinliği göstermek ve toplantıdan önce uyarmak için.", "To show your next event and alert you before meetings.")) {
                HStack(spacing: 8) {
                    permissionBadge(state)
                    if state == .notAsked {
                        Button(text("İzin ver", "Allow"), action: calendarManager.requestAccess)
                            .buttonStyle(IsloButtonStyle(prominent: true, accent: accent))
                    } else if state == .missing {
                        Button(text("Ayarları aç", "Open Settings"), action: calendarManager.openPrivacySettings)
                            .buttonStyle(IsloButtonStyle(prominent: true, accent: accent))
                    }
                }
            }
        case .folder(let folder):
            let name = (settings.folderURL(folder).path as NSString).abbreviatingWithTildeInPath
            row(
                symbol: folder == .screenshots ? "camera.viewfinder" : "arrow.down.circle.fill",
                colors: folder == .screenshots ? Tint.purple : Tint.mint,
                title: folder == .screenshots ? text("Ekran görüntüsü klasörü", "Screenshot folder") : text("İndirilenler klasörü", "Downloads folder"),
                subtitle: (folder == .screenshots
                    ? text("Yeni ekran görüntülerini görmek için: ", "To see new screenshots: ")
                    : text("İnen dosyaları görmek için: ", "To see downloaded files: ")) + name
            ) {
                HStack(spacing: 8) {
                    permissionBadge(state)
                    if state == .missing {
                        Button(text("Düzelt", "Fix")) { settings.requestFolderAccess(folder) }
                            .buttonStyle(IsloButtonStyle(prominent: true, accent: accent))
                    }
                }
            }
        }
    }

    private var accessibilitySteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            permissionStep(1, text("“İzin ver”e bas. macOS bir izin penceresi açar.", "Click “Allow”. macOS shows a permission prompt."))
            permissionStep(2, text("“Sistem Ayarları'nı Aç”ı seç ve listede islo.'nun anahtarını aç.", "Choose “Open System Settings” and switch islo. on in the list."))
            permissionStep(3, text("Bu sayfa birkaç saniye içinde kendiliğinden “Verildi” olur.", "This page changes to “Allowed” by itself within seconds."))
            Text(text("Güncellemeden sonra islo. listede açık görünse bile burada “Eksik” yazıyorsa yine “İzin ver”e bas; islo. eski kaydı kendisi temizler.", "If islo. looks switched on in the list after an update but this still says “Missing”, click “Allow” anyway; islo. clears the old entry itself."))
                .font(.system(size: 11))
                .foregroundStyle(IsloStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.1)))
        .padding(.leading, 44)
        .padding(.bottom, 12)
    }

    private func permissionStep(_ number: Int, _ message: String) -> some View {
        HStack(spacing: 9) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.orange))
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func automationRow(_ target: AutomationTarget) -> some View {
        let state = settings.automationStates[target] ?? .appClosed
        return row(symbol: target == .music ? "music.note" : "waveform", colors: target == .music ? Tint.red : Tint.green, title: target.name, subtitle: automationSubtitle(state)) {
            HStack(spacing: 8) {
                permissionBadge(state)
                if state == .missing || state == .notAsked {
                    Button(state == .missing ? text("Düzelt", "Fix") : text("İzin ver", "Allow")) {
                        settings.requestAutomationPermission(for: target)
                    }
                    .buttonStyle(IsloButtonStyle(prominent: true, accent: accent))
                }
            }
        }
    }

    private func automationSubtitle(_ state: PermissionState) -> String {
        switch state {
        case .missing:
            text("Kapalı olduğu için çalan şarkı gösterilemiyor ve kontrol edilemiyor. “Düzelt” macOS'un yeniden sormasını sağlar.", "It's off, so the current song can't be shown or controlled. “Fix” makes macOS ask again.")
        case .appClosed:
            text("Çalan şarkıyı göstermek ve kontrol etmek için. Durumu, uygulama açıkken görünür.", "To show and control the current song. Its status shows while the app is open.")
        case .appNotInstalled:
            text("Bu Mac'te yüklü değil.", "Not installed on this Mac.")
        case .granted, .notAsked:
            text("Çalan şarkıyı göstermek ve kontrol etmek için.", "To show and control the current song.")
        }
    }

    private func permissionBadge(_ state: PermissionState) -> some View {
        let style: (title: String, symbol: String, color: Color) = switch state {
        case .granted: (text("Verildi", "Allowed"), "checkmark.circle.fill", .green)
        case .missing: (text("Eksik", "Missing"), "exclamationmark.triangle.fill", .orange)
        case .notAsked: (text("Sorulmadı", "Not asked"), "questionmark.circle.fill", IsloStyle.muted)
        case .appClosed: (text("Uygulama kapalı", "App not running"), "moon.zzz.fill", IsloStyle.muted)
        case .appNotInstalled: (text("Yüklü değil", "Not installed"), "minus.circle.fill", IsloStyle.muted)
        }
        return Label(style.title, systemImage: style.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(style.color)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(style.color.opacity(0.14)))
            .fixedSize()
    }

    // MARK: About

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 84, height: 84)
                    .shadow(color: accent.opacity(0.4), radius: 22, y: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("islo.").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text(text("Mac'inin üstünde, gününün yanında.", "At the top of your Mac, close to your day."))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(IsloStyle.muted)
                    Text(versionText)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(accent.opacity(0.14)))
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(cardBackground(highlighted: true))

            section(text("Güncellemeler", "Updates")) {
                row(symbol: "arrow.down.circle.fill", colors: Tint.blue, title: text("Güncellemeleri denetle", "Check for updates"), subtitle: text("Yeni sürümler imzalı GitHub sürümlerinden gelir.", "New versions come from signed GitHub releases.")) {
                    Button(text("Şimdi denetle", "Check now")) { updateManager.checkForUpdates() }
                        .buttonStyle(IsloButtonStyle(prominent: true, accent: accent))
                        .disabled(!updateManager.canCheckForUpdates)
                }
                divider
                row(symbol: "arrow.triangle.2.circlepath", colors: Tint.teal, title: text("Otomatik güncelle", "Update automatically"), subtitle: text("Yeni sürümleri kendiliğinden indirip hazırlar.", "Downloads and prepares new versions by itself.")) {
                    switchControl(automaticUpdatesBinding)
                }
            }

            section(text("Bağlantılar", "Links")) {
                row(symbol: "globe", colors: Tint.indigo, title: text("Web sitesi", "Website"), subtitle: "ozdmrysn.github.io/islo") {
                    Button(text("Aç", "Open")) { open("https://ozdmrysn.github.io/islo/") }
                        .buttonStyle(IsloButtonStyle(accent: accent))
                }
                divider
                row(symbol: "chevron.left.forwardslash.chevron.right", colors: Tint.gray, title: "GitHub", subtitle: "github.com/OzdmrYsn/islo") {
                    Button(text("Aç", "Open")) { open("https://github.com/OzdmrYsn/islo") }
                        .buttonStyle(IsloButtonStyle(accent: accent))
                }
                divider
                row(symbol: "sparkles", colors: Tint.purple, title: text("Tanıtım", "Welcome guide"), subtitle: text("islo.'yu ilk açtığındaki tanıtımı yeniden göster.", "Show the guide from islo.'s first launch again.")) {
                    Button(text("Göster", "Show")) { onShowOnboarding() }
                        .buttonStyle(IsloButtonStyle(accent: accent))
                }
            }

            Text(text("Yasin Özdemir tarafından geliştirildi.", "Built by Yasin Özdemir."))
                .font(.system(size: 11.5))
                .foregroundStyle(IsloStyle.faint)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Building blocks

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased(with: Locale(identifier: settings.language == .turkish ? "tr_TR" : "en_US")))
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(IsloStyle.faint)
            .padding(.leading, 4)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel(title)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground(highlighted: false))
        }
    }

    private func row<Accessory: View>(symbol: String, colors: [Color], title: String, subtitle: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, colors: colors)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(IsloStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            accessory()
        }
        .padding(.vertical, 11)
    }

    /// A row whose control is too wide to sit beside the title.
    private func stackedRow<Content: View>(symbol: String, colors: [Color], title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: symbol, colors: colors)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(IsloStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content().padding(.leading, 44)
        }
        .padding(.vertical, 12)
    }

    private func sliderRow(symbol: String, colors: [Color], title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String) -> some View {
        // Rounded here rather than with `step:`, which draws a row of ticks.
        let stepped = Binding<Double>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max((($0 - range.lowerBound) / step).rounded() * step + range.lowerBound, range.lowerBound), range.upperBound) }
        )
        return row(symbol: symbol, colors: colors, title: title, subtitle: valueText) {
            Slider(value: stepped, in: range).frame(width: 200)
        }
    }

    private func switchControl(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(accent)
    }

    private var divider: some View {
        Rectangle().fill(IsloStyle.line).frame(height: 1).padding(.leading, 44)
    }

    private func cardBackground(highlighted: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: IsloStyle.cardRadius, style: .continuous)
        return shape
            .fill(IsloStyle.cardFill)
            .overlay {
                if highlighted {
                    shape.fill(LinearGradient(colors: [accent.opacity(0.1), .clear], startPoint: .topLeading, endPoint: .center))
                }
            }
            .overlay(shape.strokeBorder(IsloStyle.line, lineWidth: 1))
    }

    private func tip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(IsloStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 44)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private func bullet(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(accent).frame(width: 5, height: 5).padding(.top, 6)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(IsloStyle.text.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func noticeCard(message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12.5, weight: .medium))
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(IsloButtonStyle(prominent: true, accent: .orange))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
        )
    }

    private func inlineNotice(_ message: String, buttonTitle: String? = nil, action: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).foregroundStyle(IsloStyle.muted)
            Spacer()
            if let buttonTitle {
                Button(buttonTitle, action: action).buttonStyle(IsloButtonStyle(accent: accent))
            }
        }
        .padding(.leading, 44)
        .padding(.bottom, 12)
    }

    /// Up to seven shortcuts for the notch's Shortcuts tab, in the order
    /// they were picked.
    private var shortcutFavoritesPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(text("\(settings.shortcutFavorites.count)/7 seçili", "\(settings.shortcutFavorites.count) of 7 picked"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IsloStyle.muted)
                Spacer()
                if shortcutsManager.isLoading { ProgressView().controlSize(.small) }
                Button(text("Yenile", "Refresh"), action: shortcutsManager.reload)
                    .buttonStyle(IsloButtonStyle(accent: accent))
                Button(text("Kısayollar'ı aç", "Open Shortcuts"), action: shortcutsManager.openShortcutsApp)
                    .buttonStyle(IsloButtonStyle(accent: accent))
            }
            if shortcutsManager.available.isEmpty, !shortcutsManager.isLoading {
                Text(text("Hiç kısayol bulunamadı. Kısayollar uygulamasında bir kısayol oluşturup Yenile'ye bas.", "No shortcuts found. Create one in the Shortcuts app, then click Refresh."))
                    .font(.system(size: 12))
                    .foregroundStyle(IsloStyle.muted)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                        // By position: two shortcuts can share a name that
                        // Swift treats as equal (different Unicode forms).
                        ForEach(Array(shortcutsManager.available.enumerated()), id: \.offset) { _, name in
                            shortcutChip(name)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(.vertical, 14)
    }

    private func shortcutChip(_ name: String) -> some View {
        let isOn = settings.shortcutFavorites.contains(name)
        let isFull = !isOn && settings.shortcutFavorites.count >= 7
        return Button {
            if isOn {
                settings.shortcutFavorites.removeAll { $0 == name }
            } else if !isFull {
                settings.shortcutFavorites.append(name)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : IsloStyle.faint)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? Color.white : IsloStyle.text.opacity(0.8))
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? AnyShapeStyle(LinearGradient(colors: Tint.shortcuts, startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.white.opacity(0.06)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isFull ? 0.4 : 1)
        .disabled(isFull)
        .help(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func shortcutPicker(_ selection: Binding<String?>) -> some View {
        Picker("", selection: Binding(
            get: { selection.wrappedValue ?? "" },
            set: { selection.wrappedValue = $0.isEmpty ? nil : $0 }
        )) {
            Text(text("Yok", "None")).tag("")
            if let current = selection.wrappedValue, !shortcutsManager.available.contains(current) {
                Text(current).tag(current)
            }
            ForEach(Array(shortcutsManager.available.enumerated()), id: \.offset) { Text($0.element).tag($0.element) }
        }
        .labelsHidden()
        .frame(width: 190)
    }

    private var weatherCityPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(symbol: "mappin.and.ellipse", colors: Tint.sky, title: settings.weatherLocation?.name ?? text("Otomatik", "Automatic"), subtitle: weatherLocationText) {
                if settings.weatherLocation != nil {
                    Button(text("Otomatiğe dön", "Use automatic")) { settings.weatherLocation = nil }
                        .buttonStyle(IsloButtonStyle(accent: accent))
                }
            }
            divider
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(IsloStyle.faint)
                    TextField(text("Şehir ara", "Search city"), text: $weatherQuery)
                        .textFieldStyle(.plain)
                        .onSubmit(searchWeatherCity)
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(IsloStyle.line, lineWidth: 1))
                if isSearchingWeather { ProgressView().controlSize(.small) }
                Button(text("Ara", "Search"), action: searchWeatherCity)
                    .buttonStyle(IsloButtonStyle(prominent: true, accent: accent))
                    .disabled(weatherQuery.trimmingCharacters(in: .whitespaces).isEmpty || isSearchingWeather)
            }
            .padding(.leading, 44)
            .padding(.vertical, 12)
            if !weatherResults.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(weatherResults) { location in
                        Button {
                            settings.weatherLocation = location
                            weatherResults = []
                            weatherQuery = ""
                        } label: {
                            HStack(spacing: 6) {
                                Text(location.name).font(.system(size: 12, weight: .semibold))
                                Text(location.detail).font(.system(size: 11.5)).foregroundStyle(IsloStyle.muted)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
                .padding(.leading, 44)
                .padding(.bottom, 12)
            }
        }
    }

    private var weatherLocationText: String {
        if let location = settings.weatherLocation {
            return [location.name, location.detail].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return text("Mac'in saat dilimindeki şehir", "The city in your Mac's time zone")
    }

    private func searchWeatherCity() {
        let query = weatherQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearchingWeather = true
        Task {
            let results = await WeatherManager.search(query)
            weatherResults = results
            isSearchingWeather = false
        }
    }

    private func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
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

/// Click, then press a key combination; it becomes the shortcut.
private struct ShortcutRecorder: View {
    @Binding var hotKey: HotKey
    let language: AppLanguage
    let accent: Color
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: { isRecording ? stop() : start() }) {
            Text(isRecording ? language.value(turkish: "Tuşlara bas…", english: "Press keys…") : hotKey.displayString)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isRecording ? accent : IsloStyle.text)
                .frame(minWidth: 104)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isRecording ? accent.opacity(0.16) : Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isRecording ? accent : Color.white.opacity(0.12), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
        // Closing Settings only hides it, so onDisappear may not run.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            if isRecording { stop() }
        }
        .accessibilityLabel(Text(language.value(turkish: "Kısayol: ", english: "Shortcut: ") + hotKey.displayString))
    }

    private func start() {
        isRecording = true
        HotKeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            guard HotKey.isAllowed(keyCode: Int(event.keyCode), flags: event.modifierFlags) else {
                NSSound.beep()
                return nil
            }
            hotKey = HotKey(
                keyCode: UInt32(event.keyCode),
                modifiers: HotKey.carbonModifiers(from: event.modifierFlags)
            )
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotKeyManager.shared.resume()
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
        HStack(spacing: 10) {
            ForEach(AccentTheme.allCases) { theme in
                let isSelected = selection == theme
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = theme }
                } label: {
                    Circle()
                        .fill(LinearGradient(colors: [theme.color.opacity(0.85), theme.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(theme == .yellow || theme == .mint ? Color.black : Color.white)
                            }
                        }
                        .shadow(color: theme.color.opacity(isSelected ? 0.55 : 0), radius: 7)
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
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black)
                            .overlay {
                                LinearGradient(
                                    colors: [accent.opacity(tone.tintOpacity), accent.opacity(tone.tintOpacity * 0.35), .black],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                            .frame(height: 42)
                        Text(tone.title(language: language))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSelected ? IsloStyle.text : IsloStyle.muted)
                            .lineLimit(1)
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(isSelected ? 0.08 : 0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isSelected ? accent : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
