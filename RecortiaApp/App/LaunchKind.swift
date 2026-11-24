import AppKit
import Features

extension LaunchKind {
    /// Reads the open-application event, current during `applicationDidFinishLaunching`. macOS
    /// marks a login item's launch with `keyAELaunchedAsLogInItem`; anything else, including no
    /// event, counts as the person's own launch, so a missing marker shows a window rather than
    /// hiding one.
    init(openEvent: NSAppleEventDescriptor?) {
        let marker = openEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        self = marker == OSType(keyAELaunchedAsLogInItem) ? .loginItem : .user
    }
}
