import Foundation
import Testing
@testable import WispCore

@Suite struct FanTests {
    final class FakeFans: FanHardware {
        var fans = [FanState(index: 0, rpm: nil, minRPM: 2000, maxRPM: 6000), FanState(index: 1, rpm: nil, minRPM: 2500, maxRPM: 7500)]
        var celsius: Double? = 50
        var thermalPressure: ThermalPressure = .nominal
        var manual: [Int: Double] = [:]
        var automaticCalls = 0
        var refuses = false

        func temperatures() -> FanTemperatures { FanTemperatures(cpu: celsius, gpu: celsius.map { $0 - 5 }, hottest: celsius) }
        func rpm(_ index: Int) -> Double? { manual[index] ?? 1800 }
        func setManual(_ index: Int, rpm: Double) -> Bool {
            guard !refuses else { return false }
            manual[index] = rpm
            return true
        }
        func setAutomatic(_ index: Int) -> Bool {
            automaticCalls += 1
            manual[index] = nil
            return true
        }
    }

    @Test func curvesInterpolateAndHoldFlatPastTheirEnds() {
        let curve = FanCurve(name: "Test", points: [.init(80, 100), .init(40, 0), .init(60, 50)])
        #expect(curve.points.map(\.celsius) == [40, 60, 80])
        #expect(curve.percent(at: 20) == 0)
        #expect(curve.percent(at: 50) == 25)
        #expect(curve.percent(at: 70) == 75)
        #expect(curve.percent(at: 99) == 100)
        #expect(FanCurve(name: "Empty", points: []).percent(at: 70) == 0)
        // Out of range values are clamped, and two points on one degree keep the first.
        let clamped = FanCurve(name: "Odd", points: [.init(10, -5), .init(150, 300), .init(10.2, 40)])
        #expect(clamped.points == [.init(30, 0), .init(100, 100)])
    }

    @Test func modesParseFromWhatPeopleType() {
        let mine = FanCurve(name: "Render", points: [.init(50, 20)])
        #expect(FanMode.parse("auto", curves: []) == .auto)
        #expect(FanMode.parse("MAX", curves: []) == .max)
        #expect(FanMode.parse("quiet", curves: []) == .quiet)
        #expect(FanMode.parse("60%", curves: []) == .fixed(60))
        #expect(FanMode.parse("render", curves: [mine]) == .curve(mine))
        #expect(FanMode.parse("140%", curves: []) == nil)
        #expect(FanMode.parse("loud", curves: []) == nil)
        #expect(FanMode.fixed(60).title == "60%" && FanMode.max.title == "Max" && FanMode.quiet.title == "Quiet")
    }

    @Test func speedsRiseFastAndFallSlowly() {
        #expect(FanEngine.ease(from: nil, to: 40) == 40)
        #expect(FanEngine.ease(from: 10, to: 90) == 35)
        #expect(FanEngine.ease(from: 90, to: 10) == 86)
        #expect(FanEngine.ease(from: 50, to: nil) == nil)
    }

    @Test func fixedSpeedsSpreadOverEachFansOwnRange() {
        let fans = FakeFans()
        let engine = FanEngine(hardware: fans)
        engine.set(.fixed(50))
        let status = engine.tick()
        #expect(fans.manual == [0: 4000, 1: 5000])
        #expect(status.percent == 50 && status.fans.map(\.targetRPM) == [4000, 5000])
        engine.set(.auto)
        let back = engine.tick()
        #expect(fans.manual.isEmpty && back.percent == nil && back.fans.allSatisfy { $0.targetRPM == nil })
    }

    @Test func curvesGiveTheFansBackToMacOSWhereTheyReachZero() {
        let fans = FakeFans()
        let engine = FanEngine(hardware: fans)
        engine.set(.curve(FanCurve(name: "T", points: [.init(60, 0), .init(80, 100)])))
        fans.celsius = 70
        engine.tick()
        #expect(fans.manual[0] == 4000)
        // Cooling down eases off 4 points a tick before macOS takes over again.
        fans.celsius = 40
        engine.tick()
        #expect(fans.manual[0] == 2000 + 4000 * 0.46)
        for _ in 0..<20 { engine.tick() }
        #expect(fans.manual.isEmpty)
    }

