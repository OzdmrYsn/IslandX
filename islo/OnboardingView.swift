import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared
    let onComplete: () -> Void

    @State private var step = 0
    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                pageContent
                    .id(step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 1040, height: 680)
        .background(background)
        .preferredColorScheme(.dark)
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().scaledToFit().frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Text("islo.").font(.system(size: 25, weight: .bold, design: .rounded))
            Spacer()
            pageIndicator
            Spacer()
            Picker("Language", selection: $settings.language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 150)
        }
        .padding(.horizontal, 34).padding(.top, 24).padding(.bottom, 10)
    }

    @ViewBuilder private var pageContent: some View {
        switch step {
        case 0: welcomePage
        case 1: commandEchoPage
        case 2: appearancePage
        case 3: interactionPage
        default: finishPage
        }
    }

    private var welcomePage: some View {
        onboardingPage {
            eyebrow(text("HOŞ GELDİNİZ", "WELCOME"))
            Text(text("Mac'inizin üstünde.\nGününüze yakın.", "At the top of your Mac.\nClose to your day."))
                .font(.system(size: 44, weight: .bold, design: .rounded)).tracking(-1.2)
            Text(text("islo.; müziğinizi, sistem değişikliklerini ve günlük araçları kamera çentiğiyle birleştirir.", "islo. blends your music, system changes, and everyday utilities into the camera notch."))
                .font(.system(size: 16)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                featureLine("music.note", text("Müzik ve Spotify kontrolleri", "Music and Spotify controls"))
                featureLine("waveform.path", text("Ses ve parlaklık için Command Echo", "Command Echo for volume and brightness"))
                featureLine("tray.full", text("Dosya rafı, AirDrop ve odak araçları", "File shelf, AirDrop, and focus utilities"))
            }.padding(.top, 10)
        } preview: {
            WelcomePreview()
        }
    }

    private var commandEchoPage: some View {
        onboardingPage {
            eyebrow("COMMAND ECHO")
            Text(text("Sistem hareketleri\nçentiğin içinde.", "System feedback,\ninside the notch."))
                .font(.system(size: 38, weight: .bold, design: .rounded)).tracking(-0.8)
            Text(text("Ses, parlaklık, kopyalama, ekran görüntüsü ve Caps Lock değişikliklerini ekranın ortasında ayrı bir kutu yerine islo. gösterir.", "islo. shows volume, brightness, copy, screenshot, and Caps Lock changes instead of a detached box in the middle of the screen."))
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            permissionRow(symbol: "waveform.path", title: "Command Echo", message: text("İstediğiniz zaman Ayarlar'dan kapatabilirsiniz.", "You can turn it off any time in Settings."), isOn: $settings.dashboardCommandEchoEnabled)
            permissionRow(symbol: "tray.and.arrow.down", title: text("Dosya Rafı + AirDrop", "File Shelf + AirDrop"), message: text("Dosyaları çentiğe sürükleyin.", "Drag files onto the notch."), isOn: $settings.dashboardFileShelfEnabled)
            Button(text("macOS göstergesini gizlemek için izin ver", "Allow hiding the macOS indicator")) {
                settings.requestAccessibilityPermission()
            }
            .buttonStyle(.bordered)
            .disabled(settings.isAccessibilityTrusted)
        } preview: {
            CommandEchoPreview()
        }
    }

    private var appearancePage: some View {
        onboardingPage {
            eyebrow(text("GÖRÜNÜM", "APPEARANCE"))
            Text(text("Çentik, Mac'inizin\nbir parçası gibi.", "A notch that feels\npart of your Mac."))
                .font(.system(size: 38, weight: .bold, design: .rounded)).tracking(-0.8)
            Text(text("Tema rengini ve islo.'nun boşta nasıl görüneceğini seçin.", "Choose the theme color and how islo. looks while idle."))
                .font(.system(size: 15)).foregroundStyle(.secondary)
            AccentSwatchPicker(selection: $settings.accentTheme, language: settings.language)
            Picker("", selection: $settings.notchIdleMode) {
                ForEach(NotchIdleMode.allCases) { mode in Text(mode.title(language: settings.language)).tag(mode) }
            }.labelsHidden().pickerStyle(.segmented)
        } preview: {
            AppearancePreview(hidden: settings.notchIdleMode == .hiddenMini)
        }
    }

    private var interactionPage: some View {
        onboardingPage {
            eyebrow(text("ETKİLEŞİM", "INTERACTION"))
            Text(text("Sizin istediğiniz anda\naçılır.", "It opens exactly\nwhen you want."))
                .font(.system(size: 38, weight: .bold, design: .rounded)).tracking(-0.8)
            Text(text("Hover, tıklama veya çentiğin belirli bir bölgesini kullanabilirsiniz.", "Use hover, click, or a dedicated activation area."))
                .font(.system(size: 15)).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(NotchActivationMode.allCases) { mode in
                    wideChoice(symbol: activationSymbol(mode), title: mode.title(language: settings.language), subtitle: mode.subtitle(language: settings.language), selected: settings.activationMode == mode) {
                        settings.activationMode = mode
                    }
                }
            }
        } preview: {
            InteractionPreview()
        }
    }

    private var finishPage: some View {
        onboardingPage {
            eyebrow(text("SON ADIM", "ONE LAST STEP"))
            Text(text("islo. hazır.", "islo. is ready."))
                .font(.system(size: 42, weight: .bold, design: .rounded))
            Text(text("Bu seçimlerin tamamını daha sonra yeni Ayarlar ekranından değiştirebilirsiniz.", "You can change every choice later from the redesigned Settings window."))
                .font(.system(size: 15)).foregroundStyle(.secondary)
            permissionRow(symbol: "power", title: text("Mac açıldığında başlat", "Launch at login"), message: text("Oturum açtığınızda hazır olsun.", "Be ready when you log in."), isOn: launchAtLoginBinding)
            permissionRow(symbol: "arrow.triangle.2.circlepath", title: text("Otomatik güncellemeler", "Automatic updates"), message: text("Yeni sürümleri otomatik alın.", "Receive new releases automatically."), isOn: automaticUpdatesBinding)
            if settings.launchAtLoginRequiresApproval {
                Button(text("macOS Giriş Öğelerini Aç", "Open macOS Login Items")) { settings.openLoginItemsSettings() }
            }
        } preview: {
            FinishPreview()
        }
    }

    private func onboardingPage<Left: View, Right: View>(@ViewBuilder left: () -> Left, @ViewBuilder preview: () -> Right) -> some View {
        HStack(spacing: 48) {
            VStack(alignment: .leading, spacing: 20) { left(); Spacer(minLength: 0) }
                .frame(maxWidth: .infinity, alignment: .leading)
            preview().frame(width: 400, height: 430)
        }
        .padding(.horizontal, 58).padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            if step > 0 { Button { move(to: step - 1) } label: { Label(text("Geri", "Back"), systemImage: "chevron.left") }.buttonStyle(.plain) }
            Spacer()
            Text("github.com/OzdmrYsn  |  Yasin Özdemir").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            if step < pageCount - 1 {
                Button(text("Daha sonra", "Set up later")) { move(to: pageCount - 1) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button(step == pageCount - 1 ? text("islo.'yu Başlat", "Start islo.") : text("Devam", "Continue")) {
                if step == pageCount - 1 { settings.completeOnboarding(); onComplete() } else { move(to: step + 1) }
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 34).padding(.vertical, 22)
    }

    private var background: some View {
        IsloWindowBackground(accent: accent, tone: settings.surfaceTone)
    }

    private func eyebrow(_ value: String) -> some View {
        Text(value).font(.system(size: 11, weight: .bold)).tracking(1.8).foregroundStyle(accent)
    }

    private func featureLine(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func permissionRow(symbol: String, title: String, message: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(accent).frame(width: 32, height: 32).background(Circle().fill(accent.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13, weight: .semibold)); Text(message).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }.padding(13).background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
    }

    private func wideChoice(symbol: String, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(selected ? accent : .secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 13, weight: .semibold)); Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer(); Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? accent : Color.secondary.opacity(0.45))
            }.padding(12).background(RoundedRectangle(cornerRadius: 13).fill(Color.primary.opacity(selected ? 0.07 : 0.035)))
        }.buttonStyle(.plain)
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) { ForEach(0..<pageCount, id: \.self) { index in Capsule().fill(index <= step ? accent : Color.secondary.opacity(0.18)).frame(width: index == step ? 20 : 8, height: 6) } }
            .animation(.easeInOut(duration: 0.2), value: step)
    }

    private var pageTransition: AnyTransition { .asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)), removal: .opacity.combined(with: .move(edge: .leading))) }
    private func move(to value: Int) { withAnimation(.easeInOut(duration: 0.28)) { step = min(max(value, 0), pageCount - 1) } }
    private func activationSymbol(_ mode: NotchActivationMode) -> String { switch mode { case .hover: "cursorarrow.motionlines"; case .click: "cursorarrow.click"; case .activationZone: "viewfinder" } }
    private func text(_ tr: String, _ en: String) -> String { settings.language.value(turkish: tr, english: en) }
    private var accent: Color { settings.accentTheme.color }
    private var launchAtLoginBinding: Binding<Bool> { Binding(get: { settings.launchAtLogin }, set: settings.setLaunchAtLogin) }
    private var automaticUpdatesBinding: Binding<Bool> { Binding(get: { updateManager.automaticUpdatesEnabled }, set: updateManager.setAutomaticUpdates) }
}

