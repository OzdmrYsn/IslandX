import AppKit
import ApplicationServices
import Combine
import CoreAudio
import Darwin
import IOKit.graphics
import UniformTypeIdentifiers

enum MediaSkipDirection: Equatable {
    case previous
    case next

    var symbolName: String { self == .previous ? "backward.fill" : "forward.fill" }
}

enum CommandEchoKind: Equatable {
    case volume(Double)
    case brightness(Double)
    case copied
    case pasted
    case screenshot(String)
    case capsLock(Bool)
    case mediaSkip(MediaSkipDirection)
    case trackChanged(String, MediaSkipDirection?)

    var symbolName: String {
        switch self {
        case .volume(let value):
            value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness: "sun.max.fill"
        case .copied: "doc.on.doc.fill"
        case .pasted: "doc.on.clipboard.fill"
        case .screenshot: "camera.viewfinder"
        case .capsLock: "capslock.fill"
        case .mediaSkip(let direction): direction.symbolName
        case .trackChanged(_, let direction): direction?.symbolName ?? "music.note"
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
    private var keyboardMonitor: Any?
    private var mediaKeyMonitor: Any?

    func startMonitoring() {
        guard timer == nil else { return }
        lastBrightness = Self.readBrightness()
        lastVolume = Self.readSystemVolume()
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        lastCapsLockState = NSEvent.modifierFlags.contains(.capsLock)
        startScreenshotMonitoring()
        startInputMonitoring()

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
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let mediaKeyMonitor { NSEvent.removeMonitor(mediaKeyMonitor) }
        keyboardMonitor = nil
        mediaKeyMonitor = nil
    }

    func showVolume(_ value: Double) {
        let normalized = value > 1 ? value / 100 : value
        publish(.volume(min(max(normalized, 0), 1)))
    }

    func showMediaSkip(_ direction: MediaSkipDirection) {
        publish(.mediaSkip(direction))
    }

    func showTrackChanged(_ title: String, direction: MediaSkipDirection?) {
        publish(.trackChanged(title, direction))
    }

    /// For key presses islo. handled itself. Also primes the pollers so the
    /// same change isn't announced a second time.
    func showHandledVolume(_ value: Double) {
        lastVolume = Self.readSystemVolume()
        publish(.volume(min(max(value, 0), 1)))
    }

    func showHandledBrightness(_ value: Double) {
        lastBrightness = Self.readBrightness()
        publish(.brightness(min(max(value, 0), 1)))
    }

    private func startInputMonitoring() {
        guard keyboardMonitor == nil, mediaKeyMonitor == nil else { return }
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return }
            Task { @MainActor in self?.publish(.pasted) }
        }
        mediaKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let data = UInt32(bitPattern: Int32(truncatingIfNeeded: event.data1))
            let keyCode = Int((data & 0xFFFF0000) >> 16)
            let keyFlags = Int(data & 0x0000FFFF)
            guard keyFlags & 0xFF00 == 0x0A00 else { return }
            let direction: MediaSkipDirection?
            switch keyCode {
            case 17: direction = .next
            case 18: direction = .previous
            default: direction = nil
            }
            guard let direction else { return }
            Task { @MainActor in self?.publish(.mediaSkip(direction)) }
        }
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
        SystemAudioOutput.volume()
    }
}

/// The default output device's volume and mute state through CoreAudio.
enum SystemAudioOutput {
    private static let channelElements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain,
        AudioObjectPropertyElement(1),
        AudioObjectPropertyElement(2)
    ]

    static func defaultDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr, device != 0 else { return nil }
        return device
    }

    static func volume() -> Double? {
        guard let device = defaultDevice() else { return nil }
        var values: [Double] = []
        for element in channelElements {
            var address = volumeAddress(element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                values.append(Double(value))
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        guard !values.isEmpty else { return nil }
        return min(max(values.reduce(0, +) / Double(values.count), 0), 1)
    }

    /// Sets the main volume, or each stereo channel when the device has no
    /// main control. Returns false when the device can't be adjusted.
    @discardableResult
    static func setVolume(_ value: Double) -> Bool {
        guard let device = defaultDevice() else { return false }
        var scalar = Float32(min(max(value, 0), 1))
        let settable = channelElements.filter { isSettable(device, volumeAddress($0)) }
        let targets = settable.contains(kAudioObjectPropertyElementMain)
            ? [kAudioObjectPropertyElementMain]
            : settable
        guard !targets.isEmpty else { return false }
        for element in targets {
            var address = volumeAddress(element)
            AudioObjectSetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &scalar
            )
        }
        return true
    }

    static var canSetVolume: Bool {
        guard let device = defaultDevice() else { return false }
        return channelElements.contains { isSettable(device, volumeAddress($0)) }
    }

    static func isMuted() -> Bool? {
        guard let device = defaultDevice() else { return nil }
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
        else { return nil }
        return muted != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultDevice(), isSettable(device, muteAddress) else {
            return false
        }
        var address = muteAddress
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        ) == noErr
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volumeAddress(
        _ element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func isSettable(
        _ device: AudioDeviceID,
        _ address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }
}

/// The built-in display's brightness. macOS has no public API for this on
/// Apple Silicon, so DisplayServices is loaded at runtime; if it's missing,
/// islo. leaves the brightness keys to macOS.
enum BuiltInDisplayBrightness {
    private typealias Getter = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )
    private static let getter: Getter? = symbol("DisplayServicesGetBrightness")
    private static let setter: Setter? = symbol("DisplayServicesSetBrightness")

    private static func symbol<T>(_ name: String) -> T? {
        guard let framework, let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static var displayID: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return nil
        }
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func brightness() -> Double? {
        guard let getter, let display = displayID else { return nil }
        var value: Float = 0
        guard getter(display, &value) == 0 else { return nil }
        return min(max(Double(value), 0), 1)
    }

    @discardableResult
    static func setBrightness(_ value: Double) -> Bool {
        guard let setter, let display = displayID else { return false }
        return setter(display, Float(min(max(value, 0), 1))) == 0
    }
}

