import AppKit
import Combine
import EventKit

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
