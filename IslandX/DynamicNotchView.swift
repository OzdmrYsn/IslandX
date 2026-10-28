import AppKit
import Combine
import SwiftUI

enum NotchPresentationState: Equatable {
    case idle
    case expanded
}

private enum DashboardSection: String, CaseIterable {
    case home
    case calendar
    case timer
    case battery
}

/// Derives the camera-housing geometry from AppKit's safe display regions.
/// This intentionally detects the active screen rather than a Mac model name,
/// so new MacBooks and external displays inherit the correct presentation.
struct NotchLayout: Equatable {
    let idleWidth: CGFloat
    let notchBandHeight: CGFloat
    let cameraHousingWidth: CGFloat
    let expandedWidth: CGFloat
    let screenWidth: CGFloat

    private static let compactWingWidth: CGFloat = 52

    init(screen: NSScreen?) {
        guard let screen else {
            idleWidth = 176
            notchBandHeight = 0
            cameraHousingWidth = 0
            expandedWidth = 460
            screenWidth = 724
            return
        }

        screenWidth = screen.frame.width
        expandedWidth = min(460, max(screen.frame.width - 24, 320))

        guard screen.safeAreaInsets.top > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            idleWidth = 176
            notchBandHeight = 0
            cameraHousingWidth = 0
            return
        }

        let measuredHousingWidth = rightArea.minX - leftArea.maxX
        let areasTouchTopEdge =
            abs(leftArea.maxY - screen.frame.maxY) < 1 &&
            abs(rightArea.maxY - screen.frame.maxY) < 1

        guard measuredHousingWidth > 0, areasTouchTopEdge else {
            idleWidth = 176
            notchBandHeight = 0
            cameraHousingWidth = 0
            return
        }

        cameraHousingWidth = measuredHousingWidth
        notchBandHeight = screen.safeAreaInsets.top
        idleWidth = measuredHousingWidth + Self.compactWingWidth * 2
    }

    var hasCameraHousing: Bool {
        cameraHousingWidth > 0 && notchBandHeight > 0
    }

    var compactWingWidth: CGFloat {
        Self.compactWingWidth
    }

    var idleHeight: CGFloat {
        hasCameraHousing ? notchBandHeight + 12 : 38
    }

    var expandedShoulderHeight: CGFloat {
        hasCameraHousing ? notchBandHeight + 8 : 0
    }

    func size(
        for state: NotchPresentationState,
        idleMode: NotchIdleMode = .visibleIsland,
        contentMode: IslandContentMode = .music
    ) -> CGSize {
        switch state {
        case .idle:
            if hasCameraHousing, idleMode == .hiddenMini {
                return CGSize(
                    width: cameraHousingWidth,
                    height: notchBandHeight
                )
            }

            return CGSize(
                width: idleWidth,
                height: idleHeight
            )
        case .expanded:
            if contentMode == .dashboard {
                return CGSize(
                    width: min(700, max(screenWidth - 24, 600)),
                    height: hasCameraHousing ? 216 : 204
                )
            }
            return CGSize(
                width: expandedWidth,
                height: hasCameraHousing ? 136 : 124
            )
        }
    }

    var expandedTopPadding: CGFloat {
        hasCameraHousing ? expandedShoulderHeight + 2 : 8
    }
}

struct DynamicNotchView: View {
    @ObservedObject private var mediaManager: MediaManager
    @ObservedObject private var settings: AppSettings

    private let layout: NotchLayout
    private let onPreferredSizeChange: (CGSize, Bool) -> Void

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    @Environment(\.colorScheme)
    private var systemColorScheme

    @Namespace private var artworkNamespace

    @State private var presentation: NotchPresentationState = .idle
    @State private var isPinned = false
    @State private var isPointerInside = false
    @State private var isInteracting = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var trackChangeTask: Task<Void, Never>?
    @State private var isTemporaryTrackPreview = false
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var expansionProgress: CGFloat = 0
    @State private var dashboardSection: DashboardSection = .home

    init(
        mediaManager: MediaManager,
        settings: AppSettings,
        layout: NotchLayout,
        onPreferredSizeChange: @escaping (CGSize, Bool) -> Void = { _, _ in }
    ) {
        _mediaManager = ObservedObject(wrappedValue: mediaManager)
        _settings = ObservedObject(wrappedValue: settings)
        self.layout = layout
        self.onPreferredSizeChange = onPreferredSizeChange
    }

