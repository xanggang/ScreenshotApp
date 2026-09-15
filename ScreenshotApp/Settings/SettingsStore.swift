import Combine
import Foundation

enum ScreenshotImageFormat: String, CaseIterable, Codable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let launchAtLogin = "settings.launchAtLogin"
        static let playCaptureSound = "settings.playCaptureSound"
        static let showCompletionNotification = "settings.showCompletionNotification"
        static let completionAction = "settings.completionAction"
        static let imageFormat = "settings.imageFormat"
        static let jpegQuality = "settings.jpegQuality"
        static let includeCursor = "settings.includeCursor"
        static let includeWindowShadow = "settings.includeWindowShadow"
        static let showMagnifier = "settings.showMagnifier"
        static let pinOpacity = "settings.pinOpacity"
    }

    private let defaults: UserDefaults
    private let launchAtLoginService: LaunchAtLoginService

    @Published var launchAtLogin: Bool {
        didSet { updateLaunchAtLogin() }
    }
    @Published var playCaptureSound: Bool { didSet { defaults.set(playCaptureSound, forKey: Key.playCaptureSound) } }
    @Published var showCompletionNotification: Bool { didSet { defaults.set(showCompletionNotification, forKey: Key.showCompletionNotification) } }
    @Published var completionAction: CaptureCompletionAction { didSet { defaults.set(completionAction.rawValue, forKey: Key.completionAction) } }
    @Published var imageFormat: ScreenshotImageFormat { didSet { defaults.set(imageFormat.rawValue, forKey: Key.imageFormat) } }
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) } }
    @Published var includeCursor: Bool { didSet { defaults.set(includeCursor, forKey: Key.includeCursor) } }
    @Published var includeWindowShadow: Bool { didSet { defaults.set(includeWindowShadow, forKey: Key.includeWindowShadow) } }
    @Published var showMagnifier: Bool { didSet { defaults.set(showMagnifier, forKey: Key.showMagnifier) } }
    @Published var pinOpacity: Double { didSet { defaults.set(pinOpacity, forKey: Key.pinOpacity) } }
    @Published private(set) var launchAtLoginError: String?

    init(
        defaults: UserDefaults = .standard,
        launchAtLoginService: LaunchAtLoginService = .init()
    ) {
        self.defaults = defaults
        self.launchAtLoginService = launchAtLoginService
        launchAtLogin = launchAtLoginService.isEnabled
        playCaptureSound = defaults.object(forKey: Key.playCaptureSound) as? Bool ?? true
        showCompletionNotification = defaults.object(forKey: Key.showCompletionNotification) as? Bool ?? false
        completionAction = defaults.string(forKey: Key.completionAction)
            .flatMap(CaptureCompletionAction.init(rawValue:)) ?? .copy
        imageFormat = defaults.string(forKey: Key.imageFormat)
            .flatMap(ScreenshotImageFormat.init(rawValue:)) ?? .png
        jpegQuality = defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.9
        includeCursor = defaults.object(forKey: Key.includeCursor) as? Bool ?? false
        includeWindowShadow = defaults.object(forKey: Key.includeWindowShadow) as? Bool ?? true
        showMagnifier = defaults.object(forKey: Key.showMagnifier) as? Bool ?? true
        pinOpacity = defaults.object(forKey: Key.pinOpacity) as? Double ?? 1.0
    }

    func refreshLaunchAtLoginState() {
        launchAtLogin = launchAtLoginService.isEnabled
    }

    private func updateLaunchAtLogin() {
        do {
            try launchAtLoginService.setEnabled(launchAtLogin)
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = launchAtLoginService.isEnabled
        }
    }
}
