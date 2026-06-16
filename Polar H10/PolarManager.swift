//
//  PolarManager.swift
//  Polar H10
//
//  Wraps the Polar BLE SDK (PolarBleSdk 8.x) and exposes a SwiftUI-friendly,
//  observable interface for: discovery, connect/disconnect, connection status,
//  live HR streaming, and start/pause/stop recording control.
//

import Foundation
import Combine
import CoreBluetooth
import WidgetKit
import PolarBleSdk

/// A single discovered device row.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: String          // Polar deviceId (e.g. "B1234567")
    let name: String        // advertised name, e.g. "Polar H10 B1234567"
    var rssi: Int
    let connectable: Bool
}

/// One heart-rate reading captured while recording.
struct HeartRateReading: Identifiable {
    let id = UUID()
    let date: Date
    let bpm: Int
    let rrsMs: [Int]
    let contact: Bool
}

/// One ECG sample (microvolts) captured while recording.
struct EcgSample: Identifiable {
    let index: Int
    let timeStamp: UInt64
    let microvolts: Int
    var id: Int { index }
}

/// A baseline-filtered ECG point for the on-screen waveform.
struct EcgPoint: Identifiable {
    let index: Int
    let microvolts: Double
    var id: Int { index }
}

/// One accelerometer sample (milli-g per axis) captured while recording.
struct AccSample: Identifiable {
    let index: Int
    let timeStamp: UInt64
    let x: Int
    let y: Int
    let z: Int
    var id: Int { index }
}

/// High-level connection state for the UI.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

@MainActor
final class PolarManager: NSObject, ObservableObject {

    // MARK: Published UI state

    @Published var bluetoothOn: Bool = false
    @Published var isSearching: Bool = false
    @Published var discovered: [DiscoveredDevice] = []

    @Published var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectedDeviceId: String?
    @Published private(set) var connectedDeviceName: String?

    /// True whenever the live HR stream is running (auto-started on connect).
    @Published var hrStreaming: Bool = false

    /// Latest live values for the dashboard.
    @Published var currentHr: Int = 0
    @Published var currentRr: [Int] = []
    @Published var contactDetected: Bool = false
    @Published var batteryLevel: Int?
    @Published var hrFeatureReady: Bool = false

    /// Heart-derived metrics (HRV, zones, training load, respiration, VO₂max),
    /// computed continuously while connected.
    @Published var metrics = HeartMetrics()

    /// Rolling buffer of readings captured during the current recording session.
    @Published private(set) var readings: [HeartRateReading] = []

    @Published var onlineStreamingReady: Bool = false

    // Calories (HR-based, accumulated during the HR recording session)
    @Published var sessionCalories: Double = 0
    @Published var sessionSeconds: Int = 0
    /// Current profile used by the calorie model; kept in sync with `ProfileStore`.
    var profile: UserProfile = .default

    // Unified capture session (HR + ECG + ACC together) for the Calories tab.
    @Published var sessionActive: Bool = false
    @Published var lastSessionZipURL: URL?
    private(set) var sessionStartDate: Date?

    // ECG (Feature: live electrocardiography recording)
    @Published var ecgStreaming: Bool = false
    @Published var currentEcgUv: Int = 0
    @Published private(set) var ecgRecording: [EcgSample] = []

    // ACC (Feature: live accelerometer / motion recording)
    @Published var accStreaming: Bool = false
    @Published var currentAcc: (x: Int, y: Int, z: Int) = (0, 0, 0)
    @Published private(set) var accRecording: [AccSample] = []

    // Steps / cadence / activity derived from the accelerometer.
    @Published var steps: Int = 0
    @Published var cadence: Int = 0          // steps per minute
    @Published var activity: String = "—"    // Still / Walking / Running

    // Readable ECG summary.
    @Published var ecgRhythm: String = "—"   // Regular / Slightly irregular / Irregular
    @Published var ecgQuality: String = "—"  // Good / Weak signal

    /// Human-readable status / error line.
    @Published var statusMessage: String = "Idle"

