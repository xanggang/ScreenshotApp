import AppKit
import Foundation

@MainActor
final class DefaultSaveDirectoryStore {
    private static let bookmarkKey = "export.defaultDirectoryBookmark"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func chooseDirectory() async throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择默认截图保存位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        try store(url)
        return url
    }

    func store(_ url: URL) throws {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Self.bookmarkKey)
        } catch {
            throw ScreenshotAppError.exportFailed("无法保存目录权限：\(error.localizedDescription)")
        }
    }

    func resolve() throws -> URL {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else {
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale { try store(url) }
            return url
        } catch {
            defaults.removeObject(forKey: Self.bookmarkKey)
            throw ScreenshotAppError.exportFailed("默认保存目录已失效，请重新选择")
        }
    }

    func reset() {
        defaults.removeObject(forKey: Self.bookmarkKey)
    }
}
