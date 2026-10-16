/// Public system-font designs and decorations supported by editable text annotations (FR-05).
public enum TextAppearance: String, CaseIterable, Hashable, Sendable, Codable {
    case standard
    case rounded
    case monospaced
    case outlined
    case boxed
    case roundedBoxed
    case monospacedBoxed

    public var isBoxed: Bool {
        switch self {
        case .boxed, .roundedBoxed, .monospacedBoxed: true
        case .standard, .rounded, .monospaced, .outlined: false
        }
    }
}
