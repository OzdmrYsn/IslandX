import AppKit
import Combine
import CoreAudio
import IOKit.graphics
import UniformTypeIdentifiers

enum CommandEchoKind: Equatable {
    case volume(Double)
    case brightness(Double)
    case copied
    case screenshot(String)
    case capsLock(Bool)

    var symbolName: String {
        switch self {
        case .volume(let value):
            value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness: "sun.max.fill"
        case .copied: "doc.on.doc.fill"
        case .screenshot: "camera.viewfinder"
        case .capsLock: "capslock.fill"
        }
    }
}

@MainActor
final class CommandEchoManager: ObservableObject {
    @Published private(set) var event: CommandEchoKind = .copied
    @Published private(set) var revision = 0

    private var timer: Timer?
    private var lastBrightness: Double?
    private var lastVolume: Double?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var lastCapsLockState = NSEvent.modifierFlags.contains(.capsLock)
    private var screenshotObservers: [NSObjectProtocol] = []

    func startMonitoring() {
        guard timer == nil else { return }
        lastBrightness = Self.readBrightness()
        lastVolume = Self.readSystemVolume()
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        lastCapsLockState = NSEvent.modifierFlags.contains(.capsLock)
        startScreenshotMonitoring()

        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.pollSystemState() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        let center = DistributedNotificationCenter.default()
        screenshotObservers.forEach(center.removeObserver)
        screenshotObservers.removeAll()
    }

    func showVolume(_ value: Double) {
        let normalized = value > 1 ? value / 100 : value
        publish(.volume(min(max(normalized, 0), 1)))
    }

    private func pollSystemState() {
        if let volume = Self.readSystemVolume() {
            if let previous = lastVolume, abs(volume - previous) >= 0.005 {
                publish(.volume(volume))
            }
            lastVolume = volume
        }

        let pasteboardCount = NSPasteboard.general.changeCount
        if pasteboardCount != lastPasteboardChangeCount {
            lastPasteboardChangeCount = pasteboardCount
            publish(.copied)
        }

        let capsLockState = NSEvent.modifierFlags.contains(.capsLock)
        if capsLockState != lastCapsLockState {
            lastCapsLockState = capsLockState
            publish(.capsLock(capsLockState))
        }

        if let brightness = Self.readBrightness() {
            if let previous = lastBrightness,
               abs(brightness - previous) >= 0.015 {
                publish(.brightness(brightness))
            }
            lastBrightness = brightness
        }

    }

    private func startScreenshotMonitoring() {
        guard screenshotObservers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        let names = [
            "com.apple.screencaptureui.completed",
            "com.apple.screencapture.completed"
        ]
        screenshotObservers = names.map { rawName in
            center.addObserver(
                forName: Notification.Name(rawName),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let filename = (notification.userInfo?["filename"] as? String)
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "PNG"
                Task { @MainActor in self?.publish(.screenshot(filename)) }
            }
        }
    }

    private func publish(_ event: CommandEchoKind) {
        self.event = event
        revision &+= 1
    }

    private static func readBrightness() -> Double? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect")
        )
        if service != 0 {
            defer { IOObjectRelease(service) }

            var brightness: Float = 0
            let result = IODisplayGetFloatParameter(
                service,
                0,
                kIODisplayBrightnessKey as CFString,
                &brightness
            )
            if result == kIOReturnSuccess {
                return min(max(Double(brightness), 0), 1)
            }
        }

        // Apple Silicon's internal display exposes its public brightness
        // parameters through AppleARMBacklight instead of IODisplayConnect.
        let backlight = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleARMBacklight")
        )
        guard backlight != 0 else { return nil }
        defer { IOObjectRelease(backlight) }

        guard let parameters = IORegistryEntryCreateCFProperty(
            backlight,
            "IODisplayParameters" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any],
        let brightness = parameters["brightness"] as? [String: Any],
        let value = brightness["value"] as? NSNumber,
        let maximum = brightness["max"] as? NSNumber,
        maximum.doubleValue > 0 else {
            return nil
        }

        return min(max(value.doubleValue / maximum.doubleValue, 0), 1)
    }

    private static func readSystemVolume() -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &deviceSize,
            &device
        ) == noErr, device != 0 else { return nil }

        var values: [Double] = []
        for element in [
            kAudioObjectPropertyElementMain,
            AudioObjectPropertyElement(1),
            AudioObjectPropertyElement(2)
        ] {
            address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = Float32(0)
            var valueSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(
                device,
                &address,
                0,
                nil,
                &valueSize,
                &value
            ) == noErr {
                values.append(Double(value))
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        guard !values.isEmpty else { return nil }
        let average = values.reduce(0, +) / Double(values.count)
        return min(max(average, 0), 1)
    }
}

