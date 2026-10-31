import AppKit
import Carbon.HIToolbox
import Combine
import CoreAudio
import CoreMediaIO
import Darwin
import EventKit
import IOKit.ps
import QuickLookThumbnailing

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
            // Any store: the store is recreated when access is granted.
            storeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
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
        // Access granted in System Settings: a store made before that
        // keeps returning no events.
        if state == .granted { store = EKEventStore() }
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
    /// The default output this manager last reacted to. The device-list
    /// listener also refreshes `currentOutputID`, so it can't be the guard.
    private var handledOutputID: AudioDeviceID = 0

    private init() {}

    var currentOutput: AudioOutputDevice? {
        outputs.first { $0.id == currentOutputID }
    }

    func start() {
        guard !isListening else { return }
        isListening = true
        reload()
        handledOutputID = currentOutputID
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
        reload()
        guard currentOutputID != handledOutputID else { return }
        handledOutputID = currentOutputID
        guard let device = currentOutput, device.isBluetooth else { return }
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
            let appName = microphoneApp
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

    /// The app with a running input stream (macOS 14+), or nil. Only
    /// processes that belong to an app count: system services such as
    /// corespeechd open the microphone whenever audio plays, and macOS
    /// doesn't light its own indicator for them either.
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
            // Helpers and XPC services (Safari's WebKit audio) record for
            // the app responsible for them.
            if let name = appName(for: responsiblePID(for: pid)) ?? appName(for: pid) { return name }
            if let name = callServiceName(for: pid) { return name }
        }
        return nil
    }

    /// System daemons that record for a call the user is on.
    nonisolated private static func callServiceName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        switch (String(cString: buffer) as NSString).lastPathComponent {
        case "avconferenced": return "FaceTime"
        default: return nil
        }
    }

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t
    nonisolated(unsafe) private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    /// The app macOS holds responsible for a process (Safari for its WebKit
    /// helpers); the process itself when unknown.
    nonisolated private static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let function = responsiblePIDFunction else { return pid }
        let responsible = function(pid)
        return responsible > 0 ? responsible : pid
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

// MARK: - Lyrics

struct LyricLine: Equatable {
    let time: TimeInterval
    let text: String
}

enum LyricsState: Equatable {
    case idle
    case loading
    case synced([LyricLine])
    case unsynced
    case instrumental
    case notFound
}

/// Time-synced lyrics from LRCLIB, a free lyrics database. Only the
/// track's title, artist, album and length are sent.
@MainActor
final class LyricsManager: ObservableObject {
    static let shared = LyricsManager()

    @Published private(set) var state: LyricsState = .idle

    private var trackKey = ""
    private var cache: [String: LyricsState] = [:]
    private var task: Task<Void, Never>?

    private init() {}

    func load(title: String, artist: String, album: String, duration: TimeInterval) {
        let key = "\(artist.lowercased())|\(title.lowercased())"
        guard key != trackKey else { return }
        trackKey = key
        task?.cancel()
        guard !title.isEmpty else {
            state = .idle
            return
        }
        if let cached = cache[key] {
            state = cached
            return
        }
        state = .loading
        task = Task { [weak self] in
            let result = await Self.fetch(title: title, artist: artist, album: album, duration: duration)
            guard !Task.isCancelled, let self else { return }
            guard self.trackKey == key else { return }
            if let result {
                self.cache[key] = result
                self.state = result
            } else {
                // LRCLIB couldn't be reached: forget the key so the next
                // look (or the lyrics button) tries again.
                self.trackKey = ""
                self.state = .notFound
            }
        }
    }

    func reset() {
        task?.cancel()
        trackKey = ""
        state = .idle
    }

