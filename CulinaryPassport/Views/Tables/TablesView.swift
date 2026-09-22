import SwiftUI

/// The tables you eat at — a dinner club, the family, the office lunch
/// crowd — laid out like a floor plan, each a round table with everyone
/// seated at it. Friends' latest plates sit underneath.
struct TablesView: View {
    /// A table to open (from an invite link, or one just set).
    @Binding var open: UUID?

    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()
    @State private var sheet: Sheet?
    @State private var showActivity = false
    @State private var viewing: Meal?
    @State private var feed = FeedModel(kind: .friends)

    enum Sheet: String, Identifiable {
        case create, join, people
        var id: String { rawValue }
    }

    enum Destination: Hashable { case friends }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 26) {
                    if app.groups.isEmpty && app.loadState != .loading {
                        VStack(spacing: 6) {
                            Text("Pull up a chair")
                                .font(.display)
                                .foregroundStyle(Color.ink)
                            Text("Set a table for the people you eat with. Everyone at it shares a globe, spins for dinner together and talks it over.")
                                .font(.subheadline)
                                .foregroundStyle(Color.inkSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 8)
                    }
                    floorPlan
                    friendsPlates
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 30)
            }
            .background(FloorPlanBackdrop())
            .navigationTitle("Tables")
            .navigationDestination(for: UUID.self) { TableView(groupId: $0) }
            .navigationDestination(for: Destination.self) { _ in FriendsFeedView() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showActivity = true } label: {
                        Image(systemName: app.unseenActivity > 0 ? "bell.badge" : "bell")
                            .symbolRenderingMode(app.unseenActivity > 0 ? .multicolor : .monochrome)
                    }
                    .accessibilityLabel(app.unseenActivity > 0 ? "Activity, \(app.unseenActivity) new" : "Activity")
                    Menu {
                        Button { sheet = .create } label: { Label("Set a new table", systemImage: "plus.circle") }
                        Button { sheet = .join } label: { Label("Join with a code", systemImage: "ticket") }
                        Button { sheet = .people } label: { Label("Find friends", systemImage: "person.badge.plus") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New table, join, or find friends")
                }
            }
            .refreshable {
                await app.refreshGroups()
                await feed.refresh(app: app)
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .create:
                    NameEntrySheet(title: "Set a table", field: "What's it called?", placeholder: "Friday Dinner Club",
                                   actionLabel: "Set it", autocapitalize: true,
                                   footer: "You'll get an invite code to share once it's set.") { name in
                        let group = try await app.createGroup(name: name)
                        app.celebrate("Table set — invite people from its details.")
                        open = group.id
                    }
                case .join:
                    NameEntrySheet(title: "Join a table", field: "Invite code", placeholder: "e.g. fridaydinner",
                                   actionLabel: "Join", autocapitalize: false,
                                   footer: "Ask someone at the table for the code — it's in the table's details.") { code in
                        let id = try await app.joinGroup(code: code)
                        app.celebrate("You're in!")
                        open = id
                    }
                case .people:
                    PeopleSearchView()
                }
            }
            .sheet(isPresented: $showActivity, onDismiss: { app.markActivitySeen() }) { ActivityView() }
            .sheet(item: $viewing) { MealDetailView(meal: $0) }
            // A task, not onChange: a link can arrive before this tab has
            // ever been shown, when there's nothing yet to observe the change.
            .task(id: open) {
                guard let id = open else { return }
                path = NavigationPath()
                path.append(id)
                open = nil
            }
            .task { if !feed.loaded { await feed.refresh(app: app) } }
        }
    }

    // ── The floor ────────────────────────────────────────────────────────────

    private var floorPlan: some View {
        let tables = app.groups
        return VStack(spacing: -34) {
            ForEach(Array(tables.enumerated()), id: \.element.id) { index, group in
                NavigationLink(value: group.id) {
                    TableSpot(group: group,
                              members: app.members(of: group.id).compactMap { app.profile($0) },
                              between: app.tasted(by: app.members(of: group.id)).count)
                }
                .buttonStyle(PressScale())
                .frame(maxWidth: .infinity, alignment: index.isMultiple(of: 2) ? .leading : .trailing)
            }
            newTable
                .frame(maxWidth: .infinity, alignment: tables.count.isMultiple(of: 2) ? .leading : .trailing)
                .padding(.top, tables.isEmpty ? 0 : 6)
        }
    }

    private var newTable: some View {
        VStack(spacing: 8) {
            Button { sheet = .create } label: {
                RoundTable(seats: (0..<4).map { TableSeat.empty($0) }, cloth: .inkTertiary, seatSize: 30,
                           showsPlates: false, isSet: false) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Set a table")
                            .font(.system(size: 14, weight: .semibold, design: .serif))
                    }
                    .foregroundStyle(Color.brand)
                }
                .frame(width: 170, height: 170)
            }
            .buttonStyle(PressScale())
            Button("or join with a code") { sheet = .join }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.brand)
        }
        .frame(width: 196)
    }

    // ── Friends' plates ──────────────────────────────────────────────────────

    @ViewBuilder private var friendsPlates: some View {
        let plates = Array(feed.visible(app: app).prefix(12))
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Friends' plates", subtitle: plates.isEmpty ? nil : "What your people ate lately") {
                NavigationLink(value: Destination.friends) {
                    Text("See all").font(.subheadline.weight(.semibold))
                }
            }
            if plates.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "person.2")
                        .font(.title3)
                        .foregroundStyle(Color.brand)
                        .frame(width: 48, height: 48)
                        .background(Color.brandSoft, in: Circle())
                    Text(feed.loaded ? "Follow friends to see what they're eating." : "Setting the table…")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                    Spacer(minLength: 4)
                    if feed.loaded {
                        Button("Find") { sheet = .people }
                            .buttonStyle(.capsuleProminent)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(plates) { meal in
                            Button { viewing = meal } label: {
                                VStack(spacing: 5) {
                                    MealPlate(meal: meal, size: 96)
                                        .overlay(alignment: .topLeading) {
                                            AvatarView(profile: app.profile(meal.userId), size: 28)
                                                .overlay(Circle().strokeBorder(Color.card, lineWidth: 2))
                                                .offset(x: -2, y: -2)
                                        }
                                    Text(app.profile(meal.userId)?.firstName ?? "Friend")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.ink)
                                        .lineLimit(1)
                                    Text(Cuisine.name(for: meal.countryCode))
                                        .font(.caption2)
                                        .foregroundStyle(Color.inkSecondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 100)
                            }
                            .buttonStyle(PressScale())
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(.top, 10)
    }
}

