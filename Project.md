# Polar H10 — SwiftUI App

BLE SDK: https://github.com/polarofficial/polar-ble-sdk.git
- Integrated via Swift Package Manager, pinned to **PolarBleSdk 8.0.0** (uses async/await + Combine; no RxSwift).
- Product docs: https://github.com/polarofficial/polar-ble-sdk/blob/master/documentation/products/PolarH10.md

---

## Features available in the SDK (for Polar H10)

Capabilities the H10 + SDK expose. ✅ = integrated in this app, ⬜ = available but not integrated.

| SDK Feature flag | Capability | Status |
|---|---|---|
| `feature_hr` | Heart rate (BPM), RR intervals (ms), skin-contact status | ✅ |
| `feature_polar_online_streaming` → ECG | Electrocardiography, 130 Hz, microvolts (µV) | ✅ |
| `feature_polar_online_streaming` → ACC | Accelerometer, 25/50/100/200 Hz, milli-g (x/y/z) | ✅ |
| `feature_battery_info` | Battery level (0–100%) | ✅ |
| `feature_device_info` | Device Information Service (firmware, model, serial, etc.) | ⬜ |
| Heart rate broadcast | Non-connected HR advertisement / auto-connect by RSSI | ⬜ |
| `feature_polar_h10_exercise_recording` | On-device (offline) exercise recording: start/stop/status/list/read/remove | ⬜ |
| `feature_polar_offline_recording` | Generic offline recording to device flash | ⬜ |
| `feature_polar_device_time_setup` | Read / set device time | ⬜ |
| `feature_polar_sdk_mode` | SDK mode (wider stream setting ranges) | ⬜ |
| `feature_polar_led_animation` | Enable/disable SDK-mode LED animation | ⬜ |
| `feature_polar_firmware_update` | Firmware update | ⬜ |

> Note: the H10 does **not** provide PPG/PPI/Gyro/Magnetometer/Temperature/Pressure online streams — those `PolarDeviceDataType` cases exist in the SDK but apply to other Polar devices.

---

## Features integrated in this app

Maps to the original requirements (1–6) plus the in-app ECG/Motion recording.

| # | Requirement | How it's implemented | Code |
|---|---|---|---|
| 1 | **Discover devices** | `searchForDevice()` async stream → deduplicated list sorted by signal strength | `PolarManager.startSearch()` |
| 2 | **Connect / Disconnect** | `connectToDevice` / `disconnectFromDevice` | `PolarManager.connect(to:)` / `disconnect()` |
| 3 | **Connected status** | `PolarBleApiObserver` + power-state + battery observers → `@Published` state shown in status card | `PolarManager` observer extensions |
| 4 | **Show data on screen** | Live HR (BPM), RR intervals, skin contact, battery, + Swift Charts HR graph | `HeartRateView` |
| 5 | **Start / Pause / Stop** | Async `Task` lifecycle around `startHrStreaming`; pause keeps the buffer, stop finalizes it | `PolarManager.startStreaming()` / `pauseStreaming()` / `stopStreaming()` |
| 6 | **Export to iOS Health** | Buffered readings written as `HKQuantitySample` heart-rate samples | `HealthKitManager.export(_:deviceName:)` |
| + | **ECG recording (in-app)** | `requestStreamSettings(.ecg)` → `startEcgStreaming`; live 130 Hz waveform (baseline high-pass filtered for display), record/stop/clear, CSV export | `ECGView`, `PolarManager.startEcg()` |
| + | **Motion recording (in-app)** | `requestStreamSettings(.acc)` → `startAccStreaming`; live 3-axis waveform, record/stop/clear, CSV export | `MotionView`, `PolarManager.startAcc()` |
| + | **Calorie estimation** | HR-based energy expenditure (Keytel 2005 **VO₂max variant**) using a persisted profile incl. resting HR / max HR / VO₂max (auto-estimated when 0); accumulated live | `CaloriesView`, `CalorieEstimator`, `ProfileStore` |
| + | **Capture session + ZIP export** | "Start Counting" records HR + ECG + motion together; streamed to disk incrementally; on stop bundles date-stamped CSVs into one ZIP (`NSFileCoordinator`, no extra dependency) via `ShareLink` | `PolarManager.startSession()` / `stopSession()`, `SessionWriter` |
| + | **Background recording** | Session keeps running when backgrounded, screen-locked, or after a system-termination relaunch (CoreBluetooth state restoration); auto-reconnects mid-session; only Stop ends it | `bluetooth-central` mode, `restoreIdentifier`, `restoreSessionIfNeeded()` |

### Background recording — how it works
- **Background mode:** `UIBackgroundModes = bluetooth-central` (declared in `Info.plist`, surfaced in Xcode as Background Modes → "Uses Bluetooth LE accessories") lets the already-connected H10's HR/ECG/ACC notifications keep waking the app to record while backgrounded or locked.
- **Disk-backed:** samples are appended to CSV files in Application Support (file protection `completeUntilFirstUserAuthentication`, so writes work while locked) — memory stays bounded for arbitrarily long sessions; the in-memory buffers only feed the live charts.
- **State restoration:** the SDK is created with a `restoreIdentifier`; if iOS terminates the app under memory pressure it relaunches in the background, reopens the session files, and resumes streaming on reconnect. The active session is persisted in `UserDefaults`.
- **Auto-reconnect:** a mid-session disconnect doesn't tear down — the SDK reconnects and streams resume from the feature-ready callbacks, preserving the calorie total.
- **Limitation (iOS):** if the user **force-quits** (swipe-away in the App Switcher), iOS will not relaunch the app and recording ends — this is an OS rule no app can override.

HR, ECG and ACC streams run as independent tasks and can record concurrently. ECG/Motion recordings are buffered in memory (capped ~5 min) and can be exported to CSV via the iOS share sheet.

### Sensors & calories — notes
- **H10 sensors:** ECG electrodes (HR / RR / HRV) + a 3-axis accelerometer. **No gyroscope, magnetometer, altimeter or GPS** — so the Motion tab is accelerometer-only, and incline/elevation cannot be measured directly.
- **Why HR drives calories:** heart rate reflects total physiological effort (including incline, load, fatigue) that a chest accelerometer can't see, so the Keytel HR model captures inclined running automatically. The accelerometer is available as a future refinement (Brage branched model).
- **Limitations:** HR-based EE is strong for cardio, approximate for resistance training (HR decouples from energy cost). A "complete gym session" would benefit from extra sensors not present on the H10 (wrist/limb IMU, altimeter, GPS, respiration).
- **Profile inputs:** age, weight, sex, height — edited on the Calories tab, persisted in `UserDefaults`.

---

## Project structure

| File | Responsibility |
|---|---|
| `Polar_H10App.swift` | App entry; injects `PolarManager` and `HealthKitManager` as environment objects |
| `PolarManager.swift` | SDK wrapper: discovery, connection, observers, HR/ECG/ACC streaming, CSV export |
| `HealthKitManager.swift` | HealthKit authorization + writing heart-rate samples |
| `ContentView.swift` | 3-tab UI: Heart Rate · ECG · Motion |
| `Polar_H10.entitlements` | HealthKit capability |

### Configuration (already set in the Xcode project)
- SPM dependency: `PolarBleSdk` @ 8.0.0
- Privacy strings: `NSBluetoothAlwaysUsageDescription`, `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`
- Entitlement: HealthKit (`com.apple.developer.healthkit`)

### Running
Run on a **real iPhone** — BLE and the Polar sensor are not available in the iOS Simulator.
