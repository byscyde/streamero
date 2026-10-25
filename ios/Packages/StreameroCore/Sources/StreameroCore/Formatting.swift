import Foundation

public enum Format {
    /// 3:07, 1:02:03; negative values render as "-0:42" for remaining time.
    public static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--:--" }
        let negative = seconds < 0
        let total = Int(abs(seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let body = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return negative ? "-" + body : body
    }

    /// "1 h 12 min", "42 min"
    public static func longDuration(ms: Int) -> String {
        let minutes = ms / 60_000
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return "\(max(1, minutes)) min"
    }

    public static func bytes(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(count)
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(count) B" : String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    /// Compact count with three significant digits: 950, 7.92K, 23.1M, 118M, 3.6B.
    public static func compact(_ n: Int) -> String {
        let v = Double(abs(n))
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        guard let (scale, suffix) = units.first(where: { v >= $0.0 }) else { return String(n) }
        var x = v / scale
        // Rounding can carry into the next unit (999.95K → 1M).
        if x >= 999.5, suffix != "B" { return compact(n.signum() * Int(scale * 1000)) }
        let decimals = x < 10 ? 2 : x < 100 ? 1 : 0
        let factor = pow(10, Double(decimals))
        x = (x * factor).rounded() / factor
        var text = String(format: "%.\(decimals)f", x)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return (n < 0 ? "-" : "") + text + suffix
    }

    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}

/// Coalesces rapid calls (e.g. keystrokes) and cancels superseded work.
public actor Debouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    public init(delay: Duration) { self.delay = delay }

    public func submit(_ operation: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    public func cancel() { task?.cancel(); task = nil }
}
