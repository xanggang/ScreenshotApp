import Foundation

enum ScreenshotAppError: LocalizedError, Sendable {
    case permissionDenied
    case contentUnavailable
    case displayNotFound(UInt32)
    case windowNotFound(UInt32)
    case captureFailed(String)
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "没有屏幕捕获权限"
        case .contentUnavailable: "当前没有可捕获的屏幕内容"
        case .displayNotFound(let id): "找不到显示器（ID：\(id)）"
        case .windowNotFound(let id): "找不到窗口（ID：\(id)）"
        case .captureFailed(let reason): "截图失败：\(reason)"
        case .exportFailed(let reason): "导出失败：\(reason)"
        case .cancelled: "操作已取消"
        }
    }
}
