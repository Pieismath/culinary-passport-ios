import SwiftUI

/// Where to eat next. Specific restaurants first — real places your people
/// rated highly that you haven't been to — then the cuisines to aim for if
/// nobody's been anywhere new lately.
struct CuisineSuggestionsView: View {
    let entries: [Entry]

    @State private var picks: [RestaurantRecommender.Pick] = []
    @State private var cuisines: [Recommender.Suggestion] = []
    @State private var logCountry: Country?
    @State private var logRestaurant: RestaurantRecommender.Pick?
    @State private var loading = true

    var body: some View {
        List {
            if !picks.isEmpty {
                Section {
                    ForEach(picks) { pick in
                        RestaurantRow(pick: pick) { logRestaurant = pick }
                    }
                } header: {
                    Text("Places your people loved")
                } footer: {
                    Text("From meals shared by people you follow and your groups — places you haven't logged yet.")
                }
            }

            Section {
                ForEach(cuisines) { suggestion in
                    CuisineRow(suggestion: suggestion) { logCountry = suggestion.country }
                }
            } header: {
                Text(picks.isEmpty ? "Cuisines to try next" : "New cuisines to aim for")
            } footer: {
                if picks.isEmpty && !cuisines.isEmpty {
                    Text("Follow people or join a group and this fills with the specific restaurants they rated highly.")
                }
            }
        }
        .overlay {
            if loading {
                ProgressView()
            } else if picks.isEmpty && cuisines.isEmpty {
                ContentUnavailableView(
                    "Log a few meals first",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Once there are a few meals — and a few notes about what you liked — this fills with places picked for you.")
                )
            }
        }
        .navigationTitle("Recommended for you")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $logCountry) { country in
            EntrySheet(mode: .add, presetCountryCode: country.code) { }
        }
        .sheet(item: $logRestaurant) { pick in
            EntrySheet(mode: .add, presetCountryCode: pick.country.code) { }
        }
        .task { await load() }
    }

    private func load() async {
        cuisines = Recommender.suggestions(entries: entries)
        if let social = try? await SupabaseService.shared.entriesFromMyPeople() {
            picks = RestaurantRecommender.picks(mine: entries,
                                                theirs: social.entries,
                                                people: social.people)
        }
        loading = false
    }
}

private struct RestaurantRow: View {
    let pick: RestaurantRecommender.Pick
    let onLog: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(pick.country.flagEmoji).font(.title2)
                Text(String(format: "%.1f", pick.averageRating))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(pick.restaurant).font(.headline)
                Text([pick.country.cuisineName, pick.city].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
                Text(pick.reason)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
                if let dish = pick.signatureDish {
                    Label(dish, systemImage: "fork.knife")
                        .font(.caption2)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            Spacer(minLength: 4)
            Button(action: onLog) {
                BrandedIcon(name: "action-add", size: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Log a meal at \(pick.restaurant)")
        }
        .padding(.vertical, 3)
    }
}

private struct CuisineRow: View {
    let suggestion: Recommender.Suggestion
    let onLog: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(suggestion.country.flagEmoji).font(.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(suggestion.country.cuisineName).font(.headline)
                    if suggestion.country.rare {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            Spacer()
            Button(action: onLog) {
                BrandedIcon(name: "action-add", size: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Log a \(suggestion.country.cuisineName) meal")
        }
        .padding(.vertical, 3)
    }
}
