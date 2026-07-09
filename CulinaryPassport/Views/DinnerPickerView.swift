import SwiftUI

/// v1.3 item 15 — "what should we eat tonight?" A filter-aware spin that lands on
/// a cuisine, then find it nearby (Apple Maps) or log it. Ports the web A3 spin.
struct DinnerPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Filter: String, CaseIterable { case all = "Any", untried = "New to me" }

    @State private var filter: Filter = .all
    @State private var picked: Country?
    @State private var spinning = false
    @State private var triedCodes: Set<String> = []
    @State private var showLog = false

    private var candidates: [Country] {
        switch filter {
        case .all: CountryStore.all
        case .untried: CountryStore.all.filter { !triedCodes.contains($0.code) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Spacer()

                if let picked {
                    VStack(spacing: 10) {
                        Text(picked.flagEmoji).font(.system(size: 96))
                            .scaleEffect(spinning ? 0.9 : 1)
                        Text(picked.cuisineName).font(.largeTitle).bold()
                        Text(picked.subregion.isEmpty ? picked.continent : picked.subregion)
                            .foregroundStyle(.secondary)
                        if picked.rare { Label("A rare find", systemImage: "sparkles").font(.caption).foregroundStyle(.orange) }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "dice").font(.system(size: 72)).foregroundStyle(.secondary)
                        Text("Spin for tonight's cuisine").foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    Task { await spin() }
                } label: {
                    Label(picked == nil ? "Spin" : "Spin again", systemImage: "shuffle")
                        .frame(maxWidth: .infinity).frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(spinning || candidates.isEmpty)

                if let picked {
                    HStack {
                        Button {
                            openInMaps(picked)
                        } label: {
                            Label("Find nearby", systemImage: "map").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showLog = true
                        } label: {
                            Label("Log this meal", systemImage: "plus.circle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .navigationTitle("Tonight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { triedCodes = (try? await loadTried()) ?? [] }
            .sheet(isPresented: $showLog) {
                if let picked {
                    EntrySheet(mode: .add, presetCountryCode: picked.code) { }
                }
            }
        }
    }

    private func spin() async {
        guard !candidates.isEmpty else { return }
        spinning = true
        // A few quick teasers before landing, for a little suspense.
        for _ in 0..<8 {
            picked = candidates.randomElement()
            try? await Task.sleep(nanoseconds: 55_000_000)
        }
        picked = candidates.randomElement()
        spinning = false
    }

    private func openInMaps(_ country: Country) {
        let query = "\(country.cuisineName) restaurant"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "restaurant"
        if let url = URL(string: "maps://?q=\(query)") { openURL(url) }
    }

    private func loadTried() async throws -> Set<String> {
        Set(try await SupabaseService.shared.myEntries().map(\.countryCode))
    }
}
