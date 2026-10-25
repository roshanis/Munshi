import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Cover thumbnails, made with Core Graphics and ImageIO so the same code runs on iOS and macOS.
enum CoverImage {
    static let maxPixelSize = 600

    /// Downscales any image ImageIO can read into a JPEG thumbnail.
    static func thumbnail(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpegData(from: image)
    }

    /// Renders the first page of a PDF.
    static func thumbnail(of document: PDFDocument) -> Data? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(bounds.width, bounds.height)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage().flatMap(jpegData(from:))
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Decoded covers, keyed by book id, so scrolling the library does not re-decode JPEGs.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private var images: [UUID: CGImage] = [:]

    func image(for id: UUID, data: Data?) -> CGImage? {
        if let cached = images[id] { return cached }
        guard let data, let image = CoverImage.cgImage(from: data) else { return nil }
        images[id] = image
        return image
    }

    func remove(_ id: UUID) {
        images[id] = nil
    }
}
