import SwiftUI

/// v1.3 item 16 — long-distance sync meals. Cuisines two or more members have
/// each eaten become "heart-linked" stamps; you can also propose a cuisine for
/// everyone to try tonight (posts to the group feed).
struct SyncedMealsView: View {
    let group: Group

    @StateObject private var vm = GroupGlobeViewModel()
    @State private var proposing = false
    @State private var status: String?

    /// Countries at least two members have each tried, most-shared first.
    private var synced: [(country: Country, tasters: [String])] {
        vm.statusByCountry.compactMap { code, ids -> (Country, [String])? in
            guard ids.count >= 2, let c = CountryStore.byCode[code] else { return nil }
            let names = ids.compactMap { vm.usersById[$0]?.name }.sorted()
            return (c, names)
        }
        .sorted { $0.1.count > $1.1.count || ($0.1.count == $1.1.count && $0.0.name < $1.0.name) }
    }

    var body: some View {
        List {
            if synced.isEmpty {
                ContentUnavailableView(
                    "No synced meals yet",
                    systemImage: "heart",
                    description: Text("When two of you have each tried the same cuisine, it links here.")
                )
            } else {
                Section("Heart-linked cuisines") {
                    ForEach(synced, id: \.country.id) { item in
                        HStack(spacing: 12) {
                            Text(item.country.flagEmoji).font(.title)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.country.cuisineName).font(.headline)
                                Text(item.tasters.joined(separator: " & "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "heart.fill").foregroundStyle(.pink)
                        }
                    }
                }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("Synced")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await propose() }
                } label: {
                    Label("Propose tonight", systemImage: "sparkles")
                }
                .disabled(proposing)
            }
        }
        .task { await vm.load(group: group) }
    }

    /// Pick a cuisine no one in the group has synced yet and post it to the feed.
    private func propose() async {
        proposing = true
        defer { proposing = false }
        let syncedCodes = Set(synced.map(\.country.code))
        let candidate = CountryStore.all.filter { !syncedCodes.contains($0.code) }.randomElement()
            ?? CountryStore.all.randomElement()
        guard let candidate else { return }
        do {
            try await SupabaseService.shared.createPost(
                groupId: group.id,
                text: "Let's both try \(candidate.flagEmoji) \(candidate.cuisineName) tonight 💕"
            )
            status = "Proposed \(candidate.cuisineName) — check the feed!"
        } catch {
            status = error.localizedDescription
        }
    }
}