struct ClipboardEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let source: String
    let capturedAt: Date
}

/// A deliberately in-memory clipboard history. Nothing is written to disk and
/// the list is discarded when islo. quits.
@MainActor
final class ClipboardHistoryManager: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    func startMonitoring() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.captureIfNeeded() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func copy(_ entry: ClipboardEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    func remove(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    func clear() { entries.removeAll() }

    private func captureIfNeeded() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let concealedTypes = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
            NSPasteboard.PasteboardType("com.agilebits.onepassword")
        ]
        let availableTypes = pasteboard.types ?? []
        guard concealedTypes.allSatisfy({ !availableTypes.contains($0) }) else { return }
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              entries.first?.text != text else { return }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Mac"
        entries.insert(ClipboardEntry(text: text, source: source, capturedAt: .now), at: 0)
        entries = Array(entries.prefix(12))
    }
}

enum FocusTimerMode: String, CaseIterable, Identifiable {
    case timer
    case pomodoro

    var id: String { rawValue }
}

@MainActor
final class FocusTimerManager: ObservableObject {
    @Published var mode: FocusTimerMode = .pomodoro {
        didSet { reset() }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isBreak = false
    @Published private(set) var remainingSeconds = 25 * 60
    @Published var timerMinutes = 10 {
        didSet {
            guard mode == .timer, !isRunning else { return }
            remainingSeconds = timerMinutes * 60
        }
    }

    private var timer: Timer?
    private var targetDate: Date?

    var totalSeconds: Int {
        switch mode {
        case .timer: timerMinutes * 60
        case .pomodoro: (isBreak ? 5 : 25) * 60
        }
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1 - Double(remainingSeconds) / Double(totalSeconds)
    }

    var formattedTime: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    func reset() {
        stopTimer()
        isRunning = false
        isBreak = false
        remainingSeconds = mode == .pomodoro ? 25 * 60 : timerMinutes * 60
    }

    func skipPhase() {
        guard mode == .pomodoro else { return }
        stopTimer()
        isRunning = false
        isBreak.toggle()
        remainingSeconds = (isBreak ? 5 : 25) * 60
    }

    private func start() {
        if remainingSeconds <= 0 { reset() }
        isRunning = true
        targetDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func pause() {
        tick()
        stopTimer()
        isRunning = false
    }

    private func tick() {
        guard let targetDate else { return }
        remainingSeconds = max(Int(ceil(targetDate.timeIntervalSinceNow)), 0)
        guard remainingSeconds == 0 else { return }
        stopTimer()
        isRunning = false
        NSSound.beep()
        if mode == .pomodoro {
            isBreak.toggle()
            remainingSeconds = (isBreak ? 5 : 25) * 60
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        targetDate = nil
    }
}

@MainActor
final class KeepAwakeManager: ObservableObject {
    @Published private(set) var isActive = false
    private var activity: NSObjectProtocol?

    func toggle() {
        setActive(!isActive)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated],
                reason: "islo. Keep Awake"
            )
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        isActive = active
    }
}

@MainActor
final class FileShelfManager: ObservableObject {
    @Published private(set) var items: [URL] = []
    private let defaultsKey = "dashboard.fileShelf.items"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        items = paths.map(URL.init(fileURLWithPath:)).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func receive(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        for provider in matching {
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { [weak self] item, _ in
                guard let url = Self.url(from: item) else { return }
                Task { @MainActor in self?.add(url) }
            }
        }
        return !matching.isEmpty
    }

    func add(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        items.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        items.insert(url, at: 0)
        items = Array(items.prefix(8))
        persist()
    }

    func remove(_ url: URL) {
        items.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        persist()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func sendViaAirDrop(_ url: URL) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: defaultsKey)
    }

    nonisolated private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String { return URL(string: string) }
        return nil
    }
}
