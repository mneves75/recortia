/// Where a message about one editor's document is shown (design direction "Alerts"): a sheet on
/// that editor's window while the person can see it, otherwise an app alert on the current Space.
/// A report about a closed, minimized or hidden editor, or one on another Space, is never lost.
public enum MessagePlacement: Equatable, Sendable {
    case editorSheet
    case appAlert

    public init(editorIsOpen: Bool, windowIsOnScreen: Bool) {
        self = editorIsOpen && windowIsOnScreen ? .editorSheet : .appAlert
    }
}
