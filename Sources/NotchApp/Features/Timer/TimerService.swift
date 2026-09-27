import AppKit

/// A countdown timer with an optional Pomodoro mode
/// (25 min focus → 5 min break, with a 15 min break after every 4th focus).
@MainActor
final class TimerService: ObservableObject {
    enum Mode: Equatable { case simple, pomodoro }

    enum Phase: Equatable {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus: "Focus"
            case .shortBreak: "Short break"
            case .longBreak: "Long break"
            }
        }

        var duration: TimeInterval {
            switch self {
            case .focus: 25 * 60
            case .shortBreak: 5 * 60
            case .longBreak: 15 * 60
            }
        }
    }

    enum RunState: Equatable {
        case idle
        case running(endDate: Date)
        case paused(remaining: TimeInterval)
    }

    @Published private(set) var runState: RunState = .idle
    @Published private(set) var mode: Mode = .simple
    @Published private(set) var phase: Phase = .focus
    @Published private(set) var completedFocusSessions = 0
    @Published private(set) var totalDuration: TimeInterval = 0

    /// Called when a countdown ends, with a short message for the notch.
    var onFinished: ((_ message: String) -> Void)?

    private var completion: DispatchWorkItem?

    var isActive: Bool { runState != .idle }

    var title: String {
        guard mode == .pomodoro else { return "Timer" }
        return phase == .focus ? "Focus · \(completedFocusSessions % 4 + 1)/4" : phase.title
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        switch runState {
        case .idle: 0
        case .running(let endDate): max(0, endDate.timeIntervalSince(date))
        case .paused(let remaining): remaining
        }
    }

    func progress(at date: Date = Date()) -> Double {
        totalDuration > 0 ? 1 - remaining(at: date) / totalDuration : 0
    }

    // MARK: - Controls

    func start(minutes: Int) {
        mode = .simple
        begin(duration: TimeInterval(minutes * 60))
    }

    func startPomodoro() {
        mode = .pomodoro
        phase = .focus
        completedFocusSessions = 0
        begin(duration: phase.duration)
    }

    func pause() {
        guard case .running = runState else { return }
        completion?.cancel()
        runState = .paused(remaining: remaining())
    }

    func resume() {
        guard case .paused(let remaining) = runState else { return }
        schedule(remaining)
    }

    func stop() {
        completion?.cancel()
        runState = .idle
        mode = .simple
    }

    // MARK: - Internals

    private func begin(duration: TimeInterval) {
        totalDuration = duration
        schedule(duration)
    }

    /// One wake-up at the end time, instead of ticking every second.
    /// `wallDeadline` keeps counting while the Mac sleeps.
    private func schedule(_ remaining: TimeInterval) {
        completion?.cancel()
        runState = .running(endDate: Date().addingTimeInterval(remaining))
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + remaining, execute: item)
        completion = item
    }

    private func finish() {
        NSSound(named: "Glass")?.play()

        guard mode == .pomodoro else {
            runState = .idle
            onFinished?("Time's up")
            return
        }
        // Pomodoro: move to the next phase automatically.
        if phase == .focus {
            completedFocusSessions += 1
            phase = completedFocusSessions % 4 == 0 ? .longBreak : .shortBreak
            onFinished?("Break time")
        } else {
            phase = .focus
            onFinished?("Focus time")
        }
        begin(duration: phase.duration)
    }
}

#if DEBUG
extension TimerService {
    func showPreview(remaining: TimeInterval, total: TimeInterval, pomodoro: Bool) {
        mode = pomodoro ? .pomodoro : .simple
        phase = .focus
        totalDuration = total
        runState = .running(endDate: Date().addingTimeInterval(remaining))
    }
}
#endif
