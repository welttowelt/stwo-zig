// StwoBenchView.swift — minimal shell around the stwo-zig mobile bench.
//
// Setup (10 min): create an iOS App project in Xcode, drop this file in,
// link libstwo_mobile_bench.a (build it with ../build_ios_lib.sh) under
// "Link Binary With Libraries", and add the lib's folder to Library Search
// Paths. No bridging header needed — the two C symbols are bound below.
//
// The bench runs on a background queue; the phone should be on a charger,
// screen kept awake, airplane mode, for anything you intend to report.

import SwiftUI

@_silgen_name("stwo_mobile_bench")
func stwo_mobile_bench(_ argLine: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>

@_silgen_name("stwo_mobile_bench_free")
func stwo_mobile_bench_free(_ ptr: UnsafeMutablePointer<CChar>)

struct Workload: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let args: String
}

let workloads: [Workload] = [
    Workload(name: "small — wide_fibonacci 2^10×8",
             args: "--example wide_fibonacci --log-n-rows 10 --sequence-len 8 --protocol functional --warmups 2 --samples 5"),
    Workload(name: "wide — wide_fibonacci 2^14×32",
             args: "--example wide_fibonacci --log-n-rows 14 --sequence-len 32 --protocol functional --warmups 2 --samples 5"),
    Workload(name: "deep — plonk 2^14",
             args: "--example plonk --log-n-rows 14 --protocol functional --warmups 2 --samples 5"),
]

struct StwoBenchView: View {
    @State private var selected = workloads[0]
    @State private var running = false
    @State private var report = "no run yet"
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
        NavigationStack {
            Form {
                Section("workload") {
                    Picker("workload", selection: $selected) {
                        ForEach(workloads) { w in Text(w.name).tag(w) }
                    }
                }
                Section {
                    Button(running ? "running…" : "run bench") { runBench() }
                        .disabled(running)
                    Text("thermal: \(String(describing: thermal)) · lowPower: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON (do not report)" : "off")")
                        .font(.footnote)
                }
                Section("report json") {
                    ScrollView { Text(report).font(.system(size: 10, design: .monospaced)) }
                        .frame(minHeight: 240)
                    ShareLink(item: report)
                }
            }
            .navigationTitle("stwo mobile bench")
        }
    }

    private func runBench() {
        running = true
        // UIKit is main-thread-only: idle timer, UIDevice reads, and the
        // start/end snapshots all happen on main; only the bench runs on
        // the worker queue.
        UIApplication.shared.isIdleTimerDisabled = true
        let start = deviceSnapshot()
        thermal = ProcessInfo.processInfo.thermalState
        let args = selected.args
        DispatchQueue.global(qos: .userInitiated).async {
            let out = args.withCString { stwo_mobile_bench($0) }
            let json = String(cString: out)
            stwo_mobile_bench_free(out)
            DispatchQueue.main.async {
                let end = deviceSnapshot()
                report = wrapWithDeviceIdentity(reportJSON: json, start: start, end: end)
                running = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}

// One point-in-time device snapshot (main thread only — UIDevice/UIKit).
// Taken at run start AND run end per schema/mobile-proof-v1.md; battery
// delta is coarse (1% steps) — MetricKit calibration is the open task.
func deviceSnapshot() -> [String: Any] {
    UIDevice.current.isBatteryMonitoringEnabled = true
    return [
        "thermal_state": String(describing: ProcessInfo.processInfo.thermalState),
        "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        "battery_level": UIDevice.current.batteryLevel,
        "battery_state": UIDevice.current.batteryState.rawValue,
        "uptime_seconds": ProcessInfo.processInfo.systemUptime,
    ]
}

func wrapWithDeviceIdentity(reportJSON: String, start: [String: Any], end: [String: Any]) -> String {
    let batteryDelta: Any = {
        if let s = start["battery_level"] as? Float, let e = end["battery_level"] as? Float,
           s >= 0, e >= 0 { return s - e }
        return NSNull() // simulator / monitoring unavailable
    }()
    let device: [String: Any] = [
        "model": UIDevice.current.model,
        "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
        "machine": machineIdentifier(),
        "at_start": start,
        "at_end": end,
        "battery_delta": batteryDelta,
    ]
    guard let deviceData = try? JSONSerialization.data(withJSONObject: device),
          let deviceStr = String(data: deviceData, encoding: .utf8) else { return reportJSON }
    return "{\"schema\":\"mobile-proof-v1\",\"device_identity\":\(deviceStr),\"prover_report\":\(reportJSON)}"
}

func machineIdentifier() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
}
