//
//  PolarH10WidgetBundle.swift
//  PolarH10Widget
//
//  Live Activity for an active capture session: shows calories, duration,
//  heart rate and motion (x/y/z) on the lock screen and in the Dynamic Island.
//

import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct PolarH10WidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
        CalorieWidget()
        SessionsWidget()
    }
}

// MARK: - Home-screen calorie widget

struct CalorieEntry: TimelineEntry {
    let date: Date
    let summary: SessionSummary
}

struct CalorieProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalorieEntry {
        CalorieEntry(date: Date(), summary: SessionSummary(
            calories: 312, durationSeconds: 1830, heartRate: 132, steps: 2450,
            active: false, updatedAt: 0, startedAt: 0, kcalPerMin: 0, stepsPerMin: 0))
    }

    func getSnapshot(in context: Context, completion: @escaping (CalorieEntry) -> Void) {
        completion(CalorieEntry(date: Date(), summary: SharedStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalorieEntry>) -> Void) {
        let summary = SharedStore.load()
        let now = Date()

        guard summary.active else {
            // Idle: one static entry, no scheduled refresh needed.
            completion(Timeline(entries: [CalorieEntry(date: now, summary: summary)], policy: .never))
            return
        }

        // Active: pre-compute entries every 30 s for the next ~30 min, projecting
        // calories/steps from the current rate. The OS advances through these
        // WITHOUT spending reload budget, so the numbers climb on their own; a
        // real reload (each ~20 s while the app runs, and on stop) corrects them.
        var entries: [CalorieEntry] = []
        for i in 0..<60 {
            let date = now.addingTimeInterval(Double(i) * 30)
            entries.append(CalorieEntry(date: date, summary: summary.projected(to: date)))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct CalorieWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CalorieWidget", provider: CalorieProvider()) { entry in
            CalorieWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Polar H10 Session")
        .description("Calories, duration, heart rate and steps from your latest session.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CalorieWidgetView: View {
    let entry: CalorieEntry
    @Environment(\.widgetFamily) private var family

    private var s: SessionSummary { entry.summary }

    var body: some View {
        if family == .systemSmall {
            small
        } else {
            medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            Text("\(Int(s.calories))")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("kcal").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Label("\(s.heartRate) bpm", systemImage: "heart.fill")
                .font(.caption2).foregroundStyle(.red)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(spacing: 14) {
                stat("\(Int(s.calories))", "kcal", "flame.fill", .orange)
                timeStat
                stat("\(s.heartRate)", "bpm", "heart.fill", .red)
                stat("\(s.steps)", "steps", "figure.walk", .green)
            }
        }
    }

    /// Duration as a self-updating timer (ticks every second with no reload)
    /// while a session is active; static otherwise.
    private var timeStat: some View {
        VStack(spacing: 2) {
            Image(systemName: "clock.fill").foregroundStyle(.blue).font(.callout)
            Group {
                if s.active, s.startedAt > 0 {
                    Text(Date(timeIntervalSince1970: s.startedAt), style: .timer)
                        .multilineTextAlignment(.center)
                } else {
                    Text(duration)
                }
            }
            .font(.headline.bold().monospacedDigit())
            Text("time").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack {
            Label("Polar H10", systemImage: "waveform.path.ecg")
                .font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            if s.active {
                Text("● LIVE").font(.caption2.bold()).foregroundStyle(.red)
            }
        }
    }

    private func stat(_ value: String, _ unit: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(color).font(.callout)
            Text(value).font(.headline.bold().monospacedDigit())
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var duration: String {
        String(format: "%d:%02d", s.durationSeconds / 60, s.durationSeconds % 60)
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            // Lock screen / banner presentation.
            LockScreenLiveActivityView(state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(Int(context.state.calories))", systemImage: "flame.fill")
                        .foregroundStyle(.orange)
                        .font(.title3.bold())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label("\(context.state.heartRate)", systemImage: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.title3.bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(durationString(context.state.durationSeconds), systemImage: "clock.fill")
                            .font(.headline.monospacedDigit())
                        Spacer()
                        Label("\(context.state.steps)", systemImage: "figure.walk")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: "heart.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text("\(context.state.heartRate)").monospacedDigit()
            } minimal: {
                Image(systemName: "heart.fill").foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Recent-sessions widget (tap ◀ ▶ to page through the last 7)

struct PrevSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Newer Session"
    func perform() async throws -> some IntentResult {
        SharedStore.page(by: -1)
        return .result()
    }
}

struct NextSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Older Session"
    func perform() async throws -> some IntentResult {
        SharedStore.page(by: 1)
        return .result()
    }
}

struct SessionsEntry: TimelineEntry {
    let date: Date
    let sessions: [SessionSummary]
    let index: Int
}

struct SessionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SessionsEntry {
        SessionsEntry(date: Date(), sessions: [SessionSummary(
            calories: 312, durationSeconds: 1830, heartRate: 156, steps: 2450,
            active: false, updatedAt: Date().timeIntervalSince1970, startedAt: 0,
            kcalPerMin: 0, stepsPerMin: 0)], index: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (SessionsEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionsEntry>) -> Void) {
        // No scheduled refresh: updates come from the page buttons (which reload
        // automatically) and from the app when a session ends.
        completion(Timeline(entries: [makeEntry()], policy: .never))
    }

    private func makeEntry() -> SessionsEntry {
        let sessions = SharedStore.loadHistory()
        let index = sessions.isEmpty ? 0 : min(max(SharedStore.selectedIndex(), 0), sessions.count - 1)
        return SessionsEntry(date: Date(), sessions: sessions, index: index)
    }
}

struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SessionsWidget", provider: SessionsProvider()) { entry in
            SessionsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Polar H10 — Recent Sessions")
        .description("Tap the arrows to page through your last 7 sessions.")
        .supportedFamilies([.systemMedium])
    }
}

struct SessionsWidgetView: View {
    let entry: SessionsEntry

    var body: some View {
        if entry.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "figure.run.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("No sessions yet").font(.headline)
                Text("Finish a Capture Session to see it here.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let s = entry.sessions[min(entry.index, entry.sessions.count - 1)]
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Session", systemImage: "figure.run")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(entry.index + 1) / \(entry.sessions.count)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(dateString(s)).font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    stat("\(Int(s.calories))", "kcal", "flame.fill", .orange)
                    stat(durationString(s.durationSeconds), "time", "clock.fill", .blue)
                    stat("\(s.heartRate)", "max bpm", "heart.fill", .red)
                    stat("\(s.steps)", "steps", "figure.walk", .green)
                }

                HStack {
                    Button(intent: PrevSessionIntent()) {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                    }
                    .disabled(entry.index == 0)
                    Spacer()
                    Text("newer ◀  ▶ older").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button(intent: NextSessionIntent()) {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                    }
                    .disabled(entry.index >= entry.sessions.count - 1)
                }
                .buttonStyle(.plain)
                .tint(.blue)
            }
        }
    }

    private func stat(_ value: String, _ unit: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(color).font(.callout)
            Text(value).font(.subheadline.bold().monospacedDigit())
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func dateString(_ s: SessionSummary) -> String {
        let t = s.startedAt > 0 ? s.startedAt : s.updatedAt
        guard t > 0 else { return "—" }
        return Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)
    }
}

struct LockScreenLiveActivityView: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Polar H10 Session", systemImage: "record.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
                Spacer()
                Text(durationString(state.durationSeconds))
                    .font(.headline.monospacedDigit())
            }
            HStack(spacing: 16) {
                stat("Calories", "\(Int(state.calories))", "flame.fill", .orange)
                stat("Heart Rate", "\(state.heartRate)", "heart.fill", .red)
                stat("Steps", "\(state.steps)", "figure.walk", .green)
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.title3.bold().monospacedDigit())
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func durationString(_ seconds: Int) -> String {
    String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
