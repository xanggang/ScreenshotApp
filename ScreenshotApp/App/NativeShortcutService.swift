import Carbon
import Combine
import Foundation

enum AppShortcut: Hashable, Sendable {
    case interactiveCapture
    case displayCapture

    fileprivate var id: UInt32 {
        switch self {
        case .interactiveCapture: 1
        case .displayCapture: 2
        }
    }

    fileprivate var defaultConfiguration: ShortcutConfiguration {
        let modifiers = UInt32(cmdKey | shiftKey)
        return switch self {
        case .interactiveCapture: ShortcutConfiguration(keyCode: UInt32(kVK_ANSI_A), modifiers: modifiers)
        case .displayCapture: ShortcutConfiguration(keyCode: UInt32(kVK_ANSI_S), modifiers: modifiers)
        }
    }
}

struct ShortcutConfiguration: Codable, Hashable, Identifiable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    var id: String { "\(modifiers)-\(keyCode)" }

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    private static func keyName(for code: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z"
        ]
        return names[code] ?? "未知按键"
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    private enum Key {
        static let interactive = "shortcuts.interactiveCapture"
        static let display = "shortcuts.displayCapture"
    }

    static let selectableConfigurations: [ShortcutConfiguration] = {
        let keys: [UInt32] = [
            UInt32(kVK_ANSI_A), UInt32(kVK_ANSI_B), UInt32(kVK_ANSI_C), UInt32(kVK_ANSI_D),
            UInt32(kVK_ANSI_E), UInt32(kVK_ANSI_F), UInt32(kVK_ANSI_G), UInt32(kVK_ANSI_H),
            UInt32(kVK_ANSI_I), UInt32(kVK_ANSI_J), UInt32(kVK_ANSI_K), UInt32(kVK_ANSI_L),
            UInt32(kVK_ANSI_M), UInt32(kVK_ANSI_N), UInt32(kVK_ANSI_O), UInt32(kVK_ANSI_P),
            UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_R), UInt32(kVK_ANSI_S), UInt32(kVK_ANSI_T),
            UInt32(kVK_ANSI_U), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_X),
            UInt32(kVK_ANSI_Y), UInt32(kVK_ANSI_Z)
        ]
        let commandShift = UInt32(cmdKey | shiftKey)
        let commandControl = UInt32(cmdKey | controlKey)
        return keys.flatMap { key in
            [
                ShortcutConfiguration(keyCode: key, modifiers: commandShift),
                ShortcutConfiguration(keyCode: key, modifiers: commandControl)
            ]
        }
    }()

    @Published var interactiveCapture: ShortcutConfiguration { didSet { save(interactiveCapture, forKey: Key.interactive) } }
    @Published var displayCapture: ShortcutConfiguration { didSet { save(displayCapture, forKey: Key.display) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        interactiveCapture = Self.load(forKey: Key.interactive, defaults: defaults) ?? AppShortcut.interactiveCapture.defaultConfiguration
        displayCapture = Self.load(forKey: Key.display, defaults: defaults) ?? AppShortcut.displayCapture.defaultConfiguration
    }

    private static func load(forKey key: String, defaults: UserDefaults) -> ShortcutConfiguration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ShortcutConfiguration.self, from: data)
    }

    private func save(_ configuration: ShortcutConfiguration, forKey key: String) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}

protocol ShortcutRegistering: AnyObject {
    func register(
        _ shortcut: AppShortcut,
        configuration: ShortcutConfiguration,
        handler: @escaping @Sendable () -> Void
    ) throws
    func unregisterAll()
}

enum ShortcutRegistrationError: LocalizedError {
    case systemStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .systemStatus(let status): "快捷键注册失败（系统状态：\(status)）"
        }
    }
}

final class NativeShortcutService: ShortcutRegistering, @unchecked Sendable {
    private let signature: OSType = 0x514A_4945 // "QJIE"
    private var handlers: [UInt32: @Sendable () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let service = Unmanaged<NativeShortcutService>.fromOpaque(userData).takeUnretainedValue()
            service.handlers[id.id]?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    deinit { unregisterAll() }

    func register(
        _ shortcut: AppShortcut,
        configuration: ShortcutConfiguration,
        handler: @escaping @Sendable () -> Void
    ) throws {
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(configuration.keyCode, configuration.modifiers, EventHotKeyID(signature: signature, id: shortcut.id), GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else { throw ShortcutRegistrationError.systemStatus(status) }
        handlers[shortcut.id] = handler
        hotKeyRefs.append(hotKeyRef)
    }

    func unregisterAll() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        handlers.removeAll()
    }
}
