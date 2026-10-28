import AppKit
import Combine
import SwiftUI

enum NotchPresentationState: Equatable {
    case idle
    case expanded
}

/// Derives the camera-housing geometry from AppKit's safe display regions.
/// This intentionally detects the active screen rather than a Mac model name,
/// so new MacBooks and external displays inherit the correct presentation.
struct NotchLayout: Equatable {
    let idleWidth: CGFloat
    let notchBandHeight: CGFloat
    let cameraHousingWidth: CGFloat
    let expandedWidth: CGFloat

    private static let compactWingWidth: CGFloat = 52

    init(screen: NSScreen?) {
        guard let screen else {
            idleWidth = 176
            notchBandHeight = 0
            cameraHousingWidth = 0
            expandedWidth = 460
            return
        }

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
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var expansionProgress: CGFloat = 0

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
        .onHover(perform: handleHover)
        .onAppear {
            scrubValue = mediaManager.playbackPosition
            expansionProgress = presentation == .expanded ? 1 : 0
            onPreferredSizeChange(preferredSize, false)
        }
        .onDisappear {
            hoverTask?.cancel()
        }
        .onReceive(mediaManager.$playbackPosition) { newValue in
            guard !isScrubbing else { return }
            scrubValue = newValue
        }
        .onReceive(mediaManager.$duration) { newDuration in
            guard !isScrubbing else { return }
            scrubValue = min(scrubValue, max(newDuration, 0))
        }
        .onChange(of: settings.expandOnHover) { enabled in
            if !enabled, !isPinned, presentation == .expanded {
                setPresentation(.idle)
            }
        }
        .onChange(of: settings.notchIdleMode) { _ in
            guard presentation == .idle else { return }
            onPreferredSizeChange(preferredSize, !reduceMotion)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .islandXExpand)
        ) { _ in
            hoverTask?.cancel()
            isPinned = true
            setPresentation(.expanded)
        }
        .contextMenu {
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
        if layout.hasCameraHousing {
            notchedExpandedContent
        } else {
            standardExpandedContent
        }
    }

    /// On a MacBook display the camera housing becomes the visual centre of the
    /// control. Content lives in its two side wings, so expanding feels like the
    /// physical notch widening instead of a card dropping down from it.
    private var notchedExpandedContent: some View {
        VStack(spacing: 4) {
            notchAccessoryRow

            HStack(spacing: 10) {
                artwork(size: 52, cornerRadius: 14)

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
        .accessibilityElement(children: .combine)
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
        }
    }

    private var trackHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            artwork(size: 52, cornerRadius: 11)

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
                    isPinned = false
                    setPresentation(.idle)
                }
            }
        }
        .frame(height: 52)
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            mediaControlButton(
                icon: "backward.fill",
                label: "Previous track",
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
                label: "Next track",
                action: mediaManager.nextTrack
            )
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

    private func handleHover(_ isInside: Bool) {
        isPointerInside = isInside
        hoverTask?.cancel()

        guard settings.expandOnHover else { return }
        guard !isPinned, !isInteracting else { return }
        schedulePresentation(isInside ? .expanded : .idle)
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
            setPresentation(state)
        }
    }

    private func updateInteraction(_ active: Bool) {
        isInteracting = active

        if !active, !isPinned, !isPointerInside {
            schedulePresentation(.idle)
        }
    }

    private func setPresentation(_ newValue: NotchPresentationState) {
        guard newValue != presentation else { return }

        onPreferredSizeChange(
            layout.size(
                for: newValue,
                idleMode: settings.notchIdleMode
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
            idleMode: settings.notchIdleMode
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
