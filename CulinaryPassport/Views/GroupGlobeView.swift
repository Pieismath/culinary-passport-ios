import SwiftUI
import UIKit

/// v1.2 item 13 — the group globe. The same SceneKit globe, colored by the whole
/// group's collective status with three lenses:
///  - My view: just your own cuisines.
///  - Solidarity: anywhere *anyone* in the group has eaten (union).
///  - Consensus: only where *everyone* has eaten (intersection).
struct GroupGlobeView: View {
    let group: Group

    enum Mode: String, CaseIterable {
        case mine = "My view", solidarity = "Solidarity", consensus = "Consensus"
        var blurb: String {
            switch self {
            case .mine: "Cuisines you've tried."
            case .solidarity: "Anywhere any of you has eaten."
            case .consensus: "Only where everyone has eaten."
            }
        }
    }

    @StateObject private var vm = GroupGlobeViewModel()
    @State private var mode: Mode = .solidarity
    @State private var selected: String?
    @State private var viewingEntry: Entry?

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobeCanvas(color: { code, sel in vm.color(for: code, mode: mode, selected: sel) },
                        selected: $selected)
                .ignoresSafeArea(edges: .bottom)

            if vm.loading { ProgressView().padding(.bottom, 40) }

            if let code = selected, let country = CountryStore.byCode[code] {
                GroupCountryPanel(
                    country: country,
                    tasters: vm.tasterNames(for: code),
                    entries: vm.entriesByCountry[code] ?? [],
                    authors: vm.usersById,
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
            EntryDetailView(entry: entry, author: vm.usersById[entry.userId]) {
                await vm.load(group: group)
            }
            .presentationDetents([.medium, .large])
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selected)
        .navigationTitle("\(group.name) globe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Lens", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .task { await vm.load(group: group) }
    }
}

@MainActor
final class GroupGlobeViewModel: ObservableObject {
    @Published var statusByCountry: [String: Set<UUID>] = [:]
    @Published var entriesByCountry: [String: [Entry]] = [:]
    @Published var memberIds: [UUID] = []
    @Published var usersById: [UUID: Profile] = [:]
    @Published var myId: UUID?
    @Published var loading = false

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
            guard !tasters.isEmpty, !memberIds.isEmpty else { return untouched }
            // Warmer the more members have been.
            let share = CGFloat(tasters.count) / CGFloat(memberIds.count)
            return GlobeViewModel.opaque(GlobeViewModel.amber, min(1, 0.45 + 0.35 * share + boost))
        case .consensus:
            let everyone = !memberIds.isEmpty && tasters.count >= memberIds.count
            return everyone ? GlobeViewModel.opaque(GlobeViewModel.purple, 0.7 + boost) : untouched
        }
    }

    func tasterNames(for code: String) -> [String] {
        (statusByCountry[code] ?? []).compactMap { usersById[$0]?.name }.sorted()
    }

    private var myColor: UIColor {
        (myId.flatMap { usersById[$0]?.color }).flatMap { UIColor(hex: $0) } ?? GlobeViewModel.amber
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
                        .font(.caption).foregroundStyle(.secondary)
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
