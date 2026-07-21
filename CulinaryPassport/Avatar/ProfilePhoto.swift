import SwiftUI
import UIKit

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

/// A user's profile photo, circular. (This replaced the composited AI-avatar
/// view: avatars are plain photos now, so there's nothing to composite.)
struct ProfilePhotoView: View {
    let url: URL?
    var size: CGFloat = 104

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(Color(.secondarySystemBackground))
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
