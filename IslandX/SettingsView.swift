import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared
    var onShowOnboarding: () -> Void = {}

    var body: some View {
        Form {
            Section(text("Genel", "General")) {
                Picker(
                    text("Dil", "Language"),
                    selection: $settings.language
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(
                    text(
                        "Mac açıldığında IslandX'i başlat",
                        "Launch IslandX when I log in"
                    ),
                    isOn: launchAtLoginBinding
                )

                if settings.launchAtLoginRequiresApproval {
                    HStack {
                        Text(
                            text(
                                "macOS onayı bekleniyor.",
                                "Waiting for macOS approval."
                            )
                        )
                        .foregroundStyle(.secondary)

                        Spacer()

                        Button(text("Giriş Öğelerini Aç", "Open Login Items")) {
                            settings.openLoginItemsSettings()
                        }
                    }
                } else if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(text("Görünüm", "Appearance")) {
                Picker(
                    text("IslandX düzeni", "IslandX layout"),
                    selection: $settings.contentMode
                ) {
                    ForEach(IslandContentMode.allCases) { mode in
                        Text(mode.title(language: settings.language))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(
                    settings.contentMode.subtitle(
                        language: settings.language
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ThemeChoicePicker(
                    selection: $settings.theme,
                    language: settings.language
                )
                    .padding(.vertical, 4)

                if settings.contentMode == .music {
                    Picker(
                        text("Çentik boşta görünümü", "Notch idle appearance"),
                        selection: $settings.notchIdleMode
                    ) {
                        ForEach(NotchIdleMode.allCases) { mode in
                            Text(mode.title(language: settings.language))
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(
                        settings.notchIdleMode.subtitle(
                            language: settings.language
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if settings.contentMode == .dashboard {
                Section(text("Genel Görünüm Özellikleri", "General View Features")) {
                    Toggle(
                        text(
                            "Üzerine gelince genişlet",
                            "Expand on hover"
                        ),
                        isOn: $settings.dashboardHoverExpansionEnabled
                    )

                    Toggle(
                        text(
                            "Boştayken kamera çentiğinde gizle",
                            "Hide inside the camera notch while idle"
                        ),
                        isOn: $settings.dashboardAutoHideWhenIdle
                    )

                    Toggle(
                        text(
                            "Reaktif ışık çizgisini göster",
                            "Show the reactive light line"
                        ),
                        isOn: $settings.dashboardReactiveLightEnabled
                    )

                    Toggle(
                        text(
                            "Güce bağlanınca şarj animasyonu göster",
                            "Show a charging animation when power connects"
                        ),
                        isOn: $settings.dashboardChargingAnimationEnabled
                    )

                    Text(
                        text(
                            "Bu seçenekler yalnızca Genel düzeni etkiler.",
                            "These options only affect the General layout."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button(
                            text(
                                "Genel Özellik Varsayılanlarını Geri Yükle",
                                "Restore General Feature Defaults"
                            )
                        ) {
                            settings.resetDashboardFeatureDefaults()
                        }
                    }
                }
            }

            Section(text("Etkileşim", "Interaction")) {
                if settings.contentMode == .music {
                    Picker(
                        text("Açılma davranışı", "Opening behavior"),
                        selection: $settings.activationMode
                    ) {
                        ForEach(NotchActivationMode.allCases) { mode in
                            Text(mode.title(language: settings.language))
                                .tag(mode)
                        }
                    }

                    Text(
                        settings.activationMode.subtitle(
                            language: settings.language
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Toggle(
                    text(
                        "Şarkı değiştiğinde geçici olarak göster",
                        "Temporarily show when the track changes"
                    ),
                    isOn: $settings.showOnTrackChange
                )

                if settings.showOnTrackChange {
                    LabeledContent(text("Gösterim süresi", "Display duration")) {
                        HStack(spacing: 10) {
                            Slider(
                                value: $settings.trackChangeDisplayDuration,
                                in: 2...8,
                                step: 0.5
                            )
                            .frame(width: 170)

                            Text("\(settings.trackChangeDisplayDuration, specifier: "%.1f") s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }

                Toggle(
                    text(
                        "Tam ekran uygulamalarda IslandX'i gizle",
                        "Hide IslandX over full-screen apps"
                    ),
                    isOn: $settings.hideInFullScreen
                )

                LabeledContent(text("Otomatik kapanma gecikmesi", "Automatic collapse delay")) {
                    HStack(spacing: 10) {
                        Slider(
                            value: $settings.collapseDelay,
                            in: 0.15...1.2,
                            step: 0.05
                        )
                        .frame(width: 170)

                        Text("\(settings.collapseDelay, specifier: "%.2f") s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                HStack {
                    Spacer()
                    Button(text("Etkileşim Varsayılanlarını Geri Yükle", "Restore Interaction Defaults")) {
                        settings.resetInteractionDefaults()
                    }
                }
            }

            Section(text("Güncellemeler", "Updates")) {
                Toggle(
                    text(
                        "Güncellemeleri otomatik indir ve kur",
                        "Automatically download and install updates"
                    ),
                    isOn: automaticUpdatesBinding
                )

                HStack {
                    Text(
                        text(
                            "Güncellemeler imzalı GitHub sürümlerinden alınır.",
                            "Updates are delivered from signed GitHub releases."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button(text("Şimdi Denetle", "Check Now")) {
                        updateManager.checkForUpdates()
                    }
                    .disabled(!updateManager.canCheckForUpdates)
                }
            }

            Section(text("Yardım", "Help")) {
                LabeledContent(text("Menü çubuğu", "Menu bar")) {
                    Text(
                        text(
                            "Ayarlar ve hızlı işlemler için IslandX simgesini kullanın.",
                            "Use the IslandX icon for settings and quick actions."
                        )
                    )
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(text("Tanıtımı Yeniden Göster", "Show Welcome Guide")) {
                        onShowOnboarding()
                    }

                    Spacer()

                    Text(versionText)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 580, height: 740)
        .preferredColorScheme(settings.theme.colorScheme)
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

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        return "IslandX \(version)"
    }
}

struct ThemeChoicePicker: View {
    @Binding var selection: AppTheme
    let language: AppLanguage

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    guard theme.isAvailable else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = theme
                    }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: theme.symbolName)
                            .font(.system(size: 22, weight: .semibold))

                        Text(theme.title(language: language))
                            .font(.system(size: 13, weight: .semibold))

                        Text(theme.subtitle(language: language))
                            .font(.caption)
                            .foregroundStyle(cardSecondaryColor(for: theme))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 104)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(cardBackground(for: theme))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                selection == theme
                                    ? Color.accentColor
                                    : Color.primary.opacity(0.1),
                                lineWidth: selection == theme ? 2 : 1
                            )
                    }
                    .contentShape(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .foregroundStyle(cardForegroundColor(for: theme))
                }
                .buttonStyle(.plain)
                .disabled(!theme.isAvailable)
                .opacity(theme.isAvailable ? 1 : 0.45)
                .accessibilityLabel(
                    Text(theme.title(language: language))
                )
                .accessibilityAddTraits(
                    selection == theme ? .isSelected : []
                )
            }
        }
    }

    private func cardBackground(for theme: AppTheme) -> Color {
        switch theme {
        case .system:
            return Color(nsColor: .controlBackgroundColor)
        case .light:
            return .white
        case .dark:
            return Color(red: 0.06, green: 0.065, blue: 0.08)
        case .liquidGlass:
            return Color.accentColor.opacity(0.12)
        }
    }

    private func cardForegroundColor(for theme: AppTheme) -> Color {
        switch theme {
        case .light: .black
        case .dark: .white
        case .system, .liquidGlass: .primary
        }
    }

    private func cardSecondaryColor(for theme: AppTheme) -> Color {
        cardForegroundColor(for: theme).opacity(0.62)
    }
}