    /// The line being sung at `time`, if any has started yet.
    static func lineIndex(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        var low = 0
        var high = lines.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].time <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    // MARK: Network

    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// nil when LRCLIB couldn't be reached.
    nonisolated private static func fetch(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async -> LyricsState? {
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }

        switch await request(path: "/api/get", items: items) {
        case .failure:
            return nil
        case .success(let data):
            if let data, let record = try? JSONDecoder().decode(Record.self, from: data),
               let state = state(from: record) {
                return state
            }
        }

        // No exact match: search and take the closest length.
        let searchItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard case .success(let data) = await request(path: "/api/search", items: searchItems) else { return nil }
        guard let data, let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return .notFound
        }
        let ranked = records.sorted {
            abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration)
        }
        if let synced = ranked.first(where: { $0.syncedLyrics?.isEmpty == false }),
           let state = state(from: synced) {
            return state
        }
        return ranked.first.flatMap(state(from:)) ?? .notFound
    }

    nonisolated private static func state(from record: Record) -> LyricsState? {
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if record.plainLyrics?.isEmpty == false { return .unsynced }
        return nil
    }

    /// `.success(nil)` means "not found".
    nonisolated private static func request(path: String, items: [URLQueryItem]) async -> Result<Data?, Error> {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = items
        guard let url = components.url else { return .success(nil) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2"
        request.setValue("islo/\(version) (https://github.com/OzdmrYsn/islo)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .success(nil) }
            guard (200..<300).contains(status) else { return .failure(URLError(.badServerResponse)) }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }

    /// Parses LRC lines such as "[01:02.50]text"; a line may carry several
    /// timestamps, and empty lines become a musical pause.
    nonisolated static func parse(_ lrc: String) -> [LyricLine] {
        guard let pattern = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#) else {
            return []
        }
        var lines: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = pattern.matches(in: raw, range: range)
            guard let last = matches.last, let textRange = Range(last.range, in: raw) else { continue }
            let text = raw[textRange.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Range(match.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
                      let seconds = Range(match.range(at: 2), in: raw)
                        .flatMap({ Double(raw[$0].replacingOccurrences(of: ":", with: ".")) }) else { continue }
                lines.append(LyricLine(time: minutes * 60 + seconds, text: text.isEmpty ? "♪" : text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}

// MARK: - Weather

struct WeatherLocation: Codable, Equatable, Identifiable {
    let name: String
    let detail: String
    let latitude: Double
    let longitude: Double

    var id: String { "\(latitude),\(longitude)" }
}

struct WeatherSnapshot: Equatable {
    let temperature: Double
    let code: Int
    let isDay: Bool
    let high: Double
    let low: Double
    let locationName: String
}

/// Current weather from Open-Meteo (free, no account). The place is the
/// city the user picked, or the one in the Mac's time zone, so no location
/// permission is needed.
@MainActor
final class WeatherManager: ObservableObject {
    static let shared = WeatherManager()

    @Published private(set) var snapshot: WeatherSnapshot?

    private var isEnabled = false
    private var chosenLocation: WeatherLocation?
    private var automaticLocation: WeatherLocation?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?

    private init() {}

    var usesFahrenheit: Bool {
        Locale.current.measurementSystem == .us
    }

    func configure(enabled: Bool, location: WeatherLocation?) {
        let locationChanged = location != chosenLocation
        chosenLocation = location
        if enabled != isEnabled {
            isEnabled = enabled
            if enabled {
                timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
                    Task { @MainActor in WeatherManager.shared.refresh() }
                }
                wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
                ) { _ in
                    Task { @MainActor in WeatherManager.shared.refresh() }
                }
            } else {
                timer?.invalidate()
                timer = nil
                if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
                wakeObserver = nil
                task?.cancel()
                snapshot = nil
                return
            }
            refresh()
        } else if enabled, locationChanged {
            refresh()
        }
    }

    func refresh() {
        guard isEnabled else { return }
        task?.cancel()
        let chosen = chosenLocation
        let fahrenheit = usesFahrenheit
        task = Task { [weak self] in
            guard let self else { return }
            var location = chosen ?? self.automaticLocation
            if location == nil {
                location = await Self.timeZoneLocation()
                self.automaticLocation = location
            }
            guard let location, !Task.isCancelled,
                  let snapshot = await Self.forecast(for: location, fahrenheit: fahrenheit),
                  !Task.isCancelled else { return }
            self.snapshot = snapshot
        }
    }

    /// "Europe/Istanbul" → Istanbul, looked up by name.
    nonisolated static func timeZoneLocation() async -> WeatherLocation? {
        let identifier = TimeZone.current.identifier
        guard let city = identifier.split(separator: "/").last.map({ $0.replacingOccurrences(of: "_", with: " ") }),
              !city.isEmpty else { return nil }
        return await search(city).first
    }

    nonisolated static func search(_ name: String) async -> [WeatherLocation] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: Locale.preferredLanguages.first?.prefix(2).description ?? "en")
        ]
        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let name = result["name"] as? String,
                  let latitude = result["latitude"] as? Double,
                  let longitude = result["longitude"] as? Double else { return nil }
            let detail = [result["admin1"] as? String, result["country"] as? String]
                .compactMap { $0 }
                .joined(separator: ", ")
            return WeatherLocation(name: name, detail: detail, latitude: latitude, longitude: longitude)
        }
    }

    nonisolated private static func forecast(for location: WeatherLocation, fahrenheit: Bool) async -> WeatherSnapshot? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        var items = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        if fahrenheit { items.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit")) }
        components?.queryItems = items
        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let daily = root["daily"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (current["weather_code"] as? NSNumber)?.intValue else { return nil }
        let high = ((daily["temperature_2m_max"] as? [NSNumber])?.first?.doubleValue) ?? temperature
        let low = ((daily["temperature_2m_min"] as? [NSNumber])?.first?.doubleValue) ?? temperature
        return WeatherSnapshot(
            temperature: temperature,
            code: code,
            isDay: (current["is_day"] as? NSNumber)?.intValue != 0,
            high: high,
            low: low,
            locationName: location.name
        )
    }

    /// SF Symbol for a WMO weather code.
    static func symbolName(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 61, 63, 66, 80, 81: "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func summary(code: Int, turkish: Bool) -> String {
        switch code {
        case 0: turkish ? "Açık" : "Clear"
        case 1: turkish ? "Az bulutlu" : "Mostly clear"
        case 2: turkish ? "Parçalı bulutlu" : "Partly cloudy"
        case 3: turkish ? "Kapalı" : "Overcast"
        case 45, 48: turkish ? "Sisli" : "Foggy"
        case 51, 53, 55, 56, 57: turkish ? "Çiseliyor" : "Drizzle"
        case 61, 63, 66, 80, 81: turkish ? "Yağmurlu" : "Rain"
        case 65, 67, 82: turkish ? "Sağanak" : "Heavy rain"
        case 71, 73, 75, 77, 85, 86: turkish ? "Karlı" : "Snow"
        case 95, 96, 99: turkish ? "Gök gürültülü" : "Thunderstorm"
        default: turkish ? "Bulutlu" : "Cloudy"
        }
    }
}

