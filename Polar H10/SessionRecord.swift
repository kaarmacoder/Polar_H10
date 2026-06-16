//
//  SessionRecord.swift
//  Polar H10
//
//  Consolidated, persisted summary of a finished capture session, plus the
//  store that lists / reads / writes / deletes them. The raw streams already
//  live on disk as CSVs (see SessionWriter); this adds a `meta.json` per
//  session folder holding the derived metrics so the History dashboard can
//  show everything without re-parsing megabytes of CSV, while the CSVs remain
//  the source of truth for a complete (uncapped) Health export.
//

import Foundation

/// All the consolidated information about one recorded session.
struct SessionRecord: Codable, Identifiable, Equatable {
    var stamp: String              // "yyyy-MM-dd_HH-mm-ss" — folder + file key
    var startedAt: Date
    var endedAt: Date
    var deviceName: String?
    var durationSeconds: Int

    var calories: Double
    var steps: Int

    var avgHr: Int
    var maxHr: Int
    var minHr: Int

    var rmssd: Double              // ms
    var sdnn: Double               // ms
    var pnn50: Double              // %
    var respiration: Int           // breaths/min
    var vo2max: Double             // ml·kg⁻¹·min⁻¹
    var trimp: Double

    var timeInZone: [Double]       // seconds in Z1…Z5 (5 entries)

    var hrSampleCount: Int
    var ecgSampleCount: Int
    var accSampleCount: Int

    var id: String { stamp }
    var totalZoneTime: Double { timeInZone.reduce(0, +) }

    /// Decoding tolerant of records written by older builds (missing fields).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stamp = try c.decode(String.self, forKey: .stamp)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        calories = try c.decodeIfPresent(Double.self, forKey: .calories) ?? 0
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0
        avgHr = try c.decodeIfPresent(Int.self, forKey: .avgHr) ?? 0
        maxHr = try c.decodeIfPresent(Int.self, forKey: .maxHr) ?? 0
        minHr = try c.decodeIfPresent(Int.self, forKey: .minHr) ?? 0
        rmssd = try c.decodeIfPresent(Double.self, forKey: .rmssd) ?? 0
        sdnn = try c.decodeIfPresent(Double.self, forKey: .sdnn) ?? 0
        pnn50 = try c.decodeIfPresent(Double.self, forKey: .pnn50) ?? 0
        respiration = try c.decodeIfPresent(Int.self, forKey: .respiration) ?? 0
        vo2max = try c.decodeIfPresent(Double.self, forKey: .vo2max) ?? 0
        trimp = try c.decodeIfPresent(Double.self, forKey: .trimp) ?? 0
        let zones = try c.decodeIfPresent([Double].self, forKey: .timeInZone) ?? []
        timeInZone = zones.count == 5 ? zones : [0, 0, 0, 0, 0]
        hrSampleCount = try c.decodeIfPresent(Int.self, forKey: .hrSampleCount) ?? 0
        ecgSampleCount = try c.decodeIfPresent(Int.self, forKey: .ecgSampleCount) ?? 0
        accSampleCount = try c.decodeIfPresent(Int.self, forKey: .accSampleCount) ?? 0
    }

    init(stamp: String, startedAt: Date, endedAt: Date, deviceName: String?,
         durationSeconds: Int, calories: Double, steps: Int,
         avgHr: Int, maxHr: Int, minHr: Int,
         rmssd: Double, sdnn: Double, pnn50: Double,
         respiration: Int, vo2max: Double, trimp: Double,
         timeInZone: [Double], hrSampleCount: Int,
         ecgSampleCount: Int, accSampleCount: Int) {
        self.stamp = stamp; self.startedAt = startedAt; self.endedAt = endedAt
        self.deviceName = deviceName; self.durationSeconds = durationSeconds
        self.calories = calories; self.steps = steps
        self.avgHr = avgHr; self.maxHr = maxHr; self.minHr = minHr
        self.rmssd = rmssd; self.sdnn = sdnn; self.pnn50 = pnn50
        self.respiration = respiration; self.vo2max = vo2max; self.trimp = trimp
        self.timeInZone = timeInZone.count == 5 ? timeInZone : [0, 0, 0, 0, 0]
        self.hrSampleCount = hrSampleCount
        self.ecgSampleCount = ecgSampleCount; self.accSampleCount = accSampleCount
    }
}

/// Reads, writes, lists and deletes persisted sessions. Sessions live under the
/// same `Application Support/Sessions` root that `SessionWriter` uses.
enum SessionStore {

    static let folderPrefix = "PolarH10_"

