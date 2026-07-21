import SwiftUI
import UIKit

/// Composites the base avatar with equipped accessories. The base portrait is
/// clipped to a circle; a hat overhangs the top, a frame rings the edge, and a
/// badge sits at the lower-right — all drawn locally (emoji + strokes) so no art
/// assets are required for the first pass.
enum AvatarComposer {
    static func compose(base: UIImage, equipped: [AccessorySlot: String], size: CGFloat = 512) -> UIImage {
        let hat = equipped[.hat].flatMap(AvatarCatalog.accessory)
        let frame = equipped[.frame].flatMap(AvatarCatalog.accessory)
        let badge = equipped[.badge].flatMap(AvatarCatalog.accessory)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)

        return renderer.image { ctx in
            let W = size
            // Leave headroom at the top for a hat; drop the circle center slightly.
            let radius = W * 0.40
            let center = CGPoint(x: W * 0.5, y: W * 0.56)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

            // Base portrait, aspect-filled into the circle.
            ctx.cgContext.saveGState()
            UIBezierPath(ovalIn: circle).addClip()
            drawAspectFill(base, into: circle)
            ctx.cgContext.restoreGState()

            // Frame ring.
            if let ring = frame?.ringColor {
                let lineWidth = W * 0.035
                let path = UIBezierPath(ovalIn: circle.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
                ring.setStroke()
                path.lineWidth = lineWidth
                path.stroke()
            }

            // Hat — centered over the top of the head.
            if let glyph = hat?.glyph {
                let hatSize = W * 0.46
                let rect = CGRect(x: center.x - hatSize / 2, y: W * 0.02, width: hatSize, height: hatSize)
                drawEmoji(glyph, in: rect)
            }

            // Badge — lower-right, on a small light disc so it reads on any portrait.
            if let glyph = badge?.glyph {
                let badgeSize = W * 0.30
                let bx = center.x + radius * 0.62 - badgeSize / 2
                let by = center.y + radius * 0.62 - badgeSize / 2
                let disc = CGRect(x: bx, y: by, width: badgeSize, height: badgeSize)
                UIColor.white.withAlphaComponent(0.92).setFill()
                UIBezierPath(ovalIn: disc).fill()
                drawEmoji(glyph, in: disc.insetBy(dx: badgeSize * 0.14, dy: badgeSize * 0.14))
            }
        }
    }

    private static func drawAspectFill(_ image: UIImage, into rect: CGRect) {
        let iw = image.size.width, ih = image.size.height
        guard iw > 0, ih > 0 else { return }
        let scale = max(rect.width / iw, rect.height / ih)
        let w = iw * scale, h = ih * scale
        image.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    private static func drawEmoji(_ emoji: String, in rect: CGRect) {
        let font = UIFont.systemFont(ofSize: rect.height)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let str = emoji as NSString
        let measured = str.size(withAttributes: attrs)
        let origin = CGPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2)
        str.draw(at: origin, withAttributes: attrs)
    }
}

/// Shared image prep for the photos users upload as identity (profile photo,
/// group photo): center-crop to a square and downscale before upload.
enum ImageTools {
    static func squareJPEG(_ image: UIImage, side: CGFloat, quality: CGFloat = 0.8) -> Data? {
        let source = min(image.size.width, image.size.height)
        guard source > 0 else { return nil }
        let scale = side / source
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let cropped = renderer.image { _ in
            image.draw(in: CGRect(
                x: (side - size.width) / 2,
                y: (side - size.height) / 2,
                width: size.width, height: size.height
            ))
        }
        return cropped.jpegData(compressionQuality: quality)
    }
}

/// Loads the base avatar once and renders it composited with the currently
/// equipped accessories. Reused by the profile header and the customizer preview.
struct ComposedAvatarView: View {
    let url: URL?
    var equipped: [AccessorySlot: String] = EquippedStore.load()
    var size: CGFloat = 180

    @State private var base: UIImage?

    var body: some View {
        SwiftUI.Group {
            if let base {
                Image(uiImage: AvatarComposer.compose(base: base, equipped: equipped, size: 512))
                    .resizable().scaledToFit()
            } else {
                Image(systemName: "person.crop.circle.dashed")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { await loadBase() }
    }

    private func loadBase() async {
        guard let url else { base = nil; return }
        if let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) {
            base = img
        }
    }
}