// MARK: - Global shortcut

/// A key plus Carbon modifier flags, e.g. ⌥Space.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultToggle = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    /// Keys that type nothing, so ⌥ alone is enough with them (⌥Space).
    static let nonCharacterKeys: Set<Int> = [
        kVK_Space, kVK_Return, kVK_Tab, kVK_Delete, kVK_ForwardDelete,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown
    ]

    /// A system-wide shortcut swallows its keys everywhere, so ⇧A or ⌥Q
    /// (@ on Turkish keyboards) would stop people typing those characters.
    static func isAllowed(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        if functionKeys.contains(keyCode) { return true }
        if flags.contains(.command) || flags.contains(.control) { return true }
        return flags.contains(.option) && nonCharacterKeys.contains(keyCode)
    }

    static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]

    static func keyName(_ keyCode: UInt32) -> String {
        let code = Int(keyCode)
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟"
        ]
        if let name = named[code] { return name }
        if let index = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            .firstIndex(of: code) {
            return "F\(index + 1)"
        }
        return character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// The character the key types on the current keyboard layout.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

/// One system-wide shortcut through Carbon's hot keys, which need no
/// Accessibility permission.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var currentKey: HotKey?

    private init() {}

    /// Registers `hotKey` (nil clears it); false if another app holds it.
    @discardableResult
    func register(_ hotKey: HotKey?) -> Bool {
        unregisterCurrent()
        currentKey = hotKey
        guard let hotKey else { return true }
        return registerCurrent(hotKey)
    }

    /// While the shortcut is being re-recorded, pressing the old one must
    /// reach the recorder instead of toggling the notch.
    func suspend() {
        unregisterCurrent()
    }

    func resume() {
        guard hotKeyRef == nil, let currentKey else { return }
        _ = registerCurrent(currentKey)
    }

    private func registerCurrent(_ hotKey: HotKey) -> Bool {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x69_73_6C_6F), id: 1) // 'islo'
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers, identifier,
            // Exclusive, so a shortcut another app holds fails visibly.
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    private func unregisterCurrent() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotKeyManager.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

