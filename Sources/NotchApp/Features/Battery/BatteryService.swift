import Foundation
import IOKit.ps

struct BatteryStatus: Equatable {
    var percent: Int
    var isPluggedIn: Bool
    var isCharging: Bool
    /// Minutes until empty (on battery) or full (charging), if macOS knows.
    var minutesRemaining: Int?

    var symbolName: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var isLow: Bool { !isPluggedIn && percent <= 20 }

    var stateText: String {
        if isCharging { return "Charging" }
        if isPluggedIn { return percent >= 100 ? "Charged" : "Plugged in" }
        return "On battery"
    }
}

/// Watches the battery using IOKit's power-source notifications. macOS calls
/// us only when something changes, so this costs nothing while idle.
@MainActor
final class BatteryService: ObservableObject {
    enum Event {
        case pluggedIn(BatteryStatus)
        case unplugged(BatteryStatus)
        case low(BatteryStatus)
    }

    @Published private(set) var status: BatteryStatus?
    var onEvent: ((Event) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var lowWarningsShown: Set<Int> = []
    private static let lowThresholds = [20, 10, 5]

    func start() {
        guard runLoopSource == nil else { return }
        refresh(notify: false)

        // IOKit takes a plain C callback, so we pass `self` through a raw pointer.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.refresh(notify: true) }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    private func refresh(notify: Bool) {
        let previous = status
        guard let current = Self.readStatus() else {
            status = nil // desktop Mac, no battery
            return
        }
        status = current
        guard notify, let previous else { return }

        if current.isPluggedIn && !previous.isPluggedIn {
            lowWarningsShown.removeAll()
            onEvent?(.pluggedIn(current))
        } else if !current.isPluggedIn && previous.isPluggedIn {
            onEvent?(.unplugged(current))
        } else if !current.isPluggedIn,
                  let threshold = Self.lowThresholds.last(where: { current.percent <= $0 }),
                  !lowWarningsShown.contains(threshold) {
            lowWarningsShown.insert(threshold)
            onEvent?(.low(current))
        }
    }

    private static func readStatus() -> BatteryStatus? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            let isPluggedIn = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = info[minutesKey] as? Int

            return BatteryStatus(
                percent: current * 100 / max,
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil
            )
        }
        return nil
    }
}

#if DEBUG
extension BatteryService {
    func showPreview(_ status: BatteryStatus) { self.status = status }
}
#endif