    static func directory(for stamp: String) -> URL {
        SessionWriter.sessionsRoot().appendingPathComponent("\(folderPrefix)\(stamp)", isDirectory: true)
    }
    static func metaURL(for stamp: String) -> URL {
        directory(for: stamp).appendingPathComponent("meta.json")
    }
    static func hrURL(for stamp: String) -> URL {
        directory(for: stamp).appendingPathComponent("\(stamp)_heart_rate.csv")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    // MARK: Write

    static func save(_ record: SessionRecord) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(record) else { return }
        try? data.write(to: metaURL(for: record.stamp), options: .atomic)
    }

    // MARK: List

    /// All persisted sessions, newest first. Folders without a `meta.json`
    /// (recorded before this feature, or interrupted) are recomputed from the
    /// HR CSV and migrated so they appear too.
    static func all() -> [SessionRecord] {
        let root = SessionWriter.sessionsRoot()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var records: [SessionRecord] = []
        for dir in dirs where dir.lastPathComponent.hasPrefix(folderPrefix) {
            let stamp = String(dir.lastPathComponent.dropFirst(folderPrefix.count))
            if let rec = load(stamp: stamp) {
                records.append(rec)
            } else if let rec = recompute(stamp: stamp) {
                save(rec)   // one-time migration so future loads are cheap
                records.append(rec)
            }
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    static func load(stamp: String) -> SessionRecord? {
        guard let data = try? Data(contentsOf: metaURL(for: stamp)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionRecord.self, from: data)
    }

    // MARK: Delete

    static func delete(_ stamp: String) {
        try? FileManager.default.removeItem(at: directory(for: stamp))
    }

    // MARK: HR readings (full, uncapped — for Health export)

    /// Parse the complete heart-rate CSV into readings. Streams line-by-line so
    /// even multi-hour sessions stay reasonable; the caller batches the save.
    static func readings(for stamp: String) -> [HeartRateReading] {
        guard let text = try? String(contentsOf: hrURL(for: stamp), encoding: .utf8) else { return [] }
        var out: [HeartRateReading] = []
        var isHeader = true
        text.enumerateLines { line, _ in
            if isHeader { isHeader = false; return }   // skip "time_iso,bpm,rr_ms,contact"
            if line.isEmpty { return }
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 2,
                  let date = iso.date(from: cols[0]),
                  let bpm = Int(cols[1]) else { return }
            let rrs = cols.count > 2 ? cols[2].split(separator: ";").compactMap { Int($0) } : []
            let contact = cols.count > 3 ? (cols[3] == "true") : false
            out.append(HeartRateReading(date: date, bpm: bpm, rrsMs: rrs, contact: contact))
        }
        return out
    }

    // MARK: Migration / recompute

    /// Build a record from the CSVs for a session that has no meta.json.
    private static func recompute(stamp: String) -> SessionRecord? {
        let dir = directory(for: stamp)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let rs = readings(for: stamp)
        let start = stampFormatter.date(from: stamp) ?? rs.first?.date ?? Date(timeIntervalSince1970: 0)
        let end = rs.last?.date ?? start
        let hrVals = rs.map(\.bpm).filter { $0 > 0 }
        let avg = hrVals.isEmpty ? 0 : hrVals.reduce(0, +) / hrVals.count
        let rr = rs.flatMap { $0.rrsMs.map(Double.init) }.filter { $0 > 0 }
        return SessionRecord(
            stamp: stamp, startedAt: start, endedAt: end, deviceName: nil,
            durationSeconds: max(0, Int(end.timeIntervalSince(start))),
            calories: 0, steps: 0,
            avgHr: avg, maxHr: hrVals.max() ?? 0, minHr: hrVals.min() ?? 0,
            rmssd: HeartMetricsMath.rmssd(rr), sdnn: HeartMetricsMath.sdnn(rr),
            pnn50: HeartMetricsMath.pnn50(rr), respiration: 0, vo2max: 0, trimp: 0,
            timeInZone: [0, 0, 0, 0, 0],
            hrSampleCount: rs.count, ecgSampleCount: 0, accSampleCount: 0)
    }

    // MARK: Share

    /// Zip a session's folder (all CSVs + meta.json) into the temp dir.
    /// Call off the main thread. Uses NSFileCoordinator — no dependency.
    static func makeZip(for stamp: String) -> URL? {
        let dir = directory(for: stamp)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var result: URL?
        coordinator.coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { zipped in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(folderPrefix)\(stamp).zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zipped, to: dest)) != nil {
                result = dest
            }
        }
        return result
    }
}
