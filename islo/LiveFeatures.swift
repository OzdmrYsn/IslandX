import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import Darwin
import EventKit
import IOKit.ps

// MARK: - Calendar

/// One calendar event, trimmed to what the notch shows.
struct CalendarEventInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let joinURL: URL?
    let color: NSColor

    func isOngoing(at date: Date) -> Bool {
        start <= date && date < end
    }
}

/// Reads the user's calendars and announces meetings shortly before they
/// start. Needs the Calendars permission.
@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    /// How long before an event the notch says so.
    static let alertLeadTime: TimeInterval = 5 * 60

    @Published private(set) var authorization: PermissionState = CalendarManager.currentAuthorization()
    /// Timed events that haven't ended yet, soonest first (next two days).
    @Published private(set) var upcoming: [CalendarEventInfo] = []
    /// Everything on today's calendars, all-day events first.
    @Published private(set) var today: [CalendarEventInfo] = []
    @Published private(set) var alertRevision = 0
    private(set) var alertEvent: CalendarEventInfo?

    var alertsEnabled = true

    private var store = EKEventStore()
    private var isEnabled = false
    private var timer: Timer?
    private var storeObserver: NSObjectProtocol?
    private var alerted: Set<String> = []

    private init() {}

    var nextEvent: CalendarEventInfo? { upcoming.first }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            storeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
            storeObserver = nil
            upcoming = []
            today = []
        }
    }

    func requestAccess() {
        let finish: @Sendable (Bool, Error?) -> Void = { _, _ in
            Task { @MainActor in
                // A fresh store picks up the new permission right away.
                CalendarManager.shared.store = EKEventStore()
                CalendarManager.shared.refresh()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: finish)
        } else {
            store.requestAccess(to: .event, completion: finish)
        }
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func join(_ event: CalendarEventInfo) {
        guard let url = event.joinURL else {
            openCalendarApp()
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// A cheap check for Settings, which polls while it's open; loads the
    /// events as soon as access is granted.
    func refreshAuthorization() {
        let state = Self.currentAuthorization()
        guard state != authorization else { return }
        authorization = state
        refresh()
    }

    func refresh() {
        let state = Self.currentAuthorization()
        if state != authorization { authorization = state }
        guard isEnabled, state == .granted else {
            if !upcoming.isEmpty { upcoming = [] }
            if !today.isEmpty { today = [] }
            return
        }

        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay),
              let horizon = calendar.date(byAdding: .day, value: 2, to: startOfDay) else { return }

        let predicate = store.predicateForEvents(withStart: startOfDay, end: horizon, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { event in
                // Skip invitations the user turned down.
                let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
                return !declined && event.status != .canceled
            }
            .map(Self.info(from:))

        let newUpcoming = events
            .filter { !$0.isAllDay && $0.end > now }
            .sorted { $0.start < $1.start }
        let newToday = events
            .filter { $0.start < endOfDay && $0.end > startOfDay }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }

        if newUpcoming != upcoming { upcoming = newUpcoming }
        if newToday != today { today = newToday }
        checkAlerts(now: now)
    }

    private func checkAlerts(now: Date) {
        guard alertsEnabled else { return }
        for event in upcoming {
            let lead = event.start.timeIntervalSince(now)
            guard lead > 0, lead <= Self.alertLeadTime + 30 else { continue }
            guard !alerted.contains(event.id) else { continue }
            alerted.insert(event.id)
            alertEvent = event
            alertRevision &+= 1
            break
        }
    }

    private static func info(from event: EKEvent) -> CalendarEventInfo {
        let identifier = (event.eventIdentifier ?? UUID().uuidString)
            + "-\(Int(event.startDate.timeIntervalSince1970))"
        return CalendarEventInfo(
            id: identifier,
            title: (event.title?.isEmpty == false ? event.title : nil) ?? "—",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            joinURL: meetingURL(in: event),
            color: event.calendar?.color ?? .systemBlue
        )
    }

    private static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "facetime.apple.com", "around.co", "meet.jit.si"
    ]

    /// The first video-call link in the event's URL, location or notes.
    private static func meetingURL(in event: EKEvent) -> URL? {
        var candidates: [URL] = []
        if let url = event.url { candidates.append(url) }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        if !text.isEmpty,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            candidates += detector.matches(in: text, range: range).compactMap(\.url)
        }
        return candidates.first { url in
            if url.scheme == "zoommtg" || url.scheme == "msteams" { return true }
            guard let host = url.host?.lowercased() else { return false }
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    static func currentAuthorization() -> PermissionState {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined: return .notAsked
        case .restricted, .denied: return .missing
        default:
            if #available(macOS 14.0, *) {
                return status == .fullAccess ? .granted : .missing
            }
            return .granted
        }
    }
}

