import AppKit
import ApplicationServices
import Combine
import CoreAudio
import Darwin
import IOKit.graphics
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum MediaSkipDirection: Equatable {
    case previous
    case next

    var symbolName: String { self == .previous ? "backward.fill" : "forward.fill" }
}

/// Which countdown just ran out, so the notch can say what comes next.
enum TimerFinish: Equatable {
    case timer
    case focusDone
    case breakDone
}

enum CommandEchoKind: Equatable {
    case timerFinished(TimerFinish)
    case upcomingEvent(CalendarEventInfo)
    case power(PowerEvent)
    case headphones(HeadphoneBattery)
    case privacy(PrivacyUsage)
    case volume(Double)
    case brightness(Double)
    case copied
    case pasted
    case screenshot(String)
    case capsLock(Bool)
    case mediaSkip(MediaSkipDirection)
    case trackChanged(String, MediaSkipDirection?)
    case notification(CapturedNotification)

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
        case .notification: "bell.fill"
        case .upcomingEvent: "calendar"
        case .power(let event):
            switch event {
            case .pluggedIn: "bolt.fill"
            case .unplugged: "battery.75"
            case .low: "battery.25"
            }
        case .headphones(let battery): battery.symbolName
        case .privacy(let usage): usage.camera ? "video.fill" : "mic.fill"
        case .timerFinished(let finish):
            switch finish {
            case .timer: "bell.fill"
            case .focusDone: "cup.and.saucer.fill"
            case .breakDone: "brain.head.profile"
            }
        }
    }

    /// Alerts that everyday echoes (volume, copy, Caps Lock, track changes)
    /// must not replace while they're on screen.
    var isImportant: Bool {
        switch self {
        case .notification, .upcomingEvent, .timerFinished, .headphones, .privacy, .power: true
        case .volume, .brightness, .copied, .pasted, .screenshot, .capsLock, .mediaSkip, .trackChanged: false
        }
    }
}

@MainActor
final class CommandEchoManager: ObservableObject {
    @Published private(set) var event: CommandEchoKind = .copied
    @Published private(set) var revision = 0

    private var timer: Timer?
    private var lastVolume: Double?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var lastCapsLockState = NSEvent.modifierFlags.contains(.capsLock)
    private var screenshotObservers: [NSObjectProtocol] = []
    private var keyboardMonitor: Any?
    private var mediaKeyMonitor: Any?

    func startMonitoring() {
        guard timer == nil else { return }
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

    func showNotification(_ notification: CapturedNotification) {
        publish(.notification(notification))
    }

    func showTimerFinished(_ finish: TimerFinish) {
        publish(.timerFinished(finish))
    }

    func showUpcomingEvent(_ event: CalendarEventInfo) {
        publish(.upcomingEvent(event))
    }

    func showPower(_ event: PowerEvent) {
        publish(.power(event))
    }

    func showHeadphones(_ battery: HeadphoneBattery) {
        publish(.headphones(battery))
    }

    func showPrivacy(_ usage: PrivacyUsage) {
        publish(.privacy(usage))
    }

    /// For key presses islo. handled itself. Also primes the volume poller so
    /// the same change isn't announced a second time.
    func showHandledVolume(_ value: Double) {
        lastVolume = Self.readSystemVolume()
        publish(.volume(min(max(value, 0), 1)))
    }

    func showHandledBrightness(_ value: Double) {
        publish(.brightness(min(max(value, 0), 1)))
    }

    /// Without Accessibility, macOS handles the brightness keys itself; read
    /// the value once it has applied the step. Brightness isn't polled, so
    /// auto-brightness changes never show up in the notch.
    private func announceBrightnessAfterKeyPress() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let brightness = Self.readBrightness() else { return }
            self?.publish(.brightness(brightness))
        }
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
            // Global monitors see these keys without Accessibility. When
            // islo.'s own key handler is active it consumes them first.
            if keyCode == HUDKey.brightnessUp.rawValue ||
                keyCode == HUDKey.brightnessDown.rawValue {
                Task { @MainActor in self?.announceBrightnessAfterKeyPress() }
                return
            }
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
        // On Apple Silicon only DisplayServices reports the live value; the
        // AppleARMBacklight registry entry keeps its boot-time value.
        if let brightness = BuiltInDisplayBrightness.brightness() {
            return brightness
        }

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
        return nil
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
        entries = Array(entries.prefix(40))
    }
}