// MARK: - Screenshots

/// A screenshot (or screen recording) that was just saved.
struct ScreenshotCapture: Equatable {
    let url: URL
    let thumbnail: NSImage?

    var name: String { url.lastPathComponent }
}

/// Watches a folder and reports names that appear in it (new files and
/// files renamed into it, like a finished download dropping .crdownload).
/// Opening a folder macOS guards (Desktop, Downloads) waits until the user
/// answers macOS's permission prompt, so all file access runs on a
/// background queue; `onNew` is called there too.
final class FolderWatcher {
    let url: URL
    private let state: State

    init(url: URL, onNew: @escaping ([URL]) -> Void) {
        self.url = url
        let state = State(url: url, onNew: onNew)
        self.state = state
        state.queue.async { state.start() }
    }

    deinit {
        let state = state
        state.queue.async { state.stop() }
    }

    /// Everything here runs on `queue` only.
    private final class State {
        let url: URL
        let onNew: ([URL]) -> Void
        let queue = DispatchQueue(label: "islo.folder-watcher", qos: .utility)
        private var source: DispatchSourceFileSystemObject?
        private var known: Set<String> = []
        /// The folder couldn't be listed yet (macOS hadn't allowed access);
        /// its first readable listing is what was already there, not new.
        private var needsBaseline = false
        private var isStopped = false

        init(url: URL, onNew: @escaping ([URL]) -> Void) {
            self.url = url
            self.onNew = onNew
        }

        func start() {
            guard !isStopped else { return }
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                known = Set(names)
            } else {
                needsBaseline = true
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
            source.setEventHandler { [weak self] in self?.scan() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }

        func stop() {
            isStopped = true
            source?.cancel()
            source = nil
        }

        private func scan() {
            guard !isStopped,
                  let listing = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
            let names = Set(listing)
            if needsBaseline {
                needsBaseline = false
                known = names
                return
            }
            let added = names.subtracting(known).filter { !$0.hasPrefix(".") }
            known = names
            guard !added.isEmpty else { return }
            onNew(added.sorted().map { url.appendingPathComponent($0) })
        }
    }

    static func hasAttribute(_ name: String, at url: URL) -> Bool {
        getxattr(url.path, name, nil, 0, 0, 0) >= 0
    }
}

/// Watches the folder macOS saves screenshots to (System Settings or the
/// Screenshot app can change it; Desktop by default) for files carrying the
/// screen-capture tag. macOS writes the file once its floating thumbnail
/// goes away.
@MainActor
final class ScreenshotMonitor: ObservableObject {
    static let shared = ScreenshotMonitor()

    @Published private(set) var revision = 0
    private(set) var latest: ScreenshotCapture?

    private var watcher: FolderWatcher?
    private var locationTimer: Timer?

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard locationTimer == nil else { return }
            watchCurrentLocation()
            // The save location can change while islo. runs.
            locationTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
                Task { @MainActor in ScreenshotMonitor.shared.watchCurrentLocation() }
            }
        } else {
            locationTimer?.invalidate()
            locationTimer = nil
            watcher = nil
        }
    }

    static var saveLocation: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let path = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    private func watchCurrentLocation() {
        let location = Self.saveLocation
        guard watcher?.url.standardizedFileURL != location.standardizedFileURL else { return }
        watcher = FolderWatcher(url: location) { urls in
            Task { @MainActor in ScreenshotMonitor.shared.inspect(urls, attempt: 0) }
        }
    }

    /// The tag can land a moment after the file does; look once more.
    private func inspect(_ urls: [URL], attempt: Int) {
        var pending: [URL] = []
        for url in urls {
            if FolderWatcher.hasAttribute("com.apple.metadata:kMDItemIsScreenCapture", at: url) {
                announce(url)
            } else if attempt == 0 {
                pending.append(url)
            }
        }
        guard !pending.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            ScreenshotMonitor.shared.inspect(pending, attempt: 1)
        }
    }

    private func announce(_ url: URL) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 320, height: 200), scale: 2, representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.nsImage
            Task { @MainActor in
                let monitor = ScreenshotMonitor.shared
                monitor.latest = ScreenshotCapture(url: url, thumbnail: image)
                monitor.revision &+= 1
            }
        }
    }
}

