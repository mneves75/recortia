import Foundation

/// What snapping needs to know about an element's role (AXRole), and nothing more.
public enum InterfaceElementKind: Hashable, Sendable, CaseIterable {
    /// The application or one of its windows; the window list already gives their frames.
    case container
    case element
}

/// Everything Recortia reads about one interface element of another app (B-7, ADR-010): its frame
/// (AXPosition and AXSize) and its kind (AXRole). It has no text field by design, so no value,
/// title, description or other on-screen text can travel through it.
public struct InterfaceElementReading: Hashable, Sendable {
    public var frame: Rect<DesktopSpace>?
    public var kind: InterfaceElementKind

    public init(frame: Rect<DesktopSpace>?, kind: InterfaceElementKind) {
        self.frame = frame
        self.kind = kind
    }
}

/// One element of another app's interface tree, as the element walk sees it.
public protocol InterfaceElementNode {
    /// The element's frame and kind; nil when it cannot be read (it went away or timed out).
    func read() -> InterfaceElementReading?
    /// At most `limit` of its children, in the app's order.
    func children(limit: Int) -> [Self]
}

/// Snapping a region selection to the interface elements of the app under the pointer (FR-02,
/// B-7, ADR-010). The frames join the window frames as extra snap frames for one selection.
public enum ElementSnapping {
    /// Elements smaller than this on either side are not snap targets.
    public static let minimumSide = 8.0

    public struct Limits: Hashable, Sendable {
        /// Levels below the application; the application itself is level 0.
        public var maxDepth: Int
        public var maxElements: Int
        public var deadline: Duration

        public init(maxDepth: Int, maxElements: Int, deadline: Duration) {
            self.maxDepth = maxDepth
            self.maxElements = maxElements
            self.deadline = deadline
        }

        public static let standard = Limits(maxDepth: 12, maxElements: 2_000, deadline: .milliseconds(150))
    }

    public enum Stop: Hashable, Sendable {
        case elementLimit
        case deadline
    }

    /// The element frames one walk read, how many elements it read, and which bound ended it early.
    public struct Walk: Hashable, Sendable {
        public var frames: [Rect<DesktopSpace>]
        public var visited: Int
        public var stoppedBy: Stop?

        public init(frames: [Rect<DesktopSpace>], visited: Int, stoppedBy: Stop?) {
            self.frames = frames
            self.visited = visited
            self.stoppedBy = stoppedBy
        }
    }

    /// Reads the tree under `root` breadth first, so when a bound ends the walk the larger,
    /// shallower elements are the ones kept. No more than `maxElements` elements are ever taken
    /// in, whatever a node reports; `elapsed` is checked before every message to the app. An
    /// element that cannot be read is skipped with everything below it.
    public static func walk<Node: InterfaceElementNode>(
        from root: Node, limits: Limits = .standard, elapsed: () -> Duration
    ) -> Walk {
        var queue: [(node: Node, depth: Int)] = [(root, 0)]
        var next = 0
        var frames: [Rect<DesktopSpace>] = []
        var stop: Stop?
        while next < queue.count {
            guard elapsed() < limits.deadline else {
                stop = .deadline
                break
            }
            let (node, depth) = queue[next]
            next += 1
            guard let reading = node.read() else { continue }
            if reading.kind == .element, let frame = reading.frame { frames.append(frame) }
            guard depth < limits.maxDepth else { continue }
            let room = limits.maxElements - queue.count
            guard room > 0 else {
                stop = .elementLimit
                continue
            }
            guard elapsed() < limits.deadline else {
                stop = .deadline
                break
            }
            let children = node.children(limit: room)
            if children.count >= room { stop = .elementLimit }
            queue.append(contentsOf: children.prefix(room).map { ($0, depth + 1) })
        }
        return Walk(frames: frames, visited: next, stoppedBy: stop)
    }

    /// The frames worth snapping to: finite, at least `minimumSide` on each side, on at least one
    /// of `displays`, each once, in their original order.
    public static func admitted(_ frames: [Rect<DesktopSpace>], displays: [Rect<DesktopSpace>]) -> [Rect<DesktopSpace>]
    {
        var seen = Set<Rect<DesktopSpace>>()
        return frames.filter { frame in
            frame.isValid && frame.width >= minimumSide && frame.height >= minimumSide
                && displays.contains { frame.intersects($0) } && seen.insert(frame).inserted
        }
    }
}
