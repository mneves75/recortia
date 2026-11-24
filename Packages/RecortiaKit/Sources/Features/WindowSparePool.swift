/// Windows built before a capture needs them (A-13 step 2), at most one per key (a display, or the
/// next editor). A spare is only held, never shown, so window presence, window switchers and quit
/// decisions never see it; a taken window belongs to its taker until it is given back. Disabled,
/// the pool builds every window on demand and keeps none, which is construction as before.
@MainActor
public final class WindowSparePool<Key: Hashable, Window: AnyObject> {
    public let isEnabled: Bool
    private let build: (Key) -> Window?
    private var spares: [Key: Window] = [:]
    /// The keys the last `prepare` asked for; a window given back for any other key is dropped.
    private var wanted: Set<Key> = []

    public init(isEnabled: Bool, build: @escaping (Key) -> Window?) {
        self.isEnabled = isEnabled
        self.build = build
    }

    /// Builds a spare for each of `keys` that lacks one and drops the spares of every other key,
    /// such as a display that went away or changed.
    public func prepare(_ keys: some Sequence<Key>) {
        guard isEnabled else { return }
        wanted = Set(keys)
        spares = spares.filter { wanted.contains($0.key) }
        for key in wanted where spares[key] == nil {
            spares[key] = build(key)
        }
    }

    /// The spare for `key`, or a newly built window when there is none; nil when `key` cannot be built.
    public func take(_ key: Key) -> Window? {
        spares.removeValue(forKey: key) ?? build(key)
    }

    /// Keeps a taken window that is hidden again, if its key is still wanted and has no spare.
    /// Returns whether the pool kept it; otherwise the caller's reference is the last one.
    @discardableResult
    public func giveBack(_ window: Window, for key: Key) -> Bool {
        guard isEnabled, wanted.contains(key), spares[key] == nil else { return false }
        spares[key] = window
        return true
    }

    public func spare(for key: Key) -> Window? { spares[key] }

    public var spareCount: Int { spares.count }
}
