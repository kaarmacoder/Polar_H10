//
//  HealthKitManager.swift
//  Polar H10
//
//  Writes captured heart-rate readings into the iOS Health app via HealthKit.
//

import Foundation
import Combine
import HealthKit

@MainActor
final class HealthKitManager: ObservableObject {

    enum ExportError: LocalizedError {
        case healthDataUnavailable
        case notAuthorized
        case nothingToExport

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable: return "Health data is not available on this device."
            case .notAuthorized: return "Permission to write to Health was not granted."
            case .nothingToExport: return "There are no readings to export."
            }
        }
    }

    @Published var isAuthorized = false
    @Published var lastExportMessage: String?

    private let store = HKHealthStore()
    private let heartRateType = HKQuantityType(.heartRate)

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Request permission to write heart-rate samples.
    func requestAuthorization() async throws {
        guard isHealthDataAvailable else { throw ExportError.healthDataUnavailable }
        try await store.requestAuthorization(toShare: [heartRateType], read: [])
        // HealthKit never reveals whether *write* was granted (privacy). We optimistically
        // mark authorized; a denied write simply throws when we attempt the save.
        isAuthorized = true
    }

    /// Save the given readings to HealthKit as discrete heart-rate samples.
    /// Returns the number of samples written.
    @discardableResult
    func export(_ readings: [HeartRateReading], deviceName: String?) async throws -> Int {
        guard isHealthDataAvailable else { throw ExportError.healthDataUnavailable }
        guard !readings.isEmpty else { throw ExportError.nothingToExport }

        if !isAuthorized {
            try await requestAuthorization()
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let device = HKDevice(
            name: deviceName ?? "Polar H10",
            manufacturer: "Polar",
            model: "H10",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )

        let samples: [HKQuantitySample] = readings.map { reading in
            let quantity = HKQuantity(unit: unit, doubleValue: Double(reading.bpm))
            return HKQuantitySample(
                type: heartRateType,
                quantity: quantity,
                start: reading.date,
                end: reading.date,
                device: device,
                metadata: nil
            )
        }

        try await store.save(samples)
        lastExportMessage = "Exported \(samples.count) heart-rate samples to Health."
        return samples.count
    }
}
