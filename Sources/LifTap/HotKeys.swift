import Carbon

enum Command: UInt32, CaseIterable {
    case capture = 1, restoreLatest, showSessions, captureTab, cutTab

    var keyCode: Int {
        switch self {
        case .capture, .captureTab: kVK_ANSI_C
        case .cutTab: kVK_ANSI_X
        case .restoreLatest: kVK_ANSI_V
        case .showSessions: kVK_Space
        }
    }

    var modifiers: UInt32 {
        UInt32(self == .captureTab ? optionKey : controlKey | optionKey)
    }

    var title: String {
        switch self {
        case .capture: "현재 창 담기"
        case .captureTab: "현재 탭 담기"
        case .cutTab: "현재 탭 잘라내기"
        case .restoreLatest: "마지막 세션 열기"
        case .showSessions: "세션 목록 보기"
        }
    }

    var shortcut: String {
        switch self {
        case .capture: "⌃⌥C"
        case .captureTab: "⌥C"
        case .cutTab: "⌃⌥X"
        case .restoreLatest: "⌃⌥V"
        case .showSessions: "⌃⌥Space"
        }
    }
}

@MainActor
final class HotKeys {
    private static let signature: OSType = 0x4C465450 // LFTP
    private var handlerRef: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var pressed: Set<Command> = []
    private let onPress: (Command) -> Void

    init(onPress: @escaping (Command) -> Void) {
        self.onPress = onPress
    }

    func register() -> Set<Command> {
        let target = GetApplicationEventTarget()
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            // The application event target invokes handlers on AppKit's main thread.
            return MainActor.assumeIsolated {
                Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue().handle(event)
            }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { return [] }

        var registered: Set<Command> = []
        for command in Command.allCases {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: command.rawValue)
            let result = RegisterEventHotKey(UInt32(command.keyCode), command.modifiers,
                                             id, target, 0, &reference)
            if result == noErr, let reference {
                registrations.append(reference)
                registered.insert(command)
            }
        }
        return registered
    }

    func unregister() {
        for reference in registrations { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        pressed.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let status = GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == Self.signature, let command = Command(rawValue: id.id)
        else { return OSStatus(eventNotHandledErr) }

        if GetEventKind(event) == kEventHotKeyPressed {
            if pressed.insert(command).inserted { onPress(command) }
        } else {
            pressed.remove(command)
        }
        return noErr
    }
}
