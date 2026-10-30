import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum NotchPresentationState: Equatable {
    case idle
    case expanded
}

private enum DashboardSection: String, CaseIterable {
    case home
    case calendar
    case timer
    case shelf
    case clipboard
}

/// Derives the camera-housing geometry from AppKit's safe display regions.
/// This intentionally detects the active screen rather than a Mac model name,
/// so new MacBooks and external displays inherit the correct presentation.
struct NotchLayout: Equatable {
    let idleWidth: CGFloat
    let notchBandHeight: CGFloat
    let cameraHousingWidth: CGFloat
    let screenWidth: CGFloat

    private static let compactWingWidth: CGFloat = 50

    init(screen: NSScreen?) {
        guard let screen else {
            idleWidth = 176
            notchBandHeight = 0
            cameraHousingWidth = 0
            screenWidth = 724
            return
        }

        screenWidth = screen.frame.width

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
        hasCameraHousing ? notchBandHeight : 38
    }

    func size(
        for state: NotchPresentationState,
        idleMode: NotchIdleMode = .visibleIsland
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
            return CGSize(
                width: min(780, max(screenWidth - 24, 620)),
                height: hasCameraHousing ? 244 : 232
            )
        }
    }
}

struct DynamicNotchView: View {
    @ObservedObject private var mediaManager: MediaManager
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var commandEchoManager: CommandEchoManager
    @ObservedObject private var focusTimerManager: FocusTimerManager
    @ObservedObject private var keepAwakeManager: KeepAwakeManager
    @ObservedObject private var fileShelfManager: FileShelfManager
    @ObservedObject private var clipboardHistoryManager: ClipboardHistoryManager

    private let layout: NotchLayout
    private let onPreferredSizeChange: (CGSize, Bool) -> Void

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

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
    @State private var isCustomizingDashboard = false
    @State private var isFileDropTargeted = false
    @State private var isCommandEchoVisible = false
    @State private var commandEchoTask: Task<Void, Never>?
    @State private var pendingSkipDirection: MediaSkipDirection?
    /// The visible silhouette. It animates inside a window that only ever
    /// jumps in size, so the notch always grows from the top edge.
    @State private var surfaceSize: CGSize = .zero
    @State private var windowMargin: CGFloat = 0
    @State private var windowSettleTask: Task<Void, Never>?
    /// The resting island shows its wings only while music plays.
    @State private var showsIdleWings = false
    @State private var idleWingsTask: Task<Void, Never>?
    /// Draws nothing over the camera housing once it has fully shrunk back.
    @State private var isIdleSurfaceConcealed = true

    /// Room around the surface for the Command Echo light to spread into.
    private static let haloMargin: CGFloat = 22

    init(
        mediaManager: MediaManager,
        settings: AppSettings,
        commandEchoManager: CommandEchoManager,
        focusTimerManager: FocusTimerManager,
        keepAwakeManager: KeepAwakeManager,
        fileShelfManager: FileShelfManager,
        clipboardHistoryManager: ClipboardHistoryManager,
        layout: NotchLayout,
        onPreferredSizeChange: @escaping (CGSize, Bool) -> Void = { _, _ in }
    ) {
        _mediaManager = ObservedObject(wrappedValue: mediaManager)
        _settings = ObservedObject(wrappedValue: settings)
        _commandEchoManager = ObservedObject(wrappedValue: commandEchoManager)
        _focusTimerManager = ObservedObject(wrappedValue: focusTimerManager)
        _keepAwakeManager = ObservedObject(wrappedValue: keepAwakeManager)
        _fileShelfManager = ObservedObject(wrappedValue: fileShelfManager)
        _clipboardHistoryManager = ObservedObject(wrappedValue: clipboardHistoryManager)
        self.layout = layout
        self.onPreferredSizeChange = onPreferredSizeChange
    }

