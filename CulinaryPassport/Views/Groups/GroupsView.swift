import SwiftUI

/// Your travel groups — a trip crew, family, the friends you always go with.
/// Each shares one globe and a chat.
struct GroupsView: View {
    @Environment(AppModel.self) private var app
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case create, join
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(app.groups) { group in
                        NavigationLink(value: group) {
                            GroupCard(group: group, members: app.members(of: group.id).compactMap { app.profile($0) })
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Metrics.gutter)
            }
            .overlay {
                if app.groups.isEmpty && app.loadState != .loading {
                    EmptyStateView(
                        systemImage: "person.3",
                        title: "Plan trips together",
                        message: "A group shares one globe and a chat — see where your crew has been, where you all still want to go, and plan the next one.",
                        primaryTitle: "Create a group",
                        primaryAction: { sheet = .create },
                        secondaryTitle: "Join with a code",
                        secondaryAction: { sheet = .join }
                    )
                }
            }
            .paperBackground()
            .navigationTitle("Groups")
            .navigationDestination(for: Group.self) { GroupHomeView(groupId: $0.id) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { sheet = .create } label: { Label("Create a group", systemImage: "plus.circle") }
                        Button { sheet = .join } label: { Label("Join with a code", systemImage: "ticket") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create or join a group")
                }
            }
            .refreshable { await app.refreshGroups() }
            .sheet(item: $sheet) { which in
                switch which {
                case .create:
                    NameEntrySheet(title: "New group", field: "Group name", placeholder: "Europe 2027",
                                   actionLabel: "Create", autocapitalize: true,
                                   footer: "You'll get an invite code to share once it's created.") { name in
                        try await app.createGroup(name: name)
                        app.celebrate("Group created — invite your crew from its details.")
                    }
                case .join:
                    NameEntrySheet(title: "Join a group", field: "Invite code", placeholder: "e.g. europe2027",
                                   actionLabel: "Join", autocapitalize: false,
                                   footer: "Ask a member for the code — it's under the group's details.") { code in
                        try await app.joinGroup(code: code)
                        app.celebrate("You're in!")
                    }
                }
            }
        }
    }
}

private struct GroupCard: View {
    let group: Group
    let members: [Profile]