private struct WelcomePreview: View {
    var body: some View {
        ZStack {
            previewBackground
            VStack(spacing: 26) {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 132, height: 132).shadow(color: .pink.opacity(0.22), radius: 28)
                Text("islo.").font(.system(size: 36, weight: .bold, design: .rounded))
                NotchMockup(left: "music.note", right: "waveform")
            }
        }.clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

private struct CommandEchoPreview: View {
    @State private var level = 0.18
    var body: some View {
        ZStack {
            previewBackground
            VStack(spacing: 28) {
                NotchLevelMockup(level: level)
                HStack { Image(systemName: "speaker.fill"); Slider(value: $level); Text("\(Int(level * 100))%").monospacedDigit() }.padding(18).background(RoundedRectangle(cornerRadius: 18).fill(.thinMaterial))
            }.padding(26)
        }.clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

private struct AppearancePreview: View {
    let hidden: Bool
    var body: some View {
        ZStack { previewBackground; VStack(spacing: 30) { NotchMockup(left: hidden ? "" : "music.note", right: hidden ? "" : "waveform"); Text(hidden ? "Hidden Mini" : "Visible Island").font(.headline).foregroundStyle(.secondary) } }
            .clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

private struct InteractionPreview: View {
    @State private var expanded = false
    var body: some View {
        ZStack {
            previewBackground
            VStack(spacing: 24) {
                RoundedRectangle(cornerRadius: expanded ? 28 : 14).fill(.black).frame(width: expanded ? 330 : 180, height: expanded ? 150 : 48).overlay(Image(systemName: expanded ? "pause.fill" : "cursorarrow.motionlines").foregroundStyle(.white))
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: expanded)
                Button(expanded ? "Collapse" : "Hover / Click") { expanded.toggle() }.buttonStyle(.borderedProminent)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

private struct FinishPreview: View {
    var body: some View {
        ZStack { previewBackground; VStack(spacing: 22) { Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 144, height: 144); Image(systemName: "checkmark.circle.fill").font(.system(size: 42)).foregroundStyle(.green); Text("Ready.").font(.title2.bold()) } }
            .clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

private struct NotchMockup: View {
    let left: String; let right: String
    var body: some View {
        HStack(spacing: 0) {
            wing(left); Rectangle().fill(.black).frame(width: 118, height: 34); wing(right)
        }.foregroundStyle(.white)
    }
    private func wing(_ symbol: String) -> some View { RoundedRectangle(cornerRadius: 13).fill(.black).frame(width: 76, height: 56).overlay(Group { if !symbol.isEmpty { Image(systemName: symbol).foregroundStyle(symbol == "waveform" ? .orange : .white) } }) }
}

private struct NotchLevelMockup: View {
    let level: Double
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"); Spacer(); Text("\(Int(level * 100))%").font(.headline.monospacedDigit()) }.padding(.horizontal, 24).frame(height: 52)
            GeometryReader { proxy in ZStack(alignment: .leading) { Rectangle().fill(.white.opacity(0.1)); Rectangle().fill(LinearGradient(colors: [.pink, .orange, .yellow], startPoint: .leading, endPoint: .trailing)).frame(width: proxy.size.width * level) } }.frame(height: 4)
        }.foregroundStyle(.white).frame(width: 330).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 18)).shadow(color: .pink.opacity(level * 0.5), radius: 16)
    }
}

private var previewBackground: some View { LinearGradient(colors: [Color(nsColor: .controlBackgroundColor), Color.accentColor.opacity(0.08), Color.pink.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing) }
