import SwiftUI
import PhotosUI

/// Log a meal in under fifteen seconds: type the restaurant, tap it, rate it,
/// done. The cuisine is inferred from the place's Google types where possible
/// (a Thai restaurant is Thai food wherever it stands); everything else —
/// notes, dish, visibility — can be edited later from the meal's detail card.
struct QuickLogView: View {
    var onSaved: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    @State private var query = ""
    @State private var suggestions: [PlacesService.Suggestion] = []
    @State private var searchTask: Task<Void, Never>?

    @State private var place: PlacesService.Details?
    @State private var country: Country?
    @State private var rating = 4
    @State private var pickedItem: PhotosPickerItem?
    @State private var photo: (image: UIImage, jpeg: Data)?
    @State private var pickingCuisine = false
    @State private var saving = false
    @State private var error: String?
    @State private var stamp: EntrySheet.StampInfo?

    private let places = PlacesService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if place == nil {
                    searchStage
                } else {
                    confirmStage
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Quick log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $pickingCuisine) {
                CuisineMiniPicker { picked in country = picked }
            }
            .fullScreenCover(item: $stamp) { info in
                StampMomentView(country: info.country, cuisineNumber: info.number) {
                    stamp = nil
                    dismiss()
                }
            }
        }
    }

    // ── Stage 1: find the restaurant ─────────────────────────────────────────

    private var searchStage: some View {
        VStack(spacing: 10) {
            TextField("Restaurant name…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
                .onChange(of: query) { scheduleSearch() }

            ForEach(suggestions) { suggestion in
                Button {
                    Task { await pick(suggestion) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.mainText).foregroundStyle(.primary)
                        if !suggestion.secondaryText.isEmpty {
                            Text(suggestion.secondaryText)
                                .font(.caption).foregroundStyle(Color(.secondaryLabel))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            suggestions = (try? await places.autocomplete(q, near: nil)) ?? []
        }
    }

    private func pick(_ suggestion: PlacesService.Suggestion) async {
        do {
            let details = try await places.details(placeId: suggestion.placeId)
            place = details
            if let code = PlacesService.cuisineCountry(fromTypes: details.types) {
                country = CountryStore.byCode[code]
            } else {
                pickingCuisine = true // couldn't infer — one tap to choose
            }
        } catch { self.error = error.localizedDescription }
    }

    // ── Stage 2: cuisine + stars + optional photo ────────────────────────────

    @ViewBuilder private var confirmStage: some View {
        if let place {
            VStack(spacing: 16) {
                VStack(spacing: 3) {
                    Text(place.name).font(.title3.bold())
                    if let city = place.city {
                        Text(city).font(.caption).foregroundStyle(Color(.secondaryLabel))
                    }
                }

                Button {
                    pickingCuisine = true
                } label: {
                    HStack(spacing: 6) {
                        Text(country?.flagEmoji ?? "🌍")
                        Text(country?.cuisineName ?? "Pick the cuisine")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(.systemGray6), in: Capsule())
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            rating = star
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: star <= rating ? "star.fill" : "star")
                                .font(.title)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                }

                PhotosPicker(selection: $pickedItem, matching: .images) {
                    if let photo {
                        Image(uiImage: photo.image)
                            .resizable().scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Label("Add a photo", systemImage: "camera")
                            .font(.subheadline)
                    }
                }
                .onChange(of: pickedItem) { Task { await loadPhoto() } }

                Button {
                    Task { await save() }
                } label: {
                    Text(saving ? "Saving…" : "Log it")
                        .font(.headline)
                        .frame(maxWidth: .infinity).frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(country == nil || saving)

                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private func loadPhoto() async {
        guard let pickedItem,
              let data = try? await pickedItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = ImageTools.squareJPEG(image, side: 1280, quality: 0.78) else { return }
        photo = (image, jpeg)
    }

    private func save() async {
        guard let place, let country else { return }
        saving = true
        defer { saving = false }
        do {
            var photos: [String] = []
            if let photo {
                photos = [try await SupabaseService.shared.uploadPhoto(photo.jpeg)]
            }
            let priorCodes = Set(((try? await SupabaseService.shared.myEntries()) ?? [])
                .map(\.countryCode))
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            let session = try await SupabaseService.shared.client.auth.session
            try await SupabaseService.shared.addEntry(NewEntry(
                userId: session.user.id,
                countryCode: country.code,
                restaurantName: place.name,
                city: place.city ?? "",
                dateTried: fmt.string(from: Date()),
                rating: rating,
                notes: "",
                signatureDish: "",
                wouldReturn: rating >= 4,
                placeId: nil,
                lat: place.lat,
                lng: place.lng,
                photos: photos,
                visibility: "groups"
            ))
            SupabaseService.shared.logEvent("meal_logged",
                                            props: ["country": country.code, "quick": "true"])
            await onSaved()
            if !priorCodes.contains(country.code) {
                stamp = .init(country: country, number: priorCodes.count + 1)
            } else {
                dismiss()
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// Bare-bones cuisine chooser for quick-log (search, tap, done).
private struct CuisineMiniPicker: View {
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
            List(results) { country in
                Button {
                    onPick(country)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text(country.flagEmoji)
                        Text(country.cuisineName).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Cuisine")
            .navigationTitle("Cuisine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