    var body: some View {
        ZStack(alignment: .top) {
            if presentation == .idle {
                compactContent
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.96, anchor: .top)
                        )
                    )
            } else {
                expandedContent
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.96, anchor: .top)
                        )
                    )
            }
        }
        .frame(
            width: preferredSize.width,
            height: preferredSize.height,
            alignment: .top
        )
        .background {
            if isHiddenMiniIdle {
                Color.clear
            } else {
                notchBackground
            }
        }
        .clipShape(notchShape)
        .overlay {
            if !layout.hasCameraHousing {
                notchShape
                    .stroke(primaryColor.opacity(0.13), lineWidth: 0.5)
            }
        }
        .contentShape(notchShape)
        .onContinuousHover(perform: handleContinuousHover)
        .onAppear {
            scrubValue = mediaManager.playbackPosition
            expansionProgress = presentation == .expanded ? 1 : 0
            onPreferredSizeChange(preferredSize, false)
        }
        .onDisappear {
            hoverTask?.cancel()
            trackChangeTask?.cancel()
        }
        .onReceive(mediaManager.$playbackPosition) { newValue in
            guard !isScrubbing else { return }
            scrubValue = newValue
        }
        .onReceive(mediaManager.$duration) { newDuration in
            guard !isScrubbing else { return }
            scrubValue = min(scrubValue, max(newDuration, 0))
        }
        .onChange(of: settings.activationMode) { mode in
            if mode == .click,
               !isPinned,
               !isTemporaryTrackPreview,
               presentation == .expanded {
                setPresentation(.idle)
            }
        }
        .onChange(of: settings.notchIdleMode) { _ in
            guard presentation == .idle else { return }
            onPreferredSizeChange(preferredSize, !reduceMotion)
        }
        .onChange(of: settings.contentMode) { _ in
            guard presentation == .expanded else { return }
            onPreferredSizeChange(preferredSize, !reduceMotion)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .islandXExpand)
        ) { _ in
            hoverTask?.cancel()
            trackChangeTask?.cancel()
            isTemporaryTrackPreview = false
            isPinned = true
            setPresentation(.expanded)
        }
        .onReceive(mediaManager.$trackChangeRevision.dropFirst()) { _ in
            showTrackChangePreviewIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .islandXCollapse)
        ) { _ in
            hoverTask?.cancel()
            trackChangeTask?.cancel()
            isTemporaryTrackPreview = false
            isPinned = false
            setPresentation(.idle)
        }
        .contextMenu {
            Menu(localized("IslandX Düzeni", "IslandX Layout")) {
                ForEach(IslandContentMode.allCases) { mode in
                    Button {
                        settings.contentMode = mode
                    } label: {
                        Label(
                            mode.title(language: settings.language),
                            systemImage: settings.contentMode == mode
                                ? "checkmark"
                                : (mode == .music
                                    ? "music.note"
                                    : "rectangle.split.2x1.fill")
                        )
                    }
                }
            }

            Menu(localized("Görünüm", "Appearance")) {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        guard theme.isAvailable else { return }
                        settings.theme = theme
                    } label: {
                        Label(
                            theme.title(language: settings.language),
                            systemImage: settings.theme == theme
                                ? "checkmark"
                                : theme.symbolName
                        )
                    }
                    .disabled(!theme.isAvailable)
                }
            }

            Menu(localized("Çentik Boşta Görünümü", "Notch Idle Appearance")) {
                ForEach(NotchIdleMode.allCases) { mode in
                    Button {
                        settings.notchIdleMode = mode
                    } label: {
                        Label(
                            mode.title(language: settings.language),
                            systemImage: settings.notchIdleMode == mode
                                ? "checkmark"
                                : mode.symbolName
                        )
                    }
                }
            }

            Menu(localized("Açılma Davranışı", "Opening Behavior")) {
                ForEach(NotchActivationMode.allCases) { mode in
                    Button {
                        settings.activationMode = mode
                    } label: {
                        Label(
                            mode.title(language: settings.language),
                            systemImage: settings.activationMode == mode
                                ? "checkmark"
                                : "cursorarrow.motionlines"
                        )
                    }
                }
            }

            Button(localized("Ayarlar…", "Settings…")) {
                NotificationCenter.default.post(
                    name: .islandXShowSettings,
                    object: nil
                )
            }

            Divider()

            Button(localized("IslandX'ten Çık", "Quit IslandX")) {
                NSApp.terminate(nil)
            }
        }
        .accessibilityElement(children: .contain)
        .preferredColorScheme(settings.theme.colorScheme)
    }

    // MARK: - Compact UI

    private var compactContent: some View {
        Button {
            hoverTask?.cancel()
            trackChangeTask?.cancel()
            isTemporaryTrackPreview = false
            isPinned = true
            setPresentation(.expanded)
        } label: {
            Group {
                if isHiddenMiniIdle {
                    Color.clear
                } else if layout.hasCameraHousing {
                    notchedCompactContent
                } else {
                    standardCompactContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(notchShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(compactAccessibilityText))
        .accessibilityHint(Text("Shows media controls"))
        .help("Open media controls")
    }

    private var notchedCompactContent: some View {
        HStack(spacing: 0) {
            artwork(size: 27, cornerRadius: 7)
                .frame(width: layout.compactWingWidth)

            Color.clear
                .frame(width: layout.cameraHousingWidth)
                .accessibilityHidden(true)

            PlaybackWaveform(isPlaying: mediaManager.isPlaying)
                .foregroundStyle(playbackIndicatorColor)
                .frame(width: layout.compactWingWidth)
                .accessibilityHidden(true)
        }
    }

    private var standardCompactContent: some View {
        HStack(spacing: 8) {
            artwork(size: 27, cornerRadius: 7)

            Spacer(minLength: 30)

            PlaybackWaveform(isPlaying: mediaManager.isPlaying)
                .foregroundStyle(playbackIndicatorColor)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
    }

    private var playbackIndicatorColor: Color {
        mediaManager.isPlaying
            ? .green
            : primaryColor.opacity(0.55)
    }

    // MARK: - Expanded UI

    @ViewBuilder
    private var expandedContent: some View {
        if settings.contentMode == .dashboard {
            dashboardExpandedContent
        } else if layout.hasCameraHousing {
            notchedExpandedContent
        } else {
            standardExpandedContent
        }
    }

    private var dashboardExpandedContent: some View {
        VStack(spacing: 0) {
            dashboardNavigationRow

            HStack(spacing: 18) {
                dashboardMediaPane

                Divider()
                    .overlay(primaryColor.opacity(0.13))
                    .padding(.vertical, 4)

                dashboardSidePane
                    .frame(width: 210)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var dashboardNavigationRow: some View {
        Group {
            if layout.hasCameraHousing {
                HStack(spacing: 0) {
                    dashboardNavigationLeading
                        .padding(.trailing, 12)
                        .frame(
                            width: dashboardNotchWingWidth,
                            alignment: .trailing
                        )

                    Color.clear
                        .frame(width: layout.cameraHousingWidth)
                        .accessibilityHidden(true)

                    dashboardNavigationTrailing
                        .padding(.leading, 12)
                        .frame(
                            width: dashboardNotchWingWidth,
                            alignment: .leading
                        )
                }
                .frame(height: max(layout.notchBandHeight + 8, 38))
            } else {
                HStack(spacing: 8) {
                    dashboardNavigationLeading
                    Spacer(minLength: 12)
                    dashboardNavigationTrailing
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
        }
        .foregroundStyle(primaryColor.opacity(0.78))
        .padding(.bottom, 8)
    }

    private var dashboardNavigationLeading: some View {
        HStack(spacing: 8) {
            Button {
                selectDashboardSection(.home)
            } label: {
                Label(localized("Ana", "Home"), systemImage: "house.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(
                        Capsule().fill(
                            dashboardSection == .home
                                ? primaryColor.opacity(0.16)
                                : Color.clear
                        )
                    )
            }
            .buttonStyle(.plain)
            .help(localized("Ana özeti göster", "Show home summary"))

            dashboardNavigationIcon("calendar", section: .calendar)
            dashboardNavigationIcon("timer", section: .timer)
            dashboardNavigationIcon("battery.75percent", section: .battery)
        }
    }

    private var dashboardNavigationTrailing: some View {
        HStack(spacing: 8) {
            Text(localized("GENEL", "GENERAL"))
                .font(.system(size: 8, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(primaryColor.opacity(0.38))

            smallUtilityButton(
                icon: "gearshape.fill",
                label: localized("Ayarlar", "Settings")
            ) {
                NotificationCenter.default.post(
                    name: .islandXShowSettings,
                    object: nil
                )
            }

            smallUtilityButton(
                icon: "chevron.up",
                label: localized("Küçült", "Collapse")
            ) {
                isPinned = false
                setPresentation(.idle)
            }
        }
    }

    private var dashboardNotchWingWidth: CGFloat {
        max((preferredSize.width - layout.cameraHousingWidth) / 2, 0)
    }

    private func dashboardNavigationIcon(
        _ name: String,
        section: DashboardSection
    ) -> some View {
        Button {
            selectDashboardSection(section)
        } label: {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    dashboardSection == section
                        ? primaryColor
                        : primaryColor.opacity(0.5)
                )
                .frame(width: 27, height: 27)
                .background(
                    Circle().fill(
                        dashboardSection == section
                            ? primaryColor.opacity(0.14)
                            : Color.clear
                    )
                )
        }
        .buttonStyle(.plain)
        .help(dashboardSectionLabel(section))
    }

    private func selectDashboardSection(_ section: DashboardSection) {
        withAnimation(.easeInOut(duration: 0.18)) {
            dashboardSection = section
        }
    }

    private var dashboardMediaPane: some View {
        VStack(spacing: 7) {
            HStack(spacing: 11) {
                sourceArtwork(size: 48, cornerRadius: 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text(trackTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)

                    Text(artistTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(primaryColor.opacity(0.55))
                        .lineLimit(1)

                }

                Spacer(minLength: 8)

                sourceTile
            }

            progressSection
                .offset(y: 0)

            HStack(spacing: 10) {
                compactPlaybackControls

                Divider()
                    .overlay(primaryColor.opacity(0.12))
                    .frame(height: 22)

                volumeSection
                    .frame(maxWidth: 128)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dashboardSidePane: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 7) {
                Text(dashboardEyebrow(context.date))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.red.opacity(0.85))

                HStack(alignment: .firstTextBaseline) {
                    Text(dashboardHeadline(context.date))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)

                    Spacer()

                    Text(dashboardTrailingText(context.date))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(primaryColor.opacity(0.58))
                }

                dashboardPrimaryCard(date: context.date)

                Text(localized("Sıradaki", "Up next"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.4))

                dashboardSecondaryCard(date: context.date)
            }
        }
    }

    @ViewBuilder
    private func dashboardPrimaryCard(date: Date) -> some View {
        switch dashboardSection {
        case .home:
            dashboardSummaryCard(
                icon: "calendar.badge.checkmark",
                title: localized("Bugün için hazırsın", "You're clear for today"),
                subtitle: localized("Takvimi aç", "Open Calendar"),
                action: openCalendar
            )
        case .calendar:
            dashboardSummaryCard(
                icon: "calendar",
                title: localized("Takvimi aç", "Open Calendar"),
                subtitle: dashboardLongDate(date),
                action: openCalendar
            )
        case .timer:
            dashboardSummaryCard(
                icon: "timer",
                title: localized("Zamanlayıcıları aç", "Open timers"),
                subtitle: localized("Saat uygulamasında yönet", "Manage in the Clock app"),
                action: openClock
            )
        case .battery:
            dashboardSummaryCard(
                icon: "battery.75percent",
                title: localized("Pil ayarlarını aç", "Open Battery settings"),
                subtitle: localized("Enerji kullanımını yönet", "Manage energy usage"),
                action: openBatterySettings
            )
        }
    }

    @ViewBuilder
    private func dashboardSecondaryCard(date: Date) -> some View {
        switch dashboardSection {
        case .home, .calendar:
            dashboardSummaryCard(
                icon: "plus",
                title: localized("Yeni etkinlik", "New event"),
                subtitle: localized("Takvim'de oluştur", "Create in Calendar"),
                action: openCalendar
            )
        case .timer:
            dashboardSummaryCard(
                icon: "alarm",
                title: localized("Alarm ve kronometre", "Alarm and stopwatch"),
                subtitle: localized("Saat'i öne getir", "Bring Clock forward"),
                action: openClock
            )
        case .battery:
            dashboardSummaryCard(
                icon: ProcessInfo.processInfo.isLowPowerModeEnabled
                    ? "leaf.fill"
                    : "leaf",
                title: ProcessInfo.processInfo.isLowPowerModeEnabled
                    ? localized("Düşük Güç açık", "Low Power is on")
                    : localized("Düşük Güç kapalı", "Low Power is off"),
                subtitle: localized("Pil ayarlarında değiştir", "Change in Battery settings"),
                action: openBatterySettings
            )
        }
    }

    private func dashboardSummaryCard(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 8))
                        .foregroundStyle(primaryColor.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(primaryColor.opacity(0.3))
            }
            .padding(.horizontal, 9)
            .frame(height: 39)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(primaryColor.opacity(0.075))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func dashboardSectionLabel(_ section: DashboardSection) -> String {
        switch section {
        case .home: localized("Ana", "Home")
        case .calendar: localized("Takvim", "Calendar")
        case .timer: localized("Zamanlayıcı", "Timer")
        case .battery: localized("Pil", "Battery")
        }
    }

    private func dashboardEyebrow(_ date: Date) -> String {
        switch dashboardSection {
        case .home, .calendar: dashboardWeekday(date).uppercased()
        case .timer: localized("ZAMANLAYICI", "TIMER")
        case .battery: localized("PİL", "BATTERY")
        }
    }

    private func dashboardHeadline(_ date: Date) -> String {
        switch dashboardSection {
        case .home, .calendar: dashboardDate(date)
        case .timer: dashboardTime(date)
        case .battery: localized("Enerji", "Energy")
        }
    }

    private func dashboardTrailingText(_ date: Date) -> String {
        switch dashboardSection {
        case .home, .calendar: dashboardTime(date)
        case .timer: localized("Saat", "Clock")
        case .battery:
            ProcessInfo.processInfo.isLowPowerModeEnabled
                ? localized("Açık", "On")
                : localized("Kapalı", "Off")
        }
    }

    private func dashboardLongDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.language == .turkish ? "tr_TR" : "en_US")
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }

    private func openCalendar() {
        openApplication(bundleIdentifier: "com.apple.iCal")
    }

    private func openClock() {
        openApplication(bundleIdentifier: "com.apple.clock")
    }

    private func openBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openApplication(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return }

        NSWorkspace.shared.open(url)
    }

    private func dashboardWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.language == .turkish ? "tr_TR" : "en_US")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func dashboardDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.language == .turkish ? "tr_TR" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }

    private func dashboardTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// On a MacBook display the camera housing becomes the visual centre of the
    /// control. Content lives in its two side wings, so expanding feels like the
    /// physical notch widening instead of a card dropping down from it.
    private var notchedExpandedContent: some View {
        VStack(spacing: 4) {
            notchAccessoryRow

            HStack(spacing: 10) {
                sourceArtwork(size: 52, cornerRadius: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(trackTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(artistTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(primaryColor.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    compactPlaybackControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                sourceTile
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            HStack(alignment: .center, spacing: 10) {
                progressSection

                Divider()
                    .overlay(primaryColor.opacity(0.12))
                    .frame(height: 24)

                volumeSection
                    .frame(width: 112)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var notchAccessoryRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                smallUtilityButton(
                    icon: isPinned ? "pin.fill" : "pin",
                    label: isPinned
                        ? localized("Otomatik kapanmaya izin ver", "Allow automatic collapse")
                        : localized("Açık tut", "Keep open")
                ) {
                    isPinned.toggle()
                }

                PlaybackWaveform(isPlaying: mediaManager.isPlaying)
                    .foregroundStyle(playbackIndicatorColor)
            }
            .padding(.leading, 18)
            .frame(width: notchWingWidth, alignment: .leading)

            Color.clear
                .frame(width: layout.cameraHousingWidth)
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                smallUtilityButton(
                    icon: "gearshape.fill",
                    label: localized("Ayarlar", "Settings")
                ) {
                    NotificationCenter.default.post(
                        name: .islandXShowSettings,
                        object: nil
                    )
                }

                smallUtilityButton(
                    icon: "chevron.up",
                    label: localized("Medya kontrollerini küçült", "Collapse media controls")
                ) {
                    hoverTask?.cancel()
                    trackChangeTask?.cancel()
                    isTemporaryTrackPreview = false
                    isPinned = false
                    setPresentation(.idle)
                }
            }
            .padding(.trailing, 18)
            .frame(width: notchWingWidth, alignment: .trailing)
        }
        .frame(height: max(layout.notchBandHeight + 4, 36))
    }

    private var sourceTile: some View {
        Button(action: mediaManager.openSourceApplication) {
            VStack(spacing: 2) {
                Image(systemName: sourceSymbolName)
                    .font(.system(size: 15, weight: .semibold))

                Text(sourceShortName)
                    .font(.system(size: 7, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(primaryColor.opacity(0.72))
            .frame(width: 48, height: 48)
            .background(Circle().fill(primaryColor.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(mediaManager.source == .none)
        .opacity(mediaManager.source == .none ? 0.5 : 1)
        .accessibilityLabel(Text(openSourceLabel))
        .help(openSourceLabel)
    }

    private var sourceSymbolName: String {
        switch mediaManager.source {
        case .appleMusic: "music.note"
        case .spotify: "waveform"
        case .none: "hifispeaker.fill"
        }
    }

    private var sourceShortName: String {
        switch mediaManager.source {
        case .appleMusic: "Music"
        case .spotify: "Spotify"
        case .none: localized("Medya", "Media")
        }
    }

    private var openSourceLabel: String {
        switch mediaManager.source {
        case .appleMusic:
            localized("Music'te aç", "Open in Music")
        case .spotify:
            localized("Spotify'da aç", "Open in Spotify")
        case .none:
            localized("Medya uygulamasını aç", "Open media app")
        }
    }

    private var standardExpandedContent: some View {
        VStack(spacing: 6) {
            trackHeader
            HStack(alignment: .center, spacing: 12) {
                progressSection

                Divider()
                    .overlay(primaryColor.opacity(0.12))
                    .frame(height: 28)

                volumeSection
                    .frame(width: 150)
            }
        }
        .padding(.top, layout.expandedTopPadding)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var notchWingWidth: CGFloat {
        max((layout.expandedWidth - layout.cameraHousingWidth) / 2, 0)
    }

    private var compactPlaybackControls: some View {
        HStack(spacing: 3) {
            compactPlaybackModeButton(
                icon: "shuffle",
                label: mediaManager.isShuffleEnabled
                    ? localized("Karışık çalmayı kapat", "Turn shuffle off")
                    : localized("Karışık çal", "Shuffle"),
                isActive: mediaManager.isShuffleEnabled,
                action: mediaManager.toggleShuffle
            )

            compactMediaControlButton(
                icon: "backward.fill",
                label: localized("Önceki parça", "Previous track"),
                action: mediaManager.previousTrack
            )

            Button(action: mediaManager.togglePlayPause) {
                Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(panelColor)
                    .frame(width: 27, height: 27)
                    .background(Circle().fill(primaryColor))
            }
            .buttonStyle(.plain)
            .disabled(!mediaManager.hasActiveTrack)
            .opacity(mediaManager.hasActiveTrack ? 1 : 0.45)

            compactMediaControlButton(
                icon: "forward.fill",
                label: localized("Sonraki parça", "Next track"),
                action: mediaManager.nextTrack
            )

            compactPlaybackModeButton(
                icon: mediaManager.repeatMode == .one
                    ? "repeat.1"
                    : "repeat",
                label: repeatControlLabel,
                isActive: mediaManager.repeatMode != .off,
                action: mediaManager.cycleRepeatMode
            )
        }
    }

    private var trackHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            sourceArtwork(size: 52, cornerRadius: 11)

            VStack(alignment: .leading, spacing: 2) {
                Text(trackTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(artistTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(primaryColor.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !mediaManager.albumName.isEmpty {
                    Text(mediaManager.albumName)
                        .font(.system(size: 11))
                        .foregroundStyle(primaryColor.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Text(mediaManager.source.displayName.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(primaryColor.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            playbackControls

            VStack(spacing: 6) {
                smallUtilityButton(
                    icon: isPinned ? "pin.fill" : "pin",
                    label: isPinned ? "Allow automatic collapse" : "Keep open"
                ) {
                    isPinned.toggle()
                }

                smallUtilityButton(
                    icon: "chevron.up",
                    label: "Collapse media controls"
                ) {
                    hoverTask?.cancel()
                    trackChangeTask?.cancel()
                    isTemporaryTrackPreview = false
                    isPinned = false
                    setPresentation(.idle)
                }
            }
        }
        .frame(height: 52)
    }

    private var playbackControls: some View {
        HStack(spacing: 6) {
            playbackModeButton(
                icon: "shuffle",
                label: mediaManager.isShuffleEnabled
                    ? localized("Karışık çalmayı kapat", "Turn shuffle off")
                    : localized("Karışık çal", "Shuffle"),
                isActive: mediaManager.isShuffleEnabled,
                action: mediaManager.toggleShuffle
            )

            mediaControlButton(
                icon: "backward.fill",
                label: localized("Önceki parça", "Previous track"),
                action: mediaManager.previousTrack
            )

            Button(action: mediaManager.togglePlayPause) {
                Image(
                    systemName: mediaManager.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(panelColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(primaryColor))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!mediaManager.hasActiveTrack)
            .opacity(mediaManager.hasActiveTrack ? 1 : 0.45)
            .accessibilityLabel(
                Text(mediaManager.isPlaying ? "Pause" : "Play")
            )
            .help(mediaManager.isPlaying ? "Pause" : "Play")

            mediaControlButton(
                icon: "forward.fill",
                label: localized("Sonraki parça", "Next track"),
                action: mediaManager.nextTrack
            )

            playbackModeButton(
                icon: mediaManager.repeatMode == .one
                    ? "repeat.1"
                    : "repeat",
                label: repeatControlLabel,
                isActive: mediaManager.repeatMode != .off,
                action: mediaManager.cycleRepeatMode
            )
        }
    }

    private var repeatControlLabel: String {
        switch mediaManager.repeatMode {
        case .off:
            localized("Tekrarı aç", "Turn repeat on")
        case .all:
            localized("Tümünü tekrarla", "Repeat all")
        case .one:
            localized("Bir parçayı tekrarla", "Repeat one")
        }
    }

    private var progressSection: some View {
        VStack(spacing: 2) {
            Slider(
                value: $scrubValue,
                in: 0...max(mediaManager.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    updateInteraction(editing)

                    if !editing, mediaManager.duration > 0 {
                        mediaManager.seek(to: scrubValue)
                    }
                }
            )
            .controlSize(.small)
            .tint(primaryColor)
            .disabled(mediaManager.duration <= 0)
            .accessibilityLabel(Text("Playback progress"))
            .accessibilityValue(
                Text("\(Int(normalizedProgress * 100)) percent")
            )

            HStack {
                Text(formatTime(isScrubbing ? scrubValue : playbackTime))
                Spacer()
                Text(remainingTimeText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(primaryColor.opacity(0.52))
        }
        // The timestamp row makes this stack taller than the volume control.
        // Nudge the whole stack down so both slider tracks share one visual axis.
        .offset(y: 8)
    }

    private var volumeSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(primaryColor.opacity(0.55))
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { min(max(mediaManager.volume, 0), 1) },
                    set: mediaManager.setVolume
                ),
                in: 0...1,
                onEditingChanged: updateInteraction
            )
            .controlSize(.small)
            .tint(primaryColor)
            .accessibilityLabel(Text("System volume"))
            .accessibilityValue(
                Text("\(Int(mediaManager.volume * 100)) percent")
            )

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(primaryColor.opacity(0.55))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Reusable Components

    @ViewBuilder
    private func artwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let image = mediaManager.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    primaryColor.opacity(0.08)

                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.34, weight: .medium))
                        .foregroundStyle(primaryColor.opacity(0.48))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .stroke(primaryColor.opacity(0.12), lineWidth: 0.5)
        }
        .matchedGeometryEffect(id: "artwork", in: artworkNamespace)
        .accessibilityHidden(true)
    }

    private func sourceArtwork(
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        Button(action: mediaManager.openSourceApplication) {
            artwork(size: size, cornerRadius: cornerRadius)
        }
        .buttonStyle(.plain)
        .disabled(mediaManager.source == .none)
        .accessibilityLabel(Text(openSourceLabel))
        .help(openSourceLabel)
    }

    private func mediaControlButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(0.88))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!mediaManager.hasActiveTrack)
        .opacity(mediaManager.hasActiveTrack ? 1 : 0.45)
        .accessibilityLabel(Text(label))
        .help(label)
    }

    private func playbackModeButton(
        icon: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    isActive ? Color.green : primaryColor.opacity(0.62)
                )
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(
                        isActive
                            ? Color.green.opacity(0.16)
                            : primaryColor.opacity(0.07)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!mediaManager.hasActiveTrack)
        .opacity(mediaManager.hasActiveTrack ? 1 : 0.45)
        .accessibilityLabel(Text(label))
        .accessibilityValue(
            Text(isActive ? localized("Açık", "On") : localized("Kapalı", "Off"))
        )
        .help(label)
    }

    private func compactMediaControlButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(0.88))
                .frame(width: 24, height: 27)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!mediaManager.hasActiveTrack)
        .opacity(mediaManager.hasActiveTrack ? 1 : 0.45)
        .accessibilityLabel(Text(label))
        .help(label)
    }

    private func compactPlaybackModeButton(
        icon: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    isActive ? Color.green : primaryColor.opacity(0.62)
                )
                .frame(width: 24, height: 27)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!mediaManager.hasActiveTrack)
        .opacity(mediaManager.hasActiveTrack ? 1 : 0.45)
        .accessibilityLabel(Text(label))
        .accessibilityValue(
            Text(isActive ? localized("Açık", "On") : localized("Kapalı", "Off"))
        )
        .help(label)
    }

    private func smallUtilityButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(0.78))
                .frame(width: 26, height: 26)
                .background(Circle().fill(primaryColor.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .help(label)
    }

    // MARK: - Interaction and State

    private func handleContinuousHover(_ phase: HoverPhase) {
        switch phase {
        case let .active(location):
            isPointerInside = true
            hoverTask?.cancel()

            guard presentation == .idle,
                  !isPinned,
                  !isInteracting else {
                return
            }

            let shouldExpand: Bool
            switch settings.activationMode {
            case .hover:
                shouldExpand = true
            case .click:
                shouldExpand = false
            case .activationZone:
                shouldExpand = isInsideActivationZone(location)
            }

            if shouldExpand {
                isTemporaryTrackPreview = false
                schedulePresentation(.expanded)
            }

        case .ended:
            isPointerInside = false
            hoverTask?.cancel()

            guard !isPinned, !isInteracting else { return }
            guard presentation == .expanded else { return }

            if settings.activationMode != .click || isTemporaryTrackPreview {
                schedulePresentation(.idle)
            }
        }
    }

    private func isInsideActivationZone(_ location: CGPoint) -> Bool {
        let zoneWidth: CGFloat
        if layout.hasCameraHousing {
            zoneWidth = min(
                layout.cameraHousingWidth + 24,
                preferredSize.width
            )
        } else {
            zoneWidth = min(76, preferredSize.width)
        }

        return abs(location.x - preferredSize.width / 2) <= zoneWidth / 2
    }

    private func showTrackChangePreviewIfNeeded() {
        guard settings.showOnTrackChange,
              mediaManager.hasActiveTrack,
              !isPinned else {
            return
        }

        hoverTask?.cancel()
        trackChangeTask?.cancel()
        isTemporaryTrackPreview = true
        setPresentation(.expanded)

        let delay = UInt64(
            settings.trackChangeDisplayDuration * 1_000_000_000
        )
        trackChangeTask = Task { @MainActor in
            do {
                try await Task<Never, Never>.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard !Task.isCancelled,
                  !isPinned,
                  !isInteracting else {
                return
            }

            guard !isPointerInsideFloatingWindow else {
                isPointerInside = true
                return
            }

            isTemporaryTrackPreview = false
            setPresentation(.idle)
        }
    }

    private func schedulePresentation(_ state: NotchPresentationState) {
        hoverTask?.cancel()
        let delaySeconds = state == .expanded
            ? 0.08
            : settings.collapseDelay
        let delay = UInt64(delaySeconds * 1_000_000_000)

        hoverTask = Task { @MainActor in
            do {
                try await Task<Never, Never>.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard !Task.isCancelled, !isPinned, !isInteracting else {
                return
            }

            // Resizing the centered panel can briefly emit a false hover exit,
            // especially near its right edge. Trust the pointer's real screen
            // position once the resize animation has settled before collapsing.
            if state == .idle, isPointerInsideFloatingWindow {
                isPointerInside = true
                return
            }

            setPresentation(state)
        }
    }

    private var isPointerInsideFloatingWindow: Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "IslandXFloatingNotch"
        }), let screen = window.screen ?? NSScreen.main else {
            return isPointerInside
        }

        let expandedSize = layout.size(
            for: .expanded,
            contentMode: settings.contentMode
        )
        let topGap: CGFloat = screen.safeAreaInsets.top > 0 ? 0 : 6
        let expandedFrame = NSRect(
            x: screen.frame.midX - expandedSize.width / 2,
            y: screen.frame.maxY - topGap - expandedSize.height,
            width: expandedSize.width,
            height: expandedSize.height
        )

        return expandedFrame
            .insetBy(dx: -4, dy: -4)
            .contains(NSEvent.mouseLocation)
    }

    private func updateInteraction(_ active: Bool) {
        isInteracting = active

        if !active, !isPinned, !isPointerInside {
            schedulePresentation(.idle)
        }
    }

    private func setPresentation(_ newValue: NotchPresentationState) {
        guard newValue != presentation else { return }

        if newValue == .idle {
            trackChangeTask?.cancel()
            isTemporaryTrackPreview = false
        }

        onPreferredSizeChange(
            layout.size(
                for: newValue,
                idleMode: settings.notchIdleMode,
                contentMode: settings.contentMode
            ),
            !reduceMotion
        )

        withAnimation(presentationAnimation) {
            presentation = newValue
            expansionProgress = newValue == .expanded ? 1 : 0
        }
    }

    // MARK: - Derived Values

    private var preferredSize: CGSize {
        layout.size(
            for: presentation,
            idleMode: settings.notchIdleMode,
            contentMode: settings.contentMode
        )
    }

    private var isHiddenMiniIdle: Bool {
        layout.hasCameraHousing &&
            settings.notchIdleMode == .hiddenMini &&
            presentation == .idle
    }

    private var notchShape: AdaptiveNotchShape {
        AdaptiveNotchShape(
            layout: layout,
            expansionProgress: expansionProgress
        )
    }

    @ViewBuilder
    private var notchBackground: some View {
        if settings.theme == .liquidGlass {
            if #available(macOS 26.0, *) {
                notchShape
                    .fill(Color.clear)
                    .glassEffect(
                        .regular.interactive(true),
                        in: notchShape
                    )
            } else {
                notchShape.fill(.ultraThinMaterial)
            }
        } else {
            ZStack {
                if settings.theme == .system,
                   !layout.hasCameraHousing,
                   !reduceTransparency {
                    notchShape.fill(.ultraThinMaterial)
                }

                notchShape.fill(panelColor.opacity(panelOpacity))
            }
        }
    }

    private var effectiveColorScheme: ColorScheme {
        settings.theme.colorScheme ?? systemColorScheme
    }

    private var isLightAppearance: Bool {
        effectiveColorScheme == .light
    }

    private var primaryColor: Color {
        isLightAppearance ? .black : .white
    }

    private var panelColor: Color {
        isLightAppearance ? .white : .black
    }

    private var panelOpacity: Double {
        if reduceTransparency || layout.hasCameraHousing {
            return 1
        }
        return settings.theme == .system ? 0.88 : 0.96
    }

    private var presentationAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.12)
        }

        return .spring(
            response: 0.46,
            dampingFraction: 0.86,
            blendDuration: 0.12
        )
    }

    private var playbackTime: Double {
        min(max(mediaManager.playbackPosition, 0), max(mediaManager.duration, 0))
    }

    private var normalizedProgress: Double {
        guard mediaManager.duration > 0 else { return 0 }
        return min(max(scrubValue / mediaManager.duration, 0), 1)
    }

    private var remainingTimeText: String {
        guard mediaManager.duration > 0 else { return "--:--" }
        let current = isScrubbing ? scrubValue : playbackTime
        return "-\(formatTime(max(mediaManager.duration - current, 0)))"
    }

    private var trackTitle: String {
        mediaManager.trackName.isEmpty ? "No Media" : mediaManager.trackName
    }

    private var artistTitle: String {
        mediaManager.artistName.isEmpty
            ? localized("Music veya Spotify'ı açın", "Open Music or Spotify")
            : mediaManager.artistName
    }

    private func localized(_ turkish: String, _ english: String) -> String {
        settings.language.value(turkish: turkish, english: english)
    }

    private var compactAccessibilityText: String {
        guard mediaManager.hasActiveTrack else {
            return "Media controls. Nothing is currently playing."
        }

        let state = mediaManager.isPlaying ? "Playing" : "Paused"
        return "\(trackTitle), \(artistTitle). \(state)."
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }

        let totalSeconds = Int(time.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                seconds
            )
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// A single continuously animatable silhouette keeps its top edge attached to
/// the physical camera housing while its shoulders, width, and lower corners
/// expand. This avoids visually swapping between unrelated compact/expanded
/// paths and makes the camera housing itself appear to become IslandX.
private struct AdaptiveNotchShape: Shape {
    let layout: NotchLayout
    var expansionProgress: CGFloat

    var animatableData: CGFloat {
        get { expansionProgress }
        set { expansionProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(max(expansionProgress, 0), 1)

        guard layout.hasCameraHousing else {
            let compactRadius = rect.height / 2
            let radius = interpolate(
                from: compactRadius,
                to: 28,
                progress: progress
            )
            return Path(
                roundedRect: rect,
                cornerRadius: radius
            )
        }

        return cameraConnectedPath(in: rect, progress: progress)
    }

    private func cameraConnectedPath(
        in rect: CGRect,
        progress: CGFloat
    ) -> Path {
        let bottomRadius = min(
            interpolate(from: 13, to: 28, progress: progress),
            rect.width / 4,
            rect.height / 4
        )

        // A notched Mac already has a physical black camera housing at the
        // centre. Extending a perfectly flat software surface from the display
        // edge removes the artificial sloped shoulders around it. Only the
        // lower corners are rounded, matching a Dynamic Island attached to the
        // top bezel.
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(
            to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }

    private func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }
}

private struct PlaybackWaveform: View {
    let isPlaying: Bool

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 20.0,
                paused: !isPlaying
            )
        ) { context in
            let phase = context.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = (
                        sin(phase * 7 + Double(index) * 1.35) + 1
                    ) / 2

                    Capsule()
                        .frame(
                            width: 2.5,
                            height: isPlaying
                                ? 5 + CGFloat(wave) * 10
                                : 4
                        )
                }
            }
        }
        .frame(width: 22, height: 18)
    }
}
