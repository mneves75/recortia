import Testing

@testable import Features

// Failure modes (A-13 step 2): one pre-built window handed to two presentations, a window built for
// a display that changed or went away shown again with stale geometry, spares piling up, or a
// disabled pool keeping windows (and their memory) alive anyway.
@Suite("Window spare pool (A-13 step 2)")
@MainActor
struct WindowSparePoolTests {
    final class Window {
        let key: String
        init(key: String) { self.key = key }
    }

    final class Builder {
        var built: [String] = []
        var fails: Set<String> = []

        func build(_ key: String) -> Window? {
            guard !fails.contains(key) else { return nil }
            built.append(key)
            return Window(key: key)
        }
    }

    @Test("A taken spare belongs to the taker: the next take builds a new window")
    func takeConsumesSpare() throws {
        let builder = Builder()
        let pool = WindowSparePool<String, Window>(isEnabled: true, build: builder.build)
        pool.prepare(["main"])
        let spare = try #require(pool.spare(for: "main"))
        let taken = try #require(pool.take("main"))
        #expect(taken === spare)
        #expect(pool.spare(for: "main") == nil)
        let next = try #require(pool.take("main"))
        #expect(next !== taken)
        #expect(builder.built == ["main", "main"])
    }

    @Test("Preparing again builds only what is missing and drops spares for displays no longer present")
    func prepareFollowsDisplays() throws {
        let builder = Builder()
        let pool = WindowSparePool<String, Window>(isEnabled: true, build: builder.build)
        pool.prepare(["a", "b"])
        let a = try #require(pool.spare(for: "a"))
        pool.prepare(["a", "c"])
        #expect(pool.spare(for: "a") === a)
        #expect(pool.spare(for: "b") == nil)
        #expect(pool.spare(for: "c") != nil)
        #expect(pool.spareCount == 2)
        #expect(builder.built.sorted() == ["a", "b", "c"])
    }

    @Test("A window given back is kept only for a wanted key without a spare")
    func giveBackIsBounded() throws {
        let builder = Builder()
        let pool = WindowSparePool<String, Window>(isEnabled: true, build: builder.build)
        pool.prepare(["a"])
        let first = try #require(pool.take("a"))
        let second = try #require(pool.take("a"))
        #expect(pool.giveBack(first, for: "a"))
        #expect(!pool.giveBack(second, for: "a"))
        #expect(pool.spare(for: "a") === first)
        // The display changed while its window was shown: the old window is never reused.
        let shown = try #require(pool.take("a"))
        pool.prepare(["a2"])
        #expect(!pool.giveBack(shown, for: "a"))
        #expect(pool.spare(for: "a") == nil)
        #expect(pool.spareCount == 1)
    }

    @Test("A disabled pool builds on demand and never holds a window")
    func disabledHoldsNothing() throws {
        let builder = Builder()
        let pool = WindowSparePool<String, Window>(isEnabled: false, build: builder.build)
        pool.prepare(["a"])
        #expect(builder.built.isEmpty)
        let window = try #require(pool.take("a"))
        #expect(!pool.giveBack(window, for: "a"))
        #expect(pool.spareCount == 0)
        #expect(builder.built == ["a"])
    }

    @Test("A key that cannot be built leaves no spare and take reports it")
    func failedBuild() {
        let builder = Builder()
        builder.fails = ["gone"]
        let pool = WindowSparePool<String, Window>(isEnabled: true, build: builder.build)
        pool.prepare(["gone"])
        #expect(pool.spareCount == 0)
        #expect(pool.take("gone") == nil)
    }
}