extension ClipboardEntry {
    /// A web address worth opening rather than only copying.
    var linkURL: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), !trimmed.contains("\n") else { return nil }
        let candidate = trimmed.lowercased().hasPrefix("www.") ? "https://" + trimmed : trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }
}

/// A notification macOS showed as a banner, read through Accessibility.
struct CapturedNotification: Identifiable, Equatable {
    let id: String
    let appName: String
    let bundleIdentifier: String?
    let title: String
    let subtitle: String
    let body: String
    let date: Date

    /// The line to lead with: the title, or the body when there's no title.
    var headline: String { title.isEmpty ? body : title }

    /// What follows the headline, without repeating it.
    var detail: String {
        let parts = title.isEmpty ? [subtitle] : [subtitle, body]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Watches the banners Notification Center puts on screen. macOS has no API
/// for other apps' notifications, but each banner is an Accessibility
/// element with a unique identifier and separate title, subtitle and body,
/// so islo. can read new ones as they appear. Needs Accessibility access;
/// notifications that never show a banner (e.g. in a Focus) aren't seen.
@MainActor
final class NotificationMonitor: ObservableObject {
    @Published private(set) var items: [CapturedNotification] = []
    @Published private(set) var unreadCount = 0
    /// Bumps once per notification worth announcing in the notch.
    @Published private(set) var announcementRevision = 0
    private(set) var latest: CapturedNotification?

    private let scanQueue = DispatchQueue(label: "islo.notifications", qos: .utility)
    private var timer: Timer?
    private var isScanning = false
    private var hasBaseline = false
    private var seenIdentifiers: [String] = []

    func setEnabled(_ enabled: Bool) {
        guard enabled != (timer != nil) else { return }
        if enabled {
            hasBaseline = false
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.scheduleScan() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func markAllRead() {
        if unreadCount != 0 { unreadCount = 0 }
    }

    func clear() {
        items.removeAll()
        unreadCount = 0
    }

    func remove(_ item: CapturedNotification) {
        items.removeAll { $0.id == item.id }
    }

    func openApplication(for item: CapturedNotification) {
        guard let bundleIdentifier = item.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
              ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func scheduleScan() {
        guard !isScanning, AXIsProcessTrusted(),
              let center = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.notificationcenterui"
              ).first else { return }
        isScanning = true
        let pid = center.processIdentifier
        // Accessibility calls are cross-process; keep them off the main thread.
        scanQueue.async { [weak self] in
            let banners = Self.readBanners(processIdentifier: pid)
            Task { @MainActor in
                self?.isScanning = false
                self?.ingest(banners)
            }
        }
    }

    private func ingest(_ banners: [RawBanner]) {
        let fresh = banners.filter { !seenIdentifiers.contains($0.id) }
        seenIdentifiers.append(contentsOf: fresh.map(\.id))
        if seenIdentifiers.count > 400 {
            seenIdentifiers.removeFirst(seenIdentifiers.count - 400)
        }

        // Banners already on screen when monitoring starts aren't new.
        guard hasBaseline else {
            hasBaseline = true
            return
        }
        // Opening Notification Center lists the whole history at once; only
        // banners arriving a few at a time are real new notifications.
        guard !fresh.isEmpty, fresh.count <= 3 else { return }

        let captured = fresh.map { banner in
            CapturedNotification(
                id: banner.id,
                appName: banner.appName,
                bundleIdentifier: Self.bundleIdentifier(forAppNamed: banner.appName),
                title: banner.title,
                subtitle: banner.subtitle,
                body: banner.body,
                date: .now
            )
        }
        items.insert(contentsOf: captured.reversed(), at: 0)
        items = Array(items.prefix(60))
        unreadCount += captured.count
        latest = items.first
        announcementRevision &+= 1
    }

    private static func bundleIdentifier(forAppNamed name: String) -> String? {
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName == name }?
            .bundleIdentifier
    }

    fileprivate struct RawBanner {
        let id: String
        let appName: String
        let title: String
        let subtitle: String
        let body: String
    }

    nonisolated private static func readBanners(processIdentifier: pid_t) -> [RawBanner] {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var banners: [RawBanner] = []
        for window in children(of: application)
        where string(window, kAXSubroleAttribute) == "AXSystemDialog" {
            collectBanners(in: window, depth: 0, into: &banners)
        }
        return banners
    }

    nonisolated private static func collectBanners(
        in element: AXUIElement,
        depth: Int,
        into banners: inout [RawBanner]
    ) {
        guard depth < 8 else { return }
        if string(element, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
            if let banner = banner(from: element) { banners.append(banner) }
            return
        }
        for child in children(of: element) {
            collectBanners(in: child, depth: depth + 1, into: &banners)
        }
    }

    nonisolated private static func banner(from element: AXUIElement) -> RawBanner? {
        guard let id = string(element, kAXIdentifierAttribute), !id.isEmpty else {
            return nil
        }
        var fields: [String: String] = [:]
        for child in children(of: element) {
            if let key = string(child, kAXIdentifierAttribute),
               let value = string(child, kAXValueAttribute) {
                fields[key] = value
            }
        }
        let title = fields["title"] ?? ""
        let subtitle = fields["subtitle"] ?? ""
        let body = fields["body"] ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }

        // The description reads "App, title, subtitle, body".
        let description = string(element, kAXDescriptionAttribute) ?? ""
        let leading = title.isEmpty ? body : title
        let appName: String
        if !leading.isEmpty, let range = description.range(of: ", " + leading) {
            appName = String(description[..<range.lowerBound])
        } else {
            appName = description.components(separatedBy: ", ").first ?? ""
        }
        return RawBanner(id: id, appName: appName, title: title, subtitle: subtitle, body: body)
    }

    nonisolated private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    nonisolated private static func string(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }
}

enum FocusTimerMode: String, CaseIterable, Identifiable {
    case timer
    case pomodoro

    var id: String { rawValue }
}

@MainActor
final class FocusTimerManager: ObservableObject {
    static let timerRange = 1...180
    static let focusRange = 5...90
    static let breakRange = 1...30
    /// Focus sessions in one Pomodoro round.
    static let sessionsPerRound = 4

    @Published var mode: FocusTimerMode = .pomodoro {
        // Re-picking the current mode must not wipe a running countdown.
        didSet { if mode != oldValue { reset() } }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isBreak = false
    @Published private(set) var remainingSeconds = 25 * 60

    @Published var timerMinutes: Int {
        didSet {
            durationChanged(timerMinutes, range: Self.timerRange, key: Key.timer, isCurrent: mode == .timer) {
                $0.timerMinutes = $1
            }
        }
    }
    @Published var focusMinutes: Int {
        didSet {
            durationChanged(focusMinutes, range: Self.focusRange, key: Key.focus, isCurrent: mode == .pomodoro && !isBreak) {
                $0.focusMinutes = $1
            }
        }
    }
    @Published var breakMinutes: Int {
        didSet {
            durationChanged(breakMinutes, range: Self.breakRange, key: Key.breakLength, isCurrent: mode == .pomodoro && isBreak) {
                $0.breakMinutes = $1
            }
        }
    }

    /// Bumped each time a countdown runs out; `lastFinish` says which.
    @Published private(set) var finishRevision = 0
    private(set) var lastFinish: TimerFinish = .timer

    /// Finished focus time and sessions, counted per calendar day.
    @Published private(set) var todayFocusSeconds = 0
    @Published private(set) var todaySessions = 0

    private enum Key {
        static let timer = "focus.timerMinutes"
        static let focus = "focus.pomodoroFocusMinutes"
        static let breakLength = "focus.pomodoroBreakMinutes"
        static let statsDay = "focus.statsDay"
        static let statsSeconds = "focus.statsSeconds"
        static let statsSessions = "focus.statsSessions"
    }

    private let defaults: UserDefaults
    private var timer: Timer?
    private var targetDate: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func stored(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            let value = defaults.object(forKey: key) as? Int ?? fallback
            return min(max(value, range.lowerBound), range.upperBound)
        }
        timerMinutes = stored(Key.timer, 10, Self.timerRange)
        focusMinutes = stored(Key.focus, 25, Self.focusRange)
        breakMinutes = stored(Key.breakLength, 5, Self.breakRange)
        remainingSeconds = focusMinutes * 60
        loadTodayStats()
    }

    var totalSeconds: Int {
        switch mode {
        case .timer: timerMinutes * 60
        case .pomodoro: (isBreak ? breakMinutes : focusMinutes) * 60
        }
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1 - Double(remainingSeconds) / Double(totalSeconds)
    }

    /// How much of the dial is lit: the timer works like a kitchen timer
    /// (one turn is an hour), Pomodoro shows what's left of the phase.
    var dialFraction: Double {
        switch mode {
        case .timer:
            min(Double(remainingSeconds) / 3600, 1)
        case .pomodoro:
            totalSeconds > 0 ? Double(remainingSeconds) / Double(totalSeconds) : 0
        }
    }

    /// Focus sessions finished in the current round of four; a completed
    /// round shows all four until the next session starts a new one.
    var sessionsInRound: Int {
        guard todaySessions > 0 else { return 0 }
        return (todaySessions - 1) % Self.sessionsPerRound + 1
    }

    var formattedTime: String {
        let hours = remainingSeconds / 3600
        let minutes = remainingSeconds / 60 % 60
        let seconds = remainingSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// Up in single minutes to 10, then in fives; down the same way.
    static func steppedMinutes(_ value: Int, up: Bool, range: ClosedRange<Int>) -> Int {
        let next: Int
        if up {
            next = value < 10 ? value + 1 : (value / 5 + 1) * 5
        } else {
            next = value <= 10 ? value - 1 : (value - 1) / 5 * 5
        }
        return min(max(next, range.lowerBound), range.upperBound)
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    func reset() {
        stopTimer()
        isRunning = false
        isBreak = false
        remainingSeconds = (mode == .pomodoro ? focusMinutes : timerMinutes) * 60
    }

    func skipPhase() {
        guard mode == .pomodoro else { return }
        stopTimer()
        isRunning = false
        isBreak.toggle()
        remainingSeconds = totalSeconds
    }

    private func durationChanged(
        _ value: Int,
        range: ClosedRange<Int>,
        key: String,
        isCurrent: Bool,
        assign: (FocusTimerManager, Int) -> Void
    ) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard clamped == value else {
            assign(self, clamped)
            return
        }
        defaults.set(value, forKey: key)
        // A new length for the phase on the dial applies right away, unless
        // it is counting down.
        guard isCurrent, !isRunning else { return }
        stopTimer()
        remainingSeconds = totalSeconds
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
        if NSSound(named: "Glass")?.play() != true { NSSound.beep() }
        if mode == .timer || !isBreak {
            recordFinishedFocus(seconds: totalSeconds, countsAsSession: mode == .pomodoro)
        }
        lastFinish = mode == .timer ? .timer : (isBreak ? .breakDone : .focusDone)
        if mode == .pomodoro {
            isBreak.toggle()
            remainingSeconds = totalSeconds
        }
        finishRevision &+= 1
    }

    private func recordFinishedFocus(seconds: Int, countsAsSession: Bool) {
        loadTodayStats()
        todayFocusSeconds += seconds
        if countsAsSession { todaySessions += 1 }
        defaults.set(todayFocusSeconds, forKey: Key.statsSeconds)
        defaults.set(todaySessions, forKey: Key.statsSessions)
    }

    /// Starts the counts from zero on a new day.
    func loadTodayStats() {
        let today = Self.dayKey(Date())
        if defaults.string(forKey: Key.statsDay) != today {
            defaults.set(today, forKey: Key.statsDay)
            defaults.set(0, forKey: Key.statsSeconds)
            defaults.set(0, forKey: Key.statsSessions)
        }
        let seconds = defaults.integer(forKey: Key.statsSeconds)
        let sessions = defaults.integer(forKey: Key.statsSessions)
        if seconds != todayFocusSeconds { todayFocusSeconds = seconds }
        if sessions != todaySessions { todaySessions = sessions }
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
    /// True while the user holds files being dragged anywhere on screen.
    @Published private(set) var isFileDragActive = false
    private let defaultsKey = "dashboard.fileShelf.items"
    private var dragMonitors: [Any] = []
    private var dragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
    private var dragEndTimer: Timer?

    /// Mouse monitors only see other apps' events, which is exactly a file
    /// being dragged out of Finder or elsewhere. A new drag writes to the
    /// drag pasteboard, so a changed count with file URLs means files are
    /// in hand. Mouse events need no extra permission.
    func startDragMonitoring() {
        guard dragMonitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] _ in
            Task { @MainActor in
                self?.dragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
            }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) {
            [weak self] _ in
            Task { @MainActor in self?.checkForFileDrag() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) {
            [weak self] _ in
            Task { @MainActor in self?.endFileDrag() }
        }
        dragMonitors = [down, dragged, up].compactMap { $0 }
    }

    func stopDragMonitoring() {
        dragMonitors.forEach(NSEvent.removeMonitor)
        dragMonitors.removeAll()
        endFileDrag()
    }

    private func checkForFileDrag() {
        guard !isFileDragActive else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragPasteboardChangeCount,
              pasteboard.types?.contains(.fileURL) == true else { return }
        isFileDragActive = true

        // A drop onto islo. itself is delivered to this app, where the global
        // mouse-up monitor can't see it, so also watch the button directly.
        dragEndTimer?.invalidate()
        dragEndTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.endFileDrag() }
            }
        }
    }

