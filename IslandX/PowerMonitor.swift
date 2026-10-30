import Foundation
import IOKit.ps

/// Samples macOS power-source information without requiring a privileged API.
/// A revision is emitted only when the Mac transitions from battery power to an
/// external power source, which lets the UI play one short charging animation.
@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var isConnectedToPower = false
    @Published private(set) var isCharging = false
    @Published private(set) var batteryPercentage: Int?
    @Published private(set) var connectionRevision = 0

    private var timer: Timer?
    private var hasSampledPowerState = false

    func startMonitoring() {
        guard timer == nil else { return }

        refresh()
        timer = Timer.scheduledTimer(
            withTimeInterval: 1.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        else {
            return
        }

        let sourceType = IOPSGetProvidingPowerSourceType(snapshot)?
            .takeUnretainedValue() as String?
        let connected = sourceType == (kIOPSACPowerValue as String)

        var charging = false
        var percentage: Int?

        if let sources = IOPSCopyPowerSourcesList(snapshot)?
            .takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(
                    snapshot,
                    source
                )?.takeUnretainedValue() as? [String: Any] else {
                    continue
                }

                charging = description[kIOPSIsChargingKey as String]
                    as? Bool ?? false

                let current = description[kIOPSCurrentCapacityKey as String]
                    as? NSNumber
                let maximum = description[kIOPSMaxCapacityKey as String]
                    as? NSNumber

                if let current, let maximum, maximum.doubleValue > 0 {
                    percentage = Int(
                        (
                            (current.doubleValue / maximum.doubleValue) * 100
                        ).rounded()
                    )
                }
                break
            }
        }

        if hasSampledPowerState,
           connected,
           !isConnectedToPower {
            connectionRevision &+= 1
        }

        isConnectedToPower = connected
        isCharging = charging
        batteryPercentage = percentage
        hasSampledPowerState = true
    }
}
