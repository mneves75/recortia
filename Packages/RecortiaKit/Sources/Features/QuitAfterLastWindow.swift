/// What Recortia does after the person closed its last window (FR-01).
public enum QuitAfterLastWindow: Equatable, Sendable {
    /// Keep running in the menu bar.
    case stay
    /// Decide again once the export in progress has finished.
    case wait
    /// Request normal termination, which still asks about unexported edits.
    case quit

    /// Keeping the app running or starting a capture cancels the quit. Otherwise an unfinished
    /// export is waited for so its result is reported before considering remaining windows.
    public static func decide(keepsRunningInMenuBar: Bool, isExporting: Bool, hasUserWindow: Bool, isCapturing: Bool)
        -> QuitAfterLastWindow
    {
        if keepsRunningInMenuBar || isCapturing { return .stay }
        if isExporting { return .wait }
        return hasUserWindow ? .stay : .quit
    }
}
