//
//  HistoryView.swift
//  Polar H10
//
//  Session history: a list of every recorded session (newest first, swipe to
//  delete) and a per-session dashboard consolidating all derived metrics, with
//  a full (batched) Health export and a ZIP share of the raw streams.
//

import SwiftUI

// MARK: - Formatting helpers

enum SessionFormat {
    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        return String(format: "%d:%02d", m, s)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - History list

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records: [SessionRecord] = []

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Start a recording from the Calories tab. Saved sessions appear here.")
                    )
                } else {
                    List {
                        ForEach(records) { record in
                            NavigationLink {
                                SessionDetailView(record: record)
                            } label: {
                                SessionRow(record: record)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { records = SessionStore.all() }
        }
    }

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { records[$0] }
        for record in toDelete { SessionStore.delete(record.stamp) }
        records.remove(atOffsets: offsets)
    }
}

struct SessionRow: View {
    let record: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SessionFormat.date(record.startedAt)).font(.headline)
            HStack(spacing: 14) {
                label("clock", SessionFormat.duration(record.durationSeconds))
                if record.calories > 0 { label("flame.fill", "\(Int(record.calories)) kcal") }
                if record.avgHr > 0 { label("heart.fill", "\(record.avgHr) bpm") }
                if record.steps > 0 { label("figure.walk", "\(record.steps)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func label(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
    }
}

// MARK: - Session detail dashboard

struct SessionDetailView: View {
    let record: SessionRecord
    @EnvironmentObject private var health: HealthKitManager

    @State private var exporting = false
    @State private var zipping = false
    @State private var zipURL: URL?
    @State private var message: String?

    private let zoneColors: [Color] = [.gray, .blue, .green, .orange, .red]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                statsCard
                hrvCard
                if record.totalZoneTime > 0 { zonesCard }
                streamsCard
                actionsCard
            }
            .padding()
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    private var headerCard: some View {
        Card {
            Text(SessionFormat.date(record.startedAt)).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                tile("Duration", SessionFormat.duration(record.durationSeconds), "")
                tile("Calories", record.calories > 0 ? String(format: "%.0f", record.calories) : "—", "kcal")
                tile("Steps", record.steps > 0 ? "\(record.steps)" : "—", "")
            }
            if let device = record.deviceName {
                Text(device).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statsCard: some View {
        Card {
            Text("Heart rate").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                tile("Avg HR", record.avgHr > 0 ? "\(record.avgHr)" : "—", "bpm")
                tile("Max HR", record.maxHr > 0 ? "\(record.maxHr)" : "—", "bpm")
                tile("Min HR", record.minHr > 0 ? "\(record.minHr)" : "—", "bpm")
            }
            HStack(spacing: 16) {
                tile("VO₂max", record.vo2max > 0 ? String(format: "%.0f", record.vo2max) : "—", "est")
                tile("Resp.", record.respiration > 0 ? "\(record.respiration)" : "—", "br/min")
                tile("Load", record.trimp > 0 ? String(format: "%.0f", record.trimp) : "—", "TRIMP")
            }
        }
    }

    private var hrvCard: some View {
        Card {
            Text("Heart-rate variability").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                tile("RMSSD", record.rmssd > 0 ? String(format: "%.0f", record.rmssd) : "—", "ms")
                tile("SDNN", record.sdnn > 0 ? String(format: "%.0f", record.sdnn) : "—", "ms")
                tile("pNN50", record.pnn50 > 0 ? String(format: "%.0f", record.pnn50) : "—", "%")
            }
        }
    }

    private var zonesCard: some View {
        Card {
            Text("Time in zone").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(0..<5, id: \.self) { i in
                HStack(spacing: 8) {
                    Text("Z\(i + 1)").font(.caption.monospacedDigit()).frame(width: 24, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule().fill(zoneColors[i])
                                .frame(width: max(0, geo.size.width * fraction(i)))
                        }
                    }
                    .frame(height: 10)
                    Text(SessionFormat.clock(record.timeInZone[i]))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
            Divider()
            ZoneLegend()
        }
    }

    private var streamsCard: some View {
        Card {
            Text("Recorded streams").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                tile("Heart rate", "\(record.hrSampleCount)", "samples")
                tile("ECG", record.ecgSampleCount > 0 ? "\(record.ecgSampleCount)" : "—", "samples")
                tile("Motion", record.accSampleCount > 0 ? "\(record.accSampleCount)" : "—", "samples")
            }
        }
    }

    private var actionsCard: some View {
        Card {
            Button {
                exportToHealth()
            } label: {
                HStack {
                    if exporting { ProgressView() }
                    Label("Export to Health", systemImage: "heart.text.square")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .disabled(exporting || !health.isHealthDataAvailable)

            Text("Exports the full heart-rate series plus steps, energy, HRV, respiration and VO₂max — batched, nothing left behind.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let zipURL {
                ShareLink(item: zipURL) {
                    Label("Share session (ZIP)", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    prepareZip()
                } label: {
                    HStack {
                        if zipping { ProgressView() }
                        Label("Share session (ZIP)", systemImage: "square.and.arrow.up")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(zipping)
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Actions

    private func exportToHealth() {
        exporting = true
        message = nil
        Task {
            defer { exporting = false }
            do {
                let n = try await health.export(record: record)
                message = "Exported \(n) samples to the Health app."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func prepareZip() {
        zipping = true
        let stamp = record.stamp
        Task.detached(priority: .utility) {
            let url = SessionStore.makeZip(for: stamp)
            await MainActor.run {
                zipURL = url
                zipping = false
                if url == nil { message = "Couldn't build the ZIP for this session." }
            }
        }
    }

    // MARK: Helpers

    private func fraction(_ i: Int) -> Double {
        record.totalZoneTime > 0 ? record.timeInZone[i] / record.totalZoneTime : 0
    }

    private func tile(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.bold().monospacedDigit())
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