    // MARK: Private

    private var api: PolarBleApi!
    private var searchTask: Task<Void, Never>?
    private var hrStreamTask: Task<Void, Never>?
    private var ecgTask: Task<Void, Never>?
    private var accTask: Task<Void, Never>?

    private var ecgIndex = 0
    private var accIndex = 0

    /// Calorie integration state.
    private var lastHrDate: Date?
    private var activeSeconds: Double = 0

    /// Heart-metrics state (reset when HR streaming starts).
    private var rrSeries: [(t: Double, rr: Double)] = [] // cumulative beat time (s), RR (ms)
    private var beatClock: Double = 0
    private var lastMetricDate: Date?
    private let rrWindowSeconds: Double = 120 // keep ~2 min of beats for HRV

    /// Step-detection state (reset when ACC streaming starts).
    private var accBaseline: Double = 0
    private var accPrimed = false
    private var prevAccDyn: Double = 0
    private var lastStepT: Double = 0
    private var recentStepT: [Double] = []

    /// Disk writer for the active session; nil when no session is running.
    private var sessionWriter: SessionWriter?
    /// Lock-screen / Dynamic Island Live Activity for the active session.
    private let liveActivity = LiveActivityController()
    /// Throttle for home-screen widget reloads during a session.
    private var lastWidgetReload: Date?
    /// User setting key: include ECG in the capture session (default true).
    private let kRecordEcg = "recordEcg"
    private var ecgRecordingEnabled: Bool {
        UserDefaults.standard.object(forKey: kRecordEcg) as? Bool ?? true
    }
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // UserDefaults keys for restoring an in-progress session after relaunch.
    private let kSessionStamp = "activeSessionStamp"
    private let kSessionStart = "activeSessionStart"
    private let kSessionDevice = "activeSessionDeviceId"

    /// Keep at most this many readings in memory for the on-screen chart.
    private let maxChartReadings = 120
    /// Hard caps to keep long recordings within memory (≈ 5 min at native rates).
    private let maxEcgSamples = 130 * 60 * 5
    private let maxAccSamples = 200 * 60 * 5

    override init() {
        super.init()
        // `restoreIdentifier` enables CoreBluetooth state restoration: iOS can
        // relaunch the app in the background and restore the connection after a
        // memory-pressure termination. CoreBluetooth throws on creation if a
        // restore identifier is supplied without the "bluetooth-central"
        // background mode, so only request it when that mode is actually present.
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        let restoreId: String? = backgroundModes.contains("bluetooth-central") ? "polar-h10-session" : nil

        api = PolarBleApiDefaultImpl.polarImplementation(
            DispatchQueue.main,
            features: [
                .feature_hr,
                .feature_battery_info,
                .feature_device_info,
                .feature_polar_online_streaming
            ],
            restoreIdentifier: restoreId
        )
        api.observer = self
        api.powerStateObserver = self
        api.deviceFeaturesObserver = self
        api.deviceInfoObserver = self

        restoreSessionIfNeeded()
    }

    /// If a session was running when the app was last terminated, reopen its
    /// files and mark it active so streaming resumes once the device reconnects.
    private func restoreSessionIfNeeded() {
        let d = UserDefaults.standard
        guard let stamp = d.string(forKey: kSessionStamp) else { return }
        let start = d.double(forKey: kSessionStart)
        sessionStartDate = start > 0 ? Date(timeIntervalSince1970: start) : Date()
        sessionWriter = SessionWriter(stamp: stamp, resume: true)
        sessionActive = true
        liveActivity.start(startedAt: sessionStartDate ?? Date(), initial: liveActivityState)
        statusMessage = "Restoring session — reconnecting…"
        // Nudge a reconnect; state restoration usually re-establishes it anyway.
        if let id = d.string(forKey: kSessionDevice) {
            connectedDeviceId = id
            try? api.connectToDevice(id)
        }
    }

    // MARK: - Discovery (Feature 1)

