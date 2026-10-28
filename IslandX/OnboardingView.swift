import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared
    let onComplete: () -> Void

    @State private var step = 0

    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 52)
                .padding(.top, 42)
                .padding(.bottom, 24)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    pageIndicator

                    Spacer()

                    if step > 0 {
                        Button(text("Geri", "Back")) {
                            move(to: step - 1)
                        }
                    }

                    Button(
                        step == pageCount - 1
                            ? text("IslandX'i Kullanmaya Başla", "Start Using IslandX")
                            : text("Devam", "Continue")
                    ) {
                        if step == pageCount - 1 {
                            settings.completeOnboarding()
                            onComplete()
                        } else {
                            move(to: step + 1)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 24)
                .frame(height: 48)

                HStack(spacing: 5) {
                    Link("github.com/OzdmrYsn", destination: URL(string: "https://github.com/OzdmrYsn")!)
                        .foregroundStyle(.secondary)

                    Text("|")
                        .foregroundStyle(.tertiary)

                    Text("Yasin Özdemir")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .medium))
                .frame(height: 20)
            }
            .frame(height: 68)
        }
        .frame(width: 680, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(settings.theme.colorScheme)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch step {
        case 0:
            welcomePage
                .transition(pageTransition)
        case 1:
            controlsPage
                .transition(pageTransition)
        case 2:
            appearancePage
                .transition(pageTransition)
        default:
            startupAndUpdatesPage
                .transition(pageTransition)
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 18) {
            Picker("Language", selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 240)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
                .shadow(color: .accentColor.opacity(0.24), radius: 24)

            VStack(spacing: 10) {
                Text(text("IslandX'e Hoş Geldiniz", "Welcome to IslandX"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text(
                    text(
                        "Mac'inizin bir parçasına dönüşen medya kontrolleri — kamera çentiği varsa onunla bütünleşir, diğer ekranlarda kompakt bir yüzen ada olarak görünür.",
                        "Media controls that become part of your Mac — around the camera housing when present, and as a compact floating island on every other display."
                    )
                )
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
        }
    }

    private var controlsPage: some View {
        VStack(spacing: 28) {
            Text(text("Her zaman yakın, asla engel değil", "Always close, never in the way"))
                .font(.system(size: 27, weight: .bold, design: .rounded))

            HStack(spacing: 16) {
                featureCard(
                    symbol: "cursorarrow.motionlines",
                    title: text("Üzerine Gelin veya Tıklayın", "Hover or Click"),
                    message: text(
                        "Oynatma kontrollerini göstermek için işaretçiyi IslandX'in üzerine getirin veya tıklayın.",
                        "Move the pointer over IslandX or click it to reveal playback controls."
                    )
                )

                featureCard(
                    symbol: "music.note.list",
                    title: "Music & Spotify",
                    message: text(
                        "Kapak ve parça bilgilerini görün; uygulama değiştirmeden oynatmayı yönetin.",
                        "See artwork and track details, then control playback without changing apps."
                    )
                )

                featureCard(
                    symbol: "menubar.rectangle",
                    title: text("Menü Çubuğu Ayarları", "Menu Bar Settings"),
                    message: text(
                        "Görünümü ve davranışı istediğiniz zaman IslandX menü çubuğu simgesinden değiştirin.",
                        "Change appearance and behavior any time from the IslandX menu bar icon."
                    )
                )
            }

            Text(
                text(
                    "IslandX, Music veya Spotify ile ilk kez iletişim kurduğunda macOS Otomasyon izni isteyebilir.",
                    "macOS may ask for Automation permission the first time IslandX communicates with Music or Spotify."
                )
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var appearancePage: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(text("Tarzınızı seçin", "Make it yours"))
                    .font(.system(size: 27, weight: .bold, design: .rounded))

                Text(
                    text(
                        "Görünümü şimdi seçin. Daha sonra menü çubuğundan veya Ayarlar'dan değiştirebilirsiniz.",
                        "Choose an appearance now. You can change it later from the menu bar or Settings."
                    )
                )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ThemeChoicePicker(
                selection: $settings.theme,
                language: settings.language
            )

            VStack(spacing: 6) {
                Text(text("Çentik boşta görünümü", "Notch idle appearance"))
                    .font(.system(size: 13, weight: .semibold))

                Picker(
                    text("Çentik boşta görünümü", "Notch idle appearance"),
                    selection: $settings.notchIdleMode
                ) {
                    ForEach(NotchIdleMode.allCases) { mode in
                        Label(
                            mode.title(language: settings.language),
                            systemImage: mode.symbolName
                        )
                        .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                Text(
                    settings.notchIdleMode.subtitle(
                        language: settings.language
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            VStack(spacing: 6) {
                HStack {
                    Text(text("Açılma davranışı", "Opening behavior"))
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Picker(
                        text("Açılma davranışı", "Opening behavior"),
                        selection: $settings.activationMode
                    ) {
                        ForEach(NotchActivationMode.allCases) { mode in
                            Text(mode.title(language: settings.language))
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }

                Text(
                    settings.activationMode.subtitle(
                        language: settings.language
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)

            Spacer(minLength: 0)
        }
    }

    private var startupAndUpdatesPage: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(text("Son seçimler", "Final choices"))
                    .font(.system(size: 27, weight: .bold, design: .rounded))

                Text(
                    text(
                        "IslandX'in Mac'inizde nasıl çalışacağını belirleyin. Bu seçenekleri daha sonra Ayarlar'dan değiştirebilirsiniz.",
                        "Choose how IslandX behaves on your Mac. You can change these options later in Settings."
                    )
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            }

            preferenceCard(
                symbol: "power",
                title: text("Mac açıldığında başlat", "Launch at login"),
                message: text(
                    "Oturum açtığınızda IslandX otomatik olarak hazır olur.",
                    "IslandX is ready automatically whenever you log in."
                )
            ) {
                Toggle("", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            preferenceCard(
                symbol: "arrow.triangle.2.circlepath",
                title: text("Otomatik güncellemeler", "Automatic updates"),
                message: text(
                    "Yeni GitHub sürümlerini güvenli biçimde denetler, indirir ve hazır olduğunda kurar.",
                    "Securely checks, downloads, and installs new GitHub releases when ready."
                )
            ) {
                Toggle("", isOn: automaticUpdatesBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            loginItemStatusMessage

            Button(text("Güncellemeleri Şimdi Denetle", "Check for Updates Now")) {
                updateManager.checkForUpdates()
            }
            .disabled(!updateManager.canCheckForUpdates)

            Spacer(minLength: 0)
        }
    }

    private func preferenceCard<Accessory: View>(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            accessory()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private func featureCard(
        symbol: String,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.system(size: 14, weight: .semibold))

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(
                        index == step
                            ? Color.accentColor
                            : Color.secondary.opacity(0.25)
                    )
                    .frame(width: index == step ? 20 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .accessibilityLabel(
            Text(
                text(
                    "Sayfa \(step + 1) / \(pageCount)",
                    "Page \(step + 1) of \(pageCount)"
                )
            )
        )
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .trailing)),
            removal: .opacity.combined(with: .move(edge: .leading))
        )
    }

    private func move(to newStep: Int) {
        withAnimation(.easeInOut(duration: 0.24)) {
            step = min(max(newStep, 0), pageCount - 1)
        }
    }

    private func text(_ turkish: String, _ english: String) -> String {
        settings.language.value(turkish: turkish, english: english)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: settings.setLaunchAtLogin
        )
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(
            get: { updateManager.automaticUpdatesEnabled },
            set: updateManager.setAutomaticUpdates
        )
    }

    @ViewBuilder
    private var loginItemStatusMessage: some View {
        if settings.launchAtLoginRequiresApproval {
            HStack(spacing: 8) {
                Text(
                    text(
                        "macOS onayı bekleniyor.",
                        "Waiting for macOS approval."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button(text("Giriş Öğelerini Aç", "Open Login Items")) {
                    settings.openLoginItemsSettings()
                }
                .buttonStyle(.link)
            }
        } else if let error = settings.launchAtLoginError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