/// One table on the floor plan: the cloth in the table's colour, everyone's
/// chair, its name on a card in the middle.
struct TableSpot: View {
    let group: Group
    let members: [Profile]
    let between: Int

    private var seats: [TableSeat] {
        var seats = members.prefix(8).map { TableSeat(id: $0.id.uuidString, profile: $0) }
        while seats.count < 4 { seats.append(.empty(seats.count)) }
        return seats
    }

    var body: some View {
        VStack(spacing: 4) {
            RoundTable(seats: seats, cloth: Color(hex: GroupPalette.stableColor(for: group.id)), seatSize: 34) {
                Text(group.name)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .padding(10)
                    .frame(width: 86, height: 86)
                    .background(Circle().fill(Color.card).shadow(color: .black.opacity(0.12), radius: 3, y: 1))
                    .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 0.8).padding(4))
            }
            .frame(width: 196, height: 196)
            Text("\(members.count) seated · \(between.counted("cuisine")) between you")
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 196)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.name), \(members.count) seated, \(between) cuisines between you")
        .accessibilityAddTraits(.isButton)
    }
}

/// A restaurant floor plan drawn in pencil under the tables.
struct FloorPlanBackdrop: View {
    var body: some View {
        ZStack {
            Color.paper
            Canvas { context, size in
                let ink = GraphicsContext.Shading.color(Color.hairline.opacity(0.55))
                var tiles = Path()
                var x = 0.0
                while x < size.width {
                    tiles.move(to: CGPoint(x: x, y: 0))
                    tiles.addLine(to: CGPoint(x: x, y: size.height))
                    x += 32
                }
                var y = 0.0
                while y < size.height {
                    tiles.move(to: CGPoint(x: 0, y: y))
                    tiles.addLine(to: CGPoint(x: size.width, y: y))
                    y += 32
                }
                context.stroke(tiles, with: ink, style: StrokeStyle(lineWidth: 0.4, dash: [2, 3]))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A table's photo, or its colour and initial.
struct GroupAvatarView: View {
    let group: Group
    var size: CGFloat = 44
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: GroupPalette.stableColor(for: group.id)).opacity(0.9))
            Text(String(group.name.trimmed.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let path = group.coverPhoto, let url = app.backend.groupCoverURL(path) {
                RemoteImage(source: .url(url), maxPixel: size * 3) { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One text field, Cancel and a confirm button — always escapable.
struct NameEntrySheet: View {
    let title: String
    let field: String
    let placeholder: String
    let actionLabel: String
    var autocapitalize = true
    var footer: String?
    let action: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(placeholder, text: $text)
                        .focused($focused)
                        .textInputAutocapitalization(autocapitalize ? .words : .never)
                        .autocorrectionDisabled(!autocapitalize)
                        .submitLabel(.done)
                        .onSubmit { Task { await run() } }
                } header: {
                    Text(field)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let error { Text(error).foregroundStyle(Color.danger) }
                        if let footer { Text(footer) }
                    }
                }
            }
            .paperListStyle()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "…" : actionLabel) { Task { await run() } }
                        .fontWeight(.semibold)
                        .disabled(text.trimmed.isEmpty || busy)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func run() async {
        guard !text.trimmed.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await action(text.trimmed)
            dismiss()
        } catch {
            self.error = AppError.friendly(error)
        }
    }
}
