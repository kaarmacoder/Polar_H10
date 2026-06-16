//
//  HealthKitManager.swift
//  Polar H10
//
//  Writes captured heart-rate readings — plus derived steps, active energy,
//  HRV (SDNN), respiratory rate and a VO₂max estimate — into the iOS Health
//  app via HealthKit.
//

import Foundation
import Combine
import HealthKit

/// Everything a single "Export to Health" action can write. Heart rate is a
/// per-reading time series; the rest are session-level aggregates (steps,
/// energy — cumulative over the interval) or latest snapshots (HRV, respiration,
/// VO₂max). Zero/empty fields are skipped, so partial sessions still export.
struct HealthExportData {
    var readings: [HeartRateReading] = []
    var deviceName: String?
    var steps: Int = 0                 // count, cumulative over the session
    var activeCalories: Double = 0     // kcal, cumulative over the session
    var sdnn: Double = 0               // ms (HRV)
    var respiration: Int = 0           // breaths/min
    var vo2max: Double = 0             // ml·kg⁻¹·min⁻¹
    /// Window the cumulative samples (steps, energy) span. Defaults to the
    /// first/last reading when not set explicitly.
    var intervalStart: Date?
    var intervalEnd: Date?
}

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
    private let heartRateType   = HKQuantityType(.heartRate)
    private let stepType        = HKQuantityType(.stepCount)
    private let energyType      = HKQuantityType(.activeEnergyBurned)
    private let hrvType         = HKQuantityType(.heartRateVariabilitySDNN)
    private let respiratoryType = HKQuantityType(.respiratoryRate)
    private let vo2maxType      = HKQuantityType(.vo2Max)

    /// All sample types this app writes.
    private var shareTypes: Set<HKSampleType> {
        [heartRateType, stepType, energyType, hrvType, respiratoryType, vo2maxType]
    }

    // HealthKit units, built once.
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())   // heart rate, respiration
    private let hrvUnit = HKUnit.secondUnit(with: .milli)             // SDNN in ms
    private let vo2Unit = HKUnit.literUnit(with: .milli)             // ml/(kg·min)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Request permission to write all supported sample types.
    func requestAuthorization() async throws {
        guard isHealthDataAvailable else { throw ExportError.healthDataUnavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: [])
        // HealthKit never reveals whether *write* was granted (privacy). We optimistically
        // mark authorized; a denied write simply throws when we attempt the save.
        isAuthorized = true
    }

    /// Save a capture session to HealthKit: per-reading heart-rate samples plus
    /// any non-zero derived metrics (steps, active energy, HRV, respiration,
    /// VO₂max). Returns the number of samples written.
    @discardableResult
    func export(_ data: HealthExportData) async throws -> Int {
        guard isHealthDataAvailable else { throw ExportError.healthDataUnavailable }
        guard !data.readings.isEmpty else { throw ExportError.nothingToExport }

        if !isAuthorized {
            try await requestAuthorization()
        }

        let device = HKDevice(
            name: data.deviceName ?? "Polar H10",
            manufacturer: "Polar",
            model: "H10",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )

        // Interval the cumulative samples (steps, energy) cover.
        let start = data.intervalStart ?? data.readings.first?.date ?? data.readings[0].date
        let end   = data.intervalEnd   ?? data.readings.last?.date  ?? start
        // A snapshot metric (HRV/respiration/VO₂max) is stamped at the session end.
        let snapshot = end

        // Heart rate — one discrete sample per reading.
        var samples: [HKQuantitySample] = data.readings.map { reading in
            HKQuantitySample(
                type: heartRateType,
                quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(reading.bpm)),
                start: reading.date,
                end: reading.date,
                device: device,
                metadata: nil
            )
        }

        // Cumulative metrics span the whole session window.
        if data.steps > 0 {
            samples.append(HKQuantitySample(
                type: stepType,
                quantity: HKQuantity(unit: .count(), doubleValue: Double(data.steps)),
                start: start, end: end, device: device, metadata: nil))
        }
        if data.activeCalories > 0 {
            samples.append(HKQuantitySample(
                type: energyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: data.activeCalories),
                start: start, end: end, device: device, metadata: nil))
        }

        // Snapshot metrics are instantaneous (start == end).
        if data.sdnn > 0 {
            samples.append(HKQuantitySample(
                type: hrvType,
                quantity: HKQuantity(unit: hrvUnit, doubleValue: data.sdnn),
                start: snapshot, end: snapshot, device: device, metadata: nil))
        }
        if data.respiration > 0 {
            samples.append(HKQuantitySample(
                type: respiratoryType,
                quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(data.respiration)),
                start: snapshot, end: snapshot, device: device, metadata: nil))
        }
        if data.vo2max > 0 {
            samples.append(HKQuantitySample(
                type: vo2maxType,
                quantity: HKQuantity(unit: vo2Unit, doubleValue: data.vo2max),
                start: snapshot, end: snapshot, device: device, metadata: nil))
        }

        try await store.save(samples)
        let hrCount = data.readings.count
        let extra = samples.count - hrCount
        lastExportMessage = extra > 0
            ? "Exported \(hrCount) heart-rate samples + \(extra) metric\(extra == 1 ? "" : "s") to Health."
            : "Exported \(hrCount) heart-rate samples to Health."
        return samples.count
    }
}
