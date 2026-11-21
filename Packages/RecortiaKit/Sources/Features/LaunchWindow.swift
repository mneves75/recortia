/// How this process was started; the app reads it from the open-application event.
public enum LaunchKind: Equatable, Sendable {
    /// Opened by the person (Finder, Spotlight, Dock, `open`).
    case user
    case loginItem
}

/// The window a launch shows: a menu-bar app is otherwise invisible after being opened, and with
/// its menu-bar icon hidden Settings is the only way back (FR-01, ADR-007). A launch to open
/// files (Open With, a drop on the Dock icon, `open -a`) shows their editors instead, even before
/// onboarding is finished; the tour still appears on the next plain launch.
public enum LaunchWindow: Equatable, Sendable {
    case onboarding, settings, none

    public static func choose(onboardingPending: Bool, kind: LaunchKind, opensFiles: Bool) -> LaunchWindow {
        if opensFiles { return .none }
        if onboardingPending { return .onboarding }
        return kind == .user ? .settings : .none
    }
}