private enum HUDKey: Int {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
}

/// Takes over the hardware volume and brightness keys so macOS doesn't draw
/// its own HUD next to islo.'s. Needs Accessibility access. Without it, or
/// for an output or display islo. can't adjust, the keys pass through and
/// macOS handles them as usual.
final class SystemHUDInterceptor {
    private let onVolume: (Double) -> Void
    private let onBrightness: (Double) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var isEnabled = false

    init(
        onVolume: @escaping (Double) -> Void,
        onBrightness: @escaping (Double) -> Void
    ) {
        self.onVolume = onVolume
        self.onBrightness = onBrightness
    }

    deinit {
        stop()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard enabled else {
            stop()
            return
        }
        installTapIfPossible()
        // Accessibility can be granted while islo. runs; keep trying so the
        // takeover starts without a relaunch.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            self?.installTapIfPossible()
        }
    }

    private func installTapIfPossible() {
        guard isEnabled else { return }
        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        guard AXIsProcessTrusted() else { return }

        // NX_SYSDEFINED carries the media and brightness keys.
        let systemDefinedMask = CGEventMask(1) << 14
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefinedMask,
            callback: systemHUDTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func handle(
        _ type: CGEventType,
        _ event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return passThrough
        }

        guard type.rawValue == 14,
              let systemEvent = NSEvent(cgEvent: event),
              systemEvent.subtype.rawValue == 8 else {
            return passThrough
        }

        let data = UInt32(bitPattern: Int32(truncatingIfNeeded: systemEvent.data1))
        guard let key = HUDKey(rawValue: Int((data & 0xFFFF_0000) >> 16)) else {
            return passThrough
        }
        let isKeyDown = (data & 0xFF00) >> 8 == 0x0A
        // Option-Shift gives quarter steps, as it does in macOS.
        let isFineStep = systemEvent.modifierFlags.contains([.option, .shift])

        // Swallow both halves of a press islo. can handle; act on key-down
        // (including key repeat) only.
        guard canHandle(key) else { return passThrough }
        if isKeyDown { perform(key, fineStep: isFineStep) }
        return nil
    }

    private func canHandle(_ key: HUDKey) -> Bool {
        switch key {
        case .soundUp, .soundDown, .mute:
            return SystemAudioOutput.canSetVolume
        case .brightnessUp, .brightnessDown:
            return BuiltInDisplayBrightness.brightness() != nil
        }
    }

    private func perform(_ key: HUDKey, fineStep: Bool) {
        let step = fineStep ? 1.0 / 64 : 1.0 / 16

        switch key {
        case .soundUp, .soundDown:
            let current = SystemAudioOutput.volume() ?? 0
            let direction: Double = key == .soundUp ? 1 : -1
            let next = stepped(current, by: step, direction: direction)
            if key == .soundUp, SystemAudioOutput.isMuted() == true {
                SystemAudioOutput.setMuted(false)
            }
            SystemAudioOutput.setVolume(next)
            report(onVolume, value: next)

        case .mute:
            let muted = !(SystemAudioOutput.isMuted() ?? false)
            SystemAudioOutput.setMuted(muted)
            report(onVolume, value: muted ? 0 : SystemAudioOutput.volume() ?? 0)

        case .brightnessUp, .brightnessDown:
            guard let current = BuiltInDisplayBrightness.brightness() else { return }
            let direction: Double = key == .brightnessUp ? 1 : -1
            let next = stepped(current, by: step, direction: direction)
            BuiltInDisplayBrightness.setBrightness(next)
            report(onBrightness, value: next)
        }
    }

    private func stepped(_ value: Double, by step: Double, direction: Double) -> Double {
        min(max(((value / step).rounded() + direction) * step, 0), 1)
    }

    private func report(_ callback: @escaping (Double) -> Void, value: Double) {
        DispatchQueue.main.async { callback(value) }
    }
}

private func systemHUDTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<SystemHUDInterceptor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return interceptor.handle(type, event)
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
