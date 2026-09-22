import SwiftUI

/// The payoff: a new cuisine slams onto the page. One gets the big postage
/// stamp; a batch (the checklist) fills a page of stamps. Either way there's
/// a share card, rendered once — not on every redraw.
struct StampMomentView: View {
    let codes: [String]
    var number: Int?
    var date: String?
    /// A first taste of a cuisine rather than a first visit.
    var tasted = false
    let onClose: () -> Void

    @State private var stamped = false
    @State private var revealed = 0
    @State private var shareImage: UIImage?

    private var single: String? { codes.count == 1 ? codes[0] : nil }

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 20)
                if let code = single {
                    singleStamp(code)
                } else {
                    batch
                }
                Spacer(minLength: 20)
                actions
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .onAppear(perform: animateIn)
        .task { renderShareCard() }
    }

    private func singleStamp(_ code: String) -> some View {
        VStack(spacing: 22) {
            PostageStamp(code: code, number: number, date: date.map(DayFormat.pretty) ?? "", width: 240,
                         tasted: tasted)
                .scaleEffect(stamped ? 1 : 2.4)
                .rotationEffect(.degrees(stamped ? -3 : -22))
                .opacity(stamped ? 1 : 0)
            VStack(spacing: 6) {
                Eyebrow(text: number.map { tasted ? "Cuisine Nº \($0)" : "Country Nº \($0)" } ?? "New stamp",
                        color: .brand)
                Text(tasted ? "Your first \(Cuisine.name(for: code)) meal"
                            : "Welcome to \(CountryStore.byCode[code]?.name ?? code)")
                    .font(.display)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
            }
            .opacity(stamped ? 1 : 0)
            .offset(y: stamped ? 0 : 12)
        }
    }

    private var batch: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Eyebrow(text: "Passport updated", color: .brand)
                Text(tasted ? codes.count.counted("cuisine") + " tasted" : "\(codes.count) new stamps")
                    .font(.displayLarge)
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 10) {
                ForEach(Array(codes.prefix(12).enumerated()), id: \.element) { index, code in
                    StampBadge(code: code, size: 96, tasted: tasted)
                        .scaleEffect(index < revealed ? 1 : 1.9)
                        .opacity(index < revealed ? 1 : 0)
                }
            }
            if codes.count > 12 {
                Text("+ \(codes.count - 12) more")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.inkSecondary)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let shareImage {
                ShareLink(item: Image(uiImage: shareImage),
                          preview: SharePreview(shareTitle, image: Image(uiImage: shareImage))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.primary)
            }
            Button("Done", action: onClose)
                .buttonStyle(.secondary)
        }
        .opacity(stamped ? 1 : 0)
    }

    private var shareTitle: String {
        if let code = single {
            return tasted ? "\(Country.flag(for: code)) My first \(Cuisine.name(for: code)) meal"
                          : "\(Country.flag(for: code)) \(CountryStore.byCode[code]?.name ?? code) — stamped"
        }
        return tasted ? "\(codes.count.counted("cuisine")) in my food passport" : "\(codes.count) new stamps in my passport"
    }

    private func animateIn() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { stamped = true }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
        guard single == nil else { return }
        for index in 0..<min(codes.count, 12) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(index) * 0.09) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { revealed = index + 1 }
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
            }
        }
    }

    @MainActor
    private func renderShareCard() {
        let card = ShareCard {
            if let code = single {
                PostageStamp(code: code, number: number, date: date.map(DayFormat.pretty), width: 300, tasted: tasted)
            } else {
                VStack(spacing: 14) {
                    Text(tasted ? "\(codes.count.counted("cuisine")) tasted" : "\(codes.count) new stamps")
                        .font(.system(size: 34, weight: .semibold, design: .serif))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(104)), count: 3), spacing: 12) {
                        ForEach(codes.prefix(9), id: \.self) { StampBadge(code: $0, size: 100, tasted: tasted) }
                    }
                }
            }
        }
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        shareImage = renderer.uiImage
    }
}

/// A shareable 4:5 card: content on paper with the wordmark. Always rendered
/// in light mode so shared images look the same everywhere.
struct ShareCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image("BrandMark")
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Stampd")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(uiColor: Palette.brandDeep))
            }
        }
        .padding(34)
        .frame(width: 400, height: 500)
        .background(Color(red: 0.965, green: 0.945, blue: 0.906))
        .environment(\.colorScheme, .light)
    }
}