// MARK: - Power

struct BatteryStatus: Equatable {
    let level: Int
    let isCharging: Bool
    let isPluggedIn: Bool
}

enum PowerEvent: Equatable {
    case pluggedIn(level: Int, isCharging: Bool)
    case unplugged(level: Int)
    case low(level: Int)
}

/// Watches the built-in battery: plugging the charger in or out, and
/// running low (20% and 10%).
@MainActor
final class PowerMonitor: ObservableObject {
    static let shared = PowerMonitor()

    @Published private(set) var status: BatteryStatus?
    @Published private(set) var eventRevision = 0
    private(set) var lastEvent: PowerEvent = .unplugged(level: 0)

    private var runLoopSource: CFRunLoopSource?
    private var warnedLevels: Set<Int> = []

    private init() {}

    func start() {
        guard runLoopSource == nil else { return }
        status = Self.readBattery()
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in PowerMonitor.shared.update() }
        }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    private func update() {
        guard let new = Self.readBattery() else { return }
        let old = status
        status = new
        guard let old else { return }

        if !old.isPluggedIn, new.isPluggedIn {
            warnedLevels.removeAll()
            announce(.pluggedIn(level: new.level, isCharging: new.isCharging))
        } else if old.isPluggedIn, !new.isPluggedIn {
            announce(.unplugged(level: new.level))
        } else if !new.isPluggedIn {
            for threshold in [10, 20] where new.level <= threshold && old.level > threshold {
                guard !warnedLevels.contains(threshold) else { continue }
                warnedLevels.insert(threshold)
                announce(.low(level: new.level))
                break
            }
        }
    }

    private func announce(_ event: PowerEvent) {
        lastEvent = event
        eventRevision &+= 1
    }

    static func readBattery() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let level = maximum > 0
                ? Int((Double(current) / Double(maximum) * 100).rounded())
                : current
            return BatteryStatus(
                level: min(max(level, 0), 100),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }
}

// MARK: - Audio output devices

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var symbolName: String {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods pro") { return "airpodspro" }
        if lowered.contains("airpods") { return "airpods" }
        if isBluetooth { return "headphones" }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        default: return "speaker.wave.2.fill"
        }
    }
}

/// Battery levels a headset reports: AirPods give left, right and case;
/// most other headphones a single level.
struct HeadphoneBattery: Equatable {
    let name: String
    let symbolName: String
    let left: Int?
    let right: Int?
    let caseLevel: Int?
    let main: Int?

    var hasLevels: Bool {
        left != nil || right != nil || caseLevel != nil || main != nil
    }
}

/// Lists the Mac's audio outputs, switches between them, and announces
/// Bluetooth headphones with their battery when they become the output.
@MainActor
final class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()

    @Published private(set) var outputs: [AudioOutputDevice] = []
    @Published private(set) var currentOutputID: AudioDeviceID = 0
    @Published private(set) var headphoneRevision = 0
    private(set) var lastHeadphones: HeadphoneBattery?

    private var isListening = false
    private var batteryTask: Task<Void, Never>?

    private init() {}

    var currentOutput: AudioOutputDevice? {
        outputs.first { $0.id == currentOutputID }
    }

    func start() {
        guard !isListening else { return }
        isListening = true
        reload()
        var devicesAddress = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, .main) { _, _ in
            Task { @MainActor in AudioDeviceManager.shared.reload() }
        }
        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, .main) { _, _ in
            Task { @MainActor in AudioDeviceManager.shared.defaultOutputChanged() }
        }
    }

    func select(_ device: AudioOutputDevice) {
        var id = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = Self.address(selector)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id)
        }
    }

    private func reload() {
        let devices = Self.deviceIDs().compactMap(Self.outputDevice(for:))
        if devices != outputs { outputs = devices }
        let current = Self.defaultOutputID()
        if current != currentOutputID { currentOutputID = current }
    }

    private func defaultOutputChanged() {
        let previous = currentOutputID
        reload()
        guard currentOutputID != previous,
              let device = currentOutput,
              device.isBluetooth else { return }
        announceHeadphones(device)
    }

    /// Battery levels come from macOS's Bluetooth report, which needs no
    /// permission; they can lag the connection, so try once more if empty.
    private func announceHeadphones(_ device: AudioOutputDevice) {
        batteryTask?.cancel()
        batteryTask = Task { [weak self] in
            var battery = await Self.battery(for: device)
            if battery?.hasLevels != true {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                battery = await Self.battery(for: device) ?? battery
            }
            guard !Task.isCancelled, let self else { return }
            self.lastHeadphones = battery ?? HeadphoneBattery(
                name: device.name, symbolName: device.symbolName,
                left: nil, right: nil, caseLevel: nil, main: nil
            )
            self.headphoneRevision &+= 1
        }
    }

    nonisolated private static func battery(for device: AudioOutputDevice) async -> HeadphoneBattery? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readBattery(named: device.name, symbolName: device.symbolName))
            }
        }
    }

    nonisolated private static func readBattery(named name: String, symbolName: String) -> HeadphoneBattery? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (deviceName, value) in entry {
                    guard deviceName == name || name.contains(deviceName) || deviceName.contains(name),
                          let info = value as? [String: Any] else { continue }
                    func level(_ key: String) -> Int? {
                        (info[key] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
                    }
                    return HeadphoneBattery(
                        name: name,
                        symbolName: symbolName,
                        left: level("device_batteryLevelLeft"),
                        right: level("device_batteryLevelRight"),
                        caseLevel: level("device_batteryLevelCase"),
                        main: level("device_batteryLevelMain")
                    )
                }
            }
        }
        return nil
    }

    // MARK: CoreAudio helpers

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    nonisolated private static func defaultOutputID() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    nonisolated private static func outputDevice(for id: AudioDeviceID) -> AudioOutputDevice? {
        // Only devices with output streams that aren't hidden.
        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0 else { return nil }

        var hiddenAddress = address(kAudioDevicePropertyIsHidden)
        var hidden: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &hiddenAddress, 0, nil, &size, &hidden) == noErr, hidden != 0 {
            return nil
        }

        var nameAddress = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &size, &name) == noErr,
              let deviceName = name?.takeRetainedValue() as String? else { return nil }

        var transportAddress = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &size, &transport)

        return AudioOutputDevice(id: id, name: deviceName, transportType: transport)
    }
}

