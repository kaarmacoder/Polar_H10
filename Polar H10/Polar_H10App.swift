//
//  Polar_H10App.swift
//  Polar H10
//

import SwiftUI

@main
struct Polar_H10App: App {
    @StateObject private var polar = PolarManager()
    @StateObject private var health = HealthKitManager()
    @StateObject private var profileStore = ProfileStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(polar)
                .environmentObject(health)
                .environmentObject(profileStore)
        }
    }
}
