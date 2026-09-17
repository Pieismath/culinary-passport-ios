import SwiftUI
import UIKit

/// Position and size a photo inside the circle before it becomes your avatar:
/// drag to move, pinch or use the slider to zoom. What you see inside the ring
/// is exactly what gets uploaded.
///
/// Panning and zooming are CLAMPED so the photo always covers the circle —
/// you can never frame a crescent of empty space.
struct PhotoCropSheet: View {
    let image: UIImage
    /// Cropped, downscaled JPEG ready for upload.
    let onDone: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    /// Fixed viewport so the preview geometry and the exported crop are the
    /// same maths, not an approximation of each other.
    private let viewport: CGFloat = 300
    private let maxZoom: CGFloat = 4

    /// Size the photo is drawn at, at the current zoom: scaled to fill the
    /// viewport, then zoomed.
    private var drawn: CGSize {
        let fill = max(viewport / image.size.width, viewport / image.size.height)
        return CGSize(width: image.size.width * fill * scale,
                      height: image.size.height * fill * scale)
    }

    /// How far the photo may travel before an edge would enter the circle.
    private var panLimit: CGSize {
        CGSize(width: max(0, (drawn.width - viewport) / 2),
               height: max(0, (drawn.height - viewport) / 2))
    }

    private func clamped(_ proposed: CGSize) -> CGSize {
        let limit = panLimit
        return CGSize(width: min(max(proposed.width, -limit.width), limit.width),
                      height: min(max(proposed.height, -limit.height), limit.height))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    Color.black.opacity(0.9)

                    Image(uiImage: image)
                        .resizable()
                        .frame(width: drawn.width, height: drawn.height)
                        .offset(offset)

                    // Dim outside the circle, ring on the boundary.
                    Rectangle()
                        .fill(.black.opacity(0.5))
                        .reverseMask {
                            Circle().frame(width: viewport, height: viewport)
                        }
                        .allowsHitTesting(false)
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: viewport, height: viewport)
                        .allowsHitTesting(false)
                }
                .frame(width: viewport, height: viewport)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = clamped(CGSize(width: dragStart.width + value.translation.width,
                                                    height: dragStart.height + value.translation.height))
                        }
                        .onEnded { _ in dragStart = offset }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(maxZoom, max(1, pinchStart * value))
                            offset = clamped(offset)   // zooming out can strand the photo off-centre
                            dragStart = offset
                        }
                        .onEnded { _ in pinchStart = scale }
                )

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
                .onChange(of: scale) {
                    offset = clamped(offset)
                    dragStart = offset
                }

                Button("Reset") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1; pinchStart = 1; offset = .zero; dragStart = .zero
                    }
                }
                .font(.footnote)

                Spacer(minLength: 0)
            }
            .padding(.top, 12)
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

    /// Re-draw the framed circle at upload resolution using the same geometry
    /// as the preview, scaled up.
    private func render() -> Data? {
        let output: CGFloat = 512
        let ratio = output / viewport
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: .pixels)

        return renderer.image { context in
            context.cgContext.saveGState()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: output, height: output)).addClip()
            let size = drawn
            let rect = CGRect(x: (output - size.width * ratio) / 2 + offset.width * ratio,
                              y: (output - size.height * ratio) / 2 + offset.height * ratio,
                              width: size.width * ratio,
                              height: size.height * ratio)
            image.draw(in: rect)
            context.cgContext.restoreGState()
        }
        .jpegData(compressionQuality: 0.85)
    }
}

private extension View {
    /// Punch a hole in this view in the shape of `mask`.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
