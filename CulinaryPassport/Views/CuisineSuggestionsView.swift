import SwiftUI

/// Where to eat next. Specific restaurants first — real places your people
/// rated highly that you haven't been to — then the cuisines to aim for if
/// nobody's been anywhere new lately.
struct CuisineSuggestionsView: View {
    let entries: [Entry]

    @State private var picks: [RestaurantRecommender.Pick] = []
    @State private var cuisines: [Recommender.Suggestion] = []
    @State private var saved: [SavedRestaurant] = []
    @State private var logCountry: Country?
    @State private var logRestaurant: RestaurantRecommender.Pick?
    @State private var loading = true

    private var savedKeys: Set<String> {
        Set(saved.map { "\($0.restaurantName.lowercased())|\($0.countryCode)" })
    }

    var body: some View {
        List {
            if !saved.isEmpty {
                Section("Saved for later") {
                    ForEach(saved) { place in
                        SavedRow(place: place) {
                            logCountry = CountryStore.byCode[place.countryCode]
                        } onRemove: {
                            Task {
                                try? await SupabaseService.shared.unsaveRestaurant(id: place.id)
                                saved.removeAll { $0.id == place.id }
                            }
                        }
                    }
                }
            }
            if !picks.isEmpty {
                Section {
                    ForEach(picks) { pick in
                        RestaurantRow(
                            pick: pick,
                            isSaved: savedKeys.contains("\(pick.restaurant.lowercased())|\(pick.country.code)"),
                            onLog: { logRestaurant = pick },
                            onSave: { Task { await save(pick) } }
                        )
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
        saved = (try? await SupabaseService.shared.savedRestaurants()) ?? []
        if let social = try? await SupabaseService.shared.entriesFromMyPeople() {
            picks = RestaurantRecommender.picks(mine: entries,
                                                theirs: social.entries,
                                                people: social.people)
        }
        loading = false
    }

    private func save(_ pick: RestaurantRecommender.Pick) async {
        try? await SupabaseService.shared.saveRestaurant(
            name: pick.restaurant, city: pick.city,
            countryCode: pick.country.code, note: pick.reason
        )
        saved = (try? await SupabaseService.shared.savedRestaurants()) ?? saved
    }
}

private struct SavedRow: View {
    let place: SavedRestaurant
    let onLog: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(CountryStore.byCode[place.countryCode]?.flagEmoji ?? "🌍").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.restaurantName).font(.subheadline.weight(.medium))
                if let note = place.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
                }
            }
            Spacer()
            Button(action: onLog) {
                BrandedIcon(name: "action-add", size: 22)
            }
            .buttonStyle(.plain)
        }
        .swipeActions {
            Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "bookmark.slash") }
        }
    }
}

private struct RestaurantRow: View {
    let pick: RestaurantRecommender.Pick
    let isSaved: Bool
    let onLog: () -> Void
    let onSave: () -> Void

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
            VStack(spacing: 10) {
                Button(action: onLog) {
                    BrandedIcon(name: "action-add", size: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log a meal at \(pick.restaurant)")
                Button(action: onSave) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(isSaved ? Color(uiColor: GlobeViewModel.queueAmber)
                                                 : Color(.tertiaryLabel))
                }
                .buttonStyle(.plain)
                .disabled(isSaved)
                .accessibilityLabel("Save for later")
            }
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
