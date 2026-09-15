import CoreGraphics
import Foundation

@MainActor
final class ImageExportService: ImageExporting {
    private let encoder: ImageEncoder
    private let clipboard: ClipboardService
    private let fileSaver: FileSaveService
    private let settings: SettingsStore

    init(
        settings: SettingsStore,
        directoryStore: DefaultSaveDirectoryStore,
        encoder: ImageEncoder = .init(),
        clipboard: ClipboardService = .init()
    ) {
        self.settings = settings
        self.encoder = encoder
        self.clipboard = clipboard
        fileSaver = FileSaveService(directoryStore: directoryStore)
    }

    func copyToPasteboard(_ image: CGImage) async throws {
        let pngData = try await encoder.encode(image, format: .png)
        try clipboard.write(image: image, pngData: pngData)
    }

    func save(_ image: CGImage) async throws {
        let data = try await encoder.encode(
            image,
            format: settings.imageFormat,
            jpegQuality: settings.jpegQuality
        )
        _ = try fileSaver.saveToDefaultDirectory(data: data, format: settings.imageFormat)
    }

    func saveAs(_ result: CaptureResult) async throws -> URL? {
        let data = try await encoder.encode(
            result.image,
            format: settings.imageFormat,
            jpegQuality: settings.jpegQuality
        )
        return try await fileSaver.saveUsingPanel(
            data: data,
            format: settings.imageFormat,
            capturedAt: result.capturedAt
        )
    }
}
