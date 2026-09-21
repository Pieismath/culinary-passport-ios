import SwiftUI

/// Home: your globe. Countries you've visited wear your colour (deeper with
/// every memory), cuisines you've tasted wear a lighter wash of it, your
/// bucket list glows amber, and a tap opens what's there.
struct GlobeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    @State private var selected: String?
    @State private var focus: GlobeCanvas.FocusRequest?
    @State private var flying = false
    @State private var sheet: GlobeSheet?
    @State private var viewingMemory: Memory?
    @State private var friendStamps: [String: [Stamp]] = [:]

    enum GlobeSheet: Identifiable {
        case search
        case addMemory(country: String?)
        case logMeal(cuisine: String?)
        case dinner
        case importPhotos
        case checklist
        case cuisines
        case friendsIn(String)

        var id: String {
            switch self {
            case .search: "search"
            case .addMemory(let code): "add-\(code ?? "")"
            case .logMeal(let code): "meal-\(code ?? "")"
            case .dinner: "dinner"
            case .importPhotos: "import"
            case .checklist: "checklist"
            case .cuisines: "cuisines"
            case .friendsIn(let code): "friends-\(code)"
            }
        }
    }

    private var tint: UIColor { app.me.flatMap { UIColor(hex: $0.color) } ?? Palette.brand }

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobeBackdrop()

            let tint = self.tint
            GlobeCanvas(
                style: GlobeStyle(scheme),
                color: { code, isSelected in color(for: code, selected: isSelected, tint: tint) },
                selected: $selected,
                focusOn: $focus,
                onFocusLanded: { code in
                    flying = false
                    focus = nil
                    if let code { selected = code }
                },
                onLongPress: { code in
                    sheet = .addMemory(country: code)
                },
                isEmphasized: {
                    app.visitedCodes.contains($0) || app.tastedCodes.contains($0) || app.bucketList.contains($0)
                }
            )
            .ignoresSafeArea()
            // SceneKit is opaque to VoiceOver: describe the globe and offer
            // the same jobs through actions (search finds any country).
            .accessibilityElement()
            .accessibilityLabel("Globe")
            .accessibilityValue("\(app.stats.countries) countries visited, \(app.stats.cuisines) cuisines tasted")
            .accessibilityHint("Use Find a country to open any country's details.")
            .accessibilityAction(named: "Find a country") { sheet = .search }
            .accessibilityAction(named: "Log a meal") { sheet = .logMeal(cuisine: nil) }
            .accessibilityAction(named: "What's for dinner?") { sheet = .dinner }
            .accessibilityAction(named: "Add a memory") { sheet = .addMemory(country: nil) }

            bottomArea
        }
        .overlay(alignment: .top) { header }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: selected)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .search:
                CountrySearchSheet { code in fly(to: code) }
            case .addMemory(let code):
                MemoryEditorView(mode: .new(countryCode: code, pickPhotosFirst: code == nil))
            case .logMeal(let code):
                MealEditorView(mode: .new(cuisine: code, place: nil))
            case .dinner:
                DinnerDiceSheet(people: [], onLanded: { code in fly(to: code) })
            case .cuisines:
                NavigationStack { CuisineChecklistView(onDone: { self.sheet = nil }) }
            case .importPhotos:
                NavigationStack { PhotoImportView(onDone: { self.sheet = nil }) }
            case .checklist:
                NavigationStack { CountryChecklistView(onDone: { self.sheet = nil }) }
            case .friendsIn(let code):
                FriendsInCountrySheet(code: code)
            }
        }
        .sheet(item: $viewingMemory) { memory in
            MemoryDetailView(memory: memory)
        }
        .task(id: selected) { await loadFriends(for: selected) }
        .onChange(of: app.networkIds) {
            // Follow/unfollow/join changes who "has been" — drop the cache.
            friendStamps = [:]
            Task { await loadFriends(for: selected) }
        }
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-fly"), i + 1 < args.count {
                try? await Task.sleep(for: .seconds(1.2))
                fly(to: args[i + 1])
            }
        }
        #endif
    }

    // ── Header ───────────────────────────────────────────────────────────────

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stampd")
                    .font(.wordmark)
                    .foregroundStyle(Color.brand)
                if app.stats.countries + app.stats.territories + app.stats.cuisines > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "airplane").foregroundStyle(Color.inkSecondary)
                        Text("\(app.stats.countries)")
                            .font(.number(.subheadline))
                            .contentTransition(.numericText())
                        Text(app.stats.countries == 1 ? "country" : "countries")
                        Text("·").foregroundStyle(Color.inkTertiary)
                        Image(systemName: "fork.knife").foregroundStyle(Color.inkSecondary)
                        Text("\(app.stats.cuisines)")
                            .font(.number(.subheadline))
                            .contentTransition(.numericText())
                        Text(app.stats.cuisines == 1 ? "cuisine" : "cuisines")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5))
                    .accessibilityElement(children: .combine)
                    .animation(.snappy, value: app.stats.countries + app.stats.cuisines)
                }
            }
            Spacer()
            VStack(spacing: 10) {
                FloatingIconButton(systemImage: "magnifyingglass", label: "Find a country") {
                    sheet = .search
                }
                Menu {
                    Button { sheet = .dinner } label: {
                        Label("What's for dinner?", systemImage: "fork.knife")
                    }
                    Button { spin(bucketOnly: false) } label: {
                        Label("Where next? (travel)", systemImage: "airplane")
                    }
                    Button { spin(bucketOnly: true) } label: {
                        Label("From my bucket list", systemImage: "bookmark")
                    }
                    .disabled(app.bucketList.subtracting(app.visitedCodes).isEmpty)
                } label: {
                    Image(systemName: "dice")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 46, height: 46)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.hairline.opacity(0.6), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
                        .symbolEffect(.bounce, value: flying)
                } primaryAction: {
                    sheet = .dinner
                }
                .disabled(flying)
                .accessibilityLabel("What's for dinner? Roll a cuisine")
                .accessibilityHint("Hold for travel ideas.")
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 6)
    }

    // ── Bottom: panel, first-run card, or hint + add ─────────────────────────

    @ViewBuilder private var bottomArea: some View {
        if let code = selected, let country = CountryStore.byCode[code] {
            CountryPanel(
                country: country,
                stamp: app.stampsByCode[code],
                taste: app.tastesByCode[code],
                memories: ((app.memoriesByCountry[code] ?? []) + (app.mealsByCountry[code] ?? []))
                    .sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) },
                isBucketListed: app.bucketList.contains(code),
                isHome: app.me?.homeCountry == code,
                friends: friendsWhoHaveBeen(code),
                onClose: { selected = nil },
                onAddMemory: { sheet = .addMemory(country: code) },
                onLogMeal: { sheet = .logMeal(cuisine: Cuisine.isCuisine(code) ? code : nil) },
                onStamp: { stamp(code) },
                onToggleBucket: { app.toggleBucketList(code) },
                onOpenMemory: { viewingMemory = $0 },
                onShowFriends: { sheet = .friendsIn(code) },
                onRemoveStamp: { Task { await removeStamp(code) } },
                onRemoveTaste: {
                    Task {
                        do { try await app.removeTaste(code) } catch { app.show(error) }
                    }
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            VStack(spacing: 12) {
                if case .failed(let message) = app.loadState {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.stampRed)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(Color.ink)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Retry") {
                            Task { await app.bootstrap() }
                        }
                        .buttonStyle(.capsuleProminent)
                    }
                    .card(padding: 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if app.loadState == .loaded && app.stamps.isEmpty && app.memories.isEmpty
                    && app.tastes.isEmpty && app.meals.isEmpty {
                    BuildPassportCard(
                        onScan: { sheet = .importPhotos },
                        onPick: { sheet = .checklist }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    HStack(alignment: .bottom) {
                        if app.stamps.count + app.tastes.count < 4 && !flying {
                            Label("Tap a country · + to log a meal", systemImage: "hand.tap")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.inkSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .transition(.opacity)
                        }
                        Spacer()
                        addMenu
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 14)
        }
    }

    private var addMenu: some View {
        Menu {
            Button { sheet = .logMeal(cuisine: nil) } label: {
                Label("Log a meal", systemImage: "fork.knife")
            }
            Button { sheet = .addMemory(country: nil) } label: {
                Label("Add a travel memory", systemImage: "airplane")
            }
            Divider()
            Button { sheet = .cuisines } label: {
                Label("Mark cuisines I've tried", systemImage: "checklist")
            }
            Button { sheet = .importPhotos } label: {
                Label("Find trips in my photos", systemImage: "sparkle.magnifyingglass")
            }
            Button { sheet = .checklist } label: {
                Label("Mark countries I've been to", systemImage: "globe")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.onBrand)
                .frame(width: 60, height: 60)
                .background(Color.brand, in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        } primaryAction: {
            sheet = .logMeal(cuisine: nil)
        }
        .accessibilityLabel("Log a meal")
        .accessibilityHint("Hold for travel memories and more.")
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func color(for code: String, selected isSelected: Bool, tint: UIColor) -> UIColor {
        let style = GlobeStyle(scheme)
        if app.visitedCodes.contains(code) {
            return style.visited(tint, memories: app.memoriesByCountry[code]?.count ?? 0, selected: isSelected)
        }
        if app.tastedCodes.contains(code) { return style.tasted(tint, selected: isSelected) }
        if app.bucketList.contains(code) { return style.bucketListed(selected: isSelected) }
        return style.untouched(selected: isSelected)
    }

    private func spin(bucketOnly: Bool) {
        let pool = CountryStore.all.filter { country in
            !app.visitedCodes.contains(country.code)
                && (!bucketOnly || app.bucketList.contains(country.code))
        }
        guard let pick = pool.randomElement() else {
            app.celebrate(bucketOnly ? "Your bucket list is all stamped. Add more!" : "You've been everywhere. Legend.")
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selected = nil
        flying = true
        focus = .init(id: UUID(), code: pick.code, style: .spin)
        app.backend.logEvent("globe_spun", props: ["bucket_only": String(bucketOnly)])
    }

    private func fly(to code: String) {
        guard CountryStore.byCode[code] != nil else { return }
        selected = nil
        flying = true
        focus = .init(id: UUID(), code: code, style: .fly)
    }

    private func stamp(_ code: String) {
        Task {
            do {
                let wasNew = !app.visitedCodes.contains(code)
                try await app.addStamps([StampInput(countryCode: code, firstVisited: nil,
                                                    lastVisited: nil, source: .manual)])
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if wasNew, let name = CountryStore.byCode[code]?.name {
                    app.celebrate("\(Country.flag(for: code)) \(name) stamped")
                }
            } catch {
                app.show(error)
            }
        }
    }

    private func removeStamp(_ code: String) async {
        do {
            try await app.removeStamp(code)
        } catch {
            app.show(error)
        }
    }

    private func friendsWhoHaveBeen(_ code: String) -> [Profile] {
        (friendStamps[code] ?? []).compactMap { app.profile($0.userId) }
            .filter { !app.blocked.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    private func loadFriends(for code: String?) async {
        guard let code, friendStamps[code] == nil else { return }
        let ids = Array(app.networkIds)
        guard !ids.isEmpty, let found = try? await app.backend.stamps(countryCode: code, userIds: ids) else { return }
        _ = await app.profiles(for: found.map(\.userId))
        friendStamps[code] = found
    }
}

// ── Backdrop ────────────────────────────────────────────────────────────────

private struct GlobeBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Color.paper
                RadialGradient(colors: [Color.card.opacity(0.9), Color.paper.opacity(0)],
                               center: .center, startRadius: side * 0.1, endRadius: side * 0.85)
            }
        }
        .ignoresSafeArea()
    }
}

// ── First run ───────────────────────────────────────────────────────────────

struct BuildPassportCard: View {
    let onScan: () -> Void
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Build your passport")
                    .font(.displayXSmall)
                    .foregroundStyle(Color.ink)
                Text("Find the countries you've been to in your photos — it takes a few seconds and happens on your phone.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(action: onScan) {
                    Label("Scan photos", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.primary)
                Button(action: onPick) {
                    Label("Pick", systemImage: "checklist")
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: false))
            }
        }
        .card()
    }
}

