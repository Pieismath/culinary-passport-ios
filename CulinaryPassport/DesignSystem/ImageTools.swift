import SwiftUI
import UIKit
import ImageIO

extension UIGraphicsImageRendererFormat {
    /// 1 point = 1 pixel. The default format renders at the SCREEN scale (3×
    /// on current iPhones), so a "1400px" upload silently became 4200px —
    /// nine times the bytes, and over the bucket's 10 MB cap for some photos.
    static var pixels: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return format
    }
}

enum ImageTools {
    /// Center-crop to a square and downscale (profile + group photos).
    static func squareJPEG(_ image: UIImage, side: CGFloat, quality: CGFloat = 0.8) -> Data? {
        let source = min(image.size.width, image.size.height)
        guard source > 0 else { return nil }
        let scale = side / source
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: .pixels)
        let cropped = renderer.image { _ in
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        return cropped.jpegData(compressionQuality: quality)
    }

    /// A meal photo ready to upload: longest edge capped, re-encoded as
    /// JPEG. Re-encoding also drops EXIF — the exact GPS a photo carries is
    /// read on-device for the place suggestion and never shared with viewers.
    static func uploadJPEG(from data: Data, maxDimension: CGFloat = 2048, quality: CGFloat = 0.8) -> (jpeg: Data, preview: UIImage)? {
        guard let image = ImagePipeline.downsample(data, maxPixel: maxDimension) else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: quality) else { return nil }
        let preview = ImagePipeline.downsample(jpeg, maxPixel: 600) ?? image
        return (jpeg, preview)
    }
}
