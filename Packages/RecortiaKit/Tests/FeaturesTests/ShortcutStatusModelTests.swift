import Testing

@testable import Features

// Failure modes of default global shortcuts (ADR-005), written before the implementation:
//  1. macOS and Recortia both react to one key press: a shortcut macOS claims is held (never
//     registered), and a press that arrives while macOS claims it does nothing.
//  2. A held default stays silent after the user turns the macOS shortcut off: refreshing
//     registers it again, and the model says when it still needs watching.
//  3. Seeding overwrites a user's shortcut, revives a cleared one, or gives two Recortia commands
//     the same keys (two actions per press).
//  4. Another app holds the combination: registration fails and is reported, never claimed.
@Suite("Global shortcut status and defaults (FR-01, ADR-005)")
@MainActor
struct ShortcutStatusModelTests {
    private let names = ["captureRegion", "captureDisplay", "captureWindow"]

    @Test("Registration failures are tracked per name")
    func registrationFailure() {
        let probe = FakeShortcutProbe(assigned: ["captureRegion", "captureWindow"])
        probe.failing = ["captureRegion"]
        let model = ShortcutStatusModel(probe: probe, names: names)
        model.refreshAll()
        #expect(model.state(of: "captureRegion") == .failed)
        #expect(model.hasFailed("captureRegion"))
        #expect(model.state(of: "captureWindow") == .active)
        #expect(model.state(of: "captureDisplay") == .unassigned)

        probe.assigned.remove("captureRegion")
        model.refresh(named: "captureRegion")
        #expect(model.state(of: "captureRegion") == .unassigned)
        #expect(!model.hasFailed("captureRegion"))
    }

    @Test("A shortcut macOS claims is held, never registered, until macOS lets it go")
    func heldWhileMacOSClaimsIt() {
        let probe = FakeShortcutProbe(assigned: ["captureRegion", "captureDisplay"])
        probe.takenBySystem = ["captureRegion"]
        let model = ShortcutStatusModel(probe: probe, names: names)
        model.refreshAll()
        #expect(model.state(of: "captureRegion") == .heldBySystem)
        #expect(probe.registered["captureRegion"] == false)
        #expect(probe.probed.contains("captureRegion") == false)
        #expect(model.state(of: "captureDisplay") == .active)
        #expect(probe.registered["captureDisplay"] == true)
        #expect(model.isHoldingAny)

        probe.takenBySystem = []
        model.refreshAll()
        #expect(model.state(of: "captureRegion") == .active)
        #expect(probe.registered["captureRegion"] == true)
        #expect(!model.isHoldingAny)
    }

    @Test("Watching a held shortcut re-checks only held ones, never re-probing active registrations")
    func refreshHeldTouchesOnlyHeld() {
        let probe = FakeShortcutProbe(assigned: ["captureRegion", "captureDisplay"])
        probe.takenBySystem = ["captureRegion"]
        let model = ShortcutStatusModel(probe: probe, names: names)
        model.refreshAll()
        let probesBefore = probe.probed

        model.refreshHeld()
        #expect(probe.probed == probesBefore)
        #expect(model.state(of: "captureRegion") == .heldBySystem)

        probe.takenBySystem = []
        model.refreshHeld()
        #expect(model.state(of: "captureRegion") == .active)
        #expect(probe.probed == probesBefore + ["captureRegion"])
        #expect(!model.isHoldingAny)
    }

    @Test("A press while macOS claims the keys does nothing and holds the shortcut")
    func pressWhileClaimedIsIgnored() {
        let probe = FakeShortcutProbe(assigned: ["captureRegion"])
        let model = ShortcutStatusModel(probe: probe, names: names)
        model.refreshAll()
        #expect(model.shouldPerform(named: "captureRegion"))

        probe.takenBySystem = ["captureRegion"]  // the user turned the macOS shortcut back on
        #expect(!model.shouldPerform(named: "captureRegion"))
        #expect(model.state(of: "captureRegion") == .heldBySystem)
        #expect(probe.registered["captureRegion"] == false)
    }

    @Test("An unassigned shortcut is left registrable so a new recording works at once")
    func unassignedStaysRegistrable() {
        let probe = FakeShortcutProbe(assigned: [])
        let model = ShortcutStatusModel(probe: probe, names: names)
        model.refreshAll()
        #expect(names.allSatisfy { model.state(of: $0) == .unassigned })
        #expect(names.allSatisfy { probe.registered[$0] == true })
    }

    @Test("Defaults go only to unassigned commands, once, never onto keys already in use")
    func seedingPlan() {
        let defaults: [(name: String, shortcut: String)] = [
            ("captureDisplay", "⇧⌘3"), ("captureRegion", "⇧⌘4"), ("captureMenu", "⇧⌘5"),
        ]
        #expect(
            ShortcutDefaultsPlan.namesToSeed(defaults: defaults, assigned: [:], seededVersion: 0)
                == ["captureDisplay", "captureRegion", "captureMenu"])
        #expect(
            ShortcutDefaultsPlan.namesToSeed(
                defaults: defaults, assigned: [:], seededVersion: ShortcutDefaultsPlan.version
            ).isEmpty)
        #expect(
            ShortcutDefaultsPlan.namesToSeed(
                defaults: defaults, assigned: ["captureRegion": "⌥⌘R"], seededVersion: 0)
                == ["captureDisplay", "captureMenu"])
        #expect(
            ShortcutDefaultsPlan.namesToSeed(
                defaults: defaults, assigned: ["captureWindow": "⇧⌘4"], seededVersion: 0)
                == ["captureDisplay", "captureMenu"])
    }

    @Test("Restore Defaults returns every command to the table and clears the rest")
    func restorePlan() {
        let defaults: [(name: String, shortcut: String)] = [("captureDisplay", "⇧⌘3"), ("captureRegion", "⇧⌘4")]
        let restored = ShortcutDefaultsPlan.restored(
            names: ["captureRegion", "captureDisplay", "captureText"], defaults: defaults)
        #expect(restored == ["captureRegion": "⇧⌘4", "captureDisplay": "⇧⌘3", "captureText": nil])
    }
}
