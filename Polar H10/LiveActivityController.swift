//
//  LiveActivityController.swift
//  Polar H10
//
//  Manages the capture-session Live Activity (lock screen + Dynamic Island).
//

import Foundation
import ActivityKit

@MainActor
final class LiveActivityController {

    private var activity: Activity<SessionActivityAttributes>?

    var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Begin (or adopt an already-running) Live Activity for the session.
    func start(startedAt: Date, initial: SessionActivityAttributes.ContentState) {
        // Adopt an existing activity after a relaunch instead of duplicating.
        if let existing = Activity<SessionActivityAttributes>.activities.first {
            activity = existing
            update(initial)
            return
        }
        guard isSupported else { return }
        let attributes = SessionActivityAttributes(startedAt: startedAt)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initial, staleDate: nil),
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    /// Push the latest values to the Live Activity.
    func update(_ state: SessionActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// Dismiss the Live Activity.
    func end(_ finalState: SessionActivityAttributes.ContentState) {
        let current = activity
        activity = nil
        guard let current else { return }
        Task {
            await current.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
        }
    }
}