    func startSearch() {
        guard !isSearching else { return }
        discovered.removeAll()
        isSearching = true
        statusMessage = "Searching for devices…"

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await info in self.api.searchForDevice() {
                    await self.handleDiscovered(info)
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Search error: \(error.localizedDescription)"
                }
            }
            await MainActor.run { self.isSearching = false }
        }
    }

    func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        if connectionState == .disconnected {
            statusMessage = "Idle"
        }
    }

    private func handleDiscovered(_ info: PolarDeviceInfo) {
        if let idx = discovered.firstIndex(where: { $0.id == info.deviceId }) {
            discovered[idx].rssi = info.rssi
        } else {
            discovered.append(
                DiscoveredDevice(
                    id: info.deviceId,
                    name: info.name.isEmpty ? info.deviceId : info.name,
                    rssi: info.rssi,
                    connectable: info.connectable
                )
            )
            // Strongest signal first.
            discovered.sort { $0.rssi > $1.rssi }
        }
    }

    // MARK: - Connect / Disconnect (Feature 2)

    func connect(to device: DiscoveredDevice) {
        do {
            stopSearch()
            connectionState = .connecting
            statusMessage = "Connecting to \(device.name)…"
            try api.connectToDevice(device.id)
        } catch {
            connectionState = .disconnected
            statusMessage = "Connect failed: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        guard let id = connectedDeviceId else { return }
        // Finalize an in-progress capture session before tearing down.
        if sessionActive { stopSession() }
        stopStreaming()
        do {
            try api.disconnectFromDevice(id)
            statusMessage = "Disconnecting…"
        } catch {
            statusMessage = "Disconnect failed: \(error.localizedDescription)"
        }
    }

    // MARK: - HR streaming (always-on while connected; independent of sessions)

    /// Start the live HR stream. Called automatically once the device is
    /// connected and the HR feature is ready, so heart rate always shows.
    func startStreaming() {
        guard let id = connectedDeviceId, !hrStreaming else { return }
        hrStreaming = true
        // Fresh metrics for this connection.
        metrics = HeartMetrics()
        rrSeries.removeAll()
        beatClock = 0
        lastMetricDate = nil
        if !sessionActive { statusMessage = "Connected · streaming heart rate" }

        hrStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await samples in self.api.startHrStreaming(id) {
                    if Task.isCancelled { break }
                    await self.handleHr(samples)
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.hrStreaming = false
                        self.statusMessage = "HR stream error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Stop the live HR stream (on disconnect).
    func stopStreaming() {
        hrStreamTask?.cancel()
        hrStreamTask = nil
        hrStreaming = false
        lastHrDate = nil
        currentHr = 0
        currentRr = []
    }

    /// Discard buffered readings (after a successful Health export).
    func resetSession() {
        readings.removeAll()
    }

    private func handleHr(_ samples: PolarHrData) {
        guard let sample = samples.last else { return }
        let now = Date()
        currentHr = Int(sample.hr)
        currentRr = sample.rrsMs
        contactDetected = sample.contactStatus

        // Integrate calories only while a capture session is running.
        if sessionActive {
            if let last = lastHrDate {
                let dt = now.timeIntervalSince(last)
                if dt > 0 && dt < 10 { // ignore large gaps (dropouts)
                    let kcalPerMin = CalorieEstimator.kcalPerMinute(hr: Int(sample.hr), profile: profile)
                    sessionCalories += kcalPerMin * dt / 60.0
                    activeSeconds += dt
                    sessionSeconds = Int(activeSeconds)
                }
            }
            lastHrDate = now
        } else {
            lastHrDate = nil
        }

        updateMetrics(hr: Int(sample.hr), rrs: sample.rrsMs, contact: sample.contactStatus, now: now)

        let reading = HeartRateReading(
            date: now,
            bpm: Int(sample.hr),
            rrsMs: sample.rrsMs,
            contact: sample.contactStatus
        )
        readings.append(reading)
        if readings.count > maxChartReadings * 4 {
            // Hard cap to avoid unbounded memory on very long sessions.
            readings.removeFirst(readings.count - maxChartReadings * 4)
        }

        if let writer = sessionWriter {
            let rr = sample.rrsMs.map(String.init).joined(separator: ";")
            writer.appendHr("\(isoFormatter.string(from: now)),\(sample.hr),\(rr),\(sample.contactStatus)\n")
            liveActivity.update(liveActivityState)
            publishWidgetSummary()
        }
    }

    /// Most recent readings for the on-screen chart.
    var chartReadings: [HeartRateReading] {
        Array(readings.suffix(maxChartReadings))
    }

    /// Update the derived heart metrics from the latest sample.
    private func updateMetrics(hr: Int, rrs: [Int], contact: Bool, now: Date) {
        guard hr > 0 else { return }
        var m = metrics

        // Observed max / min (min only with good skin contact).
        m.maxHr = max(m.maxHr, hr)
        if contact { m.minHr = m.minHr == 0 ? hr : min(m.minHr, hr) }

        // Accumulate RR intervals into the rolling tachogram.
        for rr in rrs where rr > 0 {
            beatClock += Double(rr) / 1000.0
            rrSeries.append((t: beatClock, rr: Double(rr)))
        }
        if let lastT = rrSeries.last?.t {
            while let first = rrSeries.first, first.t < lastT - rrWindowSeconds {
                rrSeries.removeFirst()
            }
        }

        // HRV over the rolling window.
        let rrValues = rrSeries.map { $0.rr }
        m.rmssd = HeartMetricsMath.rmssd(rrValues)
        m.sdnn = HeartMetricsMath.sdnn(rrValues)
        m.pnn50 = HeartMetricsMath.pnn50(rrValues)
        m.respiration = HeartMetricsMath.respiration(beats: rrSeries, windowSec: 45)
        ecgRhythm = HeartMetricsMath.rhythm(rrValues)

        // HR zone + time-in-zone + training load (accumulated over elapsed time).
        let maxHr = profile.effectiveMaxHr
        m.currentZone = HeartMetricsMath.zone(hr: hr, maxHr: maxHr)
        if let last = lastMetricDate {
            let dt = now.timeIntervalSince(last)
            if dt > 0 && dt < 10 {
                if m.currentZone >= 1 && m.currentZone <= 5 {
                    m.timeInZone[m.currentZone - 1] += dt
                }
                let perMin = HeartMetricsMath.trimpPerMinute(
                    hr: hr, rest: profile.restingHr, max: maxHr, isMale: profile.sex == .male)
                m.trimp += perMin * dt / 60.0
            }
        }
        lastMetricDate = now

        // Live VO₂max estimate from observed max & resting (falls back to profile).
        let rest = m.minHr > 0 ? m.minHr : profile.restingHr
        let est = HeartMetricsMath.vo2max(maxHr: m.maxHr, restingHr: rest)
        m.vo2maxEstimate = est > 0 ? est : profile.effectiveVo2max

        metrics = m
    }

    // MARK: - ECG recording (in-app)

    func startEcg() {
        guard let id = connectedDeviceId, !ecgStreaming else { return }
        ecgStreaming = true
        statusMessage = "Recording ECG…"
        ecgTask = Task { [weak self] in
            guard let self else { return }
            do {
                let settings = try await self.api.requestStreamSettings(id, feature: .ecg)
                for try await samples in self.api.startEcgStreaming(id, settings: settings.maxSettings()) {
                    if Task.isCancelled { break }
                    await self.handleEcg(samples)
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.statusMessage = "ECG error: \(error.localizedDescription)"
                        self.ecgStreaming = false
                    }
                }
            }
        }
    }

    func stopEcg() {
        ecgTask?.cancel()
        ecgTask = nil
        ecgStreaming = false
    }

    func clearEcg() {
        ecgRecording.removeAll()
        ecgIndex = 0
        currentEcgUv = 0
        ecgQuality = "—"
    }

    private func handleEcg(_ samples: PolarEcgData) {
        var batch = ""
        for sample in samples {
            ecgRecording.append(EcgSample(index: ecgIndex, timeStamp: sample.timeStamp, microvolts: Int(sample.voltage)))
            if sessionWriter != nil { batch += "\(ecgIndex),\(sample.timeStamp),\(sample.voltage)\n" }
            ecgIndex += 1
        }
        if let last = samples.last { currentEcgUv = Int(last.voltage) }
        if ecgRecording.count > maxEcgSamples {
            ecgRecording.removeFirst(ecgRecording.count - maxEcgSamples)
        }
        if !batch.isEmpty { sessionWriter?.appendEcg(batch) }

        // Signal quality from the peak-to-peak amplitude of the last ~1 s.
        let recent = ecgRecording.suffix(130).map { $0.microvolts }
        if let lo = recent.min(), let hi = recent.max(), recent.count > 30 {
            let p2p = hi - lo
            ecgQuality = !contactDetected ? "No contact" : (p2p < 150 ? "Weak signal" : "Good")
        }
    }

    /// Most recent ECG samples for the on-screen waveform (~3 s).
    var ecgWaveform: ArraySlice<EcgSample> { ecgRecording.suffix(390) }

    /// Baseline-removed ECG for display. Raw H10 ECG has a large DC offset and
    /// low-frequency baseline wander; subtracting a centered moving average
    /// (≈0.5 s) acts as a high-pass filter so the QRS complexes are visible and
    /// the trace stays centered on zero.
    var ecgDisplayWaveform: [EcgPoint] {
        let window = Array(ecgRecording.suffix(2600)) // ~20 s at 130 Hz, scrollable
        guard window.count > 1 else { return [] }
        let raw = window.map { Double($0.microvolts) }
        let n = raw.count
        let half = 32 // ±0.25 s at 130 Hz → ~0.5 s baseline window
        // Prefix sums for an O(n) moving average.
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + raw[i] }
        var out = [EcgPoint]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n - 1, i + half)
            let baseline = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
            out.append(EcgPoint(index: window[i].index, microvolts: raw[i] - baseline))
        }
        return out
    }

    // MARK: - ACC / motion recording (in-app)

    func startAcc() {
        guard let id = connectedDeviceId, !accStreaming else { return }
        accStreaming = true
        resetStepState()
        statusMessage = "Recording motion…"
        accTask = Task { [weak self] in
            guard let self else { return }
            do {
                let settings = try await self.api.requestStreamSettings(id, feature: .acc)
                for try await samples in self.api.startAccStreaming(id, settings: settings.maxSettings()) {
                    if Task.isCancelled { break }
                    await self.handleAcc(samples)
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.statusMessage = "Motion error: \(error.localizedDescription)"
                        self.accStreaming = false
                    }
                }
            }
        }
    }

    func stopAcc() {
        accTask?.cancel()
        accTask = nil
        accStreaming = false
    }

    func clearAcc() {
        accRecording.removeAll()
        accIndex = 0
        currentAcc = (0, 0, 0)
        resetStepState()
    }

    private func resetStepState() {
        steps = 0
        cadence = 0
        activity = "Still"
        accPrimed = false
        accBaseline = 0
        prevAccDyn = 0
        lastStepT = 0
        recentStepT.removeAll()
    }

    private func handleAcc(_ samples: PolarAccData) {
        var batch = ""
        for sample in samples {
            accRecording.append(AccSample(index: accIndex, timeStamp: sample.timeStamp,
                                          x: Int(sample.x), y: Int(sample.y), z: Int(sample.z)))
            if sessionWriter != nil { batch += "\(accIndex),\(sample.timeStamp),\(sample.x),\(sample.y),\(sample.z)\n" }
            accIndex += 1
            detectStep(x: Double(sample.x), y: Double(sample.y), z: Double(sample.z),
                       tSec: Double(sample.timeStamp) / 1_000_000_000.0)
        }
        if let last = samples.last { currentAcc = (Int(last.x), Int(last.y), Int(last.z)) }
        if accRecording.count > maxAccSamples {
            accRecording.removeFirst(accRecording.count - maxAccSamples)
        }
        if !batch.isEmpty { sessionWriter?.appendAcc(batch) }
    }

    /// Peak-detect steps from the acceleration magnitude (gravity removed).
    private func detectStep(x: Double, y: Double, z: Double, tSec: Double) {
        let mag = (x * x + y * y + z * z).squareRoot()  // milli-g, includes gravity
        if !accPrimed { accBaseline = mag; accPrimed = true }
        accBaseline += 0.01 * (mag - accBaseline)        // slow EMA ≈ gravity baseline
        let dyn = mag - accBaseline

        let threshold = 120.0     // mg above baseline
        let refractory = 0.28     // s — caps cadence ≈ 214 spm
        if dyn > threshold, prevAccDyn <= threshold, tSec - lastStepT > refractory {
            steps += 1
            lastStepT = tSec
            recentStepT.append(tSec)
            if recentStepT.count > 12 { recentStepT.removeFirst(recentStepT.count - 12) }
            updateCadenceAndActivity(now: tSec)
        }
        prevAccDyn = dyn
    }

    private func updateCadenceAndActivity(now: Double) {
        // Cadence from the recent step intervals (drop steps older than 6 s).
        recentStepT.removeAll { now - $0 > 6 }
        if recentStepT.count >= 2, let first = recentStepT.first, let last = recentStepT.last, last > first {
            cadence = Int((Double(recentStepT.count - 1) / (last - first) * 60).rounded())
        } else {
            cadence = 0
        }
        switch cadence {
        case 0:        activity = "Still"
        case 1..<130:  activity = "Walking"
        default:       activity = "Running"
        }
    }

    /// Most recent ACC samples for the on-screen waveform (~2 s).
    var accWaveform: ArraySlice<AccSample> { accRecording.suffix(400) }

    // MARK: - Unified capture session (HR + ECG + ACC) for the Calories tab

    /// Start recording all three streams together as one timestamped session.
    /// The session runs until `stopSession()` — it keeps going in the background,
    /// while the screen is locked, and resumes automatically after a reconnect.
    func startSession() {
        guard connectionState == .connected, let id = connectedDeviceId, !sessionActive else { return }
        // Fresh buffers for a clean session.
        readings.removeAll()
        clearEcg()
        clearAcc()
        sessionCalories = 0
        sessionSeconds = 0
        activeSeconds = 0
        lastHrDate = nil
        lastSessionZipURL = nil

        let start = Date()
        sessionStartDate = start
        sessionWriter = SessionWriter(stamp: Self.fileStamp(start), resume: false)
        sessionActive = true

        // Persist so the session can be restored after a relaunch.
        let d = UserDefaults.standard
        d.set(Self.fileStamp(start), forKey: kSessionStamp)
        d.set(start.timeIntervalSince1970, forKey: kSessionStart)
        d.set(id, forKey: kSessionDevice)

        statusMessage = "Recording session…"
        liveActivity.start(startedAt: start, initial: liveActivityState)
        publishWidgetSummary(reload: true)
        resumeSessionStreamsIfNeeded()
    }

    /// Write the latest session summary to the App Group for the home-screen
    /// widget. Forces a timeline reload on start/stop, and throttled (~every
    /// 20 s) during an active session — iOS rate-limits widget reloads, so this
    /// is as "live" as a home-screen widget can be (use the Live Activity for
    /// true real-time).
    private func publishWidgetSummary(reload: Bool = false) {
        SharedStore.save(SessionSummary(
            calories: sessionCalories,
            durationSeconds: sessionSeconds,
            heartRate: currentHr,
            steps: steps,
            active: sessionActive,
            updatedAt: Date().timeIntervalSince1970,
            startedAt: sessionActive ? (sessionStartDate?.timeIntervalSince1970 ?? 0) : 0,
            kcalPerMin: sessionActive ? CalorieEstimator.kcalPerMinute(hr: currentHr, profile: profile) : 0,
            stepsPerMin: sessionActive ? Double(cadence) : 0
        ))
        var shouldReload = reload
        if sessionActive, !reload {
            let now = Date()
            if let last = lastWidgetReload {
                if now.timeIntervalSince(last) >= 20 { shouldReload = true }
            } else {
                shouldReload = true
            }
            if shouldReload { lastWidgetReload = now }
        }
        if shouldReload { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Current values packaged for the Live Activity.
    private var liveActivityState: SessionActivityAttributes.ContentState {
        SessionActivityAttributes.ContentState(
            calories: sessionCalories,
            durationSeconds: sessionSeconds,
            heartRate: currentHr,
            steps: steps
        )
    }

    /// Stop the session, finalize the files and build the export ZIP.
    /// HR streaming keeps running — it is independent of the session.
    func stopSession() {
        stopEcg()
        stopAcc()
        sessionActive = false
        lastHrDate = nil
        liveActivity.end(liveActivityState)

        // Finalize the recording (flush + zip) off the main thread so a long
        // session doesn't freeze the UI on Stop.
        if let writer = sessionWriter {
            lastSessionZipURL = nil
            statusMessage = "Saving session…"
            Task.detached(priority: .utility) { [weak self] in
                let url = writer.makeZip()
                await MainActor.run { self?.lastSessionZipURL = url }
            }
        }
        sessionWriter = nil

        let d = UserDefaults.standard
        d.removeObject(forKey: kSessionStamp)
        d.removeObject(forKey: kSessionStart)
        d.removeObject(forKey: kSessionDevice)

        // Archive this session into the rolling history for the sessions widget.
        if sessionSeconds > 0 || sessionCalories > 0 {
            SharedStore.appendHistory(SessionSummary(
                calories: sessionCalories,
                durationSeconds: sessionSeconds,
                heartRate: metrics.maxHr,
                steps: steps,
                active: false,
                updatedAt: Date().timeIntervalSince1970,
                startedAt: sessionStartDate?.timeIntervalSince1970 ?? 0,
                kcalPerMin: 0,
                stepsPerMin: 0
            ))
        }

        publishWidgetSummary(reload: true)
        WidgetCenter.shared.reloadAllTimelines()
        statusMessage = "Session saved · \(readings.count) HR · \(ecgRecording.count) ECG · \(accRecording.count) ACC (recent)"
    }

    /// Start any session streams that aren't running yet, once their feature is
    /// ready. Safe to call repeatedly (e.g. after a reconnect).
    private func resumeSessionStreamsIfNeeded() {
        guard sessionActive, onlineStreamingReady else { return }
        if ecgRecordingEnabled && !ecgStreaming { startEcg() }
        if !accStreaming { startAcc() }
    }

    /// React to the "Record ECG" switch changing during a session: start or stop
    /// ECG for the rest of the session (foreground and background).
    func setEcgRecording(_ enabled: Bool) {
        guard sessionActive else { return }
        if enabled {
            if onlineStreamingReady, !ecgStreaming { startEcg() }
        } else {
            stopEcg()
        }
    }

    // MARK: - CSV / ZIP export

    func writeEcgCSV() -> URL? {
        guard !ecgRecording.isEmpty else { return nil }
        return writeCSV(ecgCSVString(), name: "ecg")
    }

    func writeAccCSV() -> URL? {
        guard !accRecording.isEmpty else { return nil }
        return writeCSV(accCSVString(), name: "acc")
    }

    private func ecgCSVString() -> String {
        var csv = "index,timestamp_ns,microvolts\n"
        for s in ecgRecording {
            csv += "\(s.index),\(s.timeStamp),\(s.microvolts)\n"
        }
        return csv
    }

    private func accCSVString() -> String {
        var csv = "index,timestamp_ns,x_mg,y_mg,z_mg\n"
        for s in accRecording {
            csv += "\(s.index),\(s.timeStamp),\(s.x),\(s.y),\(s.z)\n"
        }
        return csv
    }

    private func writeCSV(_ contents: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("polar_h10_\(name).csv")
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            statusMessage = "CSV write failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// "yyyy-MM-dd_HH-mm-ss" stamp for file names.
    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }
}

// MARK: - PolarBleApiObserver (Feature 3: connection status)
//
// The Polar SDK may deliver observer callbacks on a background queue, so every
// callback hops to the main actor before touching @Published state (otherwise
// SwiftUI logs "Publishing changes from background threads is not allowed").

extension PolarManager {
    /// Run `work` on the main actor (used by the nonisolated SDK callbacks).
    nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }
}

