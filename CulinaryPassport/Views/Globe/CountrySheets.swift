import SwiftUI

/// "Where's Georgian?" — find any cuisine by name or dish and fly the globe
/// there. Ones you haven't tried yet are marked with an empty plate.
struct CuisineSearchSheet: View {
    let onPick: (String) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [String] { Cuisine.codes.filter { Cuisine.matches($0, query) } }

    var body: some View {
        NavigationStack {
            List {
                Section(query.isEmpty ? "Every cuisine" : "Results") {
                    ForEach(results, id: \.self) { code in
                        Button {
                            dismiss()
                            onPick(code)
                        } label: {
                            HStack(spacing: 12) {
                                FlagTile(code: code, size: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Cuisine.name(for: code)).foregroundStyle(Color.ink)
                                    if let country = CountryStore.byCode[code] {
                                        Text(country.name == Cuisine.name(for: code)
                                             ? country.continent.rawValue
                                             : "\(country.name) · \(country.continent.rawValue)")
                                            .font(.caption)
                                            .foregroundStyle(Color.inkSecondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: app.tastedCodes.contains(code) ? "fork.knife.circle.fill" : "circle.dashed")
                                    .foregroundStyle(app.tastedCodes.contains(code) ? Color.brand : Color.inkTertiary)
                                    .accessibilityLabel(app.tastedCodes.contains(code) ? "Tasted" : "Not tried yet")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.card)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .paperListStyle()
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Cuisine or dish — \"pho\", \"Georgian\"")
            .navigationTitle("Find a cuisine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Choose one country (where you're from).
struct CountryPickerSheet: View {
    var title = "Country"
    var selected: String?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section(query.isEmpty ? "Everywhere" : "Results") {
                    ForEach(CountryStore.all.filter { $0.matches(query) }) { row($0) }
                }
            }
            .listStyle(.insetGrouped)
            .paperListStyle()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ country: Country) -> some View {
        Button {
            onPick(country.code)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(country.flag).font(.title2)
                Text(country.name).foregroundStyle(Color.ink)
                Spacer()
                if country.code == selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.brand).fontWeight(.semibold)
                }
            }
        }
        .listRowBackground(Color.card)
    }
}

struct StampBurst: Identifiable {
    let codes: [String]
    var id: String { codes.joined(separator: ",") }
}
