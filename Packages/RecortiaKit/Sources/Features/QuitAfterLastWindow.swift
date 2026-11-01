/// What Recortia does after the person closed its last window (FR-01).
public enum QuitAfterLastWindow: Equatable, Sendable {
    /// Keep running in the menu bar.
    case stay
    /// Decide again once the export in progress has finished.
    case wait
    /// Request normal termination, which still asks about unexported edits.
    case quit

    /// An unfinished export is waited for before anything else, so a failure alert it raises is
    /// shown and an automatic save is never cut off; a window the person still has, or a capture
    /// in progress, cancels the quit.
    public static func decide(keepsRunningInMenuBar: Bool, isExporting: Bool, hasUserWindow: Bool, isCapturing: Bool)
        -> QuitAfterLastWindow
    {
        if keepsRunningInMenuBar { return .stay }
        if isExporting { return .wait }
        return hasUserWindow || isCapturing ? .stay : .quit
    }
}