extension PolarManager: PolarBleApiObserver {
    nonisolated func deviceConnecting(_ identifier: PolarDeviceInfo) {
        onMain { [weak self] in
            guard let self else { return }
            self.connectionState = .connecting
            self.connectedDeviceName = identifier.name.isEmpty ? identifier.deviceId : identifier.name
            self.statusMessage = "Connecting to \(self.connectedDeviceName ?? "")…"
        }
    }

    nonisolated func deviceConnected(_ identifier: PolarDeviceInfo) {
        onMain { [weak self] in
            guard let self else { return }
            self.connectionState = .connected
            self.connectedDeviceId = identifier.deviceId
            self.connectedDeviceName = identifier.name.isEmpty ? identifier.deviceId : identifier.name
            self.statusMessage = self.sessionActive ? "Reconnected — resuming session…"
                                                     : "Connected to \(self.connectedDeviceName ?? "")"
            // Streams are (re)started from the feature-ready callbacks below.
        }
    }

    nonisolated func deviceDisconnected(_ identifier: PolarDeviceInfo, pairingError: Bool) {
        onMain { [weak self] in
            guard let self else { return }
            self.hrFeatureReady = false
            self.onlineStreamingReady = false

            if self.sessionActive {
                // Keep the session alive: cancel the ended stream tasks but retain
                // the device id and buffers. The SDK auto-reconnects (we never
                // called disconnect), and streams resume from feature-ready.
                self.hrStreamTask?.cancel(); self.hrStreamTask = nil
                self.ecgTask?.cancel(); self.ecgTask = nil
                self.accTask?.cancel(); self.accTask = nil
                self.hrStreaming = false
                self.ecgStreaming = false
                self.accStreaming = false
                self.lastHrDate = nil   // calorie total is preserved; no gap integrated
                self.connectionState = .connecting
                self.statusMessage = "Connection lost — reconnecting…"
                return
            }

            self.connectionState = .disconnected
            self.connectedDeviceId = nil
            self.connectedDeviceName = nil
            self.batteryLevel = nil
            self.stopStreaming()
            self.stopEcg()
            self.stopAcc()
            self.statusMessage = pairingError ? "Disconnected (pairing error)" : "Disconnected"
        }
    }
}

