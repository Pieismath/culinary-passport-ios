import SwiftUI
import UIKit

/// The group HOME: opening a group lands here — the shared globe first, chat
/// and details a tap away. Three lenses:
///  - Solidarity: anywhere anyone has eaten, tinted by WHO (each member gets a
///    distinct color; shared countries blend them).
///  - Consensus: only where everyone has eaten.
///  - My view: just your own cuisines.
struct GroupGlobeView: View {
    let group: Group

    enum Mode: String, CaseIterable {
        case solidarity = "Solidarity", consensus = "Consensus", mine = "My view"
        var blurb: String {
            switch self {
            case .solidarity: "Anywhere any of you has eaten — colored by who."
            case .consensus: "Only where everyone has eaten."
            case .mine: "Cuisines you've tried."
            }
        }
    }

    @State private var groupInfo: Group
    @StateObject private var vm = GroupGlobeViewModel()
    @State private var mode: Mode = .solidarity
    @State private var selected: String?
    @State private var viewingEntry: Entry?
    @State private var showDetails = false
    @State private var showLeaderboard = false
    @Environment(\.dismiss) private var dismiss

    init(group: Group) {
        self.group = group
        _groupInfo = State(initialValue: group)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.972, green: 0.960, blue: 0.930).ignoresSafeArea()

