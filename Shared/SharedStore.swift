//
//  SharedStore.swift
//  Polar H10
//
//  Shared between the app and the widget extension via an App Group, so the
//  home-screen widget can read the latest session summary the app writes.
//

import Foundation

struct SessionSummary: Codable, Equatable {
    var calories: Double
    var durationSeconds: Int
    var heartRate: Int
    var steps: Int
    var active: Bool
    var updatedAt: Double  // seconds since 1970
    var startedAt: Double  // seconds since 1970, 0 if no session
    var kcalPerMin: Double  // current burn rate, for widget projection
    var stepsPerMin: Double // current cadence, for widget projection

    static let empty = SessionSummary(
        calories: 0, durationSeconds: 0, heartRate: 0, steps: 0,
        active: false, updatedAt: 0, startedAt: 0, kcalPerMin: 0, stepsPerMin: 0)

    /// Tolerant decoding for summaries written by older app versions.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calories = try c.decode(Double.self, forKey: .calories)
        durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
        heartRate = try c.decode(Int.self, forKey: .heartRate)
        steps = try c.decode(Int.self, forKey: .steps)
        active = try c.decode(Bool.self, forKey: .active)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt) ?? 0
        kcalPerMin = try c.decodeIfPresent(Double.self, forKey: .kcalPerMin) ?? 0
        stepsPerMin = try c.decodeIfPresent(Double.self, forKey: .stepsPerMin) ?? 0
    }

    init(calories: Double, durationSeconds: Int, heartRate: Int, steps: Int,
         active: Bool, updatedAt: Double, startedAt: Double,
         kcalPerMin: Double, stepsPerMin: Double) {
        self.calories = calories; self.durationSeconds = durationSeconds
        self.heartRate = heartRate; self.steps = steps; self.active = active
        self.updatedAt = updatedAt; self.startedAt = startedAt
        self.kcalPerMin = kcalPerMin; self.stepsPerMin = stepsPerMin
    }

    /// Project this summary forward to `date` assuming the current rates hold —
    /// used to advance the widget between reloads without OS help.
    func projected(to date: Date) -> SessionSummary {
        guard active else { return self }
        let minutes = max(0, date.timeIntervalSince1970 - updatedAt) / 60.0
        var s = self
        s.calories = calories + kcalPerMin * minutes
        s.steps = steps + Int(stepsPerMin * minutes)
        s.durationSeconds = durationSeconds + Int(max(0, date.timeIntervalSince1970 - updatedAt))
        return s
    }
}

enum SharedStore {
    static let appGroup = "group.co.devdiv.polarh10"
    private static let key = "sessionSummary"
    private static let historyKey = "sessionHistory"
    private static let indexKey = "sessionSelectedIndex"
    static let historyLimit = 7

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    // MARK: Live summary

    static func save(_ summary: SessionSummary) {
        guard let defaults, let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> SessionSummary {
        guard let defaults,
              let data = defaults.data(forKey: key),
              let summary = try? JSONDecoder().decode(SessionSummary.self, from: data)
        else { return .empty }
        return summary
    }

    // MARK: Last-N session history

    static func loadHistory() -> [SessionSummary] {
        guard let defaults,
              let data = defaults.data(forKey: historyKey),
              let list = try? JSONDecoder().decode([SessionSummary].self, from: data)
        else { return [] }
        return list
    }

    /// Add a finished session to the front of the history (newest first), keep
    /// the last `historyLimit`, and reset the widget to show the newest.
    static func appendHistory(_ summary: SessionSummary) {
        var list = loadHistory()
        list.insert(summary, at: 0)
        if list.count > historyLimit { list.removeLast(list.count - historyLimit) }
        if let defaults, let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: historyKey)
        }
        setSelectedIndex(0)
    }

    static func selectedIndex() -> Int { defaults?.integer(forKey: indexKey) ?? 0 }

    static func setSelectedIndex(_ index: Int) { defaults?.set(index, forKey: indexKey) }

    /// Move the selected session by `delta`, clamped to the history bounds.
    static func page(by delta: Int) {
        let count = loadHistory().count
        guard count > 0 else { return }
        let next = min(max(selectedIndex() + delta, 0), count - 1)
        setSelectedIndex(next)
    }
}