// MARK: - Power state

extension PolarManager: PolarBleApiPowerStateObserver {
    nonisolated func blePowerOn() {
        onMain { [weak self] in
            guard let self else { return }
            self.bluetoothOn = true
            if self.statusMessage == "Bluetooth is off" { self.statusMessage = "Idle" }
        }
    }

    nonisolated func blePowerOff() {
        onMain { [weak self] in
            guard let self else { return }
            self.bluetoothOn = false
            self.statusMessage = "Bluetooth is off"
        }
    }
}

// MARK: - Feature readiness

extension PolarManager: PolarBleApiDeviceFeaturesObserver {
    nonisolated func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        onMain { [weak self] in
            guard let self else { return }
            switch feature {
            case .feature_hr:
                self.hrFeatureReady = true
                // HR always streams while connected — start it as soon as it's ready.
                self.startStreaming()
            case .feature_polar_online_streaming:
                self.onlineStreamingReady = true
            default:
                break
            }
            // Resume ECG/ACC for an in-progress session once streaming is ready.
            self.resumeSessionStreamsIfNeeded()
        }
    }
}

// MARK: - Device info (battery)

extension PolarManager: PolarBleApiDeviceInfoObserver {
    nonisolated func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        onMain { [weak self] in self?.batteryLevel = Int(batteryLevel) }
    }

    nonisolated func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {}

    nonisolated func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {}

    nonisolated func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {}
}