// MARK: - Downloads

struct DownloadItem: Identifiable, Equatable {
    let id: String
    var name: String
    var fraction: Double
    var isAirDrop: Bool
}

struct FinishedDownload: Equatable {
    let url: URL
    let isAirDrop: Bool

    var name: String { url.lastPathComponent }
}

/// Follows downloads into ~/Downloads (Safari, Chrome, AirDrop…) through
/// the file progress they publish for Finder; no permission is needed.
@MainActor
final class DownloadMonitor: ObservableObject {
    static let shared = DownloadMonitor()

    @Published private(set) var active: [DownloadItem] = []
    @Published private(set) var finishRevision = 0
    private(set) var lastFinished: FinishedDownload?

    private var subscriber: Any?
    private var observations: [String: NSKeyValueObservation] = [:]
    private var watcher: FolderWatcher?
    /// Final paths already announced, so the progress and the folder
    /// watcher don't both report the same file.
    private var announced: [String: Date] = [:]

    private init() {}

    /// The share of all running downloads that's done.
    var overallFraction: Double {
        guard !active.isEmpty else { return 0 }
        return active.map(\.fraction).reduce(0, +) / Double(active.count)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard subscriber == nil else { return }
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            // Instant downloads and browsers that publish no progress
            // (Firefox and its forks) still land here with a quarantine tag.
            watcher = FolderWatcher(url: downloads) { urls in
                Task { @MainActor in DownloadMonitor.shared.filesAppeared(urls) }
            }
            subscriber = Progress.addSubscriber(forFileURL: downloads) { progress in
                let kind = progress.userInfo[.fileOperationKindKey] as? Progress.FileOperationKind
                guard kind == .downloading || kind == .receiving,
                      let url = progress.userInfo[.fileURLKey] as? URL else { return nil }
                let id = url.path
                let isAirDrop = kind == .receiving
                let observation = progress.observe(\.fractionCompleted) { progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in DownloadMonitor.shared.update(id, fraction: fraction) }
                }
                Task { @MainActor in
                    DownloadMonitor.shared.began(id, url: url, isAirDrop: isAirDrop, fraction: progress.fractionCompleted, observation: observation)
                }
                return {
                    let completed = !progress.isCancelled && (progress.isFinished || progress.fractionCompleted > 0.98)
                    Task { @MainActor in DownloadMonitor.shared.ended(id, url: url, isAirDrop: isAirDrop, completed: completed) }
                }
            }
        } else {
            if let subscriber { Progress.removeSubscriber(subscriber) }
            subscriber = nil
            watcher = nil
            observations.removeAll()
            active.removeAll()
        }
    }

    private func began(_ id: String, url: URL, isAirDrop: Bool, fraction: Double, observation: NSKeyValueObservation) {
        observations[id] = observation
        guard !active.contains(where: { $0.id == id }) else { return }
        active.append(DownloadItem(id: id, name: Self.finalName(for: url), fraction: max(0, fraction), isAirDrop: isAirDrop))
    }

    private func update(_ id: String, fraction: Double) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        // Whole percents are enough and keep redraws down.
        let rounded = (fraction * 100).rounded() / 100
        guard rounded != active[index].fraction else { return }
        active[index].fraction = rounded
    }

    private func ended(_ id: String, url: URL, isAirDrop: Bool, completed: Bool) {
        observations[id] = nil
        active.removeAll { $0.id == id }
        guard completed else { return }
        // The browser renames the file (drops .download/.crdownload) just
        // after it stops publishing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            DownloadMonitor.shared.announce(Self.finalURL(for: url), isAirDrop: isAirDrop)
        }
    }

    private func announce(_ url: URL, isAirDrop: Bool) {
        let now = Date()
        announced = announced.filter { now.timeIntervalSince($0.value) < 60 }
        guard announced[url.path] == nil else { return }
        announced[url.path] = now
        lastFinished = FinishedDownload(url: url, isAirDrop: isAirDrop)
        finishRevision &+= 1
    }

    /// New names in ~/Downloads: report finished downloaded files that no
    /// progress covers. Partial files and files the user moved in (no
    /// quarantine tag) are skipped.
    private func filesAppeared(_ urls: [URL]) {
        let candidates = urls.filter { url in
            !Self.partialExtensions.contains(url.pathExtension.lowercased())
                && FolderWatcher.hasAttribute("com.apple.quarantine", at: url)
        }
        guard !candidates.isEmpty else { return }
        // Give a publishing browser's own "finished" a moment to arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let monitor = DownloadMonitor.shared
            for url in candidates {
                let stillRunning = monitor.active.contains { $0.name == url.lastPathComponent }
                guard !stillRunning, FileManager.default.fileExists(atPath: url.path) else { continue }
                let agent = (try? String(contentsOfQuarantineOf: url)) ?? ""
                monitor.announce(url, isAirDrop: agent.localizedCaseInsensitiveContains("sharingd") || agent.localizedCaseInsensitiveContains("airdrop"))
            }
        }
    }

    private static let partialExtensions = ["download", "crdownload", "part", "partial"]

    nonisolated static func finalName(for url: URL) -> String {
        finalURL(for: url, checkingDisk: false).lastPathComponent
    }

    nonisolated static func finalURL(for url: URL, checkingDisk: Bool = true) -> URL {
        var candidate = url
        while partialExtensions.contains(candidate.pathExtension.lowercased()) {
            candidate = candidate.deletingPathExtension()
        }
        if checkingDisk, candidate != url,
           !FileManager.default.fileExists(atPath: candidate.path),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return candidate
    }

    func open(_ download: FinishedDownload) {
        NSWorkspace.shared.open(download.url)
    }

    func reveal(_ download: FinishedDownload) {
        NSWorkspace.shared.activateFileViewerSelecting([download.url])
    }

    #if DEBUG
    /// Debug builds: fake a download for checking the wings and the HUD.
    func debugSimulate(name: String) {
        let id = "debug-\(name)"
        active.append(DownloadItem(id: id, name: name, fraction: 0.42, isAirDrop: false))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.active.removeAll { $0.id == id }
            self.announce(
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/\(name)"),
                isAirDrop: false
            )
        }
    }
    #endif
}

