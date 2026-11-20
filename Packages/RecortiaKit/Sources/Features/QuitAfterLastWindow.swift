public enum QuitAfterLastWindow: Equatable, Sendable {
    /// Keep running in the menu bar.
    case stay
    /// Decide again once the export or file opening in progress has finished.
    case wait
    /// Request normal termination, which still asks about unexported edits.
    case quit

    /// Keeping the app running or starting a capture cancels the quit. Otherwise an unfinished
    /// export, or an Open With request still opening files, is waited for so its result is
    /// reported (and its editors exist) before considering remaining windows.
    public static func decide(
        keepsRunningInMenuBar: Bool, isExporting: Bool, isOpeningFiles: Bool, hasUserWindow: Bool, isCapturing: Bool
    ) -> QuitAfterLastWindow {
        if keepsRunningInMenuBar || isCapturing { return .stay }
        if isExporting || isOpeningFiles { return .wait }
        return hasUserWindow ? .stay : .quit
    }
}