            VStack(spacing: 10) {
                Picker("Lens", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if mode == .solidarity, vm.memberIds.count > 1 {
                    memberLegend
                }

                GlobeCanvas(color: { code, sel in vm.color(for: code, mode: mode, selected: sel) },
                            selected: $selected)
            }

            if vm.loading { ProgressView().padding(.bottom, 40) }

            if let code = selected, let country = CountryStore.byCode[code] {
                GroupCountryPanel(
                    country: country,
                    tasters: vm.tasterNames(for: code),
                    entries: vm.entriesByCountry[code] ?? [],
                    authors: vm.paletteProfiles,
                    memberCount: vm.memberIds.count,
                    onClose: { selected = nil },
                    onSelectEntry: { viewingEntry = $0 }
                )
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Text(mode.blurb)
                    .font(.caption)
                    .padding(8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 20)
            }
        }
        .sheet(item: $viewingEntry) { entry in
            EntryDetailView(entry: entry, author: vm.paletteProfiles[entry.userId]) {
                await vm.load(group: groupInfo)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDetails) {
            GroupDetailsView(
                group: $groupInfo,
                members: vm.memberIds,
                profiles: vm.paletteProfiles,
                onLeft: { dismiss() },
                onChanged: { await vm.load(group: groupInfo) }
            )
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selected)
        .navigationTitle(groupInfo.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showLeaderboard = true } label: {
                    Image(systemName: "trophy")
                }
                .accessibilityLabel("Leaderboard")
                NavigationLink {
                    GroupFeedView(group: groupInfo)
                } label: {
                    BrandedIcon(name: "feature-chat", size: 22)
                }
                Button { showDetails = true } label: {
                    GroupAvatarView(group: groupInfo, size: 28)
                }
                .accessibilityLabel("Group details")
            }
        }
        .sheet(isPresented: $showLeaderboard) {
            GroupLeaderboardSheet(
                members: vm.memberIds,
                profiles: vm.paletteProfiles,
                entriesByCountry: vm.entriesByCountry
            )
        }
        .task { await vm.load(group: groupInfo) }
    }

    /// Who's who: one chip per member in their globe color.
    private var memberLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.memberIds, id: \.self) { id in
                    if let profile = vm.paletteProfiles[id] {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(uiColor: UIColor(hex: profile.color) ?? .systemGray))
                                .frame(width: 9, height: 9)
                            Text(profile.name).font(.caption)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

/// Group photo, or a colored monogram fallback.
struct GroupAvatarView: View {
    let group: Group
    var size: CGFloat = 44

    var body: some View {
        SwiftUI.Group {
            if let path = group.coverPhoto,
               let url = SupabaseService.shared.groupCoverURL(path) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    monogram
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var monogram: some View {
        ZStack {
            Circle().fill(Color(uiColor: UIColor(hex: GroupPalette.fallbacks[
                abs(group.id.hashValue) % GroupPalette.fallbacks.count
            ]) ?? .systemGray3).opacity(0.85))
            Text(String(group.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

@MainActor
final class GroupGlobeViewModel: ObservableObject {
    @Published var statusByCountry: [String: Set<UUID>] = [:]
    @Published var entriesByCountry: [String: [Entry]] = [:]
    @Published var memberIds: [UUID] = []
    @Published var usersById: [UUID: Profile] = [:]
    /// Profiles with their color replaced by the group palette assignment —
    /// what every group surface (globe, legend, panel dots) should use.
    @Published var paletteProfiles: [UUID: Profile] = [:]
    @Published var myId: UUID?
    @Published var loading = false

    private var assignedColors: [UUID: String] = [:]

    func load(group: Group) async {
        loading = true
        defer { loading = false }
        do {
            myId = try? await SupabaseService.shared.client.auth.session.user.id
            let ids = try await SupabaseService.shared.groupMemberIds(groupId: group.id)
            memberIds = ids
            let entries = try await SupabaseService.shared.entriesForUsers(ids)
            var status: [String: Set<UUID>] = [:]
            var byCountry: [String: [Entry]] = [:]
            for e in entries {
                status[e.countryCode, default: []].insert(e.userId)
                byCountry[e.countryCode, default: []].append(e)
            }
            statusByCountry = status
            entriesByCountry = byCountry
            let profiles = try await SupabaseService.shared.profiles(ids: ids)
            usersById = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            assignedColors = GroupPalette.assign(memberIds: ids, profiles: usersById)
            paletteProfiles = usersById.mapValues { profile in
                var p = profile
                p.color = assignedColors[p.id] ?? p.color
                return p
            }
        } catch {
            statusByCountry = [:]
            entriesByCountry = [:]
        }
    }

    func color(for code: String, mode: GroupGlobeView.Mode, selected: Bool) -> UIColor {
        let boost: CGFloat = selected ? 0.22 : 0
        let tasters = statusByCountry[code] ?? []
        let untouched = GlobeViewModel.opaque(GlobeViewModel.parchment, 0.55 + boost)

        switch mode {
        case .mine:
            let mine = myId.map { tasters.contains($0) } ?? false
            return mine ? GlobeViewModel.opaque(myColor, 0.64 + boost) : untouched
        case .solidarity:
            guard !tasters.isEmpty else { return untouched }
            // Each member paints in their own color; shared countries blend.
            let colors = tasters.compactMap { assignedColors[$0].flatMap { UIColor(hex: $0) } }
            guard !colors.isEmpty else { return untouched }
            let blended = Self.blend(colors)
            let depth = min(0.18, CGFloat(tasters.count - 1) * 0.06)
            return GlobeViewModel.opaque(blended, min(0.9, 0.6 + depth + boost))
        case .consensus:
            let everyone = !memberIds.isEmpty && tasters.count >= memberIds.count
            return everyone ? GlobeViewModel.opaque(GlobeViewModel.purple, 0.7 + boost) : untouched
        }
    }

    func tasterNames(for code: String) -> [String] {
        (statusByCountry[code] ?? []).compactMap { usersById[$0]?.name }.sorted()
    }

    private var myColor: UIColor {
        (myId.flatMap { assignedColors[$0] }).flatMap { UIColor(hex: $0) } ?? GlobeViewModel.amber
    }

    private static func blend(_ colors: [UIColor]) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        for color in colors {
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
            color.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
            r += cr; g += cg; b += cb
        }
        let n = CGFloat(colors.count)
        return UIColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
    }
}

/// Friendly competition: who's eaten the most of the world. Computed from
/// the already-loaded group entries — no extra queries.
private struct GroupLeaderboardSheet: View {
    let members: [UUID]
    let profiles: [UUID: Profile]
    let entriesByCountry: [String: [Entry]]

    @Environment(\.dismiss) private var dismiss

    private struct Standing: Identifiable {
        let profile: Profile
        let cuisines: Int
        let meals: Int
        let rare: Int
        var id: UUID { profile.id }
    }

    private var standings: [Standing] {
        var cuisines: [UUID: Set<String>] = [:]
        var meals: [UUID: Int] = [:]
        for (code, entries) in entriesByCountry {
            for entry in entries {
                cuisines[entry.userId, default: []].insert(code)
                meals[entry.userId, default: 0] += 1
            }
        }
        return members.compactMap { id -> Standing? in
            guard let profile = profiles[id] else { return nil }
            let codes = cuisines[id] ?? []
            return Standing(profile: profile,
                            cuisines: codes.count,
                            meals: meals[id] ?? 0,
                            rare: codes.filter { Country.rareCodes.contains($0) }.count)
        }
        .sorted { ($0.cuisines, $0.meals) > ($1.cuisines, $1.meals) }
    }

    var body: some View {
        NavigationStack {
            List(Array(standings.enumerated()), id: \.element.id) { index, standing in
                HStack(spacing: 12) {
                    Text(medal(index))
                        .font(.title3)
                        .frame(width: 30)
                    Circle()
                        .fill(Color(uiColor: UIColor(hex: standing.profile.color) ?? .systemGray))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(standing.profile.name).font(.subheadline.weight(.semibold))
                        Text("\(standing.meals) meal\(standing.meals == 1 ? "" : "s")\(standing.rare > 0 ? " · \(standing.rare) rare ✦" : "")")
                            .font(.caption)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    Spacer()
                    Text("\(standing.cuisines)")
                        .font(.title3.bold()).monospacedDigit()
                    Text("cuisines")
                        .font(.caption2)
                        .foregroundStyle(Color(.secondaryLabel))
                }
                .padding(.vertical, 3)
            }
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
        default: "\(index + 1)."
        }
    }
}

private struct GroupCountryPanel: View {
    let country: Country
    let tasters: [String]
    let entries: [Entry]
    let authors: [UUID: Profile]
    let memberCount: Int
    let onClose: () -> Void
    let onSelectEntry: (Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(country.flagEmoji).font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(country.cuisineName).font(.headline)
                    Text("\(tasters.count) of \(memberCount) have tried it")
                        .font(.caption).foregroundStyle(Color(.secondaryLabel))
                }
                Spacer()
                if entries.count > 1 {
                    Text("\(entries.count) meals")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(.systemGray5), in: Capsule())
                }
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            if entries.isEmpty {
                Label("No one yet", systemImage: "circle.dashed")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Divider()
                // Who ate what, where, when — RLS already scopes this to
                // entries shared with the group. Tap one for the full card.
                CountryEntriesList(entries: entries, authors: authors, onSelect: onSelectEntry)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 12, y: 4)
    }
}