    private var renderedSurface: some View {
        ZStack(alignment: .top) {
            if isFileDropTargeted {
                fileDropHUD
                    .transition(.opacity)
            } else if isCommandEchoVisible {
                commandEchoHUD
                    .transition(.opacity)
            } else if presentation == .idle {
                compactContent
                    .transition(.opacity)
            } else {
                dashboardExpandedContent
                    .transition(.opacity)
            }
        }
        // Content is laid out at its final size; the animated surface around
        // it reveals it from the top instead of reflowing mid-animation.
        .frame(
            width: preferredSize.width,
            height: preferredSize.height,
            alignment: .top
        )
        .frame(
            width: surfaceSize.width,
            height: surfaceSize.height,
            alignment: .top
        )
        .background {
            if isHiddenMiniIdle && isIdleSurfaceConcealed
                && !isCommandEchoVisible && !isFileDropTargeted {
                Color.clear
            } else if isCommandEchoVisible || isFileDropTargeted {
                notchShape.fill(Color.black)
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
        .overlay {
            if isFileDropTargeted {
                notchShape
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(notchShape)
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isFileDropTargeted
        ) { providers in
            guard settings.dashboardFileShelfEnabled else { return false }
            let accepted = fileShelfManager.receive(providers)
            if accepted {
                isPinned = true
                setPresentation(.expanded)
                selectDashboardSection(.shelf)
            }
            return accepted
        }
    }

    /// A soft white light around the silhouette, like the reference HUD. It
    /// sits outside the shape so the camera housing can't cut it in half.
    private var commandEchoHalo: some View {
        ZStack(alignment: .top) {
            haloLayer(spread: 5).blur(radius: 11).opacity(0.75)
            haloLayer(spread: 2).blur(radius: 3.5)
        }
        // Lay the light out at the surface's size and let it spill over.
        // Its larger natural size would otherwise grow the root view past a
        // margin-less window and AppKit would centre it, lifting the notch.
        .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
        .opacity(isCommandEchoVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The silhouette grown by `spread` on the sides and bottom, so the
    /// brightest part of the blur sits right at the visible edge.
    private func haloLayer(spread: CGFloat) -> some View {
        notchShape
            .fill(Color.white)
            .frame(
                width: surfaceSize.width + spread * 2,
                height: surfaceSize.height + spread
            )
    }

    var body: some View {
        ZStack(alignment: .top) {
            commandEchoHalo

            renderedSurface
                .onContinuousHover(perform: handleContinuousHover)
                .contextMenu { surfaceContextMenu }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            scrubValue = mediaManager.playbackPosition
            expansionProgress = presentation == .expanded ? 1 : 0
            showsIdleWings = mediaManager.isPlaying
            surfaceSize = preferredSize
            isIdleSurfaceConcealed = true
            onPreferredSizeChange(preferredSize, false)
        }
        .onDisappear {
            hoverTask?.cancel()
            trackChangeTask?.cancel()
            commandEchoTask?.cancel()
            windowSettleTask?.cancel()
            idleWingsTask?.cancel()
        }
        .onReceive(mediaManager.$isPlaying.dropFirst().removeDuplicates()) { playing in
            updateIdleWings(isPlaying: playing)
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
            resizeSurface(to: preferredSize, animation: presentationAnimation)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .isloExpand)
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
        .onReceive(mediaManager.$volume.dropFirst().removeDuplicates()) { value in
            guard settings.dashboardCommandEchoEnabled else { return }
            commandEchoManager.showVolume(value)
        }
        .onReceive(commandEchoManager.$revision.dropFirst()) { _ in
            showCommandEchoIfNeeded()
        }
        .onChange(of: settings.dashboardFocusTimerEnabled) { enabled in
            if !enabled, dashboardSection == .timer { dashboardSection = .home }
        }
        .onChange(of: settings.dashboardFileShelfEnabled) { enabled in
            if !enabled, dashboardSection == .shelf { dashboardSection = .home }
        }
        .onChange(of: isFileDropTargeted) { _ in
            resizeSurface(to: preferredSize, animation: presentationAnimation)
        }
        .onChange(of: settings.dashboardKeepAwakeEnabled) { enabled in
            if !enabled { keepAwakeManager.setActive(false) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .isloCollapse)
        ) { _ in
            hoverTask?.cancel()
            trackChangeTask?.cancel()
            isTemporaryTrackPreview = false
            isPinned = false
            setPresentation(.idle)
        }
        .accessibilityElement(children: .contain)
        .preferredColorScheme(settings.theme.colorScheme)
    }

    @ViewBuilder
    private var surfaceContextMenu: some View {
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
                name: .isloShowSettings,
                object: nil
            )
        }

        Divider()

        Button(localized("islo.'dan Çık", "Quit islo.")) {
            NSApp.terminate(nil)
        }
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
                if layout.hasCameraHousing {
                    // Fades with the wings as they slide into the notch.
                    notchedCompactContent
                        .opacity(isHiddenMiniIdle ? 0 : 1)
                        .accessibilityHidden(isHiddenMiniIdle)
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
                .frame(width: layout.compactWingWidth, alignment: .trailing)

            Color.clear
                .frame(width: layout.cameraHousingWidth)
                .accessibilityHidden(true)

            PlaybackWaveform(isPlaying: mediaManager.isPlaying)
                .foregroundStyle(playbackIndicatorColor)
                .frame(width: layout.compactWingWidth, alignment: .leading)
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

    private var dashboardExpandedContent: some View {
        VStack(spacing: 0) {
            dashboardNavigationRow

            if isCustomizingDashboard {
                dashboardCustomizer
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                dashboardStage
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(dashboardSceneBackground)
    }

    private var dashboardStage: some View {
        HStack(spacing: 14) {
            dashboardPrimaryPane
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(dashboardGlassCard)

            dashboardSidePane
                .padding(14)
                .frame(width: dashboardSideWidth)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(dashboardGlassCard)
        }
        .padding(.horizontal, bodyPadding(16, gap: 12))
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var dashboardPrimaryPane: some View {
        switch dashboardSection {
        case .timer where settings.dashboardFocusTimerEnabled:
            dashboardFocusPane
        case .shelf where settings.dashboardFileShelfEnabled:
            dashboardShelfPane
        case .clipboard:
            dashboardClipboardPane
        case .home where settings.homeWidgetStyle == .focus && settings.dashboardFocusTimerEnabled:
            dashboardFocusPane
        default:
            dashboardMediaPane
        }
    }

    private var dashboardSideWidth: CGFloat {
        guard dashboardSection == .home else { return 238 }
        switch settings.homeWidgetStyle {
        case .media: return 190
        case .day: return 310
        case .balanced, .focus: return 238
        }
    }

    private var dashboardCustomizer: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Ana ekranı özelleştir", "Customize Home"))
                        .font(.system(size: 14, weight: .bold))
                    Text(localized("Ana ekran düzenini seçin.", "Choose the Home layout."))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button(localized("Bitti", "Done")) {
                    withAnimation(.easeInOut(duration: 0.2)) { isCustomizingDashboard = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 13)
                .frame(height: 25)
                .background(Capsule().fill(.white))
            }

            HStack(spacing: 9) {
                ForEach(HomeWidgetStyle.allCases) { style in
                    dashboardLayoutChoice(style)
                }
            }

        }
        .foregroundStyle(.white)
        .padding(.horizontal, bodyPadding(18, gap: 12))
        .padding(.bottom, 14)
    }

    private func dashboardLayoutChoice(_ style: HomeWidgetStyle) -> some View {
        Button { settings.homeWidgetStyle = style } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.18))
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.34)).frame(height: 6)
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.12)).frame(height: 6)
                    }
                }
                .frame(height: 42)
                Text(style.title(language: settings.language))
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.075)))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(settings.homeWidgetStyle == style ? Color.white : .white.opacity(0.1), lineWidth: settings.homeWidgetStyle == style ? 1.5 : 0.7))
        }
        .buttonStyle(.plain)
    }

    private var dashboardGlassCard: some ShapeStyle {
        LinearGradient(colors: [.white.opacity(0.115), .white.opacity(0.055)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var dashboardSceneBackground: some View {
        ZStack {
            Color.black
            sceneGradient(for: settings.notchSceneStyle).opacity(0.38)
            LinearGradient(colors: [.clear, .black.opacity(0.48)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func sceneGradient(for style: NotchSceneStyle) -> LinearGradient {
        switch style {
        case .graphite:
            LinearGradient(colors: [Color(white: 0.17), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ember:
            LinearGradient(colors: [Color(red: 0.55, green: 0.16, blue: 0.09), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .aurora:
            LinearGradient(colors: [Color.indigo, Color.teal.opacity(0.7), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .album:
            LinearGradient(colors: [Color.orange.opacity(0.72), Color.purple.opacity(0.55), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
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
            if settings.dashboardFocusTimerEnabled {
                dashboardNavigationIcon("timer", section: .timer)
            }
            if settings.dashboardFileShelfEnabled {
                dashboardNavigationIcon("tray.full", section: .shelf)
            }
            dashboardNavigationIcon("list.clipboard.fill", section: .clipboard)
        }
    }

    private var dashboardNavigationTrailing: some View {
        HStack(spacing: 8) {
            smallUtilityButton(
                icon: "slider.horizontal.3",
                label: localized("Özelleştir", "Customize")
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { isCustomizingDashboard.toggle() }
            }

            smallUtilityButton(
                icon: "gearshape.fill",
                label: localized("Ayarlar", "Settings")
            ) {
                NotificationCenter.default.post(
                    name: .isloShowSettings,
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

    private var dashboardFocusPane: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(primaryColor.opacity(0.1), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(focusTimerManager.progress, 0.002))
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Text(focusTimerManager.formattedTime)
                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                    Text(
                        focusTimerManager.isBreak
                            ? localized("Mola", "Break")
                            : localized("Odak", "Focus")
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.5))
                }
            }
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $focusTimerManager.mode) {
                    Text(localized("Zamanlayıcı", "Timer"))
                        .tag(FocusTimerMode.timer)
                    Text("Pomodoro").tag(FocusTimerMode.pomodoro)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if focusTimerManager.mode == .timer {
                    HStack(spacing: 6) {
                        ForEach([5, 10, 25], id: \.self) { minutes in
                            Button("\(minutes) dk") {
                                focusTimerManager.timerMinutes = minutes
                                focusTimerManager.reset()
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 9, weight: .semibold))
                        }
                    }
                } else {
                    Text(localized("25 dk odak · 5 dk mola", "25 min focus · 5 min break"))
                        .font(.system(size: 9))
                        .foregroundStyle(primaryColor.opacity(0.5))
                }

                HStack(spacing: 8) {
                    Button {
                        focusTimerManager.toggle()
                    } label: {
                        Label(
                            focusTimerManager.isRunning
                                ? localized("Duraklat", "Pause")
                                : localized("Başlat", "Start"),
                            systemImage: focusTimerManager.isRunning
                                ? "pause.fill"
                                : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(localized("Sıfırla", "Reset")) {
                        focusTimerManager.reset()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if focusTimerManager.mode == .pomodoro {
                        Button {
                            focusTimerManager.skipPhase()
                        } label: {
                            Image(systemName: "forward.end.fill")
                        }
                        .buttonStyle(.borderless)
                        .help(localized("Sonraki aşama", "Next phase"))
                    }
                }
            }
        }
        .foregroundStyle(primaryColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dashboardShelfPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    localized("Dosya Rafı", "File Shelf"),
                    systemImage: "tray.full.fill"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryColor)

                Spacer()

                Text(localized("Dosyaları buraya bırak", "Drop files here"))
                    .font(.system(size: 9))
                    .foregroundStyle(primaryColor.opacity(0.45))
            }

            if fileShelfManager.items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 23))
                        .foregroundStyle(Color.accentColor)
                    Text(
                        localized(
                            "Geçici bir dosya rafı oluşturmak için Finder'dan sürükle.",
                            "Drag from Finder to create a temporary file shelf."
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(primaryColor.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(primaryColor.opacity(0.06))
                )
            } else {
                HStack(spacing: 10) {
                    ForEach(fileShelfManager.items.prefix(5), id: \.self) { url in
                        VStack(spacing: 5) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 40)
                            Text(url.lastPathComponent)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(primaryColor.opacity(0.7))
                                .lineLimit(1)
                                .frame(width: 58)
                        }
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .onTapGesture { fileShelfManager.reveal(url) }
                        .contextMenu {
                            Button(localized("AirDrop ile Gönder", "Send via AirDrop")) {
                                fileShelfManager.sendViaAirDrop(url)
                            }
                            Button(localized("Finder'da Göster", "Show in Finder")) {
                                fileShelfManager.reveal(url)
                            }
                            Divider()
                            Button(localized("Raftan Kaldır", "Remove from Shelf")) {
                                fileShelfManager.remove(url)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dashboardClipboardPane: some View {
        HStack(spacing: 10) {
            if let latest = clipboardHistoryManager.entries.first {
                Button { clipboardHistoryManager.copy(latest) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(localized("Panoda", "In clipboard"), systemImage: "list.clipboard.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.48))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(latest.text)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 0)
                        Text(latest.source)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.07)))
                }
                .buttonStyle(.plain)

                VStack(spacing: 7) {
                    ForEach(clipboardHistoryManager.entries.dropFirst().prefix(2)) { entry in
                        Button { clipboardHistoryManager.copy(entry) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "text.alignleft")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(.white.opacity(0.08)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.text).font(.system(size: 9, weight: .medium)).lineLimit(2)
                                    Text(entry.source).font(.system(size: 7)).foregroundStyle(.white.opacity(0.35))
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.055)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 170)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "list.clipboard")
                        .font(.system(size: 23, weight: .light))
                    Text(localized("Kopyaladığınız metinler burada görünür.", "Copied text appears here."))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                icon: focusTimerManager.isRunning ? "pause.fill" : "play.fill",
                title: focusTimerManager.isRunning
                    ? localized("Duraklat", "Pause")
                    : localized("Başlat", "Start"),
                subtitle: focusTimerManager.formattedTime,
                action: focusTimerManager.toggle
            )
        case .shelf:
            dashboardSummaryCard(
                icon: "airplayaudio",
                title: localized("AirDrop ile gönder", "Send with AirDrop"),
                subtitle: fileShelfManager.items.first?.lastPathComponent
                    ?? localized("Önce bir dosya bırak", "Drop a file first"),
                action: {
                    guard let item = fileShelfManager.items.first else { return }
                    fileShelfManager.sendViaAirDrop(item)
                }
            )
        case .clipboard:
            dashboardSummaryCard(
                icon: "list.clipboard.fill",
                title: localized("Pano geçmişi", "Clipboard history"),
                subtitle: localized("Yalnızca bellekte tutulur", "Kept in memory only"),
                action: {}
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
                icon: "arrow.counterclockwise",
                title: localized("Zamanlayıcıyı sıfırla", "Reset timer"),
                subtitle: focusTimerManager.mode == .pomodoro
                    ? "Pomodoro 25/5"
                    : "\(focusTimerManager.timerMinutes) dk",
                action: focusTimerManager.reset
            )
        case .shelf:
            dashboardSummaryCard(
                icon: "folder",
                title: localized("Finder'da göster", "Show in Finder"),
                subtitle: localized("İlk dosyanın konumunu aç", "Reveal the first file"),
                action: {
                    guard let item = fileShelfManager.items.first else { return }
                    fileShelfManager.reveal(item)
                }
            )
        case .clipboard:
            dashboardSummaryCard(
                icon: "trash",
                title: localized("Geçmişi temizle", "Clear history"),
                subtitle: "\(clipboardHistoryManager.entries.count)",
                action: clipboardHistoryManager.clear
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

    private var commandEchoHUD: some View {
        Group {
            if layout.hasCameraHousing {
                HStack(spacing: 0) {
                    commandEchoLeading
                        .frame(width: commandEchoWingWidth, alignment: .leading)
                    Color.clear
                        .frame(width: layout.cameraHousingWidth)
                        .accessibilityHidden(true)
                    commandEchoTrailing
                        .frame(width: commandEchoWingWidth, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .padding(.top, 2)
            } else {
                HStack(spacing: 12) {
                    commandEchoLeading
                    Spacer(minLength: 8)
                    commandEchoTrailing
                }
                .padding(.horizontal, 18)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localized("Sistem değişikliği", "System change"))
    }

    private var fileDropHUD: some View {
        VStack(spacing: 10) {
            if layout.hasCameraHousing {
                Color.clear.frame(height: max(layout.notchBandHeight - 2, 18))
            }

            Label(
                localized("Dosyaları buraya bırak", "Drop your files here"),
                systemImage: "arrow.down.doc.fill"
            )
            .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 10) {
                fileDropOption("tray.full.fill", localized("Raf", "Shelf"))
                fileDropOption("airplayaudio", "AirDrop")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, bodyPadding(14, gap: 10))
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(.white.opacity(0.22))
                .padding(.horizontal, bodyPadding(8, gap: 4))
                .padding(.vertical, 8)
        }
    }

    private func fileDropOption(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 9, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.09)))
    }

    private var commandEchoLeading: some View {
        HStack(spacing: 9) {
            Image(systemName: commandEchoManager.event.symbolName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .id(commandEchoManager.revision)
                .transition(.opacity.combined(with: .scale(scale: 0.72)))

            if commandEchoValue == nil {
                Text(commandEchoTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
        }
    }

    private var commandEchoTrailing: some View {
        Group {
            if let value = commandEchoValue {
                AnimatedPercentText(value: value)
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .animation(.spring(response: 0.22, dampingFraction: 0.9), value: value)
            } else {
                Text(commandEchoDetail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
        }
    }

    private var commandEchoValue: Double? {
        switch commandEchoManager.event {
        case .volume(let value), .brightness(let value): value
        case .copied, .pasted, .screenshot, .capsLock, .mediaSkip, .trackChanged: nil
        }
    }

    private var commandEchoTitle: String {
        switch commandEchoManager.event {
        case .volume: localized("Ses", "Volume")
        case .brightness: localized("Parlaklık", "Brightness")
        case .copied: localized("Kopyalandı", "Copied")
        case .pasted: localized("Yapıştırıldı", "Pasted")
        case .screenshot: localized("Ekran görüntüsü alındı", "Screenshot captured")
        case .capsLock(let enabled): enabled ? "Caps Lock" : localized("Caps Lock kapalı", "Caps Lock off")
        case .mediaSkip(let direction): direction == .next
            ? localized("Sonraki parça", "Next track")
            : localized("Önceki parça", "Previous track")
        case .trackChanged(let title, _): title
        }
    }

    private var commandEchoDetail: String {
        switch commandEchoManager.event {
        case .screenshot(let filename): filename
        case .copied: localized("Panoya eklendi", "Added to clipboard")
        case .pasted: localized("Panodan yapıştırıldı", "Pasted from clipboard")
        case .capsLock(let enabled): enabled ? localized("Açık", "On") : localized("Kapalı", "Off")
        case .mediaSkip: localized("Parça değiştiriliyor", "Changing track")
        case .trackChanged: artistTitle
        case .volume, .brightness: ""
        }
    }

    private var commandEchoWingWidth: CGFloat {
        max((commandEchoPreferredSize.width - layout.cameraHousingWidth) / 2 - 18, 56)
    }

    private func showCommandEchoIfNeeded() {
        // The open dashboard already shows volume and playback; swapping it
        // for a HUD would yank it away mid-interaction.
        guard settings.dashboardCommandEchoEnabled,
              presentation == .idle else { return }
        commandEchoTask?.cancel()
        let echoAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.3, dampingFraction: 0.86)
        withAnimation(echoAnimation) {
            isCommandEchoVisible = true
        }
        resizeSurface(to: preferredSize, animation: echoAnimation)
        commandEchoTask = Task {
            let duration: Duration
            if case .screenshot = commandEchoManager.event {
                duration = .seconds(3.2)
            } else if case .trackChanged = commandEchoManager.event {
                duration = .seconds(2.2)
            } else {
                duration = .seconds(1.45)
            }
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(echoAnimation) {
                    isCommandEchoVisible = false
                }
                resizeSurface(to: preferredSize, animation: echoAnimation)
            }
        }
    }

    private func dashboardSectionLabel(_ section: DashboardSection) -> String {
        switch section {
        case .home: localized("Ana", "Home")
        case .calendar: localized("Takvim", "Calendar")
        case .timer: localized("Zamanlayıcı", "Timer")
        case .shelf: localized("Dosya Rafı", "File Shelf")
        case .clipboard: "Clipboard"
        }
    }

    private func dashboardEyebrow(_ date: Date) -> String {
        switch dashboardSection {
        case .home, .calendar: dashboardWeekday(date).uppercased()
        case .timer: localized("ZAMANLAYICI", "TIMER")
        case .shelf: localized("DOSYA RAFI", "FILE SHELF")
        case .clipboard: "CLIPBOARD"
        }
    }

    private func dashboardHeadline(_ date: Date) -> String {
        switch dashboardSection {
        case .home, .calendar: dashboardDate(date)
        case .timer: dashboardTime(date)
        case .shelf: localized("Paylaş", "Share")
        case .clipboard: localized("Pano", "Clipboard")
        }
    }

    private func dashboardTrailingText(_ date: Date) -> String {
        switch dashboardSection {
        case .home, .calendar: dashboardTime(date)
        case .timer: focusTimerManager.formattedTime
        case .shelf: "\(fileShelfManager.items.count)"
        case .clipboard: "\(clipboardHistoryManager.entries.count)"
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
                action: { skipTrack(.previous) }
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
                action: { skipTrack(.next) }
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

        let direction: MediaSkipDirection?
        if let pendingSkipDirection {
            direction = pendingSkipDirection
        } else if case .mediaSkip(let recentDirection) = commandEchoManager.event {
            direction = recentDirection
        } else {
            direction = nil
        }
        pendingSkipDirection = nil
        commandEchoManager.showTrackChanged(trackTitle, direction: direction)
    }

    private func skipTrack(_ direction: MediaSkipDirection) {
        pendingSkipDirection = direction
        commandEchoManager.showMediaSkip(direction)
        switch direction {
        case .previous: mediaManager.previousTrack()
        case .next: mediaManager.nextTrack()
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

            // The mirror case: after a collapse the panel shrinks under a
            // pointer that hasn't moved, which reports a hover and would
            // reopen it at once. Only expand over the island's resting frame.
            if state == .expanded, !isPointer(insideFrameOf: preferredSize) {
                return
            }

            setPresentation(state)
        }
    }

    private var isPointerInsideFloatingWindow: Bool {
        isPointer(insideFrameOf: layout.size(for: .expanded))
    }

    /// Checks the real pointer position against the frame the panel settles
    /// at for `size`, ignoring any resize animation still in flight.
    private func isPointer(insideFrameOf size: CGSize) -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "isloFloatingNotch"
        }), let screen = window.screen ?? NSScreen.main else {
            return isPointerInside
        }

        let topGap: CGFloat = screen.safeAreaInsets.top > 0 ? 0 : 6
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - topGap - size.height,
            width: size.width,
            height: size.height
        )

        return frame
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
        } else {
            // Opening replaces a system-change HUD instead of stretching it.
            commandEchoTask?.cancel()
        }

        withAnimation(presentationAnimation) {
            presentation = newValue
            expansionProgress = newValue == .expanded ? 1 : 0
            if newValue == .expanded { isCommandEchoVisible = false }
        }
        resizeSurface(to: preferredSize, animation: presentationAnimation)
    }

    /// Animates the visible surface to `target`. The window jumps straight
    /// to a size that holds both the old and the new surface, then settles
    /// once the animation is over. Never animating the window keeps the
    /// notch attached to the top edge and avoids AppKit layout loops.
    private func resizeSurface(to target: CGSize, animation: Animation?) {
        let margin = isCommandEchoVisible ? Self.haloMargin : 0
        windowMargin = max(windowMargin, margin)
        let envelope = CGSize(
            width: max(surfaceSize.width, target.width),
            height: max(surfaceSize.height, target.height)
        )
        onPreferredSizeChange(windowSize(for: envelope, margin: windowMargin), false)

        if target != surfaceSize {
            isIdleSurfaceConcealed = false
        }
        withAnimation(animation) {
            surfaceSize = target
        }

        windowSettleTask?.cancel()
        windowSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            let settledMargin = isCommandEchoVisible ? Self.haloMargin : 0
            windowMargin = settledMargin
            onPreferredSizeChange(windowSize(for: target, margin: settledMargin), false)
            isIdleSurfaceConcealed = true
        }
    }

    private func windowSize(for surface: CGSize, margin: CGFloat) -> CGSize {
        CGSize(width: surface.width + margin * 2, height: surface.height + margin)
    }

    /// Shows the wings as soon as music plays; hides them only after a short
    /// pause so skipping tracks doesn't make the notch flicker.
    private func updateIdleWings(isPlaying: Bool) {
        idleWingsTask?.cancel()
        guard !isPlaying else {
            setIdleWings(true)
            return
        }
        idleWingsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            setIdleWings(false)
        }
    }

    private func setIdleWings(_ visible: Bool) {
        guard visible != showsIdleWings else { return }
        withAnimation(presentationAnimation) {
            showsIdleWings = visible
        }
        guard presentation == .idle,
              !isCommandEchoVisible,
              !isFileDropTargeted else { return }
        resizeSurface(to: preferredSize, animation: presentationAnimation)
    }

    // MARK: - Derived Values

    private var preferredSize: CGSize {
        if isFileDropTargeted { return fileDropPreferredSize }
        if isCommandEchoVisible { return commandEchoPreferredSize }
        return basePreferredSize
    }

    private var basePreferredSize: CGSize {
        layout.size(for: presentation, idleMode: effectiveIdleMode)
    }

    /// Visible Island means "visible while music plays"; otherwise the notch
    /// rests at the size of the camera housing.
    private var effectiveIdleMode: NotchIdleMode {
        settings.notchIdleMode == .hiddenMini || !showsIdleWings
            ? .hiddenMini
            : .visibleIsland
    }

    private var commandEchoPreferredSize: CGSize {
        let extensionWidth: CGFloat
        switch commandEchoManager.event {
        case .trackChanged: extensionWidth = 380
        case .mediaSkip: extensionWidth = 260
        default: extensionWidth = 300
        }
        let width = layout.hasCameraHousing
            ? min(max(layout.cameraHousingWidth + extensionWidth, 410), layout.screenWidth - 24)
            : min(390, layout.screenWidth - 24)
        let height = layout.hasCameraHousing
            ? layout.notchBandHeight
            : 40
        return CGSize(width: width, height: height)
    }

    private var fileDropPreferredSize: CGSize {
        let width = layout.hasCameraHousing
            ? min(max(layout.cameraHousingWidth + 260, 390), layout.screenWidth - 24)
            : min(380, layout.screenWidth - 24)
        let height = layout.hasCameraHousing
            ? max(layout.notchBandHeight + 94, 124)
            : 112
        return CGSize(width: width, height: height)
    }

    /// On a notched display the shoulder curves pull the body in from both
    /// panel edges; content must start inside that inset to stay visible.
    private var bodyInset: CGFloat {
        guard layout.hasCameraHousing else { return 0 }
        return AdaptiveNotchShape.topFilletRadius(
            progress: expansionProgress,
            size: preferredSize
        )
    }

    private var bodyBottomRadius: CGFloat {
        guard layout.hasCameraHousing else { return 0 }
        return AdaptiveNotchShape.bottomRadius(
            progress: expansionProgress,
            size: preferredSize
        )
    }

    /// Edge padding that never drops below the original flat-edge value.
    private func bodyPadding(_ minimum: CGFloat, gap: CGFloat) -> CGFloat {
        max(minimum, bodyInset + gap)
    }

    private var isHiddenMiniIdle: Bool {
        layout.hasCameraHousing &&
            effectiveIdleMode == .hiddenMini &&
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

    /// The dashboard is always a dark surface, like the notch it grows from.
    private var primaryColor: Color { .white }

    private var panelColor: Color { .black }

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
/// paths and makes the camera housing itself appear to become islo.
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
        let fillet = Self.topFilletRadius(progress: progress, size: rect.size)
        let bottomRadius = Self.bottomRadius(progress: progress, size: rect.size)
        let bodyLeft = rect.minX + fillet
        let bodyRight = rect.maxX - fillet

        // Like the physical notch: the top edge meets the display edge, a
        // small concave fillet turns it straight down, and the lower corners
        // are convex. Tangent arcs keep every joint perfectly smooth.
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: bodyRight, y: rect.minY),
            tangent2End: CGPoint(x: bodyRight, y: rect.maxY),
            radius: fillet
        )
        path.addArc(
            tangent1End: CGPoint(x: bodyRight, y: rect.maxY),
            tangent2End: CGPoint(x: bodyLeft, y: rect.maxY),
            radius: bottomRadius
        )
        path.addArc(
            tangent1End: CGPoint(x: bodyLeft, y: rect.maxY),
            tangent2End: CGPoint(x: bodyLeft, y: rect.minY),
            radius: bottomRadius
        )
        path.addArc(
            tangent1End: CGPoint(x: bodyLeft, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: fillet
        )
        path.closeSubpath()

        return path
    }

    /// Radius of the concave top fillets, which is also how far each side of
    /// the body sits inside the panel edge. The view pads content by it.
    static func topFilletRadius(progress: CGFloat, size: CGSize) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        return max(0, min(6 + (14 - 6) * progress, size.width / 6, size.height / 3))
    }

    static func bottomRadius(progress: CGFloat, size: CGSize) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        let fillet = topFilletRadius(progress: progress, size: size)
        return max(0, min(
            10 + (28 - 10) * progress,
            (size.width - fillet * 2) / 2,
            size.height - fillet
        ))
    }

    private func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }
}

private struct AnimatedPercentText: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int((value * 100).rounded()))%")
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
