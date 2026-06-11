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

@main
struct PolarH10WidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
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
                    VStack(spacing: 4) {
                        Text(durationString(context.state.durationSeconds))
                            .font(.title2.monospacedDigit().bold())
                        Text("X \(context.state.accX)   Y \(context.state.accY)   Z \(context.state.accZ) mg")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
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
            }
            HStack {
                Image(systemName: "move.3d").foregroundStyle(.blue)
                Text("X \(state.accX)   Y \(state.accY)   Z \(state.accZ) mg")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
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
