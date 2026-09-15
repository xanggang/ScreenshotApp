import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ImageEncoder {
    func encode(
        _ image: CGImage,
        format: ScreenshotImageFormat,
        jpegQuality: Double = 0.9
    ) throws -> Data {
        let data = NSMutableData()
        let type: UTType = format == .png ? .png : .jpeg

        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotAppError.exportFailed("无法创建图片编码器")
        }

        let properties: CFDictionary
        switch format {
        case .png:
            properties = [:] as CFDictionary
        case .jpeg:
            properties = [
                kCGImageDestinationLossyCompressionQuality: min(max(jpegQuality, 0.1), 1.0)
            ] as CFDictionary
        }

        CGImageDestinationAddImage(destination, imageForEncoding(image, as: format), properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotAppError.exportFailed("图片编码失败")
        }
        return data as Data
    }

    private func imageForEncoding(_ image: CGImage, as format: ScreenshotImageFormat) -> CGImage {
        guard format == .jpeg, image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst,
              image.alphaInfo != .noneSkipLast else {
            return image
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? image.colorSpace
        guard let colorSpace,
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return image
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
