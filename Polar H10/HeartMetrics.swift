//
//  HeartMetrics.swift
//  Polar H10
//
//  Metrics derived from the heart-rate + RR-interval stream: HRV, HR zones,
//  training load, respiration and a live VO₂max estimate.
//

import Foundation

/// One heart-rate training zone (percentage-of-max model). Shared by the live
/// dashboard legend, the time-in-zone bars and the session history.
struct HRZoneInfo: Identifiable {
    let zone: Int        // 1…5
    let lowerPct: Int    // % of max HR (inclusive lower bound)
    let upperPct: Int    // % of max HR (exclusive upper bound, 100 for Z5)
    let name: String
    let purpose: String
    var id: Int { zone }

    /// "50–60%" style label.
    var rangeLabel: String { "\(lowerPct)–\(upperPct)%" }
}

enum HRZones {
    /// The five %-of-max-HR zones, matching `HeartMetricsMath.zone(...)`.
    static let all: [HRZoneInfo] = [
        HRZoneInfo(zone: 1, lowerPct: 50, upperPct: 60,  name: "Very light", purpose: "Warm-up & recovery"),
        HRZoneInfo(zone: 2, lowerPct: 60, upperPct: 70,  name: "Light",      purpose: "Fat burn, base endurance"),
        HRZoneInfo(zone: 3, lowerPct: 70, upperPct: 80,  name: "Moderate",   purpose: "Aerobic, tempo"),
        HRZoneInfo(zone: 4, lowerPct: 80, upperPct: 90,  name: "Hard",       purpose: "Anaerobic threshold"),
        HRZoneInfo(zone: 5, lowerPct: 90, upperPct: 100, name: "Maximum",    purpose: "VO₂max effort"),
    ]

    /// BPM range for a zone given a max HR, e.g. "120–140 bpm".
    static func bpmRange(_ info: HRZoneInfo, maxHr: Int) -> String {
        guard maxHr > 0 else { return "—" }
        let lo = Int((Double(info.lowerPct) / 100 * Double(maxHr)).rounded())
        let hi = Int((Double(info.upperPct) / 100 * Double(maxHr)).rounded())
        return "\(lo)–\(hi) bpm"
    }
}

struct HeartMetrics: Equatable {
    var rmssd: Double = 0          // ms
    var sdnn: Double = 0           // ms
    var pnn50: Double = 0          // %
    var maxHr: Int = 0             // observed peak since connect
    var minHr: Int = 0             // observed low since connect
    var currentZone: Int = 0       // 0 = rest, 1…5
    var timeInZone: [Double] = [0, 0, 0, 0, 0] // seconds in Z1…Z5
    var trimp: Double = 0          // Banister training load
    var respiration: Int = 0       // breaths/min (estimate)
    var vo2maxEstimate: Double = 0 // ml·kg⁻¹·min⁻¹ (estimate)

    var totalZoneTime: Double { timeInZone.reduce(0, +) }
}

enum HeartMetricsMath {

    static func rmssd(_ rr: [Double]) -> Double {
        guard rr.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<rr.count {
            let d = rr[i] - rr[i - 1]
            sum += d * d
        }
        return (sum / Double(rr.count - 1)).squareRoot()
    }

    static func sdnn(_ rr: [Double]) -> Double {
        guard rr.count > 1 else { return 0 }
        let mean = rr.reduce(0, +) / Double(rr.count)
        let variance = rr.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rr.count - 1)
        return variance.squareRoot()
    }

    static func pnn50(_ rr: [Double]) -> Double {
        guard rr.count > 1 else { return 0 }
        var count = 0
        for i in 1..<rr.count where abs(rr[i] - rr[i - 1]) > 50 { count += 1 }
        return Double(count) / Double(rr.count - 1) * 100
    }

    /// HR training zone (0 = rest/recovery below 50% HRmax, 1…5 otherwise).
    static func zone(hr: Int, maxHr: Int) -> Int {
        guard maxHr > 0, hr > 0 else { return 0 }
        let p = Double(hr) / Double(maxHr)
        switch p {
        case ..<0.5: return 0
        case ..<0.6: return 1
        case ..<0.7: return 2
        case ..<0.8: return 3
        case ..<0.9: return 4
        default:     return 5
        }
    }

    /// Banister TRIMP per minute for the given heart rate.
    static func trimpPerMinute(hr: Int, rest: Int, max: Int, isMale: Bool) -> Double {
        let denom = Double(max - rest)
        guard denom > 0 else { return 0 }
        let hrr = min(1, Swift.max(0, (Double(hr) - Double(rest)) / denom))
        let k = isMale ? 0.64 * exp(1.92 * hrr) : 0.86 * exp(1.67 * hrr)
        return hrr * k
    }

    /// Estimate respiration (breaths/min) from the RR tachogram by counting the
    /// respiratory-sinus-arrhythmia oscillation cycles within a time window.
    /// `beats` is a list of (cumulative time in seconds, RR in ms).
    static func respiration(beats: [(t: Double, rr: Double)], windowSec: Double) -> Int {
        guard let lastT = beats.last?.t else { return 0 }
        let window = beats.filter { $0.t >= lastT - windowSec }
        guard window.count > 4 else { return 0 }
        let values = window.map { $0.rr }
        let mean = values.reduce(0, +) / Double(values.count)
        let detrended = values.map { $0 - mean }
        // Count upward zero-crossings = number of breathing cycles.
        var crossings = 0
        for i in 1..<detrended.count where detrended[i - 1] <= 0 && detrended[i] > 0 {
            crossings += 1
        }
        let durationMin = (window.last!.t - window.first!.t) / 60
        guard durationMin > 0 else { return 0 }
        let bpm = Double(crossings) / durationMin
        // Plausible physiological range.
        return bpm >= 4 && bpm <= 40 ? Int(bpm.rounded()) : 0
    }

    /// Uth–Sørensen VO₂max estimate from max and resting heart rate.
    static func vo2max(maxHr: Int, restingHr: Int) -> Double {
        guard restingHr > 0, maxHr > restingHr else { return 0 }
        return 15.3 * Double(maxHr) / Double(restingHr)
    }

    /// Rough rhythm steadiness from RR-interval variability (NOT a diagnosis).
    static func rhythm(_ rr: [Double]) -> String {
        guard rr.count >= 8 else { return "Analyzing…" }
        let recent = Array(rr.suffix(30))
        let mean = recent.reduce(0, +) / Double(recent.count)
        guard mean > 0 else { return "Analyzing…" }
        let cov = sdnn(recent) / mean
        switch cov {
        case ..<0.06: return "Regular"
        case ..<0.12: return "Slightly irregular"
        default:      return "Irregular"
        }
    }
}
