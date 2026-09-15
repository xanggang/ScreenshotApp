import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FileSaveService {
    private let directoryStore: DefaultSaveDirectoryStore
    private let fileManager: FileManager

    init(
        directoryStore: DefaultSaveDirectoryStore,
        fileManager: FileManager = .default
    ) {
        self.directoryStore = directoryStore
        self.fileManager = fileManager
    }

    func saveToDefaultDirectory(
        data: Data,
        format: ScreenshotImageFormat,
        capturedAt: Date = Date()
    ) throws -> URL {
        let directory = try directoryStore.resolve()
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }

        let url = uniqueURL(in: directory, format: format, capturedAt: capturedAt)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw ScreenshotAppError.exportFailed("保存失败：\(error.localizedDescription)")
        }
    }

    func saveUsingPanel(
        data: Data,
        format: ScreenshotImageFormat,
        capturedAt: Date = Date()
    ) async throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = baseFilename(capturedAt: capturedAt) + "." + fileExtension(for: format)

        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw ScreenshotAppError.exportFailed("保存失败：\(error.localizedDescription)")
        }
    }

    private func uniqueURL(
        in directory: URL,
        format: ScreenshotImageFormat,
        capturedAt: Date
    ) -> URL {
        let base = baseFilename(capturedAt: capturedAt)
        let ext = fileExtension(for: format)
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }

    private func baseFilename(capturedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "截图 \(formatter.string(from: capturedAt))"
    }

    private func fileExtension(for format: ScreenshotImageFormat) -> String {
        format == .png ? "png" : "jpg"
    }
}
