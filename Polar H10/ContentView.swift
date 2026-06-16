//
//  ContentView.swift
//  Polar H10
//

import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject private var polar: PolarManager
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        TabView {
            HeartRateView()
                .tabItem { Label("Heart Rate", systemImage: "heart.fill") }
            ECGView()
                .tabItem { Label("ECG", systemImage: "waveform.path.ecg") }
            MotionView()
                .tabItem { Label("Motion", systemImage: "move.3d") }
            CaloriesView()
                .tabItem { Label("Calories", systemImage: "flame.fill") }
        }
        // Keep the calorie model's profile in sync with the persisted store.
        .onAppear { polar.profile = profileStore.profile }
        .onChange(of: profileStore.profile) { _, newValue in
            polar.profile = newValue
        }
    }
}

// MARK: - Shared card container

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Explains the five %-of-max-HR training zones. Shown in the Heart Metrics
/// card and the session detail dashboard. When `maxHr` is known it also shows
/// the matching bpm range for each zone.
struct ZoneLegend: View {
    var maxHr: Int = 0

    /// Colors mirror the time-in-zone bars (Z1…Z5).
    private let colors: [Color] = [.gray, .blue, .green, .orange, .red]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What the zones mean").font(.caption.bold()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(HRZones.all.enumerated()), id: \.element.id) { idx, z in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(colors[idx]).frame(width: 9, height: 9)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text("Z\(z.zone)").font(.caption.bold().monospacedDigit())
                        .frame(width: 22, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(z.name).font(.caption.bold())
                            Text(z.rangeLabel).font(.caption2).foregroundStyle(.secondary)
                            if maxHr > 0 {
                                Text("· \(HRZones.bpmRange(z, maxHr: maxHr))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Text(z.purpose).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if maxHr > 0 {
                Text("Ranges are % of your max HR (\(maxHr) bpm). Set your real max in the Calories profile for accurate zones.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A "what else this sensor can derive" informational card.
struct SensorCapabilitiesNote: View {
    let title: String
    let items: [String]

    var body: some View {
        Card {
            Label(title, systemImage: "lightbulb")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "plus.circle").font(.caption2).foregroundStyle(.secondary)
                    Text(item).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Not yet computed — these are derivable from this sensor's data.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Shown on the ECG / Motion tabs when there is no connected device.
struct NotConnectedView: View {
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Connect to a Polar H10 on the Heart Rate tab to start recording.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Heart Rate tab (discovery, connection, HR, Health export)

struct HeartRateView: View {
    @EnvironmentObject private var polar: PolarManager
    @EnvironmentObject private var health: HealthKitManager

    @State private var exportInProgress = false
    @State private var alertMessage: String?
    @State private var hrScroll: Date = .now
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if polar.connectionState == .connected {
                        liveDataCard
                        metricsCard
                        controlsCard
                        exportCard
                    } else {
                        discoveryCard
                    }
                }
                .padding()
            }
            .navigationTitle("Polar H10")
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showHistory = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                HistoryView()
            }
            .alert("Notice", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(polar.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let battery = polar.batteryLevel {
                    Label("\(battery)%", systemImage: batteryIcon(battery))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !polar.bluetoothOn {
                Text("Bluetooth is off — enable it in Settings to use the device.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusColor: Color {
        switch polar.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        }
    }

    private var statusTitle: String {
        switch polar.connectionState {
        case .connected: return polar.connectedDeviceName ?? "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Not connected"
        }
    }

    private var discoveryCard: some View {
        Card {
            HStack {
                Text("Devices")
                    .font(.headline)
                Spacer()
                if polar.isSearching {
                    ProgressView()
                    Button("Stop") { polar.stopSearch() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        polar.startSearch()
                    } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!polar.bluetoothOn)
                }
            }

            if polar.discovered.isEmpty {
                Text(polar.isSearching ? "Searching…" : "Tap Scan to discover nearby Polar devices.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(polar.discovered) { device in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.body)
                            Text("Signal \(device.rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") { polar.connect(to: device) }
                            .buttonStyle(.bordered)
                            .disabled(polar.connectionState == .connecting)
                    }
                }
            }
        }
    }

    private var liveDataCard: some View {
        Card {
            HStack {
                Text("Live Data").font(.headline)
                Spacer()
                contactBadge
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .font(.title)
                    .symbolEffect(.pulse, isActive: polar.hrStreaming)
                Text("\(polar.currentHr)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("BPM")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !polar.currentRr.isEmpty {
                Text("RR: " + polar.currentRr.map { "\($0)" }.joined(separator: ", ") + " ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if polar.readings.count > 1 {
                Chart(polar.readings) { reading in
                    LineMark(
                        x: .value("Time", reading.date),
                        y: .value("BPM", reading.bpm)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.red)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: 60) // show 60 s, scroll back for history
                .chartScrollPosition(x: $hrScroll)
                .frame(height: 160)
                .onChange(of: polar.readings.last?.date) { _, newDate in
                    if let d = newDate { hrScroll = d.addingTimeInterval(-60) }
                }
            }
        }
    }

    private var contactBadge: some View {
        Label(
            polar.contactDetected ? "Contact" : "No contact",
            systemImage: polar.contactDetected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(polar.contactDetected ? .green : .orange)
    }

    private var metricsCard: some View {
        let m = polar.metrics
        return Card {
            Text("Heart Metrics").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // HRV
            Text("Heart-rate variability").font(.caption.bold()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                metric("RMSSD", String(format: "%.0f", m.rmssd), "ms")
                metric("SDNN", String(format: "%.0f", m.sdnn), "ms")
                metric("pNN50", String(format: "%.0f", m.pnn50), "%")
            }

            Divider()

            // Rates & fitness
            HStack(spacing: 16) {
                metric("Max HR", "\(m.maxHr)", "bpm")
                metric("Min HR", "\(m.minHr)", "bpm")
                metric("Resp.", m.respiration > 0 ? "\(m.respiration)" : "—", "br/min")
            }
            HStack(spacing: 16) {
                metric("VO₂max", m.vo2maxEstimate > 0 ? String(format: "%.0f", m.vo2maxEstimate) : "—", "est")
                metric("Load", String(format: "%.0f", m.trimp), "TRIMP")
                metric("Zone", m.currentZone > 0 ? "Z\(m.currentZone)" : "Rest", "now")
            }

            Divider()

            // Time in zone
            Text("Time in zone").font(.caption.bold()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(0..<5, id: \.self) { i in
                zoneRow(index: i, seconds: m.timeInZone[i], total: m.totalZoneTime)
            }

            Divider()

            // What the zones mean (percentage of max HR).
            ZoneLegend(maxHr: polar.profile.effectiveMaxHr)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                noteLine("HRV is most meaningful at rest (e.g. a morning reading) — it naturally collapses during exercise.")
                noteLine("VO₂max & respiration are estimates derived from RR intervals — directional, not clinical.")
                noteLine("VO₂max via HR is rough and firms up only after a real max effort and a true resting HR.")
                noteLine("Min HR isn't your true resting HR unless it was measured while actually at rest.")
            }
        }
    }

    private func noteLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.bold().monospacedDigit())
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func zoneRow(index: Int, seconds: Double, total: Double) -> some View {
        let zoneColors: [Color] = [.gray, .blue, .green, .orange, .red]
        let fraction = total > 0 ? seconds / total : 0
        return HStack(spacing: 8) {
            Text("Z\(index + 1)").font(.caption.monospacedDigit()).frame(width: 24, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(zoneColors[index])
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 10)
            Text(zoneTime(seconds)).font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }

    private func zoneTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var controlsCard: some View {
        Card {
            Button(role: .destructive) {
                polar.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("Heart rate streams automatically while connected. Use the Calories tab to start/stop a recording session.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var exportCard: some View {
        Card {
            Text("Apple Health").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Save this session to the Health app: heart rate, plus steps, active energy, HRV, respiration and VO₂max when available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                exportToHealth()
            } label: {
                HStack {
                    if exportInProgress { ProgressView() }
                    Label("Export to Health", systemImage: "heart.text.square")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .disabled(polar.readings.isEmpty || exportInProgress || !health.isHealthDataAvailable)

            if let msg = health.lastExportMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func exportToHealth() {
        exportInProgress = true
        let m = polar.metrics
        let data = HealthExportData(
            readings: polar.readings,
            deviceName: polar.connectedDeviceName,
            steps: polar.steps,
            activeCalories: polar.sessionCalories,
            sdnn: m.sdnn,
            respiration: m.respiration,
            vo2max: m.vo2maxEstimate,
            intervalStart: polar.readings.first?.date,
            intervalEnd: polar.readings.last?.date
        )
        Task {
            defer { exportInProgress = false }
            do {
                let count = try await health.export(data)
                polar.resetSession()
                alertMessage = "Saved \(count) samples to the Health app."
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<15: return "battery.25"
        case ..<50: return "battery.50"
        case ..<85: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - ECG tab (in-app recording, 130 Hz µV)

struct ECGView: View {
    @EnvironmentObject private var polar: PolarManager
    @State private var ecgScroll: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if polar.connectionState == .connected {
                        readingCard
                        liveCard
                        recordCard
                    } else {
                        NotConnectedView()
                    }
                    SensorCapabilitiesNote(
                        title: "Also possible from ECG",
                        items: [
                            "Arrhythmia / ectopic-beat detection",
                            "ECG-derived respiration (higher fidelity than RR-based)"
                        ]
                    )
                }
                .padding()
            }
            .navigationTitle("ECG")
            .background(Color(.systemGroupedBackground))
        }
    }

    private var readingCard: some View {
        Card {
            Text("ECG Reading").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                reading("Heart rate", polar.currentHr > 0 ? "\(polar.currentHr)" : "—", "bpm", .red)
                reading("Rhythm", polar.ecgRhythm, "", rhythmColor)
                reading("Signal", polar.ecgStreaming ? polar.ecgQuality : "—", "", signalColor)
            }
            Text("Rhythm is a rough steadiness estimate from beat-to-beat timing — it is not a medical diagnosis. Record a strip and consult a clinician for any concern.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reading(_ title: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.headline.bold().monospacedDigit()).foregroundStyle(color)
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rhythmColor: Color {
        switch polar.ecgRhythm {
        case "Regular": return .green
        case "Slightly irregular": return .orange
        case "Irregular": return .red
        default: return .secondary
        }
    }

    private var signalColor: Color {
        switch polar.ecgQuality {
        case "Good": return .green
        case "Weak signal": return .orange
        case "No contact": return .red
        default: return .secondary
        }
    }

    private var liveCard: some View {
        Card {
            HStack {
                Text("Electrocardiogram").font(.headline)
                Spacer()
                Text("\(polar.currentEcgUv) µV")
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(.green)
                    .contentTransition(.numericText())
            }
            Text("130 Hz · microvolts")
                .font(.caption)
                .foregroundStyle(.secondary)

            let samples = polar.ecgDisplayWaveform
            if samples.count > 1 {
                Chart(samples) { s in
                    LineMark(
                        x: .value("Sample", s.index),
                        y: .value("µV", s.microvolts)
                    )
                    .foregroundStyle(.green)
                }
                .chartXAxis(.hidden)
                .chartYAxisLabel("µV (baseline-filtered)")
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: 650) // ~5 s window, scroll back through ~20 s
                .chartScrollPosition(x: $ecgScroll)
                .frame(height: 180)
                .onChange(of: samples.last?.index) { _, newIndex in
                    if let i = newIndex { ecgScroll = max(0, i - 650) }
                }
                Text("Swipe the chart to review past beats · full data in the CSV export")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                placeholder("Start recording to see the waveform.")
            }
        }
    }

    private var recordCard: some View {
        Card {
            HStack(spacing: 12) {
                if polar.ecgStreaming {
                    Button {
                        polar.stopEcg()
                    } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button {
                        polar.startEcg()
                    } label: {
                        Label("Record ECG", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(!polar.onlineStreamingReady)
                }

                Button {
                    polar.clearEcg()
                } label: {
                    Label("Clear", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(polar.ecgRecording.isEmpty || polar.ecgStreaming)
            }

            HStack {
                Text("\(polar.ecgRecording.count) samples recorded")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = csvURL {
                    ShareLink(item: url) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var csvURL: URL? {
        polar.ecgRecording.isEmpty || polar.ecgStreaming ? nil : polar.writeEcgCSV()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Motion tab (accelerometer, in-app recording)

struct MotionView: View {
    @EnvironmentObject private var polar: PolarManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if polar.connectionState == .connected {
                        liveCard
                        recordCard
                    } else {
                        NotConnectedView()
                    }
                    SensorCapabilitiesNote(
                        title: "Also possible from motion",
                        items: [
                            "Steps & cadence",
                            "Activity type (still / walking / running)",
                            "Motion-based energy (METs) to complement HR calories"
                        ]
                    )
                }
                .padding()
            }
            .navigationTitle("Motion")
            .background(Color(.systemGroupedBackground))
        }
    }

    private var liveCard: some View {
        Card {
            HStack {
                Text("Steps").font(.headline)
                Spacer()
                Label(polar.activity, systemImage: activityIcon)
                    .font(.caption.bold())
                    .foregroundStyle(activityColor)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "figure.walk")
                    .foregroundStyle(.blue).font(.title)
                Text("\(polar.steps)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText())
                Spacer()
            }

            HStack(spacing: 16) {
                statBox("Cadence", "\(polar.cadence)", "steps/min")
                statBox("Activity", polar.activity, "now")
            }

            if !polar.accStreaming {
                Text("Press Start to begin counting steps from the accelerometer.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var activityIcon: String {
        switch polar.activity {
        case "Running": return "figure.run"
        case "Walking": return "figure.walk"
        default:         return "figure.stand"
        }
    }

    private var activityColor: Color {
        switch polar.activity {
        case "Running": return .red
        case "Walking": return .green
        default:         return .secondary
        }
    }

    private func statBox(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.bold().monospacedDigit())
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordCard: some View {
        Card {
            HStack(spacing: 12) {
                if polar.accStreaming {
                    Button {
                        polar.stopAcc()
                    } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button {
                        polar.startAcc()
                    } label: {
                        Label("Start", systemImage: "figure.walk").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(!polar.onlineStreamingReady)
                }

                Button {
                    polar.clearAcc()
                } label: {
                    Label("Clear", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(polar.accRecording.isEmpty || polar.accStreaming)
            }

            HStack {
                Text("\(polar.accRecording.count) samples recorded")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = csvURL {
                    ShareLink(item: url) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var csvURL: URL? {
        polar.accRecording.isEmpty || polar.accStreaming ? nil : polar.writeAccCSV()
    }
}

// MARK: - Calories tab (HR-based estimate + user profile)

struct CaloriesView: View {
    @EnvironmentObject private var polar: PolarManager
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var showProfile = false
    @AppStorage("recordEcg") private var recordEcg = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    estimateCard
                    controlCard
                    profileCard
                    methodCard
                }
                .padding()
            }
            .navigationTitle("Calories")
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $showProfile) {
                ProfileEditor(profile: $profileStore.profile)
            }
        }
    }

    private var estimateCard: some View {
        Card {
            HStack {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("Estimated Burn").font(.headline)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f", polar.sessionCalories))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("kcal").font(.title3).foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 24) {
                metric("Duration", value: formattedDuration)
                metric("Heart rate", value: polar.currentHr > 0 ? "\(polar.currentHr) bpm" : "—")
                metric("Rate", value: ratePerMin)
            }
            HStack(spacing: 24) {
                metric("Steps", value: "\(polar.steps)")
                metric("Cadence", value: polar.cadence > 0 ? "\(polar.cadence)/min" : "—")
                metric("Activity", value: polar.activity)
            }

            if polar.connectionState != .connected {
                hint("Connect a device on the Heart Rate tab.")
            } else if !polar.sessionActive && polar.sessionCalories == 0 {
                hint("Press Start Counting to record HR, ECG and motion together.")
            }
        }
    }

    private var controlCard: some View {
        Card {
            Text("Capture Session").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Records heart rate, ECG and motion simultaneously and bundles them into a dated ZIP of CSV files.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: $recordEcg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record ECG")
                    Text("When off, the session records HR + motion only (no ECG) — saves battery.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .onChange(of: recordEcg) { _, on in polar.setEcgRecording(on) }

            if polar.sessionActive {
                Button {
                    polar.stopSession()
                } label: {
                    Label("Stop & Save", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                Label("Recording — keeps running in the background and while locked. Only Stop ends it.",
                      systemImage: "record.circle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else {
                Button {
                    polar.startSession()
                } label: {
                    Label("Start Counting", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(polar.connectionState != .connected)
            }

            HStack(spacing: 20) {
                metric("HR", value: "\(polar.readings.count)")
                metric("ECG", value: "\(polar.ecgRecording.count)")
                metric("Motion", value: "\(polar.accRecording.count)")
            }

            if let url = polar.lastSessionZipURL {
                ShareLink(item: url) {
                    Label("Export session (ZIP)", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Text(url.lastPathComponent)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var profileCard: some View {
        Card {
            HStack {
                Text("Your Profile").font(.headline)
                Spacer()
                Button("Edit") { showProfile = true }
                    .buttonStyle(.bordered)
            }
            let p = profileStore.profile
            HStack(spacing: 24) {
                metric("Sex", value: p.sex.label)
                metric("Age", value: "\(p.age)")
                metric("Weight", value: "\(Int(p.weightKg)) kg")
                metric("Height", value: "\(Int(p.heightCm)) cm")
            }
            HStack(spacing: 24) {
                metric("Resting HR", value: "\(p.restingHr)")
                metric("Max HR", value: "\(p.effectiveMaxHr)\(p.maxHr == 0 ? "*" : "")")
                metric("VO₂max", value: String(format: "%.0f%@", p.effectiveVo2max, p.vo2max == 0 ? "*" : ""))
                Spacer()
            }
            Text("* auto-estimated").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var methodCard: some View {
        Card {
            Text("How it's calculated").font(.subheadline.bold())
            Text("Energy expenditure is estimated from your heart rate using the Keytel (2005) equation, combined with your age, weight and sex. Heart rate reflects total effort — including incline or load that the accelerometer can't see. Strength-training estimates are approximate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formattedDuration: String {
        let s = polar.sessionSeconds
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var ratePerMin: String {
        guard polar.currentHr > 0, polar.sessionActive else { return "—" }
        let r = CalorieEstimator.kcalPerMinute(hr: polar.currentHr, profile: polar.profile)
        return String(format: "%.1f/min", r)
    }
}

struct ProfileEditor: View {
    @Binding var profile: UserProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Body") {
                    Picker("Sex", selection: $profile.sex) {
                        ForEach(Sex.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper("Age: \(profile.age)", value: $profile.age, in: 5...120)
                    Stepper("Weight: \(Int(profile.weightKg)) kg",
                            value: $profile.weightKg, in: 20...250, step: 1)
                    Stepper("Height: \(Int(profile.heightCm)) cm",
                            value: $profile.heightCm, in: 100...230, step: 1)
                }
                Section {
                    Stepper("Resting HR: \(profile.restingHr) bpm",
                            value: $profile.restingHr, in: 30...120)
                    Stepper(profile.maxHr == 0 ? "Max HR: Auto (\(profile.effectiveMaxHr) bpm)"
                                               : "Max HR: \(profile.maxHr) bpm",
                            value: $profile.maxHr, in: 0...230)
                    Stepper(profile.vo2max == 0
                                ? "VO₂max: Auto (\(String(format: "%.0f", profile.effectiveVo2max)))"
                                : "VO₂max: \(String(format: "%.0f", profile.vo2max))",
                            value: $profile.vo2max, in: 0...90, step: 1)
                } header: {
                    Text("Fitness — improves accuracy")
                } footer: {
                    Text("Set Max HR or VO₂max to 0 to auto-estimate. VO₂max auto uses the Uth–Sørensen formula (15.3 × HRmax ÷ HRrest).")
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(PolarManager())
        .environmentObject(HealthKitManager())
        .environmentObject(ProfileStore())
}
