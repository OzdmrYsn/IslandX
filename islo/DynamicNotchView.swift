import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum NotchPresentationState: Equatable {
    case idle
    case expanded
}

private enum ShelfFilter { case all, images, documents }

private enum ClipboardFilter { case all, text, links }

private enum FileDropTarget {
    case shelf
    case airDrop
}

private enum DashboardSection: String, CaseIterable {
    case home
    case notifications
    case calendar
    case timer
    case shelf
    case clipboard
    case shortcuts
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
    @ObservedObject private var notificationMonitor: NotificationMonitor
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var powerMonitor = PowerMonitor.shared
    @ObservedObject private var audioDevices = AudioDeviceManager.shared
    @ObservedObject private var privacyMonitor = PrivacyMonitor.shared
    @ObservedObject private var lyricsManager = LyricsManager.shared
    @ObservedObject private var weatherManager = WeatherManager.shared
    @ObservedObject private var screenshotMonitor = ScreenshotMonitor.shared
    @ObservedObject private var downloadMonitor = DownloadMonitor.shared
    @ObservedObject private var shortcutsManager = ShortcutsManager.shared
    @AppStorage("dashboard.lyrics.visible") private var showsLyrics = false
    @State private var showsOutputPicker = false

    private let layout: NotchLayout
    private let onPreferredSizeChange: (CGSize, Bool) -> Void

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    @Namespace private var artworkNamespace
    @Namespace private var navigationNamespace

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
    @State private var isFileDropTargeted = false
    @State private var isShelfTileTargeted = false
    @State private var isAirDropTileTargeted = false
    @State private var shelfFilter: ShelfFilter = .all
    @State private var clipboardFilter: ClipboardFilter = .all
    @State private var selectedClipboardID: UUID?
    @State private var notificationFilter: String?
    @State private var isCommandEchoVisible = false
    /// The event the HUD shows, fixed when it's accepted, so later events
    /// that aren't shown can't change what's on screen.
    @State private var displayedEcho: CommandEchoKind = .copied
    @State private var displayedEchoRevision = 0
    /// While the pointer is on a HUD with buttons it stays up.
    @State private var isEchoHovered = false
    @State private var echoActionDone: String?
    /// A meeting alert that arrived while the dashboard was open.
    @State private var pendingEventAlert: CalendarEventInfo?
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
        notificationMonitor: NotificationMonitor,
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
        _notificationMonitor = ObservedObject(wrappedValue: notificationMonitor)
        self.layout = layout
        self.onPreferredSizeChange = onPreferredSizeChange
    }

    private var renderedSurface: some View {
        ZStack(alignment: .top) {
            if isFileDropHUDVisible {
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
        .animation(presentationAnimation, value: isFileDropHUDVisible)
        .background {
            if isHiddenMiniIdle && isIdleSurfaceConcealed
                && !isCommandEchoVisible && !isFileDropHUDVisible {
                Color.clear
            } else if isCommandEchoVisible || isFileDropHUDVisible {
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
        .contentShape(notchShape)
        // Anywhere outside the two tiles counts as the shelf.
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isFileDropTargeted
        ) { providers in
            handleFileDrop(providers, to: .shelf)
        }
    }

    /// Shown the moment files are picked up anywhere, so the notch can be
    /// aimed at, and while files hover over it.
    private var isFileDropHUDVisible: Bool {
        settings.dashboardFileShelfEnabled && (
            isFileDropTargeted || isShelfTileTargeted || isAirDropTileTargeted ||
                (fileShelfManager.isFileDragActive && presentation == .idle)
        )
    }

    private var showsHalo: Bool {
        isCommandEchoVisible || isFileDropHUDVisible
    }

    private func handleFileDrop(
        _ providers: [NSItemProvider],
        to target: FileDropTarget
    ) -> Bool {
        guard settings.dashboardFileShelfEnabled else { return false }
        switch target {
        case .shelf:
            let accepted = fileShelfManager.receive(providers)
            if accepted {
                isPinned = true
                setPresentation(.expanded)
                selectDashboardSection(.shelf)
            }
            return accepted
        case .airDrop:
            return fileShelfManager.sendViaAirDrop(providers)
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
        .opacity(showsHalo ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: showsHalo)
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
        // Next run-loop pass, once the artist and album have caught up too.
        .onReceive(mediaManager.$trackName.removeDuplicates().receive(on: RunLoop.main)) { _ in
            if showsLyrics { loadLyrics() }
        }
        .onChange(of: settings.lyricsEnabled) { enabled in
            if !enabled { lyricsManager.reset() }
        }
        .onReceive(mediaManager.$volume.dropFirst().removeDuplicates()) { value in
            guard settings.dashboardCommandEchoEnabled else { return }
            commandEchoManager.showVolume(value)
        }
        .onReceive(commandEchoManager.$revision.dropFirst()) { _ in
            showCommandEchoIfNeeded()
        }
        .onChange(of: isTimerLive) { _ in
            refreshIdleSurface()
        }
        .onChange(of: isPrivacyLive) { _ in
            refreshIdleSurface()
        }
        .onChange(of: isDownloadLive) { _ in
            refreshIdleSurface()
        }
        .onReceive(screenshotMonitor.$revision.dropFirst()) { _ in
            guard let capture = screenshotMonitor.latest else { return }
            commandEchoManager.showScreenshot(capture)
        }
        .onReceive(downloadMonitor.$finishRevision.dropFirst()) { _ in
            guard let download = downloadMonitor.lastFinished else { return }
            commandEchoManager.showDownloadFinished(download)
        }
        .onReceive(privacyMonitor.$startRevision.dropFirst()) { _ in
            commandEchoManager.showPrivacy(privacyMonitor.usage)
        }
        .onReceive(focusTimerManager.$finishRevision.dropFirst()) { _ in
            commandEchoManager.showTimerFinished(focusTimerManager.lastFinish)
        }
        .onReceive(powerMonitor.$eventRevision.dropFirst()) { _ in
            commandEchoManager.showPower(powerMonitor.lastEvent)
        }
        .onReceive(audioDevices.$headphoneRevision.dropFirst()) { _ in
            guard let battery = audioDevices.lastHeadphones else { return }
            commandEchoManager.showHeadphones(battery)
        }
        .onReceive(calendarManager.$alertRevision.dropFirst()) { _ in
            guard let event = calendarManager.alertEvent else { return }
            // The HUD only shows over the closed notch; keep it for later.
            if presentation == .idle {
                commandEchoManager.showUpcomingEvent(event)
            } else {
                pendingEventAlert = event
            }
        }
        .onChange(of: settings.dashboardFocusTimerEnabled) { enabled in
            if !enabled, dashboardSection == .timer { dashboardSection = .home }
        }
        .onChange(of: settings.dashboardFileShelfEnabled) { enabled in
            if !enabled, dashboardSection == .shelf { dashboardSection = .home }
        }
        .onChange(of: settings.dashboardNotificationsEnabled) { enabled in
            if !enabled, dashboardSection == .notifications { dashboardSection = .home }
        }
        .onChange(of: settings.shortcutsEnabled) { enabled in
            if !enabled, dashboardSection == .shortcuts { dashboardSection = .home }
        }
        .onChange(of: dashboardSection) { section in
            if section == .notifications { notificationMonitor.markAllRead() }
        }
        .onReceive(notificationMonitor.$announcementRevision.dropFirst()) { _ in
            guard settings.dashboardNotificationsEnabled,
                  let latest = notificationMonitor.latest else { return }
            if presentation == .expanded {
                // Already reading them; don't count it as unread.
                if dashboardSection == .notifications { notificationMonitor.markAllRead() }
                return
            }
            commandEchoManager.showNotification(latest)
        }
        .onChange(of: isFileDropHUDVisible) { _ in
            resizeSurface(to: preferredSize, animation: presentationAnimation)
        }
        .onChange(of: settings.dashboardKeepAwakeEnabled) { enabled in
            if !enabled { keepAwakeManager.setActive(false) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .isloToggle)
        ) { _ in
            hoverTask?.cancel()
            trackChangeTask?.cancel()
            isTemporaryTrackPreview = false
            if presentation == .expanded {
                isPinned = false
                setPresentation(.idle)
            } else {
                isPinned = true
                setPresentation(.expanded)
            }
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
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var surfaceContextMenu: some View {
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
            if idleActivity == .timer { dashboardSection = .timer }
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
            compactLeadingWing
                .frame(width: layout.compactWingWidth, alignment: .trailing)
                // The left wing's outer corner is free (its content hugs the
                // camera housing), so the camera/mic dot sits there.
                .overlay(alignment: .leading) { privacyCornerDot.padding(.leading, 7) }

            Color.clear
                .frame(width: layout.cameraHousingWidth)
                .accessibilityHidden(true)

            compactTrailingWing
                .frame(width: layout.compactWingWidth, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    private var standardCompactContent: some View {
        HStack(spacing: 8) {
            compactLeadingWing

            Spacer(minLength: 30)

            compactTrailingWing
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .overlay { privacyCornerDot }
    }

    /// What the closed notch's wings show, most urgent first.
    private enum IdleActivity {
        case none
        case music
        case timer
        case download
        case privacy
    }

    private var isDownloadLive: Bool {
        settings.downloadsEnabled && !downloadMonitor.active.isEmpty
    }

    private var isPrivacyLive: Bool {
        settings.privacyIndicatorEnabled && privacyMonitor.usage.isActive
    }

    private var isTimerLive: Bool {
        settings.dashboardFocusTimerEnabled
            && settings.liveTimerInNotch
            && focusTimerManager.isRunning
    }

    private var idleActivity: IdleActivity {
        if isTimerLive { return .timer }
        if isDownloadLive { return .download }
        if showsIdleWings { return .music }
        if isPrivacyLive { return .privacy }
        return .none
    }

    @ViewBuilder
    private var compactLeadingWing: some View {
        switch idleActivity {
        case .timer:
            timerMiniRing
        case .download:
            downloadMiniRing
        case .privacy:
            PrivacyDots(usage: privacyMonitor.usage, size: 8)
        case .music, .none:
            artwork(size: 27, cornerRadius: 7)
        }
    }

    private var compactTrailingWing: some View {
        compactTrailingContent
    }

    /// A small camera/microphone dot while music or a timer fills the wings.
    @ViewBuilder
    private var privacyCornerDot: some View {
        if isPrivacyLive, idleActivity != .privacy {
            PrivacyDots(usage: privacyMonitor.usage, size: 5)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var compactTrailingContent: some View {
        switch idleActivity {
        case .download:
            Text(percentText(Int((downloadMonitor.overallFraction * 100).rounded())))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        case .privacy:
            Text(privacyMonitor.usage.appName ?? privacyKindText(privacyMonitor.usage))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .timer:
            Text(focusTimerManager.formattedTime)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText(countsDown: true))
                .animation(.easeOut(duration: 0.2), value: focusTimerManager.remainingSeconds)
        case .music, .none:
            PlaybackWaveform(isPlaying: mediaManager.isPlaying)
                .foregroundStyle(playbackIndicatorColor)
        }
    }

    /// Download progress as a small ring around an arrow; a count when
    /// several files are coming in.
    private var downloadMiniRing: some View {
        let fraction = downloadMonitor.overallFraction
        let count = downloadMonitor.active.count
        return ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: fraction)
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.green)
            } else {
                Image(systemName: downloadMonitor.active.first?.isAirDrop == true ? "dot.radiowaves.left.and.right" : "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.green)
            }
        }
        .frame(width: 20, height: 20)
    }

    /// The time left as a small ring, with the phase as its icon.
    private var timerMiniRing: some View {
        let remaining = 1 - focusTimerManager.progress
        let tint = focusTimerManager.isBreak ? Color.mint : accent
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(remaining, 0.01))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: remaining)
            Image(systemName: focusTimerManager.mode == .timer
                  ? "timer"
                  : (focusTimerManager.isBreak ? "cup.and.saucer.fill" : "brain.head.profile"))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 20, height: 20)
    }

    private var playbackIndicatorColor: Color {
        mediaManager.isPlaying
            ? accent
            : primaryColor.opacity(0.55)
    }

    // MARK: - Expanded UI

    private var dashboardExpandedContent: some View {
        VStack(spacing: 0) {
            dashboardNavigationRow
            dashboardStage
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(dashboardSceneBackground)
    }

    // MARK: - Dashboard sections

    private var dashboardCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private var dashboardGlassCard: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(0.11), .white.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The rounded glass card every section is built from, so the inside of
    /// the notch follows its soft outline instead of square panes.
    private func dashboardCard<Content: View>(
        padding: CGFloat = 14,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(dashboardCardShape.fill(dashboardGlassCard))
            .overlay(dashboardCardShape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            .clipShape(dashboardCardShape)
    }

    /// Home keeps the summary column on the right; every other section uses
    /// the full width for its own layout.
    private var dashboardStage: some View {
        Group {
            switch dashboardSection {
            case .home: dashboardHomeSection
            case .notifications: dashboardNotificationsSection
            case .calendar: dashboardCalendarSection
            case .timer: dashboardTimerSection
            case .shelf: dashboardShelfSection
            case .clipboard: dashboardClipboardSection
            case .shortcuts: dashboardShortcutsSection
            }
        }
        .padding(.horizontal, bodyPadding(16, gap: 12))
        .padding(.bottom, 16)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(primaryColor.opacity(0.5))
    }

    private func filterChip(
        _ title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.black : primaryColor.opacity(0.75))
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Capsule().fill(isSelected ? Color.white : Color.clear))
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.clear : primaryColor.opacity(0.18),
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func roundIconButton(
        _ symbol: String,
        label: String,
        filled: Bool = false,
        size: CGFloat = 28,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(filled ? Color.black : primaryColor.opacity(0.85))
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? Color.white : primaryColor.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private func emptyState(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(primaryColor.opacity(0.42))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Home

    private var dashboardHomeSection: some View {
        HStack(spacing: 14) {
            if settings.homeWidgetStyle == .focus && settings.dashboardFocusTimerEnabled {
                dashboardCard { dashboardFocusPane }
            } else {
                dashboardCard { dashboardMediaPane }
                    .background(mediaArtworkGlow)
            }

            dashboardCard { dashboardSidePane }
                .frame(width: dashboardSideWidth)
        }
    }

    private var dashboardSideWidth: CGFloat {
        switch settings.homeWidgetStyle {
        case .media: 190
        case .day: 310
        case .balanced, .focus: 238
        }
    }

    private var dashboardSidePane: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center) {
                    Text(dashboardWeekday(context.date).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.red.opacity(0.85))
                    Spacer(minLength: 6)
                    weatherChip
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(dashboardDate(context.date))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                    Spacer()
                    Text(dashboardTime(context.date))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(primaryColor.opacity(0.58))
                }

                calendarSummaryCards(now: context.date, separatorTitle: localized("Sıradaki", "Up next"))
            }
        }
    }

    /// Icon, temperature and city; the tooltip has the day's range.
    @ViewBuilder
    private var weatherChip: some View {
        if settings.weatherEnabled, let weather = weatherManager.snapshot {
            HStack(spacing: 4) {
                Image(systemName: WeatherManager.symbolName(code: weather.code, isDay: weather.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 11))
                Text("\(Int(weather.temperature.rounded()))°")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(primaryColor)
                Text(weather.locationName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.5))
                    .lineLimit(1)
            }
            .help(
                WeatherManager.summary(code: weather.code, turkish: settings.language == .turkish)
                    + localized(" · En yüksek \(Int(weather.high.rounded()))° · En düşük \(Int(weather.low.rounded()))°",
                                " · High \(Int(weather.high.rounded()))° · Low \(Int(weather.low.rounded()))°")
            )
            .transition(.opacity)
        }
    }

    /// Two stacked cards: the next event and the one after it, or a way to
    /// connect the calendar when islo. can't read it yet.
    @ViewBuilder
    private func calendarSummaryCards(now: Date, separatorTitle: String?) -> some View {
        let events = settings.calendarEnabled && calendarManager.authorization == .granted
            ? Array(calendarManager.upcoming.prefix(2))
            : []

        if settings.calendarEnabled, calendarManager.authorization == .notAsked {
            dashboardSummaryCard(
                icon: "calendar.badge.plus",
                title: localized("Takvimini bağla", "Connect your calendar"),
                subtitle: localized("Sıradaki etkinliğin burada görünsün", "See your next event here"),
                action: calendarManager.requestAccess
            )
        } else if settings.calendarEnabled, calendarManager.authorization == .missing {
            dashboardSummaryCard(
                icon: "calendar.badge.exclamationmark",
                title: localized("Takvim izni kapalı", "Calendar access is off"),
                subtitle: localized("Sistem Ayarları'ndan izin ver", "Allow it in System Settings"),
                action: calendarManager.openPrivacySettings
            )
        } else if let first = events.first {
            eventCard(first, now: now)
        } else {
            dashboardSummaryCard(
                icon: "calendar.badge.checkmark",
                title: localized("Bugün için hazırsın", "You're clear for today"),
                subtitle: localized("Takvimi aç", "Open Calendar"),
                action: openCalendar
            )
        }

        if let separatorTitle {
            Text(separatorTitle)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(primaryColor.opacity(0.4))
        }

        if events.count > 1 {
            eventCard(events[1], now: now)
        } else {
            dashboardSummaryCard(
                icon: "plus",
                title: localized("Yeni etkinlik", "New event"),
                subtitle: localized("Takvim'de oluştur", "Create in Calendar"),
                action: openCalendar
            )
        }
    }

    /// An event row: calendar colour, title, when, and Join for video calls.
    private func eventCard(_ event: CalendarEventInfo, now: Date) -> some View {
        Button {
            calendarManager.join(event)
        } label: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(Color(nsColor: event.color))
                    .frame(width: 3.5, height: 25)

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                    Text(eventTimeText(event, now: now))
                        .font(.system(size: 8))
                        .foregroundStyle(event.isOngoing(at: now) ? accent : primaryColor.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if event.joinURL != nil {
                    Text(localized("Katıl", "Join"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(primaryColor.opacity(0.3))
                }
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
        .help(event.joinURL != nil ? localized("Toplantıya katıl", "Join the meeting") : event.title)
    }

    private func eventTimeText(_ event: CalendarEventInfo, now: Date) -> String {
        if event.isOngoing(at: now) {
            return localized("Şimdi · bitiş \(dashboardTime(event.end))", "Now · until \(dashboardTime(event.end))")
        }
        let minutes = Int(ceil(event.start.timeIntervalSince(now) / 60))
        if minutes <= 60 {
            return localized("\(minutes) dk sonra · \(dashboardTime(event.start))", "In \(minutes) min · \(dashboardTime(event.start))")
        }
        if Calendar.current.isDateInToday(event.start) {
            return "\(dashboardTime(event.start)) – \(dashboardTime(event.end))"
        }
        if Calendar.current.isDateInTomorrow(event.start) {
            return localized("Yarın \(dashboardTime(event.start))", "Tomorrow \(dashboardTime(event.start))")
        }
        return formatted(event.start, template: "EEEHHmm")
    }

    // MARK: Calendar

    private var dashboardCalendarSection: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 14) {
                dashboardCard {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dashboardWeekday(context.date).uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(Color.red.opacity(0.85))
                        Text(formatted(context.date, template: "d"))
                            .font(.system(size: 50, weight: .bold, design: .rounded))
                            .foregroundStyle(primaryColor)
                        Text(formatted(context.date, template: "MMMMyyyy"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(primaryColor.opacity(0.6))
                        Spacer(minLength: 0)
                        Text(dashboardTime(context.date))
                            .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(primaryColor.opacity(0.85))
                    }
                }
                .frame(width: 190)

                dashboardCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel(localized("Bu hafta", "This week"))
                        weekStrip(for: context.date)
                        Spacer(minLength: 0)
                        HStack(spacing: 10) {
                            calendarSummaryCards(now: context.date, separatorTitle: nil)
                        }
                    }
                }
            }
        }
    }

    private func weekStrip(for date: Date) -> some View {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }

        return HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: date)
                VStack(spacing: 4) {
                    Text(formatted(day, template: "EEE"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isToday ? Color.white : primaryColor.opacity(0.45))
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(isToday ? Color.white : primaryColor.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isToday ? accent : primaryColor.opacity(0.05))
                )
            }
        }
    }

    private func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.language == .turkish ? "tr_TR" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    // MARK: Timer

    private var dashboardTimerSection: some View {
        HStack(spacing: 14) {
            dashboardCard { dashboardFocusPane }
            dashboardCard { focusStatsPane }
                .frame(width: 200)
        }
    }

    /// Shared by the Timer tab and the Home focus widget, so every row
    /// falls back to a slimmer version when the card is narrow.
    private var dashboardFocusPane: some View {
        HStack(spacing: 20) {
            // A fixed size, so the stack hands the rest of the width to the
            // controls instead of splitting it with the dial.
            focusDial
                .frame(width: 138, height: 138)

            VStack(alignment: .leading, spacing: 0) {
                focusModeSwitch
                Spacer(minLength: 6)
                focusDurationEditor
                Spacer(minLength: 6)
                focusControls
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear(perform: focusTimerManager.loadTodayStats)
    }

    /// A watch-style dial. In Timer mode it doubles as a kitchen timer:
    /// drag around it to set up to an hour.
    private var focusDial: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let fraction = focusTimerManager.dialFraction
            let canSet = focusTimerManager.mode == .timer && !focusTimerManager.isRunning

            ZStack {
                dialTicks

                ZStack {
                    Circle()
                        .stroke(primaryColor.opacity(0.08), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: max(fraction, 0.002))
                        .stroke(
                            AngularGradient(
                                colors: [accent.opacity(0.45), accent],
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(360 * max(fraction, 0.02))
                            ),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .shadow(color: accent.opacity(0.45), radius: 6)
                    if fraction > 0.004 {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 5, height: 5)
                            .offset(y: -(side - 20) / 2)
                            .rotationEffect(.degrees(360 * fraction))
                    }
                }
                .padding(10)
                .animation(.linear(duration: 0.25), value: fraction)

                VStack(spacing: 3) {
                    Text(focusTimerManager.formattedTime)
                        .font(.system(size: side * 0.19, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(primaryColor)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(focusTimerManager.isRunning ? accent : primaryColor.opacity(0.35))
                            .frame(width: 5, height: 5)
                        Text(focusPhaseLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(primaryColor.opacity(0.55))
                    }
                    if canSet {
                        Text(localized("Halkayı çevir", "Turn the dial"))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(primaryColor.opacity(0.35))
                    }
                }
                .padding(.horizontal, 22)
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard canSet else { return }
                        setTimerFromDial(gesture.location, side: side)
                    }
                    .onEnded { _ in
                        guard canSet else { return }
                        updateInteraction(false)
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }

    private var dialTicks: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 1
            for index in 0..<60 {
                let isMajor = index % 5 == 0
                let length: CGFloat = isMajor ? 5 : 2.5
                let angle = Double(index) / 60 * 2 * .pi
                var tick = Path()
                tick.move(to: CGPoint(
                    x: center.x + CGFloat(sin(angle)) * radius,
                    y: center.y - CGFloat(cos(angle)) * radius
                ))
                tick.addLine(to: CGPoint(
                    x: center.x + CGFloat(sin(angle)) * (radius - length),
                    y: center.y - CGFloat(cos(angle)) * (radius - length)
                ))
                context.stroke(
                    tick,
                    with: .color(primaryColor.opacity(isMajor ? 0.32 : 0.13)),
                    style: StrokeStyle(lineWidth: isMajor ? 1.5 : 1, lineCap: .round)
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func setTimerFromDial(_ location: CGPoint, side: CGFloat) {
        let dx = location.x - side / 2
        let dy = location.y - side / 2
        // The very middle has no clear direction.
        guard hypot(dx, dy) > side * 0.22 else { return }
        var angle = atan2(Double(dx), Double(-dy))
        if angle < 0 { angle += 2 * .pi }
        var minutes = Int((angle / (2 * .pi) * 60).rounded())
        if minutes == 0 { minutes = 60 }
        updateInteraction(true)
        guard minutes != focusTimerManager.timerMinutes else { return }
        focusTimerManager.timerMinutes = minutes
        if minutes % 5 == 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private var focusPhaseLabel: String {
        switch focusTimerManager.mode {
        case .timer: localized("Zamanlayıcı", "Timer")
        case .pomodoro:
            focusTimerManager.isBreak ? localized("Mola", "Break") : localized("Odak", "Focus")
        }
    }

    /// A capsule switch in the notch's own style instead of a system control.
    private var focusModeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(FocusTimerMode.allCases) { mode in
                let isSelected = focusTimerManager.mode == mode
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        focusTimerManager.mode = mode
                    }
                } label: {
                    Text(mode == .timer ? localized("Zamanlayıcı", "Timer") : "Pomodoro")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.black : primaryColor.opacity(0.65))
                        .padding(.horizontal, 13)
                        .frame(height: 26)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white)
                                    .matchedGeometryEffect(id: "focusMode", in: navigationNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(primaryColor.opacity(0.08)))
    }

    @ViewBuilder
    private var focusDurationEditor: some View {
        if focusTimerManager.mode == .timer {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    timerStepper
                    timerPresets([5, 10, 15, 25, 45, 60])
                }
                HStack(spacing: 10) {
                    timerStepper
                    timerPresets([5, 15, 25, 45])
                }
                HStack(spacing: 10) {
                    timerStepper
                    timerPresets([15, 25])
                }
                timerStepper
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    labeledStepper(localized("Odak", "Focus"), value: focusTimerManager.focusMinutes, range: FocusTimerManager.focusRange) {
                        focusTimerManager.focusMinutes = $0
                    }
                    labeledStepper(localized("Mola", "Break"), value: focusTimerManager.breakMinutes, range: FocusTimerManager.breakRange) {
                        focusTimerManager.breakMinutes = $0
                    }
                }
                pomodoroPhases
            }
        }
    }

    private var timerStepper: some View {
        minuteStepper(value: focusTimerManager.timerMinutes, range: FocusTimerManager.timerRange) {
            focusTimerManager.timerMinutes = $0
        }
    }

    private func labeledStepper(
        _ title: String,
        value: Int,
        range: ClosedRange<Int>,
        set: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(0.55))
            minuteStepper(value: value, range: range, name: title, set: set)
        }
    }

    /// −/+ around the length: single minutes up to 10, then fives.
    private func minuteStepper(
        value: Int,
        range: ClosedRange<Int>,
        name: String? = nil,
        set: @escaping (Int) -> Void
    ) -> some View {
        let isLocked = focusTimerManager.isRunning
        let decrease = name.map { localized("\($0) süresini azalt", "Shorten \($0.lowercased())") } ?? localized("Süreyi azalt", "Shorten")
        let increase = name.map { localized("\($0) süresini artır", "Lengthen \($0.lowercased())") } ?? localized("Süreyi artır", "Lengthen")

        return HStack(spacing: 2) {
            stepperButton("minus", label: decrease, isEnabled: !isLocked && value > range.lowerBound) {
                set(FocusTimerManager.steppedMinutes(value, up: false, range: range))
            }
            Text(minutesText(value))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(primaryColor.opacity(isLocked ? 0.5 : 1))
                .lineLimit(1)
                .frame(minWidth: 50)
            stepperButton("plus", label: increase, isEnabled: !isLocked && value < range.upperBound) {
                set(FocusTimerManager.steppedMinutes(value, up: true, range: range))
            }
        }
        .padding(3)
        .background(Capsule().fill(primaryColor.opacity(0.07)))
        .fixedSize()
    }

    private func stepperButton(
        _ symbol: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(primaryColor.opacity(isEnabled ? 0.85 : 0.25))
                .frame(width: 26, height: 26)
                .background(Circle().fill(primaryColor.opacity(isEnabled ? 0.1 : 0.04)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private func minutesText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return localized("\(minutes) dk", "\(minutes) min") }
        if rest == 0 { return localized("\(hours) sa", "\(hours) h") }
        return localized("\(hours) sa \(rest) dk", "\(hours) h \(rest) min")
    }

    private func timerPresets(_ presets: [Int]) -> some View {
        HStack(spacing: 5) {
            ForEach(presets, id: \.self) { minutes in
                let isSelected = focusTimerManager.timerMinutes == minutes
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        focusTimerManager.timerMinutes = minutes
                    }
                } label: {
                    Text(minutes == 60 ? localized("1 sa", "1 h") : "\(minutes)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? accent : primaryColor.opacity(0.7))
                        .frame(minWidth: 30)
                        .padding(.horizontal, 4)
                        .frame(height: 24)
                        .background(Capsule().fill(isSelected ? accent.opacity(0.16) : primaryColor.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(isSelected ? accent.opacity(0.6) : Color.clear, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(focusTimerManager.isRunning)
                .opacity(focusTimerManager.isRunning ? 0.45 : 1)
                .help(minutesText(minutes))
            }
        }
        .fixedSize()
    }

    private var pomodoroPhases: some View {
        HStack(spacing: 6) {
            phaseChip(localized("Odak · \(focusTimerManager.focusMinutes) dk", "Focus · \(focusTimerManager.focusMinutes) min"), isActive: !focusTimerManager.isBreak)
            phaseChip(localized("Mola · \(focusTimerManager.breakMinutes) dk", "Break · \(focusTimerManager.breakMinutes) min"), isActive: focusTimerManager.isBreak)
        }
        .fixedSize()
    }

    private func phaseChip(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isActive ? accent : primaryColor.opacity(0.5))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(isActive ? accent.opacity(0.16) : primaryColor.opacity(0.06)))
    }

    private var focusControls: some View {
        HStack(spacing: 10) {
            roundIconButton(
                focusTimerManager.isRunning ? "pause.fill" : "play.fill",
                label: focusTimerManager.isRunning ? localized("Duraklat", "Pause") : localized("Başlat", "Start"),
                filled: true,
                size: 42,
                action: focusTimerManager.toggle
            )
            roundIconButton(
                "arrow.counterclockwise",
                label: localized("Sıfırla", "Reset"),
                size: 32,
                action: focusTimerManager.reset
            )
            if focusTimerManager.mode == .pomodoro {
                roundIconButton(
                    "forward.end.fill",
                    label: localized("Sonraki aşama", "Next phase"),
                    size: 32,
                    action: focusTimerManager.skipPhase
                )
            }
        }
    }

    /// The right-hand card in the Timer tab: today's focus and what's next.
    private var focusStatsPane: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 0) {
                Text(localized("BUGÜN", "TODAY"))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(accent)

                Text(focusTotalText(focusTimerManager.todayFocusSeconds))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 2)

                Text(localized("odaklandın", "of focus"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.5))

                HStack(spacing: 4) {
                    ForEach(0..<FocusTimerManager.sessionsPerRound, id: \.self) { index in
                        Capsule()
                            .fill(index < focusTimerManager.sessionsInRound ? accent : primaryColor.opacity(0.12))
                            .frame(height: 5)
                    }
                }
                .padding(.top, 10)

                Text(localized("\(focusTimerManager.todaySessions) seans tamamlandı", focusTimerManager.todaySessions == 1 ? "1 session done" : "\(focusTimerManager.todaySessions) sessions done"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.5))
                    .padding(.top, 5)

                Spacer(minLength: 8)

                focusInfoRow(
                    icon: "flag.checkered",
                    title: focusTimerManager.isRunning ? localized("Bitiş", "Ends") : localized("Şimdi başlarsan", "If you start now"),
                    value: dashboardTime(context.date.addingTimeInterval(TimeInterval(focusTimerManager.remainingSeconds)))
                )
                if focusTimerManager.mode == .pomodoro {
                    focusInfoRow(
                        icon: focusTimerManager.isBreak ? "brain.head.profile" : "cup.and.saucer.fill",
                        title: localized("Sıradaki", "Up next"),
                        value: focusTimerManager.isBreak
                            ? localized("\(focusTimerManager.focusMinutes) dk odak", "\(focusTimerManager.focusMinutes) min focus")
                            : localized("\(focusTimerManager.breakMinutes) dk mola", "\(focusTimerManager.breakMinutes) min break")
                    )
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func focusInfoRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(accent.opacity(0.13)))
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(primaryColor.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(primaryColor)
                .lineLimit(1)
        }
    }

    private func focusTotalText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return minutes < 60
            ? localized("\(minutes) dk", "\(minutes) min")
            : minutesText(minutes)
    }

    // MARK: Shortcuts

    /// The user's pinned Shortcuts as tiles; the last tile edits the list.
    private var dashboardShortcutsSection: some View {
        let known = Set(shortcutsManager.available)
        let favorites = settings.shortcutFavorites.filter { known.isEmpty || known.contains($0) }.prefix(7)
        return dashboardCard {
            if favorites.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(accent)
                    Text(localized("Sık kullandığın kısayolları buraya sabitle.", "Pin the Shortcuts you use most here."))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(primaryColor)
                    Text(localized("Kısayollar uygulamasındaki her şey tek tıkla çentikten çalışır.", "Anything in the Shortcuts app, one click away in the notch."))
                        .font(.system(size: 10))
                        .foregroundStyle(primaryColor.opacity(0.5))
                    HStack(spacing: 8) {
                        shortcutsPillButton(localized("Kısayol seç", "Pick shortcuts"), filled: true, action: openShortcutSettings)
                        shortcutsPillButton(localized("Kısayollar'ı aç", "Open Shortcuts"), filled: false, action: shortcutsManager.openShortcutsApp)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(Array(favorites), id: \.self) { name in
                        shortcutTile(name)
                    }
                    shortcutEditTile
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { if shortcutsManager.available.isEmpty { shortcutsManager.reload() } }
    }

    private func shortcutTile(_ name: String) -> some View {
        let state = shortcutsManager.states[name]
        let tint = shortcutTint(name)
        return Button {
            shortcutsManager.run(name)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    switch state {
                    case .running:
                        ProgressView().controlSize(.small).tint(.white)
                    case .succeeded:
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    case .failed:
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    case nil:
                        Image(systemName: "bolt.fill").font(.system(size: 12, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)

                Text(name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(primaryColor.opacity(state == .running ? 0.12 : 0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(Text(localized("Kısayolu çalıştır: \(name)", "Run shortcut: \(name)")))
    }

    private var shortcutEditTile: some View {
        Button(action: openShortcutSettings) {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(primaryColor.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(primaryColor.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                Text(localized("Düzenle", "Edit"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(primaryColor.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(primaryColor.opacity(0.1), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func shortcutsPillButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(filled ? Color.white : primaryColor.opacity(0.8))
                .padding(.horizontal, 13)
                .frame(height: 26)
                .background(Capsule().fill(filled ? accent : primaryColor.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A steady colour per shortcut, like the Shortcuts app's tiles.
    private func shortcutTint(_ name: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.36, green: 0.55, blue: 1), Color(red: 0.62, green: 0.42, blue: 0.98),
            Color(red: 1, green: 0.45, blue: 0.62), Color(red: 1, green: 0.62, blue: 0.25),
            Color(red: 0.25, green: 0.78, blue: 0.55), Color(red: 0.2, green: 0.72, blue: 0.9)
        ]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }

    private func openShortcutSettings() {
        NotificationCenter.default.post(
            name: .isloShowSettings,
            object: nil,
            userInfo: ["destination": "modules"]
        )
    }

    // MARK: Shelf

    private var dashboardShelfSection: some View {
        let items = fileShelfManager.items
        let imageCount = items.filter { fileShelfManager.details(for: $0).isImage }.count
        let filtered = items.filter { url in
            switch shelfFilter {
            case .all: true
            case .images: fileShelfManager.details(for: url).isImage
            case .documents: !fileShelfManager.details(for: url).isImage
            }
        }

        return HStack(spacing: 14) {
            dashboardCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        sectionLabel(localized("Rafta", "On the shelf"))
                        Spacer()
                        roundIconButton(
                            "xmark",
                            label: localized("Rafı temizle (dosyalar silinmez)", "Clear the shelf (files aren't deleted)")
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) { fileShelfManager.clear() }
                        }
                        .disabled(items.isEmpty)
                        .opacity(items.isEmpty ? 0.35 : 1)
                    }
                    Spacer(minLength: 0)
                    Text("\(items.count)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(primaryColor)
                    Text(localized("dosya elinin altında", "files within reach"))
                        .font(.system(size: 10))
                        .foregroundStyle(primaryColor.opacity(0.55))
                    Rectangle()
                        .fill(primaryColor.opacity(0.1))
                        .frame(height: 0.5)
                        .padding(.vertical, 8)
                    Text(localized("\(imageCount) görsel · \(items.count - imageCount) belge", "\(imageCount) images · \(items.count - imageCount) documents"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(primaryColor.opacity(0.6))
                }
            }
            .frame(width: 180)

            dashboardCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        filterChip(localized("Tümü · \(items.count)", "All · \(items.count)"), isSelected: shelfFilter == .all) { shelfFilter = .all }
                        filterChip(localized("Görseller · \(imageCount)", "Images · \(imageCount)"), isSelected: shelfFilter == .images) { shelfFilter = .images }
                        filterChip(localized("Belgeler · \(items.count - imageCount)", "Documents · \(items.count - imageCount)"), isSelected: shelfFilter == .documents) { shelfFilter = .documents }
                    }

                    if filtered.isEmpty {
                        emptyState(
                            "arrow.down.doc",
                            items.isEmpty
                                ? localized("Dosyaları çentiğe sürükleyerek rafa ekleyin.", "Drag files onto the notch to add them.")
                                : localized("Bu filtrede dosya yok.", "No files in this filter.")
                        )
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                                ForEach(filtered, id: \.self) { url in
                                    shelfTile(url)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func shelfTile(_ url: URL) -> some View {
        let details = fileShelfManager.details(for: url)
        let tileShape = RoundedRectangle(cornerRadius: 13, style: .continuous)

        return VStack(alignment: .leading, spacing: 5) {
            ZStack {
                if let thumbnail = fileShelfManager.thumbnails[url] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    primaryColor.opacity(0.06)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(url.lastPathComponent)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Text([shelfKindLabel(details.kind), details.size].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 8))
                .foregroundStyle(primaryColor.opacity(0.45))
                .lineLimit(1)
        }
        .padding(6)
        .background(tileShape.fill(primaryColor.opacity(0.06)))
        .contentShape(tileShape)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture { fileShelfManager.reveal(url) }
        .help(url.lastPathComponent)
        .contextMenu {
            Button(localized("Aç", "Open")) { NSWorkspace.shared.open(url) }
            Button(localized("AirDrop ile Gönder", "Send via AirDrop")) { fileShelfManager.sendViaAirDrop(url) }
            Button(localized("Finder'da Göster", "Show in Finder")) { fileShelfManager.reveal(url) }
            Divider()
            Button(localized("Raftan Kaldır", "Remove from Shelf")) {
                withAnimation(.easeInOut(duration: 0.2)) { fileShelfManager.remove(url) }
            }
        }
    }

    private func shelfKindLabel(_ kind: String) -> String {
        switch kind {
        case "image": localized("Görsel", "Image")
        case "pdf": "PDF"
        case "video": "Video"
        case "audio": localized("Ses", "Audio")
        case "archive": localized("Arşiv", "Archive")
        case "text": localized("Metin", "Text")
        case "folder": localized("Klasör", "Folder")
        default: localized("Dosya", "File")
        }
    }

    // MARK: Clipboard

    private var dashboardClipboardSection: some View {
        let entries = clipboardHistoryManager.entries
        let selected = entries.first { $0.id == selectedClipboardID } ?? entries.first
        let linkCount = entries.filter { $0.linkURL != nil }.count
        let filtered = entries.filter { entry in
            switch clipboardFilter {
            case .all: true
            case .text: entry.linkURL == nil
            case .links: entry.linkURL != nil
            }
        }

        return HStack(spacing: 14) {
            dashboardCard {
                if let selected {
                    selectedClipboardCard(selected)
                } else {
                    emptyState("list.clipboard", localized("Kopyaladığınız metinler burada görünür.", "Copied text appears here."))
                }
            }
            .frame(width: 230)

            dashboardCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        filterChip(localized("Tümü · \(entries.count)", "All · \(entries.count)"), isSelected: clipboardFilter == .all) { clipboardFilter = .all }
                        filterChip(localized("Metin · \(entries.count - linkCount)", "Text · \(entries.count - linkCount)"), isSelected: clipboardFilter == .text) { clipboardFilter = .text }
                        filterChip(localized("Bağlantı · \(linkCount)", "Links · \(linkCount)"), isSelected: clipboardFilter == .links) { clipboardFilter = .links }
                        Spacer(minLength: 0)
                        roundIconButton("trash", label: localized("Geçmişi temizle", "Clear history"), size: 24) {
                            withAnimation(.easeInOut(duration: 0.2)) { clipboardHistoryManager.clear() }
                        }
                        .disabled(entries.isEmpty)
                        .opacity(entries.isEmpty ? 0.35 : 1)
                    }

                    if filtered.isEmpty {
                        emptyState("list.clipboard", localized("Burada henüz bir şey yok.", "Nothing here yet."))
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                ForEach(filtered) { entry in
                                    clipboardTile(entry, isSelected: entry.id == selected?.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func selectedClipboardCard(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                sectionLabel(localized("Seçili öğe", "Selected item"))
                Spacer()
                if let url = entry.linkURL {
                    roundIconButton("arrow.up.right", label: localized("Bağlantıyı aç", "Open link"), filled: true, size: 30) {
                        NSWorkspace.shared.open(url)
                    }
                }
                roundIconButton("doc.on.doc.fill", label: localized("Kopyala", "Copy"), filled: entry.linkURL == nil, size: 30) {
                    clipboardHistoryManager.copy(entry)
                }
            }
            Text(entry.text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primaryColor)
                .lineLimit(4)
            Spacer(minLength: 0)
            Text(clipboardKind(entry) + " · " + entry.source)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(primaryColor.opacity(0.45))
                .lineLimit(1)
        }
    }

    private func clipboardTile(_ entry: ClipboardEntry, isSelected: Bool) -> some View {
        let tileShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return Button {
            selectedClipboardID = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: entry.linkURL == nil ? "text.alignleft" : "link")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(primaryColor.opacity(0.08)))
                    Spacer(minLength: 0)
                    Text(clipboardKind(entry) + " · " + entry.source)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(primaryColor.opacity(0.4))
                        .lineLimit(1)
                }
                Text(entry.text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .frame(height: 74, alignment: .topLeading)
            .background(tileShape.fill(primaryColor.opacity(isSelected ? 0.1 : 0.06)))
            .overlay(tileShape.strokeBorder(isSelected ? accent : Color.clear, lineWidth: 1.5))
            .contentShape(tileShape)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(localized("Kopyala", "Copy")) { clipboardHistoryManager.copy(entry) }
            if let url = entry.linkURL {
                Button(localized("Bağlantıyı Aç", "Open Link")) { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button(localized("Geçmişten Kaldır", "Remove from History")) {
                clipboardHistoryManager.remove(entry)
            }
        }
    }

    private func clipboardKind(_ entry: ClipboardEntry) -> String {
        entry.linkURL == nil ? localized("Metin", "Text") : localized("Bağlantı", "Link")
    }

    // MARK: Notifications

    private var dashboardNotificationsSection: some View {
        let items = notificationMonitor.items
        var appNames: [String] = []
        for item in items where !appNames.contains(item.appName) && appNames.count < 3 {
            appNames.append(item.appName)
        }
        let filtered = notificationFilter.map { name in items.filter { $0.appName == name } } ?? items

        return HStack(spacing: 14) {
            dashboardCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        sectionLabel(localized("Son bildirimler", "Recent notifications"))
                        Spacer()
                        roundIconButton("xmark", label: localized("Bildirimleri temizle", "Clear notifications")) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                notificationMonitor.clear()
                                notificationFilter = nil
                            }
                        }
                        .disabled(items.isEmpty)
                        .opacity(items.isEmpty ? 0.35 : 1)
                    }
                    Spacer(minLength: 0)
                    Text("\(items.count)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(primaryColor)
                    Text(
                        settings.isAccessibilityTrusted
                            ? localized("bu oturumda gelen bildirim", "notifications this session")
                            : localized("Ayarlar › İzinler'den Erişilebilirlik izni verin.", "Allow Accessibility in Settings › Permissions.")
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(primaryColor.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 180)

            dashboardCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        filterChip(localized("Tümü", "All"), isSelected: notificationFilter == nil) { notificationFilter = nil }
                        ForEach(appNames, id: \.self) { name in
                            filterChip(name, isSelected: notificationFilter == name) { notificationFilter = name }
                        }
                    }

                    if filtered.isEmpty {
                        emptyState("bell", localized("Yeni bildirimler burada toplanır.", "New notifications collect here."))
                    } else {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVStack(spacing: 7) {
                                    ForEach(filtered) { item in
                                        notificationRow(item)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func notificationRow(_ item: CapturedNotification) -> some View {
        let rowShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return Button {
            notificationMonitor.openApplication(for: item)
        } label: {
            HStack(spacing: 10) {
                notificationAppIcon(item)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.appName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)
                        Text(relativeTime(item.date))
                            .font(.system(size: 9))
                            .foregroundStyle(primaryColor.opacity(0.4))
                    }
                    Text(item.headline)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(primaryColor.opacity(0.85))
                        .lineLimit(1)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(primaryColor.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(rowShape.fill(primaryColor.opacity(0.06)))
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(localized("Kaldır", "Remove")) { notificationMonitor.remove(item) }
        }
    }

    @ViewBuilder
    private func notificationAppIcon(_ item: CapturedNotification) -> some View {
        if let bundleIdentifier = item.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "bell.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Circle().fill(accent.opacity(0.15)))
        }
    }

    private func relativeTime(_ date: Date) -> String {
        guard Date().timeIntervalSince(date) > 50 else { return localized("şimdi", "now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: settings.language == .turkish ? "tr_TR" : "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    /// Opens the notch straight onto the notifications list.
    private func openNotifications() {
        hoverTask?.cancel()
        isPinned = true
        selectDashboardSection(.notifications)
        setPresentation(.expanded)
    }

    /// Black with the theme colour washed in at the chosen tone. The band
    /// beside the camera housing stays pure black so the real notch blends in.
    private var dashboardSceneBackground: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [
                    accent.opacity(settings.surfaceTone.tintOpacity),
                    accent.opacity(settings.surfaceTone.tintOpacity * 0.35),
                    .black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.12),
                        .init(color: .black, location: 0.38)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.25), value: settings.accentTheme)
        .animation(.easeInOut(duration: 0.25), value: settings.surfaceTone)
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

    /// The tabs beside the camera housing; if the selected tab's name
    /// doesn't fit (many tabs, a badge), they fall back to icons only.
    private var dashboardNavigationLeading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach(visibleDashboardSections, id: \.self) { section in
                    dashboardNavigationItem(section, showsLabel: true)
                }
            }
            HStack(spacing: 4) {
                ForEach(visibleDashboardSections, id: \.self) { section in
                    dashboardNavigationItem(section, showsLabel: false)
                }
            }
        }
    }

    private var visibleDashboardSections: [DashboardSection] {
        DashboardSection.allCases.filter { section in
            switch section {
            case .timer: settings.dashboardFocusTimerEnabled
            case .shelf: settings.dashboardFileShelfEnabled
            case .notifications: settings.dashboardNotificationsEnabled
            case .shortcuts: settings.shortcutsEnabled
            case .home, .calendar, .clipboard: true
            }
        }
    }

    private var dashboardNavigationTrailing: some View {
        HStack(spacing: 8) {
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

    /// The selected section opens into a capsule with its name; the others
    /// stay as icons. One shared capsule slides between them.
    private func dashboardNavigationItem(_ section: DashboardSection, showsLabel: Bool = true) -> some View {
        let isSelected = dashboardSection == section
        let badge = section == .notifications ? notificationMonitor.unreadCount : 0

        return Button {
            selectDashboardSection(section)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: dashboardSectionSymbol(section))
                    .font(.system(size: 11, weight: .semibold))

                if isSelected, showsLabel {
                    Text(dashboardSectionLabel(section))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }

                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(isSelected ? primaryColor : primaryColor.opacity(0.5))
            .padding(.horizontal, isSelected && showsLabel ? 10 : (badge > 0 ? 6 : 0))
            .frame(minWidth: 25, minHeight: 27)
            .background {
                if isSelected {
                    Capsule()
                        .fill(primaryColor.opacity(0.16))
                        .matchedGeometryEffect(id: "selectedSection", in: navigationNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(dashboardSectionLabel(section))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func dashboardSectionSymbol(_ section: DashboardSection) -> String {
        switch section {
        case .home: "house.fill"
        case .calendar: "calendar"
        case .timer: "timer"
        case .shelf: "tray.full.fill"
        case .clipboard: "list.clipboard.fill"
        case .notifications: "bell.fill"
        case .shortcuts: "bolt.fill"
        }
    }

    private func selectDashboardSection(_ section: DashboardSection) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            dashboardSection = section
        }
    }

    /// Rows spread over the card's full height, so nothing pools at the top.
    /// Displays without a notch get a shorter dashboard, so a compact
    /// version takes over when the full one doesn't fit.
    private var dashboardMediaPane: some View {
        ViewThatFits(in: .vertical) {
            mediaPane(compact: false)
            mediaPane(compact: true)
        }
    }

    private func mediaPane(compact: Bool) -> some View {
        let artworkSize: CGFloat = compact ? 52 : 68
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: compact ? 12 : 14) {
                sourceArtwork(size: artworkSize, cornerRadius: compact ? 12 : 15)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                    playbackStatusLabel

                    Text(trackTitle)
                        .font(.system(size: compact ? 15 : 17, weight: .semibold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)

                    Text(artistTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(primaryColor.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack {
                    HStack(spacing: 6) {
                        if settings.lyricsEnabled { lyricsToggle }
                        sourceBadge
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: artworkSize)

            Spacer(minLength: 4)

            if settings.lyricsEnabled && showsLyrics {
                lyricsSection
            } else {
                progressSection
            }

            Spacer(minLength: 4)

            if showsOutputPicker {
                outputPicker
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                HStack(spacing: 8) {
                    playbackControls(compact: compact)
                    Spacer(minLength: 4)
                    outputButton
                    volumeSection
                        .frame(width: 122)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Shows the current output's icon; opens the device chips.
    private var outputButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { showsOutputPicker = true }
        } label: {
            Image(systemName: audioDevices.currentOutput?.symbolName ?? "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(Circle().fill(primaryColor.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(localized("Ses çıkışı: ", "Output: ") + (audioDevices.currentOutput?.name ?? "—"))
        .accessibilityLabel(Text(localized("Ses çıkışını değiştir", "Change audio output")))
    }

    /// Every output as a chip; one click switches and closes the row.
    private var outputPicker: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(audioDevices.outputs) { device in
                        let isCurrent = device.id == audioDevices.currentOutputID
                        Button {
                            audioDevices.select(device)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { showsOutputPicker = false }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: device.symbolName)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(device.name)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .lineLimit(1)
                                    .frame(maxWidth: 130)
                                if isCurrent {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8.5, weight: .bold))
                                }
                            }
                            .foregroundStyle(isCurrent ? accent : primaryColor.opacity(0.82))
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(Capsule().fill(isCurrent ? accent.opacity(0.16) : primaryColor.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(isCurrent ? accent.opacity(0.55) : Color.clear, lineWidth: 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            roundIconButton("xmark", label: localized("Kapat", "Close"), size: 28) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { showsOutputPicker = false }
            }
        }
        .frame(height: 34)
    }

    private var lyricsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showsLyrics.toggle() }
            if showsLyrics { loadLyrics() }
        } label: {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(showsLyrics ? Color.white : primaryColor.opacity(0.72))
                .frame(width: 30, height: 22)
                .background(Capsule().fill(showsLyrics ? accent : primaryColor.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(showsLyrics ? localized("İlerleme çubuğunu göster", "Show progress") : localized("Şarkı sözlerini göster", "Show lyrics"))
        .accessibilityLabel(Text(localized("Şarkı sözleri", "Lyrics")))
    }

    /// The line being sung, big, and the next one, dim; it slides up as the
    /// song moves on.
    private var lyricsSection: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: !mediaManager.isPlaying)) { context in
            let content = lyricsContent(at: mediaManager.estimatedPosition(at: context.date))
            VStack(alignment: .leading, spacing: 3) {
                Text(content.current)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .id("current-\(content.index)")
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                Text(content.next)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(primaryColor.opacity(0.42))
                    .lineLimit(1)
                    .id("next-\(content.index)")
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34, alignment: .leading)
            .clipped()
            .animation(.easeOut(duration: 0.28), value: content.index)
        }
        .onAppear(perform: loadLyrics)
        .accessibilityElement(children: .combine)
    }

    private func lyricsContent(at time: TimeInterval) -> (index: Int, current: String, next: String) {
        switch lyricsManager.state {
        case .synced(let lines):
            // A hair early, so the line appears as it's sung.
            if let index = LyricsManager.lineIndex(in: lines, at: time + 0.15) {
                return (index, lines[index].text, index + 1 < lines.count ? lines[index + 1].text : "")
            }
            return (-1, "♪", lines.first?.text ?? "")
        case .loading:
            return (-2, localized("Sözler yükleniyor…", "Loading lyrics…"), "")
        case .instrumental:
            return (-3, localized("♪ Enstrümantal", "♪ Instrumental"), "")
        case .unsynced:
            return (-4, localized("Bu şarkının zamanlı sözü yok", "No synced lyrics for this song"), "LRCLIB")
        case .notFound:
            return (-5, localized("Söz bulunamadı", "No lyrics found"), "LRCLIB")
        case .idle:
            return (-6, mediaManager.hasActiveTrack ? "♪" : localized("Çalan şarkı yok", "Nothing playing"), "")
        }
    }

    private func loadLyrics() {
        guard settings.lyricsEnabled, mediaManager.hasActiveTrack else { return }
        lyricsManager.load(
            title: mediaManager.trackName,
            artist: mediaManager.artistName,
            album: mediaManager.albumName,
            duration: mediaManager.duration
        )
    }

    @ViewBuilder
    private var playbackStatusLabel: some View {
        if mediaManager.hasActiveTrack {
            HStack(spacing: 5) {
                if mediaManager.isPlaying {
                    PlaybackWaveform(isPlaying: true)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 10)
                } else {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 7, weight: .bold))
                }

                Text(
                    mediaManager.isPlaying
                        ? localized("ŞİMDİ ÇALIYOR", "NOW PLAYING")
                        : localized("DURAKLATILDI", "PAUSED")
                )
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.1)
            }
            .foregroundStyle(mediaManager.isPlaying ? accent : primaryColor.opacity(0.45))
            .accessibilityElement(children: .combine)
        }
    }

    /// A soft wash of the album art behind the media card.
    @ViewBuilder
    private var mediaArtworkGlow: some View {
        if let image = mediaManager.artwork {
            // Color.clear takes exactly the card's size; the filled artwork
            // overflows it and is clipped back to the card.
            Color.clear
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 36)
                        .saturation(1.35)
                        .opacity(0.4)
                }
                .clipShape(dashboardCardShape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
                    .foregroundStyle(accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(accent.opacity(0.12)))

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
            if case .notification(let item) = displayedEcho {
                notificationHUD(item)
            } else if case .timerFinished = displayedEcho {
                systemEchoHUD
                    .contentShape(Rectangle())
                    .onTapGesture { openDashboard(at: .timer) }
            } else if case .upcomingEvent(let event) = displayedEcho {
                eventHUD(event)
            } else if case .headphones(let battery) = displayedEcho {
                headphoneHUD(battery)
            } else if case .screenshotPreview(let capture) = displayedEcho {
                screenshotHUD(capture)
            } else if case .downloadFinished(let download) = displayedEcho {
                downloadHUD(download)
            } else {
                systemEchoHUD
            }
        }
    }

    /// A meeting is about to start: its title and time on the left, Join
    /// (for video calls) on the right. Clicking anywhere joins or opens it.
    private func eventHUD(_ event: CalendarEventInfo) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                RingingSymbol(symbol: "calendar", tint: Color(nsColor: event.color))
                    .id(displayedEchoRevision)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(eventTimeText(event, now: Date()))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity, alignment: .leading)

            if layout.hasCameraHousing {
                Color.clear
                    .frame(width: layout.cameraHousingWidth)
                    .accessibilityHidden(true)
            }

            HStack {
                Spacer(minLength: 0)
                if event.joinURL != nil {
                    Text(localized("Katıl", "Join"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.green))
                } else {
                    Text(dashboardTime(event.start))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: layout.hasCameraHousing ? layout.notchBandHeight : 40)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            commandEchoTask?.cancel()
            isCommandEchoVisible = false
            resizeSurface(to: preferredSize, animation: presentationAnimation)
            calendarManager.join(event)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// A new screenshot under the notch: drag the thumbnail anywhere, or
    /// copy, shelve, reveal or bin it.
    private func screenshotHUD(_ capture: ScreenshotCapture) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                    Text(localized("Ekran görüntüsü", "Screenshot"))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity, alignment: .leading)
                if layout.hasCameraHousing {
                    Color.clear.frame(width: layout.cameraHousingWidth).accessibilityHidden(true)
                }
                Text(localized("Sürükleyip bırakabilirsin", "Drag it anywhere"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .frame(maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(height: layout.hasCameraHousing ? layout.notchBandHeight : 34)

            HStack(alignment: .center, spacing: 12) {
                Group {
                    if let thumbnail = capture.thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "photo").foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .frame(width: 124, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(contentsOf: capture.url) ?? NSItemProvider() }
                .onTapGesture {
                    NSWorkspace.shared.open(capture.url)
                    dismissEcho()
                }
                .help(localized("Aç ya da sürükleyip bırak", "Open, or drag and drop"))

                VStack(alignment: .leading, spacing: 9) {
                    Text(capture.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        echoAction("doc.on.doc", localized("Kopyala", "Copy"), id: "copy") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            var objects: [NSPasteboardWriting] = [capture.url as NSURL]
                            if let image = NSImage(contentsOf: capture.url) { objects.insert(image, at: 0) }
                            pasteboard.writeObjects(objects)
                        }
                        echoAction("tray.and.arrow.down", localized("Rafa ekle", "Shelf"), id: "shelf") {
                            fileShelfManager.add(capture.url)
                        }
                        echoAction("folder", localized("Göster", "Show"), id: "show", closes: true) {
                            NSWorkspace.shared.activateFileViewerSelecting([capture.url])
                        }
                        echoAction("trash", localized("Sil", "Delete"), id: "trash", closes: true, destructive: true) {
                            NSWorkspace.shared.recycle([capture.url])
                        }
                    }
                }
            }
            .padding(.horizontal, bodyPadding(18, gap: 16))
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover(perform: echoHoverChanged)
    }

    /// A finished download: open it or show it in Finder.
    private func downloadHUD(_ download: FinishedDownload) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: download.isAirDrop ? "dot.radiowaves.left.and.right" : "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .id(displayedEchoRevision)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                VStack(alignment: .leading, spacing: 0) {
                    Text(commandEchoTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(download.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity, alignment: .leading)

            if layout.hasCameraHousing {
                Color.clear.frame(width: layout.cameraHousingWidth).accessibilityHidden(true)
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button {
                    downloadMonitor.open(download)
                    dismissEcho()
                } label: {
                    Text(localized("Aç", "Open"))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    downloadMonitor.reveal(download)
                    dismissEcho()
                } label: {
                    Text(localized("Göster", "Show"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: layout.hasCameraHousing ? layout.notchBandHeight : 40)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover(perform: echoHoverChanged)
    }

    /// A small HUD button; shows a checkmark for a moment after it runs.
    private func echoAction(
        _ symbol: String,
        _ title: String,
        id: String,
        closes: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            if closes {
                dismissEcho()
            } else {
                withAnimation(.easeOut(duration: 0.15)) { echoActionDone = id }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: echoActionDone == id ? "checkmark" : symbol)
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(destructive ? Color(red: 1, green: 0.45, blue: 0.42) : .white)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(echoActionDone == id ? 0.2 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// Headphones just became the output: their name on the left, battery
    /// levels (left, right and case for AirPods) on the right.
    private func headphoneHUD(_ battery: HeadphoneBattery) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: battery.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .id(displayedEchoRevision)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                Text(battery.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity, alignment: .leading)

            if layout.hasCameraHousing {
                Color.clear
                    .frame(width: layout.cameraHousingWidth)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if battery.hasLevels {
                    if let left = battery.left { headphoneLevel(localized("Sol", "L"), left) }
                    if let right = battery.right { headphoneLevel(localized("Sağ", "R"), right) }
                    if let caseLevel = battery.caseLevel { headphoneLevel(localized("Kutu", "Case"), caseLevel) }
                    if let main = battery.main, battery.left == nil, battery.right == nil {
                        headphoneLevel(nil, main)
                    }
                } else {
                    Text(localized("Bağlandı", "Connected"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: layout.hasCameraHousing ? layout.notchBandHeight : 40)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    private func headphoneLevel(_ label: String?, _ level: Int) -> some View {
        HStack(spacing: 3) {
            if let label {
                Text(label)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(percentText(level))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(level <= 20 ? Color.red : Color.white)
        }
    }

    private func privacyKindText(_ usage: PrivacyUsage) -> String {
        usage.camera ? localized("Kamera", "Camera") : localized("Mikrofon", "Microphone")
    }

    private func privacyDetailText(_ usage: PrivacyUsage) -> String {
        switch (usage.camera, usage.microphone) {
        case (true, true): localized("Kamera ve mikrofon açık", "Camera and microphone on")
        case (true, false): localized("Kamera açık", "Camera on")
        default: localized("Mikrofon açık", "Microphone on")
        }
    }

    private func percentText(_ value: Int) -> String {
        settings.language == .turkish ? "%\(value)" : "\(value)%"
    }

    private func openDashboard(at section: DashboardSection) {
        commandEchoTask?.cancel()
        isCommandEchoVisible = false
        dashboardSection = section
        isPinned = true
        setPresentation(.expanded)
    }

    /// The notch widens to show a new notification. Clicking it opens the
    /// notifications list.
    private func notificationHUD(_ item: CapturedNotification) -> some View {
        let showsContent = settings.notificationPreviewStyle == .content
        let unread = max(notificationMonitor.unreadCount, 1)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    if showsContent {
                        notificationAppIcon(item)
                            .frame(width: 16, height: 16)
                        Text(item.appName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    } else {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(accent)
                        Text(
                            localized(
                                "\(unread) yeni bildirim",
                                unread == 1 ? "1 new notification" : "\(unread) new notifications"
                            )
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    }
                }
                .frame(
                    maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity,
                    alignment: .leading
                )

                if layout.hasCameraHousing {
                    Color.clear
                        .frame(width: layout.cameraHousingWidth)
                        .accessibilityHidden(true)
                }

                Text(showsContent ? localized("şimdi", "now") : "")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(
                        maxWidth: layout.hasCameraHousing ? commandEchoWingWidth : .infinity,
                        alignment: .trailing
                    )
            }
            .padding(.horizontal, 18)
            .frame(height: layout.hasCameraHousing ? layout.notchBandHeight : 34)

            if showsContent {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.headline)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, bodyPadding(18, gap: 16))
                .padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: openNotifications)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(localized("Bildirimleri açar", "Opens notifications")))
    }

    private var systemEchoHUD: some View {
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
        .accessibilityLabel(Text([commandEchoTitle, commandEchoDetail].filter { !$0.isEmpty }.joined(separator: ", ")))
    }

    /// A dashed drop zone under the camera housing with one target for the
    /// shelf and one for AirDrop.
    private var fileDropHUD: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                localized("Dosyaları buraya bırak", "Drop your files here"),
                systemImage: "tray.and.arrow.down.fill"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.62))
            .padding(.leading, 1)

            HStack(spacing: 9) {
                fileDropTile(
                    .shelf,
                    symbol: "tray.and.arrow.down.fill",
                    title: localized("Raf", "Shelf"),
                    isTargeted: $isShelfTileTargeted
                )
                fileDropTile(
                    .airDrop,
                    symbol: "dot.radiowaves.right",
                    title: "AirDrop",
                    isTargeted: $isAirDropTileTargeted
                )
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        }
        .padding(.horizontal, bodyPadding(9, gap: 3))
        .padding(.top, layout.hasCameraHousing ? layout.notchBandHeight : 9)
        .padding(.bottom, 9)
    }

    private func fileDropTile(
        _ target: FileDropTarget,
        symbol: String,
        title: String,
        isTargeted: Binding<Bool>
    ) -> some View {
        // Hovering the zone outside both tiles drops onto the shelf, so the
        // shelf lights up for it as well.
        let isHighlighted = isTargeted.wrappedValue ||
            (target == .shelf && isFileDropTargeted)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(isHighlighted ? 1 : 0.82))
        .frame(maxWidth: .infinity)
        .frame(height: 47)
        .background(shape.fill(Color.white.opacity(isHighlighted ? 0.17 : 0.07)))
        .overlay {
            shape.strokeBorder(
                Color.white.opacity(isHighlighted ? 0.55 : 0.18),
                style: StrokeStyle(lineWidth: 1, dash: isHighlighted ? [] : [4, 4])
            )
        }
        .scaleEffect(isHighlighted ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: isHighlighted)
        .contentShape(shape)
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: isTargeted
        ) { providers in
            handleFileDrop(providers, to: target)
        }
    }

    private var commandEchoLeading: some View {
        HStack(spacing: 9) {
            if case .timerFinished = displayedEcho {
                RingingSymbol(symbol: displayedEcho.symbolName, tint: accent)
                    .id(displayedEchoRevision)
            } else if case .privacy(let usage) = displayedEcho {
                PrivacyDots(usage: usage, size: 9)
            } else if case .power(let event) = displayedEcho {
                switch event {
                case .pluggedIn(let level, let charging):
                    BatteryGlyph(level: level, isCharging: charging).id(displayedEchoRevision)
                case .unplugged(let level), .low(let level):
                    BatteryGlyph(level: level, isCharging: false).id(displayedEchoRevision)
                }
            } else {
                Image(systemName: displayedEcho.symbolName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .id(displayedEchoRevision)
                    .transition(.opacity.combined(with: .scale(scale: 0.72)))
            }

            if commandEchoValue == nil || isPowerEcho {
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

    private var isPowerEcho: Bool {
        if case .power = displayedEcho { return true }
        return false
    }

    private var commandEchoValue: Double? {
        switch displayedEcho {
        case .volume(let value), .brightness(let value): value
        case .power(let event):
            switch event {
            case .pluggedIn(let level, _), .unplugged(let level), .low(let level): Double(level) / 100
            }
        case .copied, .pasted, .screenshot, .capsLock, .mediaSkip, .trackChanged, .notification,
             .timerFinished, .upcomingEvent, .headphones, .privacy, .screenshotPreview, .downloadFinished: nil
        }
    }

    private var commandEchoTitle: String {
        switch displayedEcho {
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
        case .notification(let item): item.appName
        case .upcomingEvent(let event): event.title
        case .headphones(let battery): battery.name
        case .privacy(let usage): usage.appName ?? privacyKindText(usage)
        case .screenshotPreview: localized("Ekran görüntüsü", "Screenshot")
        case .downloadFinished(let download): download.isAirDrop ? localized("AirDrop ile alındı", "Received via AirDrop") : localized("İndirildi", "Downloaded")
        case .power(let event):
            switch event {
            case .pluggedIn(_, let charging): charging ? localized("Şarj oluyor", "Charging") : localized("Güç bağlandı", "Power connected")
            case .unplugged: localized("Pil gücünde", "On battery")
            case .low: localized("Pil zayıf", "Battery low")
            }
        case .timerFinished(let finish):
            switch finish {
            case .timer: localized("Süre doldu", "Time's up")
            case .focusDone: localized("Mola zamanı", "Time for a break")
            case .breakDone: localized("Odak zamanı", "Back to focus")
            }
        }
    }

    private var commandEchoDetail: String {
        switch displayedEcho {
        case .screenshot(let filename): filename
        case .copied: localized("Panoya eklendi", "Added to clipboard")
        case .pasted: localized("Panodan yapıştırıldı", "Pasted from clipboard")
        case .capsLock(let enabled): enabled ? localized("Açık", "On") : localized("Kapalı", "Off")
        case .mediaSkip: localized("Parça değiştiriliyor", "Changing track")
        case .trackChanged: artistTitle
        case .notification(let item): item.headline
        case .upcomingEvent(let event): eventTimeText(event, now: Date())
        case .headphones: localized("Bağlandı", "Connected")
        case .privacy(let usage): privacyDetailText(usage)
        case .screenshotPreview(let capture): capture.name
        case .downloadFinished(let download): download.name
        case .power: ""
        case .timerFinished(let finish):
            switch finish {
            case .timer: localized("Zamanlayıcı bitti", "Timer finished")
            case .focusDone: localized("\(focusTimerManager.breakMinutes) dk mola", "\(focusTimerManager.breakMinutes) min break")
            case .breakDone: localized("\(focusTimerManager.focusMinutes) dk odak", "\(focusTimerManager.focusMinutes) min focus")
            }
        case .volume, .brightness: ""
        }
    }

    private var commandEchoWingWidth: CGFloat {
        max((commandEchoPreferredSize.width - layout.cameraHousingWidth) / 2 - 18, 56)
    }

    private func showCommandEchoIfNeeded() {
        // The open dashboard already shows volume and playback; swapping it
        // for a HUD would yank it away mid-interaction.
        let incoming = commandEchoManager.event
        let isAllowed: Bool
        switch incoming {
        case .notification: isAllowed = settings.dashboardNotificationsEnabled
        // The user set this countdown; always say when it ends.
        case .timerFinished: isAllowed = true
        case .upcomingEvent: isAllowed = settings.calendarEnabled && settings.calendarAlertsEnabled
        case .power, .headphones: isAllowed = settings.devicesHUDEnabled
        case .privacy: isAllowed = settings.privacyIndicatorEnabled
        case .screenshotPreview: isAllowed = settings.screenshotPreviewEnabled
        case .downloadFinished: isAllowed = settings.downloadsEnabled
        // The preview replaces the plain "Screenshot captured" echo.
        case .screenshot: isAllowed = settings.dashboardCommandEchoEnabled && !settings.screenshotPreviewEnabled
        default: isAllowed = settings.dashboardCommandEchoEnabled
        }
        guard isAllowed, presentation == .idle else { return }
        // Volume, copy and the like never cover a notification, a meeting,
        // a finished timer or a device/privacy alert that is showing.
        if isCommandEchoVisible, displayedEcho.isImportant, !incoming.isImportant { return }
        commandEchoTask?.cancel()
        displayedEcho = incoming
        displayedEchoRevision &+= 1
        echoActionDone = nil
        let echoAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.3, dampingFraction: 0.86)
        withAnimation(echoAnimation) {
            isCommandEchoVisible = true
        }
        resizeSurface(to: preferredSize, animation: echoAnimation)
        let duration: Double
        switch incoming {
        case .notification, .headphones: duration = 4.5
        case .timerFinished: duration = 5
        case .upcomingEvent: duration = 10
        case .power: duration = 3
        case .privacy: duration = 3.5
        case .screenshotPreview: duration = 7
        case .downloadFinished: duration = 6
        case .screenshot: duration = 3.2
        case .trackChanged: duration = 2.2
        default: duration = 1.45
        }
        scheduleEchoHide(after: duration, animation: echoAnimation)
    }

    /// Hides the HUD after `delay`, unless the pointer is on it; leaving it
    /// starts a short countdown again.
    private func scheduleEchoHide(after delay: Double, animation: Animation? = nil) {
        commandEchoTask?.cancel()
        let echoAnimation: Animation = animation ?? (reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.3, dampingFraction: 0.86))
        commandEchoTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !isEchoHovered else { return }
                withAnimation(echoAnimation) {
                    isCommandEchoVisible = false
                }
                resizeSurface(to: preferredSize, animation: echoAnimation)
            }
        }
    }

    private func echoHoverChanged(_ hovering: Bool) {
        isEchoHovered = hovering
        if hovering {
            commandEchoTask?.cancel()
        } else if isCommandEchoVisible {
            scheduleEchoHide(after: 1.6)
        }
    }

    private func dismissEcho() {
        isEchoHovered = false
        scheduleEchoHide(after: 0)
    }

    /// HUDs with buttons; hovering them must not open the dashboard.
    private var isInteractiveEchoVisible: Bool {
        guard isCommandEchoVisible else { return false }
        switch displayedEcho {
        case .screenshotPreview, .downloadFinished, .upcomingEvent: return true
        default: return false
        }
    }

    private func dashboardSectionLabel(_ section: DashboardSection) -> String {
        switch section {
        case .home: localized("Ana", "Home")
        case .calendar: localized("Takvim", "Calendar")
        case .timer: localized("Zamanlayıcı", "Timer")
        case .shelf: localized("Dosya Rafı", "File Shelf")
        case .clipboard: localized("Pano", "Clipboard")
        case .notifications: localized("Bildirimler", "Notifications")
        case .shortcuts: localized("Kısayollar", "Shortcuts")
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

    private var sourceBadge: some View {
        Button(action: mediaManager.openSourceApplication) {
            HStack(spacing: 4) {
                Image(systemName: sourceSymbolName)
                    .font(.system(size: 9, weight: .bold))
                Text(sourceShortName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(primaryColor.opacity(0.72))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(primaryColor.opacity(0.09)))
            .contentShape(Capsule())
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

    private func playbackControls(compact: Bool) -> some View {
        let height: CGFloat = compact ? 30 : 34
        return HStack(spacing: 4) {
            compactPlaybackModeButton(
                height: height,
                icon: "shuffle",
                label: mediaManager.isShuffleEnabled
                    ? localized("Karışık çalmayı kapat", "Turn shuffle off")
                    : localized("Karışık çal", "Shuffle"),
                isActive: mediaManager.isShuffleEnabled,
                action: mediaManager.toggleShuffle
            )

            compactMediaControlButton(
                height: height,
                icon: "backward.fill",
                label: localized("Önceki parça", "Previous track"),
                action: { skipTrack(.previous) }
            )

            Button(action: mediaManager.togglePlayPause) {
                Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(panelColor)
                    .frame(width: height, height: height)
                    .background(Circle().fill(primaryColor))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!mediaManager.hasActiveTrack)
            .opacity(mediaManager.hasActiveTrack ? 1 : 0.45)

            compactMediaControlButton(
                height: height,
                icon: "forward.fill",
                label: localized("Sonraki parça", "Next track"),
                action: { skipTrack(.next) }
            )

            compactPlaybackModeButton(
                height: height,
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
        VStack(spacing: 3) {
            NotchSlider(
                value: normalizedProgress,
                fill: primaryColor.opacity(0.92),
                track: primaryColor.opacity(0.14),
                onChange: { fraction in
                    scrubValue = fraction * max(mediaManager.duration, 0)
                },
                onEditingChanged: { editing in
                    isScrubbing = editing
                    updateInteraction(editing)

                    if !editing, mediaManager.duration > 0 {
                        mediaManager.seek(to: scrubValue)
                    }
                }
            )
            .disabled(mediaManager.duration <= 0)
            .accessibilityLabel(Text(localized("Şarkının ilerleyişi", "Playback progress")))

            HStack {
                Text(formatTime(isScrubbing ? scrubValue : playbackTime))
                Spacer()
                Text(remainingTimeText)
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(primaryColor.opacity(0.5))
        }
    }

    private var volumeSection: some View {
        let volume = min(max(mediaManager.volume, 0), 1)

        return HStack(spacing: 7) {
            Image(systemName: volumeSymbol(for: volume))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(0.6))
                .frame(width: 18, alignment: .leading)
                .accessibilityHidden(true)

            NotchSlider(
                value: volume,
                fill: primaryColor.opacity(0.85),
                track: primaryColor.opacity(0.14),
                onChange: mediaManager.setVolume,
                onEditingChanged: updateInteraction
            )
            .accessibilityLabel(Text(localized("Ses düzeyi", "System volume")))
        }
    }

    private func volumeSymbol(for volume: Double) -> String {
        switch volume {
        case ..<0.001: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
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
        height: CGFloat = 34,
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryColor.opacity(0.88))
                .frame(width: 30, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!mediaManager.hasActiveTrack)
        .opacity(mediaManager.hasActiveTrack ? 1 : 0.45)
        .accessibilityLabel(Text(label))
        .help(label)
    }

    private func compactPlaybackModeButton(
        height: CGFloat = 34,
        icon: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    isActive ? accent : primaryColor.opacity(0.62)
                )
                .frame(width: 28, height: height)
                .contentShape(Rectangle())
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
                  !isInteracting,
                  !isInteractiveEchoVisible else {
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
            showsOutputPicker = false
            if let pending = pendingEventAlert {
                pendingEventAlert = nil
                if pending.start > Date() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        commandEchoManager.showUpcomingEvent(pending)
                    }
                }
            }
        } else {
            // Opening replaces a system-change HUD instead of stretching it.
            commandEchoTask?.cancel()
            if isCommandEchoVisible,
               settings.dashboardNotificationsEnabled,
               case .notification = displayedEcho {
                dashboardSection = .notifications
            }
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
        let margin = showsHalo ? Self.haloMargin : 0
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
            let settledMargin = showsHalo ? Self.haloMargin : 0
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
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            setIdleWings(false)
        }
    }

    /// Re-fits the closed notch after what its wings show has changed.
    private func refreshIdleSurface() {
        guard presentation == .idle,
              !isCommandEchoVisible,
              !isFileDropHUDVisible else { return }
        let wingsAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.3, dampingFraction: 0.82)
        resizeSurface(to: preferredSize, animation: wingsAnimation)
    }

    private func setIdleWings(_ visible: Bool) {
        guard visible != showsIdleWings else { return }
        // A quicker spring than opening the dashboard: the wings are a small
        // change and should follow playback immediately.
        let wingsAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.3, dampingFraction: 0.82)
        withAnimation(wingsAnimation) {
            showsIdleWings = visible
        }
        guard presentation == .idle,
              !isCommandEchoVisible,
              !isFileDropHUDVisible else { return }
        resizeSurface(to: preferredSize, animation: wingsAnimation)
    }

    // MARK: - Derived Values

    private var preferredSize: CGSize {
        if isFileDropHUDVisible { return fileDropPreferredSize }
        if isCommandEchoVisible { return commandEchoPreferredSize }
        return basePreferredSize
    }

    private var basePreferredSize: CGSize {
        layout.size(for: presentation, idleMode: effectiveIdleMode)
    }

    /// Visible Island means "visible while music plays"; otherwise the notch
    /// rests at the size of the camera housing.
    /// Music respects Hidden Mini; a running timer and the camera/mic
    /// indicator are things the user asked to see, so they show anyway.
    private var effectiveIdleMode: NotchIdleMode {
        switch idleActivity {
        case .none: .hiddenMini
        case .timer, .download, .privacy: .visibleIsland
        case .music: settings.notchIdleMode == .hiddenMini ? .hiddenMini : .visibleIsland
        }
    }

    private var commandEchoPreferredSize: CGSize {
        // A notification with its content gets a second row under the
        // camera housing for the title and message.
        if case .notification = displayedEcho,
           settings.notificationPreviewStyle == .content {
            let width = layout.hasCameraHousing
                ? min(max(layout.cameraHousingWidth + 340, 520), layout.screenWidth - 24)
                : min(440, layout.screenWidth - 24)
            let height = layout.hasCameraHousing ? layout.notchBandHeight + 46 : 76
            return CGSize(width: width, height: height)
        }
        if case .screenshotPreview = displayedEcho {
            let width = layout.hasCameraHousing
                ? min(max(layout.cameraHousingWidth + 350, 530), layout.screenWidth - 24)
                : min(460, layout.screenWidth - 24)
            let height = layout.hasCameraHousing ? layout.notchBandHeight + 104 : 132
            return CGSize(width: width, height: height)
        }
        let extensionWidth: CGFloat
        switch displayedEcho {
        case .trackChanged: extensionWidth = 380
        case .timerFinished: extensionWidth = 330
        case .upcomingEvent: extensionWidth = 400
        case .headphones: extensionWidth = 430
        case .power: extensionWidth = 330
        case .privacy: extensionWidth = 360
        case .downloadFinished: extensionWidth = 420
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

    /// Compact, like the reference: a zone just wide enough for two tiles,
    /// hanging under the camera housing.
    private var fileDropPreferredSize: CGSize {
        let width = layout.hasCameraHousing
            ? min(max(layout.cameraHousingWidth + 122, 300), layout.screenWidth - 24)
            : min(300, layout.screenWidth - 24)
        let height = layout.hasCameraHousing
            ? layout.notchBandHeight + 106
            : 114
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

    private var notchBackground: some View {
        notchShape.fill(panelColor.opacity(panelOpacity))
    }

    /// The dashboard is always a dark surface, like the notch it grows from.
    private var primaryColor: Color { .white }

    private var accent: Color { settings.accentTheme.color }

    private var panelColor: Color { .black }

    private var panelOpacity: Double {
        if reduceTransparency || layout.hasCameraHousing {
            return 1
        }
        return 0.96
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
        if idleActivity == .timer {
            return localized("Zamanlayıcı, kalan \(focusTimerManager.formattedTime)", "Timer, \(focusTimerManager.formattedTime) left")
        }
        if idleActivity == .download {
            let percent = Int((downloadMonitor.overallFraction * 100).rounded())
            return localized("İndiriliyor, yüzde \(percent)", "Downloading, \(percent) percent")
        }
        if idleActivity == .privacy {
            let usage = privacyMonitor.usage
            return [usage.appName, privacyDetailText(usage)].compactMap { $0 }.joined(separator: ", ")
        }
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

/// A thin capsule slider that matches the notch better than the system
/// slider's large white knob; it thickens under the pointer.
private struct NotchSlider: View {
    var value: Double
    var fill: Color
    var track: Color
    var onChange: (Double) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = min(max(value, 0), 1)
            let isActive = isEnabled && (isHovered || isDragging)

            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: max(width * fraction, isActive ? 6 : 4))
            }
            .frame(height: isActive ? 6 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        onChange(min(max(gesture.location.x / width, 0), 1))
                    }
                    .onEnded { gesture in
                        onChange(min(max(gesture.location.x / width, 0), 1))
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
            .onHover { hovering in isHovered = hovering }
            .animation(.easeOut(duration: 0.15), value: isActive)
        }
        .frame(height: 14)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((min(max(value, 0), 1) * 100).rounded())) %"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            onEditingChanged(true)
            onChange(min(max(value + step, 0), 1))
            onEditingChanged(false)
        }
    }
}

/// A battery outline that fills to its level when it appears; charging
/// fills it green with a pulsing bolt.
private struct BatteryGlyph: View {
    let level: Int
    let isCharging: Bool
    @State private var shownLevel: Double = 0
    @State private var pulse = false

    var body: some View {
        let fill: Color = isCharging ? .green : (level <= 20 ? .red : .white)
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .fill(fill)
                    .frame(width: max(2, 22 * shownLevel))
                    .padding(2.2)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .scaleEffect(pulse ? 1.18 : 0.88)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 27, height: 13)
            Capsule()
                .fill(Color.white.opacity(0.55))
                .frame(width: 2, height: 5)
        }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1)) {
                shownLevel = Double(level) / 100
            }
            if isCharging {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Green for the camera, orange for the microphone, as macOS uses them.
private struct PrivacyDots: View {
    let usage: PrivacyUsage
    var size: CGFloat = 7

    var body: some View {
        HStack(spacing: size * 0.45) {
            if usage.camera { dot(.green) }
            if usage.microphone { dot(.orange) }
        }
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.8), radius: size * 0.4)
    }
}

/// An icon that rings a few times when it appears, like an alarm.
private struct RingingSymbol: View {
    let symbol: String
    let tint: Color
    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(angle), anchor: .top)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.09).repeatCount(9, autoreverses: true)) {
                    angle = 16
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { angle = 0 }
                }
            }
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