    private func endFileDrag() {
        dragEndTimer?.invalidate()
        dragEndTimer = nil
        dragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
        if isFileDragActive { isFileDragActive = false }
    }

    /// Small previews for the shelf grid, made by Quick Look.
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    private var detailsCache: [URL: ShelfItemDetails] = [:]

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        items = paths.map(URL.init(fileURLWithPath:)).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        items.forEach(makeThumbnail)
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
        items = Array(items.prefix(60))
        persist()
        makeThumbnail(url)
    }

    func remove(_ url: URL) {
        items.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        thumbnails[url] = nil
        persist()
    }

    /// Empties the shelf. The files themselves stay where they are.
    func clear() {
        items.removeAll()
        thumbnails.removeAll()
        persist()
    }

    func details(for url: URL) -> ShelfItemDetails {
        if let cached = detailsCache[url] { return cached }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey])
        let type = values?.contentType
        let made = ShelfItemDetails(
            isImage: type?.conforms(to: .image) ?? false,
            kind: ShelfItemDetails.kind(for: type, isDirectory: values?.isDirectory ?? false),
            size: values?.fileSize.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            }
        )
        detailsCache[url] = made
        return made
    }

    private func makeThumbnail(_ url: URL) {
        guard thumbnails[url] == nil else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 160, height: 100),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in self?.thumbnails[url] = image }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func sendViaAirDrop(_ url: URL) {
        sendViaAirDrop([url])
    }

    /// Sends dropped files straight to AirDrop without keeping them on the
    /// shelf.
    func sendViaAirDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !matching.isEmpty else { return false }

        let group = DispatchGroup()
        let collected = CollectedURLs()
        for provider in matching {
            group.enter()
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                if let url = Self.url(from: item) { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let urls = collected.all
            guard !urls.isEmpty else { return }
            Task { @MainActor in self?.sendViaAirDrop(urls) }
        }
        return true
    }

    private func sendViaAirDrop(_ urls: [URL]) {
        // The AirDrop picker is a window of its own; bring it forward.
        NSApp.activate(ignoringOtherApps: true)
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: defaultsKey)
    }

    /// Gathers URLs that item providers deliver on background queues.
    private final class CollectedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }

        var all: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
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

struct ShelfItemDetails {
    let isImage: Bool
    let kind: String
    let size: String?

    static func kind(for type: UTType?, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        guard let type else { return "file" }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "video" }
        if type.conforms(to: .audio) { return "audio" }
        if type.conforms(to: .archive) { return "archive" }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return "text" }
        return "file"
    }
}