    @Test func overheatingRunsTheFansFullUntilTheChipCools() {
        let fans = FakeFans()
        let engine = FanEngine(hardware: fans)
        engine.set(.fixed(0))
        fans.celsius = 96
        var status = engine.tick()
        #expect(status.overheated && status.percent == 100)
        fans.celsius = 88
        status = engine.tick()
        #expect(status.overheated && status.percent == 100)
        fans.celsius = 80
        for _ in 0..<30 { status = engine.tick() }
        #expect(!status.overheated && status.percent == 0)
        // Automatic leaves the heat to macOS.
        engine.set(.auto)
        fans.celsius = 99
        #expect(!engine.tick().overheated)
    }

    @Test func missingTemperaturesForceFullSpeedEvenInFixedMode() {
        let fans = FakeFans()
        fans.celsius = nil
        let engine = FanEngine(hardware: fans)
        engine.set(.quiet)
        #expect(engine.tick().percent == 100)
        engine.set(.fixed(0))
        #expect(engine.tick().percent == 100)
    }

    @Test func seriousThermalPressureJumpsImmediatelyToFullSpeed() {
        let fans = FakeFans()
        fans.celsius = 70
        let engine = FanEngine(hardware: fans)
        engine.set(.fixed(10))
        #expect(engine.tick().percent == 10)
        // macOS thermal throttling jumps straight to 100% on the first tick, skipping the 25%/tick ramp.
        fans.thermalPressure = .serious
        let hot = engine.tick()
        #expect(hot.overheated && hot.percent == 100)
        // Stays overheated until thermal pressure itself clears, even when sensor temp is below 85°C.
        #expect(engine.tick().overheated)
        fans.thermalPressure = .nominal
        let recovered = engine.tick()
        #expect(!recovered.overheated)
    }

    @Test func repeatedRefusedWritesRestoreAutomaticControl() {
        let fans = FakeFans()
        let engine = FanEngine(hardware: fans)
        engine.set(.max)
        #expect(engine.tick().percent == 100)
        fans.refuses = true
        for _ in 0..<(FanEngine.maxWriteFailures - 1) {
            let status = engine.tick()
            #expect(status.error != nil && engine.isManaging)
        }
        // On the Nth consecutive failure, the engine hands the fans back to macOS while keeping the error.
        let failed = engine.tick()
        #expect(failed.error != nil && !engine.isManaging && fans.manual.isEmpty && fans.automaticCalls == 2)
    }

    @Test func restoreAlwaysCallsHardwareEvenBeforeManaged() {
        let fans = FakeFans()
        let engine = FanEngine(hardware: fans)
        engine.restore()
        #expect(fans.automaticCalls == 2 && !engine.isManaging)
    }

    @Test func theInstallerChecksTheCopyAndRunsItForOneUser() {
        let script = FanHelper.installScript(helper: "/Applications/Wis'p.app/Contents/Helpers/wisp-fan-helper", sha256: "abc123", uid: 501)
        #expect(script.contains("cp '/Applications/Wis'\\''p.app/Contents/Helpers/wisp-fan-helper' '/Library/PrivilegedHelperTools/app.wisp.fans.new'"))
        #expect(script.contains("!= 'abc123'"))
        #expect(script.contains("<string>--user</string>\n        <string>501</string>"))
        #expect(script.contains("<key>ProcessType</key>\n    <string>Interactive</string>"))
        #expect(script.contains("<key>Nice</key>\n    <integer>-10</integer>"))
        #expect(script.contains("\nPLIST\n"))
        #expect(script.hasSuffix("launchctl bootstrap system '/Library/LaunchDaemons/app.wisp.fans.plist'"))
        #expect(FanHelper.uninstallScript.hasPrefix("launchctl bootout system/app.wisp.fans"))
    }

    @Test func modesRoundTripThroughJSON() throws {
        for mode in [FanMode.auto, .max, .fixed(35), .quiet] {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(FanMode.self, from: data) == mode)
        }
    }
}

@Test func presetsRiseFromQuietestToCoolest() {
    for (slower, faster) in zip(FanCurve.presets, FanCurve.presets.dropFirst()) {
        for celsius in stride(from: 30.0, through: 100, by: 1) {
            #expect(slower.percent(at: celsius) <= faster.percent(at: celsius), "\(slower.name) above \(faster.name) at \(celsius)°")
        }
    }
    for preset in FanCurve.presets {
        #expect(preset.percent(at: 45) == 0)
        #expect(FanMode.parse(preset.name.lowercased(), curves: []) == .curve(preset))
    }
}
