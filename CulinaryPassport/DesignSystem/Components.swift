import SwiftUI

// Shared building blocks. Screens compose these instead of re-deriving
// paddings, radii and colors, so the app reads as one product.

// ── Surfaces ────────────────────────────────────────────────────────────────

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = Metrics.cornerLarge

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
    }
}

extension View {
    func card(padding: CGFloat = 16, radius: CGFloat = Metrics.cornerLarge) -> some View {
        modifier(CardModifier(padding: padding, radius: radius))
    }

    /// The paper backdrop every full screen sits on.
    func paperBackground() -> some View {
        background(Color.paper.ignoresSafeArea())
    }

    /// Lists and forms get the paper backdrop instead of system grouped gray.
    func paperListStyle() -> some View {
        scrollContentBackground(.hidden).background(Color.paper.ignoresSafeArea())
    }
}

// ── Text ────────────────────────────────────────────────────────────────────

struct Eyebrow: View {
    let text: String
    var color: Color = .inkTertiary

    var body: some View {
        Text(text.uppercased())
            .font(.eyebrow)
            .tracking(1.1)
            .foregroundStyle(color)
    }
}

struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.displayXSmall).foregroundStyle(Color.ink)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(Color.inkSecondary)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
    }
}

// ── Buttons ─────────────────────────────────────────────────────────────────

struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.onBrand)
            .padding(.horizontal, 20)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 50)
            .background(Color.brand.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Color.ink.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 46)
            .background(Color.sunken, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Compact capsule action ("Follow", "Add", chips in a toolbar row).
struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color.onBrand : Color.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(prominent ? Color.brand : Color.sunken, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsule: CapsuleButtonStyle { CapsuleButtonStyle() }
    static var capsuleProminent: CapsuleButtonStyle { CapsuleButtonStyle(prominent: true) }
}

/// Round floating control used over the globe.
struct FloatingIconButton: View {
    let systemImage: String
    var label: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 22 : 18, weight: .semibold))
                .foregroundStyle(prominent ? Color.onBrand : Color.ink)
                .frame(width: prominent ? 58 : 46, height: prominent ? 58 : 46)
                .background {
                    if prominent {
                        Circle().fill(Color.brand)
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .overlay(Circle().strokeBorder(Color.hairline.opacity(prominent ? 0 : 0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(prominent ? 0.22 : 0.10), radius: prominent ? 10 : 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// ── Chips, stats ────────────────────────────────────────────────────────────

struct Pill: View {
    var systemImage: String?
    let text: String
    var tint: Color = .inkSecondary
    var background: Color = .sunken

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(background, in: Capsule())
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var action: (() -> Void)?

    var body: some View {
        let content = VStack(spacing: 2) {
            Text(value)
                .font(.number(.title2))
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// A thin progress bar in the brand color.
struct ProgressLine: View {
    let fraction: Double
    var tint: Color = .brand

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.sunken)
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? 6 : 0, proxy.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

// ── Empty + loading states ──────────────────────────────────────────────────

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.brand)
                .frame(width: 76, height: 76)
                .background(Color.brandSoft, in: Circle())
            VStack(spacing: 6) {
                Text(title)
                    .font(.displayXSmall)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let primaryTitle, let primaryAction {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                    .padding(.top, 4)
            }
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.brand)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
    }
}

/// Placeholder block that gently pulses while content loads.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Metrics.corner
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.sunken)
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

// ── Toasts ──────────────────────────────────────────────────────────────────

struct Toast: Identifiable, Equatable {
    enum Style { case info, success, error }
    let id = UUID()
    let message: String
    var style: Style = .info
}

struct ToastView: View {
    let toast: Toast

    private var icon: String {
        switch toast.style {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .info: .brand
        case .success: .brand
        case .error: .danger
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }
}

struct ToastHost: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast {
                ToastView(toast: toast)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { withAnimation { self.toast = nil } }
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(toast.style == .error ? 4 : 2.6))
                        withAnimation(.easeOut(duration: 0.25)) {
                            if self.toast?.id == toast.id { self.toast = nil }
                        }
                    }
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toast)
    }
}

extension View {
    func toastHost(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastHost(toast: toast))
    }
}

/// Toasts live in their own window above every sheet and cover. Hosted on
/// the root view they were drawn *behind* any presented sheet, so errors and
/// confirmations raised from sheets ("Code copied", a failed delete) were
/// never seen. The window never takes touches or key status.
@MainActor
final class ToastWindow {
    static let shared = ToastWindow()
    private var window: UIWindow?

    func install(app: AppModel) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState != .unattached }) else { return }
        let host = PassiveHostingController(rootView: ToastOverlay().environment(app))
        host.view.backgroundColor = .clear
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

private struct ToastOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Color.clear
            .ignoresSafeArea()
            .toastHost($app.toast)
            .tint(Color.brand)
    }
}

/// Touches fall through to the app underneath.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// Doesn't claim the status bar or orientation from the real window.
private final class PassiveHostingController<Content: View>: UIHostingController<Content> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .default }
    override var prefersStatusBarHidden: Bool { false }
}

// ── Identity ────────────────────────────────────────────────────────────────

/// Circular profile photo with an initial-on-color fallback.
struct AvatarView: View {
    var name: String = ""
    var urlString: String?
    var color: String = "#2f5a45"
    var size: CGFloat = 40
    var ring: Color?

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: color).opacity(0.85))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let urlString, let url = URL(string: urlString) {
                RemoteImage(source: .url(url), maxPixel: size * 3) {
                    Color.clear
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if let ring { Circle().strokeBorder(ring, lineWidth: max(2, size * 0.05)) }
        }
        .accessibilityHidden(true)
    }

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}

extension AvatarView {
    init(profile: Profile?, size: CGFloat = 40, ring: Color? = nil) {
        self.init(name: profile?.name ?? "",
                  urlString: profile?.avatarUrl,
                  color: profile?.color ?? "#2f5a45",
                  size: size,
                  ring: ring)
    }
}

/// Overlapping row of faces ("Maya, Sam and 3 others have been").
struct FacePile: View {
    let profiles: [Profile]
    var size: CGFloat = 26
    var limit = 4

    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(profiles.prefix(limit)) { person in
                AvatarView(profile: person, size: size)
                    .overlay(Circle().strokeBorder(Color.card, lineWidth: 2))
            }
            if profiles.count > limit {
                Text("+\(profiles.count - limit)")
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.inkSecondary)
                    .frame(width: size, height: size)
                    .background(Color.sunken, in: Circle())
                    .overlay(Circle().strokeBorder(Color.card, lineWidth: 2))
            }
        }
    }
}

/// A flag emoji in a soft tile — used wherever a country is a list item.
struct FlagTile: View {
    let code: String
    var size: CGFloat = 40

    var body: some View {
        Text(Country.flag(for: code))
            .font(.system(size: size * 0.6))
            .frame(width: size, height: size)
            .background(Color.sunken, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}
