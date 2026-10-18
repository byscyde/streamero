import Foundation

public enum SleepTimerOption: Sendable, Equatable, Hashable, Identifiable {
    case minutes(Int)
    case endOfTrack

    public var id: String {
        switch self {
        case .minutes(let m): "m\(m)"
        case .endOfTrack: "eot"
        }
    }

    public var title: String {
        switch self {
        case .minutes(let m): m >= 60 ? "\(m / 60) h\(m % 60 > 0 ? " \(m % 60) min" : "")" : "\(m) min"
        case .endOfTrack: "End of track"
        }
    }

    public static let presets: [SleepTimerOption] = [.minutes(5), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfTrack]
}

public struct SleepTimerState: Sendable, Equatable {
    public var option: SleepTimerOption
    public var fireDate: Date?

    public init(option: SleepTimerOption, now: Date = Date()) {
        self.option = option
        if case .minutes(let m) = option { fireDate = now.addingTimeInterval(TimeInterval(m * 60)) }
    }

    public func remaining(now: Date = Date()) -> TimeInterval? { fireDate.map { max(0, $0.timeIntervalSince(now)) } }
    public func isDue(now: Date = Date()) -> Bool { fireDate.map { now >= $0 } ?? false }
    /// Volume factor for a gentle 10 s fade before the timer fires.
    public func fadeVolume(now: Date = Date()) -> Float {
        guard let r = remaining(now: now) else { return 1 }
        return r >= 10 ? 1 : Float(max(0, r / 10))
    }
}