// MARK: - Shortcuts

/// The user's Shortcuts, listed and run through the `shortcuts` tool.
@MainActor
final class ShortcutsManager: ObservableObject {
    static let shared = ShortcutsManager()

    enum RunState: Equatable { case running, succeeded, failed }

    @Published private(set) var available: [String] = []
    @Published private(set) var states: [String: RunState] = [:]
    @Published private(set) var isLoading = false

    private init() {}

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            let output = Self.runTool(["list"]).output
            let names = output
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            DispatchQueue.main.async {
                let manager = ShortcutsManager.shared
                manager.isLoading = false
                let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                if sorted != manager.available { manager.available = sorted }
            }
        }
    }

    func run(_ name: String) {
        guard states[name] != .running else { return }
        states[name] = .running
        DispatchQueue.global(qos: .userInitiated).async {
            let succeeded = Self.runTool(["run", name]).status == 0
            DispatchQueue.main.async {
                let manager = ShortcutsManager.shared
                manager.states[name] = succeeded ? .succeeded : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if manager.states[name] != .running { manager.states[name] = nil }
                }
            }
        }
    }

    func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    nonisolated private static func runTool(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private extension String {
    /// The quarantine tag's text ("flags;time;agent;id"), e.g. to tell an
    /// AirDrop from a browser download.
    init(contentsOfQuarantineOf url: URL) throws {
        let length = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard length > 0 else { throw CocoaError(.fileReadNoSuchFile) }
        var buffer = [UInt8](repeating: 0, count: length)
        getxattr(url.path, "com.apple.quarantine", &buffer, length, 0, 0)
        self = String(decoding: buffer, as: UTF8.self)
    }
}
