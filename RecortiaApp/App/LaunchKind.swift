import AppKit

enum LaunchKind: Equatable {
    /// Opened by the person (Finder, Spotlight, Dock, `open`).
    case user
    case loginItem

    /// Reads the open-application event, current during `applicationDidFinishLaunching`. macOS
    /// marks a login item's launch with `keyAELaunchedAsLogInItem`; anything else, including no
    /// event, counts as the person's own launch, so a missing marker shows a window rather than
    /// hiding one.
    init(openEvent: NSAppleEventDescriptor?) {
        let marker = openEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        self = marker == OSType(keyAELaunchedAsLogInItem) ? .loginItem : .user
    }
}

/// The window a launch shows: a menu-bar app is otherwise invisible after being opened. A launch
/// to open files (Open With, a drop on the Dock icon, `open -a`) shows their editors instead, even
/// before onboarding is finished; the tour still appears on the next plain launch.
enum LaunchWindow: Equatable {
    case onboarding, settings, none

    static func choose(onboardingPending: Bool, kind: LaunchKind, opensFiles: Bool) -> LaunchWindow {
        if opensFiles { return .none }
        if onboardingPending { return .onboarding }
        return kind == .user ? .settings : .none
    }
}
