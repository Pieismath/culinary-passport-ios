import SwiftUI

/// Cuisines you haven't tried, ranked by what your journal says you like —
/// each with the reason it made the list. Log one straight from here.
struct CuisineSuggestionsView: View {
    let entries: [Entry]

    @State private var logCountry: Country?
    @State private var suggestions: [Recommender.Suggestion] = []

    var body: some View {
        List {
            ForEach(suggestions) { suggestion in
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
                    Button {
                        logCountry = suggestion.country
                    } label: {
                        BrandedIcon(name: "action-add", size: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log a \(suggestion.country.cuisineName) meal")
                }
                .padding(.vertical, 3)
            }
        }
        .overlay {
            if suggestions.isEmpty {
                ContentUnavailableView(
                    "Log a few meals first",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("Once there are a few meals — and a few notes about what you liked — this fills with cuisines picked for you.")
                )
            }
        }
        .navigationTitle("Recommended for you")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $logCountry) { country in
            EntrySheet(mode: .add, presetCountryCode: country.code) { }
        }
        .task { suggestions = Recommender.suggestions(entries: entries) }
    }
}
