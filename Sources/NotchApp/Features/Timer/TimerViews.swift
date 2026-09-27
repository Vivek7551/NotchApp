import SwiftUI

/// Home page card: pick a preset or Pomodoro; shows progress while running.
struct TimerCard: View {
    @ObservedObject var timer: TimerService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(title: timer.title, systemImage: timer.mode == .pomodoro ? "leaf.fill" : "timer")
            if timer.isActive {
                runningView
            } else {
                presetsView
            }
        }
        .cardStyle()
    }

    private var presetsView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach([5, 15, 25], id: \.self) { minutes in
                    ChipButton(title: "\(minutes)m") { timer.start(minutes: minutes) }
                }
            }
            ChipButton(title: "Pomodoro", systemImage: "leaf.fill", tint: .orange) {
                timer.startPomodoro()
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var runningView: some View {
        let isPaused = if case .paused = timer.runState { true } else { false }

        return HStack(spacing: 12) {
            // Only redraws while the notch is open (this view exists only then).
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: timer.progress(at: context.date))
                        .stroke(.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: context.date)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                TimerCountdownText(timer: timer)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isPaused ? .secondary : .primary)
                HStack(spacing: 6) {
                    IconButton(systemImage: isPaused ? "play.fill" : "pause.fill") {
                        isPaused ? timer.resume() : timer.pause()
                    }
                    IconButton(systemImage: "stop.fill", tint: .red) { timer.stop() }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// "12:34", counting down live. `Text(timerInterval:)` is updated by the
/// system each second without re-running our view code.
struct TimerCountdownText: View {
    @ObservedObject var timer: TimerService

    var body: some View {
        switch timer.runState {
        case .running(let endDate):
            let now = Date()
            Text(timerInterval: now...max(now, endDate), countsDown: true, showsHours: false)
        case .paused(let remaining):
            Text(Self.format(remaining))
        case .idle:
            Text("0:00")
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
