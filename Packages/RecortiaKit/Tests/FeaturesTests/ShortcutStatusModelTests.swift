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
        let registry = FakeShortcutRegistry(assigned: ["captureRegion", "captureWindow"])
        registry.failing = ["captureRegion"]
        let model = ShortcutStatusModel(registry: registry, names: names)
        model.refreshAll()
        #expect(model.state(of: "captureRegion") == .failed)
        #expect(model.hasFailed("captureRegion"))
        #expect(model.state(of: "captureWindow") == .active)
        #expect(model.state(of: "captureDisplay") == .unassigned)

        registry.assigned.remove("captureRegion")
        model.refresh(named: "captureRegion")
        #expect(model.state(of: "captureRegion") == .unassigned)
        #expect(!model.hasFailed("captureRegion"))
    }

    @Test("A shortcut macOS claims is held, never registered, until macOS lets it go")
    func heldWhileMacOSClaimsIt() {
        let registry = FakeShortcutRegistry(assigned: ["captureRegion", "captureDisplay"])
        registry.takenBySystem = ["captureRegion"]
        let model = ShortcutStatusModel(registry: registry, names: names)
        model.refreshAll()
        #expect(model.state(of: "captureRegion") == .heldBySystem)
        #expect(registry.registered["captureRegion"] == false)
        #expect(registry.probed.contains("captureRegion") == false)
        #expect(model.state(of: "captureDisplay") == .active)
        #expect(registry.registered["captureDisplay"] == true)
        #expect(model.isHoldingAny)

        registry.takenBySystem = []
        model.refreshAll()
        #expect(model.state(of: "captureRegion") == .active)
        #expect(registry.registered["captureRegion"] == true)
        #expect(!model.isHoldingAny)
    }

    @Test("Every path that holds a shortcut reports it, so the caller starts watching")
    func holdingIsReported() {
        let registry = FakeShortcutRegistry(assigned: ["captureRegion"])
        let model = ShortcutStatusModel(registry: registry, names: names)
        var reports = 0
        model.onHold = { reports += 1 }
        model.refreshAll()
        #expect(reports == 0)

        registry.takenBySystem = ["captureRegion"]  // e.g. a recording forced onto macOS's keys
        model.refresh(named: "captureRegion")
        #expect(reports == 1)
        #expect(!model.admitPress(named: "captureRegion"))
        #expect(reports == 2)
    }

    @Test("Watching a held shortcut re-checks only held ones, never re-probing active registrations")
    func refreshHeldTouchesOnlyHeld() {
        let registry = FakeShortcutRegistry(assigned: ["captureRegion", "captureDisplay"])
        registry.takenBySystem = ["captureRegion"]
        let model = ShortcutStatusModel(registry: registry, names: names)
        model.refreshAll()
        let probesBefore = registry.probed

        model.refreshHeld()
        #expect(registry.probed == probesBefore)
        #expect(model.state(of: "captureRegion") == .heldBySystem)

        registry.takenBySystem = []
        model.refreshHeld()
        #expect(model.state(of: "captureRegion") == .active)
        #expect(registry.probed == probesBefore + ["captureRegion"])
        #expect(!model.isHoldingAny)
    }

    @Test("A press while macOS claims the keys does nothing and holds the shortcut")
    func pressWhileClaimedIsIgnored() {
        let registry = FakeShortcutRegistry(assigned: ["captureRegion"])
        let model = ShortcutStatusModel(registry: registry, names: names)
        model.refreshAll()
        #expect(model.admitPress(named: "captureRegion"))

        registry.takenBySystem = ["captureRegion"]  // the user turned the macOS shortcut back on
        #expect(!model.admitPress(named: "captureRegion"))
        #expect(model.state(of: "captureRegion") == .heldBySystem)
        #expect(registry.registered["captureRegion"] == false)
    }

    @Test("An unassigned shortcut is left registrable so a new recording works at once")
    func unassignedStaysRegistrable() {
        let registry = FakeShortcutRegistry(assigned: [])
        let model = ShortcutStatusModel(registry: registry, names: names)
        model.refreshAll()
        #expect(names.allSatisfy { model.state(of: $0) == .unassigned })
        #expect(names.allSatisfy { registry.registered[$0] == true })
    }

    @Test("Defaults go only to unassigned commands, once, never onto keys already in use")
    func seedingPlan() {
        let defaults = [
            DefaultShortcut(name: "captureDisplay", shortcut: "⇧⌘3"),
            DefaultShortcut(name: "captureRegion", shortcut: "⇧⌘4"),
            DefaultShortcut(name: "captureMenu", shortcut: "⇧⌘5"),
        ]
        func seed(_ assigned: [String: String], offered: Set<String> = []) -> [String] {
            ShortcutDefaultsPlan.defaultsToSeed(defaults, assigned: assigned, alreadyOffered: offered).map(\.name)
        }
        #expect(seed([:]) == ["captureDisplay", "captureRegion", "captureMenu"])
        #expect(seed([:], offered: ["captureDisplay", "captureRegion", "captureMenu"]).isEmpty)
        #expect(seed(["captureRegion": "⌥⌘R"]) == ["captureDisplay", "captureMenu"])
        #expect(seed(["captureWindow": "⇧⌘4"]) == ["captureDisplay", "captureMenu"])
        // A default added in a later version is offered once; ones the user cleared never return.
        #expect(seed([:], offered: ["captureDisplay", "captureRegion"]) == ["captureMenu"])
    }

    @Test("Restore Defaults returns every command to the table and clears the rest")
    func restorePlan() {
        let defaults = [
            DefaultShortcut(name: "captureDisplay", shortcut: "⇧⌘3"),
            DefaultShortcut(name: "captureRegion", shortcut: "⇧⌘4"),
        ]
        let restored = ShortcutDefaultsPlan.restored(
            names: ["captureRegion", "captureDisplay", "captureText"], defaults: defaults)
        #expect(restored == ["captureRegion": "⇧⌘4", "captureDisplay": "⇧⌘3", "captureText": nil])
    }
}
