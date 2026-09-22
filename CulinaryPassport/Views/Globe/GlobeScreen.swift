import SwiftUI

/// Home: the world, served on a plate. Every cuisine you've eaten wears your
/// colour on the globe, and the rim shows how far round each continent you've
/// got. Spin, and the globe whirls like a lazy Susan, lands on a cuisine
/// nobody eating has tried, and shows who serves it near you.
struct GlobeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    @State private var selected: String?
    @State private var focus: GlobeCanvas.FocusRequest?
    @State private var spinning = false
    /// Where the last spin landed, until it's tasted or spun again.
    @State private var landed: String?
    /// The ghost stamp that drops onto the plate when a spin lands.
    @State private var dropped: String?
    /// Who's eating: nil for just you, or a table.
    @State private var eatingWith: UUID?
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case search
        case logMeal(cuisine: String?)
        case cuisines
        case cuisine(String)
        case places(code: String, table: UUID?, fromSpin: Bool)

        var id: String {
            switch self {
            case .search: "search"
            case .logMeal(let code): "meal-\(code ?? "")"
            case .cuisines: "cuisines"
            case .cuisine(let code): "cuisine-\(code)"
            case .places(let code, let table, let spin): "places-\(code)-\(table?.uuidString ?? "")-\(spin)"
            }
        }
    }

    private var tint: UIColor { app.me.flatMap { UIColor(hex: $0.color) } ?? Palette.brand }
    private var table: Group? { eatingWith.flatMap { id in app.groups.first { $0.id == id } } }

    /// Cuisines counted in the headline and rim: yours, or everyone's at the table.
    private var counted: Set<String> {
        eatingWith == nil ? app.tastedCodes : app.tasted(by: app.eaters(at: eatingWith))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TableclothBackdrop()

            VStack(spacing: 0) {
                header
                headline
                    .padding(.top, 4)
                plate
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, Metrics.gutter)

            if let code = selected, !spinning {
                CuisinePanel(
                    code: code,
                    taste: app.tastesByCode[code],
                    isLanded: code == landed,
                    friends: friendsWhoHaveHad(code),
                    onClose: { selected = nil },
                    onFind: { sheet = .places(code: code, table: eatingWith, fromSpin: false) },
                    onLog: { sheet = .logMeal(cuisine: code) },
                    onOpen: { sheet = .cuisine(code) },
                    onMarkTasted: { Task { await markTasted(code) } }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: selected)
        .sheet(item: $sheet, onDismiss: afterSheet) { sheet in
            switch sheet {
            case .search:
                CuisineSearchSheet { code in fly(to: code) }
            case .logMeal(let code):
                MealEditorView(mode: .new(cuisine: code, place: nil))
            case .cuisines:
                NavigationStack { CuisineChecklistView(onDone: { self.sheet = nil }) }
            case .cuisine(let code):
                CuisineSheet(code: code)
            case .places(let code, let table, let fromSpin):
                SpinResultSheet(code: code, tableId: table,
                                onSpinAgain: fromSpin ? { spinAgain() } : nil)
            }
        }
        .task(id: eatingWith) {
            if let eatingWith { await app.refreshPeopleTastes(app.eaters(at: eatingWith)) }
        }
        .onChange(of: app.groups) {
            if let eatingWith, !app.groups.contains(where: { $0.id == eatingWith }) { self.eatingWith = nil }
        }
        .onChange(of: app.tastedCodes) {
            // Tasting tonight's spin ends its waiting colour.
            if let landed, app.tastedCodes.contains(landed) { self.landed = nil }
        }
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-spin") {
                try? await Task.sleep(for: .seconds(1.2))
                spin()
            }
            if let i = args.firstIndex(of: "-fly"), i + 1 < args.count {
                try? await Task.sleep(for: .seconds(1.2))
                fly(to: args[i + 1])
            }
        }
        #endif
    }

    // ── Header ───────────────────────────────────────────────────────────────

    private var header: some View {
        HStack {
            Text("Stampd")
                .font(.wordmark)
                .foregroundStyle(Color.brand)
            Spacer()
            FloatingIconButton(systemImage: "magnifyingglass", label: "Find a cuisine") { sheet = .search }
        }
        .padding(.top, 6)
    }

    private var headline: some View {
        let count = counted.count
        return VStack(spacing: 3) {
            Eyebrow(text: table.map { "Between \($0.name)" } ?? "You've eaten", color: .inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(FoodStats.percentText(count))
                    .font(.system(size: 46, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(uiColor: tint))
                    .contentTransition(.numericText())
                Text("of the world")
                    .font(.displaySmall)
                    .foregroundStyle(Color.ink)
            }
            if case .failed(let message) = app.loadState {
                Button {
                    Task { await app.bootstrap() }
                } label: {
                    Label("\(message) Tap to retry.", systemImage: "wifi.exclamationmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.stampRed)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            } else if app.loadState == .loaded, app.tastes.isEmpty, eatingWith == nil {
                Button { sheet = .cuisines } label: {
                    Text("Eaten around already? \(Text("Mark what you've tried").foregroundStyle(Color.brand).bold())")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
                .buttonStyle(.plain)
            } else {
                Text("\(count.counted("cuisine")) of \(Cuisine.codes.count)\(eatingWith == nil ? " · \(app.stats.meals.counted("meal"))" : "")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.inkSecondary)
                    .contentTransition(.numericText())
            }
        }
        .multilineTextAlignment(.center)
        .animation(.snappy, value: count)
        .accessibilityElement(children: .combine)
    }

    // ── The plate ────────────────────────────────────────────────────────────

    private var plate: some View {
        let tint = self.tint
        let others = eatingWith == nil ? Set<String>() : counted.subtracting(app.tastedCodes)
        let landed = self.landed
        return ZStack {
            Plate(rim: 0.15, band: .clear) {
                GlobeCanvas(
                    style: GlobeStyle(scheme),
                    color: { code, isSelected in
                        color(for: code, selected: isSelected, tint: tint, others: others, landed: landed)
                    },
                    selected: $selected,
                    focusOn: $focus,
                    onFocusLanded: landedOn,
                    onLongPress: { code in
                        if Cuisine.isCuisine(code) { sheet = .logMeal(cuisine: code) }
                    },
                    isEmphasized: { app.tastedCodes.contains($0) || $0 == landed || others.contains($0) },
                    landingBias: 0.04,
                    fitMargin: 1.05,
                    // Your world starts at home.
                    initialCenter: app.me?.homeCountry.flatMap { CountryStore.byCode[$0]?.centroid }
                )
                // SceneKit is opaque to VoiceOver: describe the globe and
                // offer its jobs as actions.
                .accessibilityElement()
                .accessibilityLabel("Globe")
                .accessibilityValue("\(app.stats.cuisines) cuisines eaten, \(app.stats.worldPercentText) of the world")
                .accessibilityAction(named: "Spin for dinner") { spin() }
                .accessibilityAction(named: "Find a cuisine") { sheet = .search }
                .accessibilityAction(named: "Log a meal") { sheet = .logMeal(cuisine: nil) }
            }
            ContinentRim(progress: FoodStats.continentProgress(counted), tint: Color(uiColor: tint))

            if let dropped {
                SpinCoaster(code: dropped, size: 176)
                    .transition(.scale(scale: 1.8).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }

    private func color(for code: String, selected isSelected: Bool, tint: UIColor,
                       others: Set<String>, landed: String?) -> UIColor {
        let style = GlobeStyle(scheme)
        if app.tastedCodes.contains(code) {
            return style.tasted(tint, meals: app.mealsByCountry[code]?.count ?? 0, selected: isSelected)
        }
        if code == landed { return style.landed(selected: isSelected) }
        if others.contains(code) { return style.tastedByOthers(style.shared, selected: isSelected) }
        return style.untouched(selected: isSelected)
    }

    // ── Controls ─────────────────────────────────────────────────────────────

    private var controls: some View {
        ZStack {
            HStack(alignment: .center) {
                whoIsEating
                Spacer(minLength: 0)
                logButton
            }
            SpinButton(spinning: spinning, size: 84) { spin() }
                .disabled(spinning)
                .accessibilityLabel(table.map { "Spin for \($0.name)" } ?? "Spin for dinner")
                .accessibilityHint("Lands on a cuisine nobody eating has tried, then shows restaurants near you.")
        }
    }

    private var whoIsEating: some View {
        Menu {
            Button { eatingWith = nil } label: {
                Label("Just me", systemImage: eatingWith == nil ? "checkmark" : "person")
            }
            if !app.groups.isEmpty {
                Section("A table") {
                    ForEach(app.groups) { group in
                        Button { eatingWith = group.id } label: {
                            Label("\(group.name) · \(app.members(of: group.id).count)",
                                  systemImage: eatingWith == group.id ? "checkmark" : "person.3")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                if let table {
                    AvatarStack(profiles: app.members(of: table.id).compactMap { app.profile($0) }, size: 22, max: 3)
                } else {
                    AvatarView(profile: app.me, size: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Spinning for")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.inkTertiary)
                        .fixedSize()
                    Text(table?.name ?? "Just me")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .frame(maxWidth: 92, alignment: .leading)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.inkTertiary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5))
            .fixedSize()
        }
        .disabled(spinning)
        .accessibilityLabel("Spinning for \(table?.name ?? "just you")")
    }

    private var logButton: some View {
        Menu {
            Button { sheet = .logMeal(cuisine: nil) } label: { Label("Log a meal", systemImage: "fork.knife") }
            Button { sheet = .cuisines } label: { Label("Mark cuisines I've tried", systemImage: "checklist") }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 56, height: 56)
                    .background(Color.card, in: Circle())
                    .overlay(Circle().strokeBorder(Color.brand.opacity(0.35), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.onBrand)
                    .frame(width: 20, height: 20)
                    .background(Color.brand, in: Circle())
                    .offset(x: 2, y: -2)
            }
        } primaryAction: {
            sheet = .logMeal(cuisine: nil)
        }
        .accessibilityLabel("Log a meal")
        .accessibilityHint("Hold for more.")
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func spin() {
        guard !spinning, let pick = app.spinPool(for: eatingWith).randomElement() else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selected = nil
        landed = nil
        withAnimation(.easeOut(duration: 0.2)) { dropped = nil }
        spinning = true
        focus = .init(id: UUID(), code: pick, style: .spin)
        app.backend.logEvent("globe_spun", props: ["table": String(eatingWith != nil)])
    }

    private func spinAgain() {
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            spin()
        }
    }

    private func landedOn(_ code: String?) {
        focus = nil
        let wasSpin = spinning
        spinning = false
        guard let code else { return }   // grabbed mid-flight
        guard wasSpin else {
            selected = code
            return
        }
        landed = code
        withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) { dropped = code }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await Task.sleep(for: .milliseconds(1150))
            guard landed == code, dropped == code else { return }
            sheet = .places(code: code, table: eatingWith, fromSpin: true)
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.25)) { dropped = nil }
        }
    }

    /// Back from a spin's restaurants: tonight's pick stays open on the globe.
    private func afterSheet() {
        if let landed, selected == nil, !spinning, focus == nil { selected = landed }
    }

    private func fly(to code: String) {
        guard CountryStore.byCode[code] != nil else { return }
        selected = nil
        focus = .init(id: UUID(), code: code, style: .fly)
    }

    private func markTasted(_ code: String) async {
        do {
            try await app.addTastes([code])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.celebrate("\(Country.flag(for: code)) \(Cuisine.name(for: code)) — tasted")
        } catch {
            app.show(error)
        }
    }

    private func friendsWhoHaveHad(_ code: String) -> [Profile] {
        app.networkIds
            .filter { app.peopleTastes[$0]?.contains(code) == true }
            .compactMap { app.profile($0) }
            .sorted { $0.name < $1.name }
    }
}

// ── Backdrop ────────────────────────────────────────────────────────────────

/// Paper, with the faintest weave — the cloth the plate is set on.
struct TableclothBackdrop: View {
    var body: some View {
        ZStack {
            Color.paper
            Canvas { context, size in
                let ink = GraphicsContext.Shading.color(Color.hairline.opacity(0.35))
                var path = Path()
                var x = 0.0
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += 6
                }
                var y = 0.0
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += 6
                }
                context.stroke(path, with: ink, lineWidth: 0.3)
            }
            RadialGradient(colors: [Color.paper.opacity(0), Color.paper.opacity(0.85)],
                           center: .center, startRadius: 120, endRadius: 520)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// ── A cuisine, tapped on the globe ──────────────────────────────────────────

struct CuisinePanel: View {
    let code: String
    let taste: Taste?
    var isLanded = false
    let friends: [Profile]
    let onClose: () -> Void
    let onFind: () -> Void
    let onLog: () -> Void
    let onOpen: () -> Void
    let onMarkTasted: () -> Void

    private var country: Country? { CountryStore.byCode[code] }
    private var hasKitchen: Bool { Cuisine.isCuisine(code) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Button(action: onOpen) {
                    StampBadge(code: code, subtitle: taste?.yearsText, size: 84, inked: taste != nil, tasted: true)
                }
                .buttonStyle(.plain)
                .disabled(!hasKitchen)
                .accessibilityLabel("Open \(Cuisine.name(for: code)) food")

                VStack(alignment: .leading, spacing: 5) {
                    Text(hasKitchen ? Cuisine.name(for: code) : country?.name ?? code)
                        .font(.displaySmall)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let country {
                        Text("\(country.flag) \(country.name) · \(country.continent.rawValue)")
                            .font(.caption)
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(1)
                    }
                    status
                    if !friends.isEmpty {
                        HStack(spacing: 6) {
                            FacePile(profiles: friends, size: 20, limit: 3)
                            Text(friendsText)
                                .font(.caption)
                                .foregroundStyle(Color.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 30, height: 30)
                        .background(Color.sunken, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            if hasKitchen {
                HStack(spacing: 10) {
                    Button(action: onFind) {
                        Label("Find it near me", systemImage: "map")
                    }
                    .buttonStyle(.primary)
                    Button(action: onLog) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.brand)
                            .frame(width: 50, height: 50)
                            .background(Color.brandSoft, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log \(Cuisine.withArticle(code)) meal")
                    Menu {
                        Button(action: onOpen) { Label("\(Cuisine.name(for: code)) food", systemImage: "book") }
                        if taste == nil {
                            Button(action: onMarkTasted) { Label("I've had it", systemImage: "checkmark.seal") }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 50, height: 50)
                            .background(Color.sunken, in: Circle())
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.card)
                .overlay(alignment: .top) {
                    // A menu card's scalloped header edge.
                    ScallopEdge().fill(Color.brand.opacity(0.1)).frame(height: 10).padding(.horizontal, 22)
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 6)
    }

    @ViewBuilder private var status: some View {
        if let taste {
            Pill(systemImage: "fork.knife",
                 text: taste.meals > 0 ? "Tasted · \(taste.meals.counted("meal"))" : "Tasted",
                 tint: .brand, background: .brandSoft)
        } else if !hasKitchen {
            Text("No kitchen to taste here.")
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
        } else if isLanded {
            Pill(systemImage: "dice", text: "Tonight's spin", tint: .saffron, background: .saffronSoft)
        } else {
            Text("Not tried yet")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.inkSecondary)
        }
    }

    private var friendsText: String {
        let names = friends.map(\.firstName)
        switch names.count {
        case 1: return "\(names[0]) has had it"
        case 2: return "\(names[0]) and \(names[1]) have had it"
        default: return "\(names[0]), \(names[1]) +\(names.count - 2) have had it"
        }
    }
}

/// A row of half-moons, like the edge of a menu card or a paper doily.
struct ScallopEdge: Shape {
    var scallop: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = max(1, Int(rect.width / scallop))
        let width = rect.width / CGFloat(count)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for index in 0..<count {
            let x = rect.minX + CGFloat(index) * width
            path.addArc(center: CGPoint(x: x + width / 2, y: rect.minY), radius: width / 2,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