    var body: some View {
        HStack(spacing: 14) {
            GroupAvatarView(group: group, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(group.name)
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                HStack(spacing: 8) {
                    FacePile(profiles: members, size: 22, limit: 5)
                    Text("\(members.count) member\(members.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.inkTertiary)
        }
        .card(padding: 14)
    }
}

/// Group photo, or a colored monogram.
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
    @Environment(AppModel.self) private var app
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

// ── Group home: the shared globe ────────────────────────────────────────────

struct GroupHomeView: View {
    let groupId: UUID

    enum Lens: String, CaseIterable, Identifiable {
        case everyone = "Everyone"
        case allOfUs = "All of us"
        case me = "Me"
        var id: String { rawValue }

        var blurb: String {
            switch self {
            case .everyone: "Anywhere any of you has been — colored by who."
            case .allOfUs: "Countries every one of you has stamped."
            case .me: "Just your stamps."
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var lens: Lens = .everyone
    @State private var selected: String?
    @State private var stamps: [Stamp] = []
    @State private var focusMember: UUID?
    @State private var showDetails = false
    @State private var showLeaderboard = false
    @State private var countryMemories: [String: [Memory]] = [:]
    @State private var viewing: Memory?

    private var group: Group? { app.groups.first { $0.id == groupId } }
    private var memberIds: [UUID] { app.members(of: groupId) }
    private var palette: [UUID: String] {
        GroupPalette.assign(memberIds: memberIds, profiles: app.people.merging(app.me.map { [$0.id: $0] } ?? [:]) { a, _ in a })
    }

    private var visitorsByCountry: [String: Set<UUID>] {
        var result: [String: Set<UUID>] = [:]
        for stamp in stamps where memberIds.contains(stamp.userId) {
            result[stamp.countryCode, default: []].insert(stamp.userId)
        }
        return result
    }

    private var unionCount: Int { visitorsByCountry.count }
    private var sharedCount: Int { visitorsByCountry.values.filter { $0.count == memberIds.count && !memberIds.isEmpty }.count }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.paper.ignoresSafeArea()
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    HStack(spacing: 18) {
                        StatTile(value: "\(unionCount)", label: "between you")
                        StatTile(value: "\(sharedCount)", label: "all of you")
                        StatTile(value: "\(memberIds.count)", label: "members")
                    }
                    Picker("Lens", selection: $lens) {
                        ForEach(Lens.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if lens == .everyone && memberIds.count > 1 {
                        legend
                    }
                }
                .padding(.horizontal, Metrics.gutter)

                // Palette and visitors are derived once per render, not once
                // per country per recolor (~230 calls).
                let palette = self.palette
                let visitors = visitorsByCountry
                GlobeCanvas(style: GlobeStyle(scheme),
                            color: { code, isSelected in
                                color(for: code, selected: isSelected, visitors: visitors[code] ?? [], palette: palette)
                            },
                            selected: $selected,
                            isEmphasized: { visitors[$0] != nil })
            }

            if let code = selected, let country = CountryStore.byCode[code] {
                GroupCountryPanel(
                    country: country,
                    visitors: (visitorsByCountry[code] ?? []).compactMap { app.profile($0) }
                        .map { profile in var p = profile; p.color = palette[p.id] ?? p.color; return p },
                    memberCount: memberIds.count,
                    memories: countryMemories[code] ?? [],
                    onOpen: { viewing = $0 },
                    onClose: { selected = nil }
                )
                .padding(12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Text(focusMember.flatMap { app.profile($0)?.firstName }.map { "Showing \($0)'s stamps · tap again to clear" } ?? lens.blurb)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.inkSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: selected)
        .onChange(of: lens) { focusMember = nil }
        .navigationTitle(group?.name ?? "Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showLeaderboard = true } label: { Image(systemName: "trophy") }
                    .accessibilityLabel("Leaderboard")
                if let group {
                    NavigationLink {
                        GroupChatView(group: group)
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .accessibilityLabel("Chat")
                    Button { showDetails = true } label: { GroupAvatarView(group: group, size: 30) }
                        .accessibilityLabel("Group details")
                }
            }
        }
        .sheet(isPresented: $showDetails) {
            if let group {
                GroupDetailsView(group: group, onGone: { dismiss() })
            }
        }
        .sheet(isPresented: $showLeaderboard) {
            LeaderboardSheet(memberIds: memberIds, stamps: stamps, palette: palette)
        }
        .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
        .task { await load() }
        .task(id: selected) { await loadMemories(for: selected) }
        .onChange(of: group == nil) { _, gone in if gone { dismiss() } }
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(memberIds, id: \.self) { id in
                    if let person = app.profile(id) {
                        Button {
                            focusMember = focusMember == id ? nil : id
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: palette[id] ?? person.color)).frame(width: 10, height: 10)
                                Text(id == app.myId ? "You" : person.firstName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.ink)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(focusMember == id ? Color.brandSoft : Color.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(focusMember == id ? Color.brand : Color.hairline, lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if memberIds.count > 1 {
                    HStack(spacing: 6) {
                        Circle().fill(Color(uiColor: GlobeStyle(scheme).shared)).frame(width: 10, height: 10)
                        Text("Shared").font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func color(for code: String, selected isSelected: Bool,
                       visitors: Set<UUID>, palette: [UUID: String]) -> UIColor {
        let style = GlobeStyle(scheme)
        switch lens {
        case .me:
            guard let me = app.myId, visitors.contains(me) else { return style.untouched(selected: isSelected) }
            return style.visited(UIColor(hex: palette[me] ?? "") ?? Palette.brand, memories: 1, selected: isSelected)
        case .allOfUs:
            guard !memberIds.isEmpty, visitors.count == memberIds.count else { return style.untouched(selected: isSelected) }
            return style.visited(style.shared, memories: 1, selected: isSelected)
        case .everyone:
            if let focus = focusMember {
                guard visitors.contains(focus) else { return style.untouched(selected: isSelected) }
                return style.visited(UIColor(hex: palette[focus] ?? "") ?? Palette.brand, memories: 1, selected: isSelected)
            }
            // One visitor wears their color; shared countries get the shared
            // ink, deeper with each extra person. (Averaging member colors
            // turned every shared country the same muddy grey.)
            if visitors.count == 1, let only = visitors.first {
                return style.visited(UIColor(hex: palette[only] ?? "") ?? Palette.brand, memories: 1, selected: isSelected)
            }
            guard visitors.count > 1 else { return style.untouched(selected: isSelected) }
            return style.visited(style.shared, memories: visitors.count - 1, selected: isSelected)
        }
    }

    private func load() async {
        _ = await app.profiles(for: memberIds)
        stamps = (try? await app.backend.stamps(userIds: memberIds)) ?? []
    }

    private func loadMemories(for code: String?) async {
        guard let code, countryMemories[code] == nil else { return }
        countryMemories[code] = (try? await app.backend.memories(countryCode: code, userIds: memberIds)) ?? []
    }
}

private struct GroupCountryPanel: View {
    let country: Country
    let visitors: [Profile]
    let memberCount: Int
    let memories: [Memory]
    let onOpen: (Memory) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FlagTile(code: country.code, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(country.name).font(.displayXSmall).foregroundStyle(Color.ink)
                    Text(visitors.isEmpty ? "Nobody yet — a group adventure?" : "\(visitors.count) of \(memberCount) have been")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer()
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
            if !visitors.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(visitors) { person in
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: person.color)).frame(width: 8, height: 8)
                            Text(person.firstName).font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.sunken, in: Capsule())
                    }
                }
            }
            if !memories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(memories) { memory in
                            Button { onOpen(memory) } label: {
                                MemoryTile(memory: memory).frame(width: 110, height: 110)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 6)
    }
}

/// Friendly competition: who's been the most places.
struct LeaderboardSheet: View {
    let memberIds: [UUID]
    let stamps: [Stamp]
    let palette: [UUID: String]

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private struct Standing: Identifiable {
        let profile: Profile
        let countries: Int
        let continents: Int
        let newThisYear: Int
        var id: UUID { profile.id }
    }

    private var standings: [Standing] {
        let year = Calendar.current.component(.year, from: Date())
        return memberIds.compactMap { id -> Standing? in
            guard let profile = app.profile(id) else { return nil }
            let theirs = stamps.filter { $0.userId == id }
            let stats = TravelStats(stamps: theirs, memories: [])
            return Standing(profile: profile, countries: stats.countries, continents: stats.continents,
                            newThisYear: TravelStats.newCountries(in: year, stamps: theirs).count)
        }
        .sorted { ($0.countries, $0.continents, $1.profile.name) > ($1.countries, $1.continents, $0.profile.name) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(standings.enumerated()), id: \.element.id) { index, standing in
                    HStack(spacing: 12) {
                        Text(medal(index))
                            .font(index < 3 ? .title2 : .headline)
                            .frame(width: 34)
                        AvatarView(profile: standing.profile, size: 40,
                                   ring: Color(hex: palette[standing.profile.id] ?? standing.profile.color))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(standing.profile.id == app.myId ? "You" : standing.profile.name)
                                .font(.headline)
                            Text("\(standing.continents) continent\(standing.continents == 1 ? "" : "s")\(standing.newThisYear > 0 ? " · \(standing.newThisYear) new this year" : "")")
                                .font(.caption)
                                .foregroundStyle(Color.inkSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(standing.countries)").font(.number(.title2)).monospacedDigit()
                            Text("countries").font(.caption2).foregroundStyle(Color.inkSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.card)
                }
            }
            .paperListStyle()
            .navigationTitle("Leaderboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func medal(_ index: Int) -> String {
        switch index {
        case 0: "🥇"
        case 1: "🥈"
        case 2: "🥉"
        default: "\(index + 1)"
        }
    }
}
