import AppKit
import CoreGraphics

@MainActor
struct ClipboardService {
    func write(image: CGImage, pngData: Data) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        var wroteRepresentation = pasteboard.setData(pngData, forType: .png)
        if let tiffData = nsImage.tiffRepresentation {
            wroteRepresentation = pasteboard.setData(tiffData, forType: .tiff) || wroteRepresentation
        }

        guard wroteRepresentation else {
            throw ScreenshotAppError.exportFailed("无法写入剪贴板")
        }
    }
}
