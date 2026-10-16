import AppKit
import Carbon.HIToolbox

/// Escape as a temporary system-wide hot key, for the delayed-capture countdown: its panel never
/// becomes key (the app being captured keeps focus), so a normal key handler would never see the
/// key. Carbon hot keys need no Input Monitoring or Accessibility permission. Registered only
/// while the countdown shows; other hot keys (the user's global shortcuts) pass through.
final class EscapeHotKey {
    private static let signature = OSType(0x5243_4553)  // 'RCES'
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard read == noErr, id.signature == EscapeHotKey.signature else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<EscapeHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { owner.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let registered = RegisterEventHotKey(
            UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0,
            &hotKey)
        guard installed == noErr, registered == noErr else {
            unregister()
            return nil
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    isolated deinit { unregister() }
}
