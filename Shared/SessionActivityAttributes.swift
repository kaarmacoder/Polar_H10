//
//  SessionActivityAttributes.swift
//  Polar H10
//
//  Shared between the app and the widget extension. Defines the Live Activity's
//  static attributes and its live-updating content state (calories, duration,
//  heart rate, motion x/y/z).
//

import Foundation
import ActivityKit

struct SessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var calories: Double
        var durationSeconds: Int
        var heartRate: Int
        var accX: Int
        var accY: Int
        var accZ: Int
    }

    /// When the session began (static for the lifetime of the activity).
    var startedAt: Date
}
