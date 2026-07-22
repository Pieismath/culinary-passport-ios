import SwiftUI

/// The phone answer to "where's Ethiopia on this thing?" — type a country or
/// cuisine, tap it, and the globe flies there with the panel open (which has
/// the Log button). Replaces on-globe name labels, which collide at phone
/// scale; matches the web's hover-card model, translated to touch.
struct CountrySearchSheet: View {
    /// Country codes the user has already logged.
    let tried: Set<String>
    /// Codes on the Want to Try list (bookmark toggles live in the rows).
    let wishlisted: Set<String>
    let onToggleWishlist: (String) -> Void
    /// Called after dismiss with the picked country (parent flies the globe there).
    let onPick: (Country) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Country] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return CountryStore.all }
        return CountryStore.all.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.cuisineName.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(results) { country in
                        Button {
                            dismiss()
                            onPick(country)
                        } label: {
                            row(for: country)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Tap a cuisine to fly there. On the globe, press and hold a country to log it straight away.")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Country or cuisine")
            .navigationTitle("Find a cuisine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private func row(for country: Country) -> some View {
        HStack(spacing: 12) {
            Text(country.flagEmoji).font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(country.cuisineName).foregroundStyle(.primary)
                    if country.rare {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(.orange)
                    }
                }
                if country.cuisineName != country.name {
                    Text(country.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if tried.contains(country.code) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Already tried")
            }
            Button {
                onToggleWishlist(country.code)
            } label: {
                Image(systemName: wishlisted.contains(country.code) ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(wishlisted.contains(country.code)
                                     ? Color(uiColor: GlobeViewModel.queueAmber)
                                     : Color(.tertiaryLabel))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Want to try")
        }
    }
}
