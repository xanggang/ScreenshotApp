import AppKit
import Combine
import CoreGraphics

@MainActor
final class ScreenCapturePermissionService: ObservableObject {
    enum Status: Equatable {
        case authorized
        case denied
        case notDetermined
    }

    @Published private(set) var status: Status

    init() {
        status = CGPreflightScreenCaptureAccess() ? .authorized : .notDetermined
    }

    @discardableResult
    func refresh() -> Status {
        let isAuthorized = CGPreflightScreenCaptureAccess()
        if isAuthorized {
            status = .authorized
        } else if status != .denied {
            // macOS intentionally doesn't expose whether access is undecided or
            // denied. Treat a fresh launch as undecided so the user's first
            // screenshot action can trigger the native permission prompt.
            status = .notDetermined
        }
        return status
    }

    @discardableResult
    func requestAccess() -> Bool {
        guard refresh() != .authorized else {
            return status == .authorized
        }
        let granted = CGRequestScreenCaptureAccess()
        status = granted ? .authorized : .denied
        return granted
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
