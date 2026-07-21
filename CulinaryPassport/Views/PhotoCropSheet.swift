import SwiftUI
import UIKit

/// Position and size a photo inside the circle before it becomes your avatar:
/// drag to move, pinch or use the slider to zoom. What you see inside the ring
/// is exactly what gets uploaded.
struct PhotoCropSheet: View {
    let image: UIImage
    /// Cropped, downscaled JPEG ready for upload.
    let onDone: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    /// How far the photo can be zoomed beyond "fills the circle".
    private let maxZoom: CGFloat = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    ZStack {
                        Color.black.opacity(0.9)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: side, height: side)
                            .scaleEffect(scale)
                            .offset(offset)
                            .clipped()
                        // Dim everything outside the circle.
                        Circle()
                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                            .frame(width: side, height: side)
                            .background {
                                Rectangle()
                                    .fill(.black.opacity(0.45))
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                    .mask {
                                        Rectangle()
                                            .overlay {
                                                Circle()
                                                    .frame(width: side, height: side)
                                                    .blendMode(.destinationOut)
                                            }
                                            .compositingGroup()
                                    }
                            }
                            .allowsHitTesting(false)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .clipped()
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(width: dragStart.width + value.translation.width,
                                                height: dragStart.height + value.translation.height)
                            }
                            .onEnded { _ in dragStart = offset }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(maxZoom, max(1, pinchStart * value))
                            }
                            .onEnded { _ in pinchStart = scale }
                    )
                }
                .frame(maxHeight: 380)

                HStack(spacing: 12) {
                    Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                    // A slider as well as pinch: easier one-handed, and it works
                    // on devices where a two-finger gesture is awkward.
                    Slider(value: $scale, in: 1...maxZoom) { editing in
                        if !editing { pinchStart = scale }
                    }
                    Image(systemName: "photo.fill").font(.body).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Button("Reset") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1; pinchStart = 1; offset = .zero; dragStart = .zero
                    }
                }
                .font(.footnote)

                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .navigationTitle("Move and scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use photo") {
                        if let data = render() { onDone(data) }
                        dismiss()
                    }
                }
            }
        }
    }

    /// Re-draw the visible circle at upload resolution. The preview lays the
    /// image out with scaledToFill in a `side`-sized square, then scales and
    /// offsets it; this repeats that transform at 512pt so what the user framed
    /// is what gets stored.
    private func render() -> Data? {
        let output: CGFloat = 512
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: output, height: output))
        let preview: CGFloat = 380 // matches the frame cap above closely enough
        let ratio = output / preview

        return renderer.image { context in
            context.cgContext.saveGState()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: output, height: output)).addClip()

            // scaledToFill inside the square
            let fill = max(preview / image.size.width, preview / image.size.height)
            let drawnWidth = image.size.width * fill * scale * ratio
            let drawnHeight = image.size.height * fill * scale * ratio
            let x = (output - drawnWidth) / 2 + offset.width * ratio
            let y = (output - drawnHeight) / 2 + offset.height * ratio
            image.draw(in: CGRect(x: x, y: y, width: drawnWidth, height: drawnHeight))
            context.cgContext.restoreGState()
        }
        .jpegData(compressionQuality: 0.85)
    }
}