// ── Country panel ───────────────────────────────────────────────────────────

struct CountryPanel: View {
    let country: Country
    let stamp: Stamp?
    var taste: Taste?
    let memories: [Memory]
    let isBucketListed: Bool
    let isHome: Bool
    let friends: [Profile]
    let onClose: () -> Void
    let onAddMemory: () -> Void
    var onLogMeal: () -> Void = {}
    let onStamp: () -> Void
    let onToggleBucket: () -> Void
    let onOpenMemory: (Memory) -> Void
    let onShowFriends: () -> Void
    let onRemoveStamp: () -> Void
    var onRemoveTaste: () -> Void = {}

    @State private var confirmRemove = false

    private var visited: Bool { stamp != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                FlagTile(code: country.code, size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(country.name)
                        .font(.displayXSmall)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    statusLine
                }
                Spacer(minLength: 4)
                Button(action: onToggleBucket) {
                    Image(systemName: isBucketListed ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isBucketListed ? Color.bucket : Color.inkSecondary)
                        .frame(width: 38, height: 38)
                        .background(Color.sunken, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isBucketListed ? "Remove from bucket list" : "Add to bucket list")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 30, height: 30)
                        .background(Color.sunken, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            if !memories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(memories.prefix(12)) { memory in
                            Button { onOpenMemory(memory) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    MemoryTile(memory: memory, showTitle: false)
                                        .frame(width: 96, height: 96)
                                    Text(memory.displayTitle)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.ink)
                                        .lineLimit(1)
                                        .frame(width: 96, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !friends.isEmpty {
                Button(action: onShowFriends) {
                    HStack(spacing: 10) {
                        FacePile(profiles: friends, size: 26)
                        Text(friendsText)
                            .font(.subheadline)
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.inkTertiary)
                    }
                    .padding(10)
                    .background(Color.sunken.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                // Eating is the everyday stamp; it leads wherever the country
                // has a cuisine to taste.
                if Cuisine.isCuisine(country.code) {
                    Button(action: onLogMeal) {
                        Label("Log a meal", systemImage: "fork.knife")
                    }
                    .buttonStyle(.primary)
                }
                if !visited {
                    Button(action: onStamp) {
                        Label("Been here", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: !Cuisine.isCuisine(country.code)))
                }
                Menu {
                    Button(action: onAddMemory) {
                        Label("Add a travel memory", systemImage: "airplane")
                    }
                    if visited {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label("Remove visited stamp", systemImage: "minus.circle")
                        }
                    }
                    if taste != nil {
                        Button(role: .destructive, action: onRemoveTaste) {
                            Label("Remove tasted stamp", systemImage: "fork.knife.circle")
                        }
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
        .padding(16)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 6)
        .confirmationDialog("Remove \(country.name) from your passport?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove stamp", role: .destructive, action: onRemoveStamp)
        } message: {
            Text(memories.isEmpty ? "You can stamp it again anytime." : "Delete the memories from here first.")
        }
    }

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 6) {
            if isHome {
                Pill(systemImage: "house.fill", text: "Home", tint: .brand, background: .brandSoft)
            }
            if let stamp {
                Pill(systemImage: "checkmark.seal.fill",
                     text: stamp.yearsText.map { "Visited \($0)" } ?? "Visited",
                     tint: .brand, background: .brandSoft)
            }
            if let taste {
                Pill(systemImage: "fork.knife",
                     text: taste.meals > 0 ? "Tasted · \(taste.meals.counted("meal"))" : "Tasted",
                     tint: .brand, background: .brandSoft)
            }
            if stamp != nil || taste != nil {
                EmptyView()
            } else if isBucketListed {
                Pill(systemImage: "bookmark.fill", text: "Bucket list", tint: .bucket, background: .bucketSoft)
            } else {
                Text(country.isSovereign ? country.continent.rawValue : "Territory · \(country.continent.rawValue)")
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
            }
            if stamp == nil || taste == nil, !memories.isEmpty {
                Text(memories.count.counted("memory", "memories"))
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .lineLimit(1)
    }

    private var friendsText: String {
        let names = friends.map(\.firstName)
        switch names.count {
        case 1: return "\(names[0]) has been here"
        case 2: return "\(names[0]) and \(names[1]) have been"
        default: return "\(names[0]), \(names[1]) +\(names.count - 2) have been"
        }
    }
}

/// Friends who've been somewhere, and what they saw.
struct FriendsInCountrySheet: View {
    let code: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var stamps: [Stamp] = []
    @State private var memories: [Memory] = []
    @State private var viewing: Memory?
    @State private var loaded = false

    private var country: Country? { CountryStore.byCode[code] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(stamps.sorted { ($0.lastVisited ?? "") > ($1.lastVisited ?? "") }) { stamp in
                        if let person = app.profile(stamp.userId) {
                            let theirs = memories.filter { $0.userId == person.id }
                            VStack(alignment: .leading, spacing: 10) {
                                NavigationLink {
                                    ProfileView(userId: person.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        AvatarView(profile: person, size: 40)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(person.name).font(.headline).foregroundStyle(Color.ink)
                                            Text(stamp.yearsText.map { "Visited \($0)" } ?? "Has been here")
                                                .font(.caption)
                                                .foregroundStyle(Color.inkSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color.inkTertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                if !theirs.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 10) {
                                            ForEach(theirs) { memory in
                                                Button { viewing = memory } label: {
                                                    MemoryTile(memory: memory).frame(width: 140, height: 140)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }
                            .card(padding: 14)
                        }
                    }
                    if loaded && stamps.isEmpty {
                        EmptyStateView(systemImage: "person.2", title: "No friends here yet",
                                       message: "When people you follow stamp \(country?.name ?? "this country"), they'll show up here.")
                            .padding(.top, 40)
                    }
                }
                .padding(Metrics.gutter)
            }
            .paperBackground()
            .navigationTitle("\(country?.flag ?? "") \(country?.name ?? code)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
            .task {
                let ids = Array(app.networkIds)
                stamps = (try? await app.backend.stamps(countryCode: code, userIds: ids)) ?? []
                _ = await app.profiles(for: stamps.map(\.userId))
                memories = (try? await app.backend.memories(countryCode: code, userIds: stamps.map(\.userId))) ?? []
                loaded = true
            }
        }
    }
}
