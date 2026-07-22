import SwiftUI
import UIKit

/// The web app's signature moment, finally on iOS: the first meal from a new
/// cuisine slams an ink stamp onto the screen. Big haptic, short animation,
/// and a share card so the moment can leave the app.
struct StampMomentView: View {
    let country: Country
    /// 1-based "this is your Nth cuisine".
    let cuisineNumber: Int
    let onClose: () -> Void

    @State private var stamped = false

    var body: some View {
        ZStack {
            Color(red: 0.972, green: 0.960, blue: 0.930).ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                StampCard(country: country, cuisineNumber: cuisineNumber)
                    .scaleEffect(stamped ? 1.0 : 2.6)
                    .rotationEffect(.degrees(stamped ? -3 : -24))
                    .opacity(stamped ? 1 : 0)

                Text("New cuisine unlocked")
                    .font(.system(.title3, design: .serif)).italic()
                    .foregroundStyle(Color(.secondaryLabel))
                    .opacity(stamped ? 1 : 0)

                Spacer()

                if stamped {
                    VStack(spacing: 10) {
                        ShareLink(
                            item: shareImage(),
                            preview: SharePreview("Cuisine #\(cuisineNumber): \(country.cuisineName)",
                                                  image: shareImage())
                        ) {
                            Label("Share the stamp", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Keep eating") { onClose() }
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 30)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .onAppear {
            // thud.
            withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                stamped = true
            }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
        }
    }

    /// The card at 3× for sharing (stories/messages friendly square-ish).
    private func shareImage() -> Image {
        let renderer = ImageRenderer(content:
            StampCard(country: country, cuisineNumber: cuisineNumber)
                .padding(46)
                .background(Color(red: 0.972, green: 0.960, blue: 0.930))
        )
        renderer.scale = 3
        if let ui = renderer.uiImage {
            return Image(uiImage: ui)
        }
        return Image(systemName: "globe")
    }
}

/// The passport-stamp card itself — also rendered to the share image.
struct StampCard: View {
    let country: Country
    let cuisineNumber: Int

    private let ink = Color(red: 0.42, green: 0.32, blue: 0.55) // stamp-pad purple

    var body: some View {
        VStack(spacing: 10) {
            Text(country.flagEmoji).font(.system(size: 64))
            Text(country.cuisineName.uppercased())
                .font(.system(.title2, design: .serif).weight(.bold))
                .tracking(2)
                .multilineTextAlignment(.center)
            Text("CUISINE Nº \(cuisineNumber)")
                .font(.caption.weight(.semibold))
                .tracking(3)
            Text(Date().formatted(.dateTime.day().month(.abbreviated).year()))
                .font(.caption2)
                .tracking(1.5)
            Text("· CULINARY PASSPORT ·")
                .font(.system(size: 8, weight: .semibold))
                .tracking(2.5)
                .padding(.top, 2)
        }
        .foregroundStyle(ink)
        .padding(.vertical, 26)
        .padding(.horizontal, 34)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(ink, style: StrokeStyle(lineWidth: 3.5, dash: [1, 0]))
            RoundedRectangle(cornerRadius: 12)
                .stroke(ink.opacity(0.65), lineWidth: 1.4)
                .padding(5)
        }
        .background(ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }
}
