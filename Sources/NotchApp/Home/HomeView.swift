import SwiftUI

/// The Home page: clock & battery, timer, and clipboard history.
struct HomeView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 10) {
            ClockCard(battery: vm.battery.status)
                .frame(width: 150)
            TimerCard(timer: vm.timer)
                .frame(width: 196)
            ClipboardCard(clipboard: vm.clipboard, isEnabled: vm.settings.clipboardHistoryEnabled)
        }
    }
}

private struct ClockCard: View {
    let battery: BatteryStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(context.date, format: .dateTime.weekday(.wide).month().day())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let battery {
                HStack(spacing: 5) {
                    Image(systemName: battery.symbolName)
                        .foregroundStyle(battery.isCharging ? .green : battery.isLow ? .red : .secondary)
                    Text("\(battery.percent)% · \(battery.stateText)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
        .cardStyle()
    }
}

/// Header used by each card.
struct CardTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// A small pill-shaped button.
struct ChipButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = .white
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(isHovering ? 0.25 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A round icon button.
struct IconButton: View {
    let systemImage: String
    var tint: Color = .white
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(isHovering ? 0.25 : 0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

extension View {
    /// The rounded translucent background used for Home page cards.
    func cardStyle() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
    }
}

/// True while rendering `--snapshot` images. ImageRenderer can't draw
/// AppKit-backed views like ScrollView, so views swap in plain stand-ins.
private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}
