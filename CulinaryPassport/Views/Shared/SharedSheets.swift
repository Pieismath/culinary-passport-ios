import SwiftUI
import MapKit

struct SavingOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(text).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .transition(.opacity)
    }
}

/// Apple Maps place search.
struct PlaceSearchSheet: View {
    let onPick: (PlaceResult) -> Void
    var foodOnly = false

    @Environment(\.dismiss) private var dismiss
    @State private var search: PlaceSearch
    @State private var resolving = false

    init(near: CLLocationCoordinate2D?, foodOnly: Bool = false, onPick: @escaping (PlaceResult) -> Void) {
        self.onPick = onPick
        self.foodOnly = foodOnly
        _search = State(initialValue: PlaceSearch(near: near, foodOnly: foodOnly))
    }

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            List {
                if !search.query.trimmed.isEmpty {
                    Button {
                        onPick(PlaceResult(title: search.query.trimmed, city: "", countryCode: nil))
                        dismiss()
                    } label: {
                        Label("Use “\(search.query.trimmed)”", systemImage: "text.cursor")
                            .foregroundStyle(Color.ink)
                    }
                    .listRowBackground(Color.card)
                }
                ForEach(search.results, id: \.self) { completion in
                    Button {
                        Task { await pick(completion) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title).foregroundStyle(Color.ink)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle).font(.caption).foregroundStyle(Color.inkSecondary)
                            }
                        }
                    }
                    .listRowBackground(Color.card)
                }
            }
            .paperListStyle()
            .overlay {
                if resolving { ProgressView() }
                else if search.query.trimmed.isEmpty {
                    ContentUnavailableView(foodOnly ? "Find the restaurant" : "Search places",
                                           systemImage: foodOnly ? "fork.knife" : "mappin.and.ellipse",
                                           description: Text(foodOnly
                                                             ? "Restaurants, cafés, bakeries and markets nearby."
                                                             : "Landmarks, restaurants, hotels, towns…"))
                }
            }
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: foodOnly ? "Where did you eat?" : "Where was this?")
            .navigationTitle(foodOnly ? "Restaurant" : "Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        defer { resolving = false }
        if let place = try? await search.resolve(completion) {
            onPick(place)
        } else {
            onPick(PlaceResult(title: completion.title, city: "", countryCode: nil))
        }
        dismiss()
    }
}

/// Small persisted preferences.
enum SettingsStore {
    static var defaultVisibility: Visibility {
        get { Visibility(rawValue: UserDefaults.standard.string(forKey: "defaultVisibility") ?? "") ?? .friends }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "defaultVisibility") }
    }
}
