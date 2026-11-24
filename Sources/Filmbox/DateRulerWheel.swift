import AppKit

/// Receding size and contrast suggest a wheel without moving date coordinates
/// or adding ticks. Geometry, hit testing and the compact calendar stay intact.
enum DateRulerWheelStyle {
    struct Depth {
        let scale: CGFloat
        let opacity: CGFloat
    }
    static func depth(at position: CGFloat, centre: CGFloat, extent: CGFloat, reduceMotion: Bool) -> Depth {
        let distance = min(1, abs(position - centre) / max(1, extent / 2))
        let depth = cos(distance * .pi / 2)
        return Depth(scale: reduceMotion ? 1 : 0.84 + depth * 0.16,
                     opacity: 0.24 + depth * 0.76)
    }
}

/// Mouse drags coast in ruler points. Trackpads already supply their own
/// momentum events and never pass through this integrator a second time.
@MainActor final class DateRulerWheelMotion {
    struct Coast {
        private(set) var velocity: Double
        private(set) var elapsed = 0.0
        init(velocity: Double, maximumTravel: Double) {
            self.velocity = min(maximumTravel / 0.22, max(-maximumTravel / 0.22, velocity))
        }
        var isFinished: Bool { abs(velocity) < 8 || elapsed >= 1.1 }
        mutating func advance(by interval: Double) -> Double {
            let dt = max(0, min(0.05, interval))
            let decay = exp(-dt / 0.22)
            let delta = velocity * 0.22 * (1 - decay)
            velocity *= decay; elapsed += dt
            return delta
        }
    }
    private var lastPosition = 0.0
    private var lastTime: Double?
    private var velocity = 0.0
    private var samples = 0
    private var task: Task<Void, Never>?
    private var lastHapticTime = 0.0
    private(set) var isCoasting = false
    private(set) var expectedPosition: Double?

    func stop() {
        task?.cancel(); task = nil; isCoasting = false
        velocity = 0; samples = 0; lastTime = nil; expectedPosition = nil
    }
    func begin(at position: Double, time: Double = ProcessInfo.processInfo.systemUptime) {
        stop(); lastPosition = position; lastTime = time
    }
    func sample(at position: Double, time: Double = ProcessInfo.processInfo.systemUptime) {
        guard let lastTime, abs(position - lastPosition) > 0.02 else { return }
        let dt = time - lastTime
        if dt >= 1 / 240.0, dt <= 0.12 {
            let next = min(2200, max(-2200, (position - lastPosition) / dt))
            velocity = samples == 0 ? next : velocity * 0.35 + next * 0.65
            samples += 1
        } else if dt > 0.12 { velocity = 0; samples = 0 }
        lastPosition = position; self.lastTime = time
    }
    func noteDetent(from oldIndex: Int, to index: Int, enabled: Bool) {
        guard enabled, oldIndex != index, oldIndex >= 0, index >= 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHapticTime >= 0.10 else { return }
        lastHapticTime = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    func reconcile(position: Double) {
        if let expectedPosition, abs(position - expectedPosition) > 0.5 { stop() }
    }
    func finish(time: Double = ProcessInfo.processInfo.systemUptime, reduceMotion: Bool,
                maximumTravel: Double, advance: @escaping (Double) -> Double?) {
        let speed = velocity, sampleTime = lastTime, count = samples, position = lastPosition
        stop()
        guard !reduceMotion, maximumTravel.isFinite, maximumTravel > 0,
              let sampleTime, time - sampleTime <= 0.10, count >= 2, abs(speed) >= 60 else { return }
        expectedPosition = position; isCoasting = true
        task = Task { @MainActor [weak self] in
            var coast = Coast(velocity: speed, maximumTravel: maximumTravel)
            var previousTime = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled, !coast.isFinished {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let delta = coast.advance(by: now - previousTime)
                previousTime = now
                guard let position = advance(delta), let previous = self.expectedPosition,
                      abs(position - previous) > 0.001 else { self.stop(); return }
                self.expectedPosition = position
            }
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
}
