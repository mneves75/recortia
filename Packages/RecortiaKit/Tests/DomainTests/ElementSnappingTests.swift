import Foundation
import Testing

@testable import Domain

// Failure modes (FR-02, B-7, ADR-010): a walk of another app's interface that outlives its depth,
// element or time bound when the tree is huge or slow; an unreadable element whose subtree is still
// walked; the app or its windows taken as element frames; tiny or off-display elements that become
// snap targets; a reading type that could carry on-screen text.
@Suite("Interface element snapping (FR-02, B-7)")
struct ElementSnappingTests {
    /// A synthetic interface tree: every node down to `depth` has `fanOut` children. Each read
    /// advances the clock by `cost`; `unreadable` nodes fail to read.
    final class Tree {
        let depth: Int
        let fanOut: Int
        let cost: Duration
        var unreadable: Set<[Int]> = []
        var now = Duration.zero
        var reads = 0
        var deepestRead = 0
        var childRequests: [[Int]] = []

        init(depth: Int, fanOut: Int, cost: Duration = .zero) {
            self.depth = depth
            self.fanOut = fanOut
            self.cost = cost
        }
    }

    struct Node: InterfaceElementNode {
        let tree: Tree
        let path: [Int]

        func read() -> InterfaceElementReading? {
            tree.reads += 1
            tree.now += tree.cost
            tree.deepestRead = max(tree.deepestRead, path.count)
            guard !tree.unreadable.contains(path) else { return nil }
            let offset = Double(path.reduce(0, +))
            return InterfaceElementReading(
                frame: Rect(x: 10 + offset, y: 10 + Double(path.count), width: 40, height: 20),
                kind: path.count < 2 ? .container : .element)
        }

        func children(limit: Int) -> [Node] {
            tree.childRequests.append(path)
            guard path.count < tree.depth else { return [] }
            // Ignores `limit` on purpose: the walk must hold the bound itself.
            return (0..<tree.fanOut).map { Node(tree: tree, path: path + [$0]) }
        }
    }

    private func walk(_ tree: Tree) -> ElementSnapping.Walk {
        ElementSnapping.walk(from: Node(tree: tree, path: [])) { tree.now }
    }

    @Test("The walk reads no element deeper than 12 levels below the application")
    func depthBound() {
        let tree = Tree(depth: 40, fanOut: 1)
        let result = walk(tree)
        #expect(tree.deepestRead == ElementSnapping.Limits.standard.maxDepth)
        #expect(result.visited == 13)
        #expect(result.stoppedBy == nil)
    }

    @Test("The walk reads at most 2,000 elements, even when an element reports more children")
    func elementBound() {
        let tree = Tree(depth: 6, fanOut: 12)
        let result = walk(tree)
        #expect(tree.reads == ElementSnapping.Limits.standard.maxElements)
        #expect(result.visited == 2_000)
        #expect(result.stoppedBy == .elementLimit)
    }

    @Test("The walk stops at the 150 ms deadline and keeps what it read")
    func deadline() {
        let tree = Tree(depth: 6, fanOut: 12, cost: .milliseconds(1))
        let result = walk(tree)
        #expect(tree.reads == 150)
        #expect(result.stoppedBy == .deadline)
        #expect(result.visited == 150)
        #expect(!result.frames.isEmpty)
    }

    @Test("An element that cannot be read is skipped with everything below it")
    func unreadablePrunes() {
        let tree = Tree(depth: 3, fanOut: 2)
        tree.unreadable = [[0]]
        _ = walk(tree)
        #expect(!tree.childRequests.contains([0]))
        #expect(!tree.childRequests.contains { $0.starts(with: [0]) && $0.count > 1 })
        #expect(tree.childRequests.contains([1]))
    }

    @Test("The application and its windows are walked but never become element frames")
    func containersAreNotFrames() {
        let tree = Tree(depth: 2, fanOut: 2)
        let result = walk(tree)
        // Depth 0 (the application) and 1 (windows) are containers; the 4 elements at depth 2 count.
        #expect(result.visited == 7)
        #expect(result.frames.count == 4)
    }

    @Test("Elements under 8 pt on a side, off every display, non-finite or repeated are dropped")
    func admission() {
        let display = Rect<DesktopSpace>(x: 0, y: 0, width: 1512, height: 982)
        let left = Rect<DesktopSpace>(x: -1920, y: -200, width: 1920, height: 1080)
        let button = Rect<DesktopSpace>(x: 100, y: 100, width: 80, height: 24)
        let leftButton = Rect<DesktopSpace>(x: -400, y: 300, width: 80, height: 24)
        let straddling = Rect<DesktopSpace>(x: 1500, y: 900, width: 80, height: 200)
        let exactlyMinimum = Rect<DesktopSpace>(x: 10, y: 10, width: 8, height: 8)
        let frames: [Rect<DesktopSpace>] = [
            button,
            Rect(x: 10, y: 10, width: 7.9, height: 40),
            Rect(x: 10, y: 10, width: 40, height: 7.9),
            exactlyMinimum,
            Rect(x: 3000, y: 100, width: 80, height: 24),
            Rect(x: 100, y: -500, width: 80, height: 24),
            leftButton,
            straddling,
            Rect(x: .nan, y: 10, width: 40, height: 40),
            Rect(x: 10, y: 10, width: .infinity, height: 40),
            button,
        ]
        #expect(
            ElementSnapping.admitted(frames, displays: [display, left])
                == [button, exactlyMinimum, leftButton, straddling])
        #expect(ElementSnapping.admitted(frames, displays: []).isEmpty)
    }

    @Test("Element frames join the display and window guides without replacing them")
    func guidesKeepDisplayAndWindows() {
        let display = Rect<DesktopSpace>(x: 0, y: 0, width: 1512, height: 982)
        let window = Rect<DesktopSpace>(x: 10, y: 10, width: 300, height: 200)
        let element = Rect<DesktopSpace>(x: 40, y: 50, width: 120, height: 30)
        let guides = RegionPrecision.guides(within: display, frames: [window, element])
        #expect(guides.count == 12)
        #expect(guides.prefix(8) == RegionPrecision.guides(within: display, frames: [window])[...])
        #expect(
            guides.contains(SnapGuide(axis: .vertical, position: element.maxX, extent: element.minY...element.maxY)))
    }

    @Test("A reading holds a frame and a kind only, so no text attribute can travel through it")
    func readingCarriesNoText() {
        let reading = InterfaceElementReading(frame: Rect(x: 1, y: 2, width: 3, height: 4), kind: .element)
        #expect(Mirror(reflecting: reading).children.map(\.label) == ["frame", "kind"])
        #expect(InterfaceElementKind.allCases == [.container, .element])
        // A kind is a bare case: no associated value could hold a role string or a title.
        #expect(Mirror(reflecting: InterfaceElementKind.element).children.isEmpty)
        let frameFields = Mirror(reflecting: Rect<DesktopSpace>(x: 1, y: 2, width: 3, height: 4)).children
        #expect(
            frameFields.allSatisfy { field in Mirror(reflecting: field.value).children.allSatisfy { $0.value is Double }
            })
    }
}
