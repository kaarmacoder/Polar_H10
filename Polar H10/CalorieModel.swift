//
//  CalorieModel.swift
//  Polar H10
//
//  HR-based energy-expenditure model (Keytel et al., 2005) plus the user
//  profile it needs. Heart rate is taken from the ECG/HR stream; the profile
//  is persisted in UserDefaults.
//

import Foundation
import Combine

enum Sex: String, Codable, CaseIterable, Identifiable {
    case male, female
    var id: String { rawValue }
    var label: String { self == .male ? "Male" : "Female" }
}

/// Anthropometric + fitness inputs required by the calorie model.
struct UserProfile: Codable, Equatable {
    var age: Int
    var weightKg: Double
    var heightCm: Double
    var sex: Sex

    /// Resting heart rate (bpm). Used to auto-estimate VO₂max.
    var restingHr: Int
    /// Max heart rate (bpm). 0 → auto-estimate as 220 − age.
    var maxHr: Int
    /// Measured VO₂max (ml·kg⁻¹·min⁻¹). 0 → auto-estimate from HRmax/HRrest.
    var vo2max: Double

    static let `default` = UserProfile(
        age: 30, weightKg: 70, heightCm: 175, sex: .male,
        restingHr: 60, maxHr: 0, vo2max: 0
    )

    /// Decoding tolerant of older persisted profiles missing the fitness fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        age      = try c.decode(Int.self, forKey: .age)
        weightKg = try c.decode(Double.self, forKey: .weightKg)
        heightCm = try c.decode(Double.self, forKey: .heightCm)
        sex      = try c.decode(Sex.self, forKey: .sex)
        restingHr = try c.decodeIfPresent(Int.self, forKey: .restingHr) ?? 60
        maxHr     = try c.decodeIfPresent(Int.self, forKey: .maxHr) ?? 0
        vo2max    = try c.decodeIfPresent(Double.self, forKey: .vo2max) ?? 0
    }

    init(age: Int, weightKg: Double, heightCm: Double, sex: Sex,
         restingHr: Int, maxHr: Int, vo2max: Double) {
        self.age = age; self.weightKg = weightKg; self.heightCm = heightCm; self.sex = sex
        self.restingHr = restingHr; self.maxHr = maxHr; self.vo2max = vo2max
    }

    /// Max HR, falling back to the Fox formula (220 − age).
    var effectiveMaxHr: Int { maxHr > 0 ? maxHr : max(120, 220 - age) }

    /// VO₂max, falling back to the Uth–Sørensen estimate (15.3 × HRmax/HRrest).
    var effectiveVo2max: Double {
        if vo2max > 0 { return vo2max }
        return 15.3 * Double(effectiveMaxHr) / Double(max(30, restingHr))
    }
}

enum CalorieEstimator {

    /// Keytel et al. (2005) heart-rate energy-expenditure regression, fitness
    /// (VO₂max) variant.
    ///
    /// Predicts gross energy expenditure in **kJ per minute** from heart rate,
    /// VO₂max, body weight, age and sex, then converts to kcal/min. Validated
    /// for exercise-range heart rates; at rest it can predict a negative value,
    /// so the result is clamped to zero.
    ///
    /// Reference: Keytel LR et al., "Prediction of energy expenditure from
    /// heart rate monitoring during submaximal exercise", J Sports Sci, 2005.
    static func kcalPerMinute(hr: Int, profile: UserProfile) -> Double {
        guard hr > 0 else { return 0 }
        let h = Double(hr)
        let w = profile.weightKg
        let a = Double(profile.age)
        let v = profile.effectiveVo2max

        let kJPerMinute: Double
        switch profile.sex {
        case .male:
            kJPerMinute = -95.7735 + 0.634 * h + 0.404 * v + 0.394 * w + 0.271 * a
        case .female:
            kJPerMinute = -59.3954 + 0.450 * h + 0.380 * v + 0.103 * w + 0.274 * a
        }
        return max(0, kJPerMinute / 4.184) // 1 kcal = 4.184 kJ
    }
}

/// Source of truth for the user profile, persisted across launches.
final class ProfileStore: ObservableObject {
    @Published var profile: UserProfile {
        didSet { save() }
    }

    private let key = "userProfile"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: data) {
            profile = decoded
        } else {
            profile = .default
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