// MARK: - Camera and microphone

struct PrivacyUsage: Equatable {
    var microphone = false
    var camera = false
    /// The app using the microphone, when macOS says which one.
    var appName: String?

    var isActive: Bool { microphone || camera }
}

/// Polls whether any app uses the camera or microphone. Reading these
/// states needs no permission.
@MainActor
final class PrivacyMonitor: ObservableObject {
    static let shared = PrivacyMonitor()

    @Published private(set) var usage = PrivacyUsage()
    /// Bumped when something starts using the camera or microphone.
    @Published private(set) var startRevision = 0

    private var timer: Timer?
    private var isPolling = false

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            poll()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } else {
            timer?.invalidate()
            timer = nil
            usage = PrivacyUsage()
        }
    }

    #if DEBUG
    /// Debug builds: pretend an app uses the camera/microphone (nil stops).
    func debugSimulate(_ simulated: PrivacyUsage?) {
        timer?.invalidate()
        timer = nil
        if let simulated {
            usage = simulated
            startRevision &+= 1
        } else {
            usage = PrivacyUsage()
            setEnabled(true)
        }
    }
    #endif

    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        DispatchQueue.global(qos: .utility).async {
            let microphoneApp = Self.microphoneApp()
            let microphone = microphoneApp != nil || Self.defaultInputIsRunning()
            let camera = Self.cameraIsRunning()
            let appName = microphoneApp.flatMap { $0.isEmpty ? nil : $0 }
            DispatchQueue.main.async {
                let monitor = PrivacyMonitor.shared
                monitor.isPolling = false
                guard monitor.timer != nil else { return }
                let new = PrivacyUsage(microphone: microphone, camera: camera, appName: appName)
                let old = monitor.usage
                guard new != old else { return }
                monitor.usage = new
                let started = (new.microphone && !old.microphone) || (new.camera && !old.camera)
                if started { monitor.startRevision &+= 1 }
            }
        }
    }

    // MARK: Readers

    /// The first app with a running input stream (macOS 14+), or nil.
    nonisolated private static func microphoneApp() -> String? {
        guard #available(macOS 14.0, *) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else {
            return nil
        }
        for process in processes {
            guard uint32Property(process, kAudioProcessPropertyIsRunningInput) != 0 else { continue }
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid)
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }
            // System services (Siri, dictation) have no app bundle and are
            // skipped; macOS doesn't light its indicator for them either.
            if let name = appName(for: pid) { return name }
        }
        return nil
    }

    /// Fallback for macOS 13, which can't say which process records.
    nonisolated private static func defaultInputIsRunning() -> Bool {
        guard #unavailable(macOS 14.0) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        return uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
    }

    nonisolated private static func cameraIsRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return false
        }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else {
            return false
        }
        for device in devices {
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var running: UInt32 = 0
            var runningSize: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &runningSize, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    nonisolated private static func uint32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    /// The outermost app bundle around a process, so a browser's helper
    /// process is reported as the browser.
    nonisolated private static func appName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = "/" + components[...index].joined(separator: "/")
        let bundle = Bundle(path: bundlePath)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? String(components[index].dropLast(4))
        return name
    }
}
