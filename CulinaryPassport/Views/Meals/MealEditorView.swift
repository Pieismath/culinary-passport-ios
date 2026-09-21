import SwiftUI
import PhotosUI
import MapKit

/// Log a meal in a few taps: a photo, where, which cuisine, what you had.
/// The photo's location finds the restaurant, the restaurant's name suggests
/// the cuisine, and a first taste plays the stamp moment.
struct MealEditorView: View {
    enum Mode {
        /// Optionally pre-filled: from the dinner dice or a country's page.
        case new(cuisine: String?, place: PlaceResult?)
        case edit(Memory)
    }

    let mode: Mode
    /// The restaurant on your list this meal came from — ticked off on save.
    var fromPlace: SavedPlace?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MemoryDraft()
    /// Stable across retries: a save whose response was lost can't land twice.
    @State private var newMemoryId = UUID()
    @State private var photos: [MealPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var loadingPhotos = false
    @State private var findingPlace = false
    @State private var pickingCuisine = false
    @State private var cuisineTouched = false
    @State private var placeTouched = false
    @State private var dateTouched = false
    @State private var guessedFromPhoto: String?
    @State private var saving = false
    @State private var stampResult: AppModel.SaveResult?
    @State private var near: CLLocationCoordinate2D?
    @State private var prepared = false
    @State private var confirmDiscard = false

    struct MealPhoto: Identifiable {
        let id = UUID()
        let preview: UIImage
        let jpeg: Data
        let meta: PhotoMetadata
    }

    private static let maxPhotos = 6

    private var original: Memory? {
        if case .edit(let meal) = mode { return meal }
        return nil
    }

    private var canSave: Bool { !draft.countryCode.isEmpty && !saving && !loadingPhotos }

    private var isDirty: Bool {
        if let original { return draft != MemoryDraft(memory: original) || !photos.isEmpty }
        return !photos.isEmpty || !draft.restaurantName.isEmpty || !draft.dish.isEmpty
    }

    /// "First taste" or "Your 3rd Georgian meal".
    private var tasteNote: String? {
        guard !draft.countryCode.isEmpty else { return nil }
        let count = (app.mealsByCountry[draft.countryCode] ?? []).filter { $0.id != original?.id }.count
        if count == 0 && !app.tastedCodes.contains(draft.countryCode) { return "First taste — new stamp" }
        let ordinal = (count + 1).formatted(.number.notation(.automatic))
        return "Your \(ordinal)\(Self.suffix(count + 1)) \(Cuisine.name(for: draft.countryCode)) meal"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    photoStrip
                    restaurantButton
                    cuisineCard
                    dishField
                    details
                }
                .padding(Metrics.gutter)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .paperBackground()
            .navigationTitle(original == nil ? "Log a meal" : "Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(isDirty || saving)
            .confirmationDialog("Discard this meal?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
            }
            .photosPicker(isPresented: $showPicker, selection: $pickerItems,
                          maxSelectionCount: max(1, Self.maxPhotos - photos.count - draft.keptPhotos.count),
                          matching: .images, photoLibrary: .shared())
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await load(items) }
            }
            .sheet(isPresented: $findingPlace) {
                PlaceSearchSheet(near: near, foodOnly: true) { place in apply(place, chosen: true) }
            }
            .sheet(isPresented: $pickingCuisine) {
                CuisinePickerSheet(selected: draft.countryCode,
                                   suggested: Cuisine.suggest(from: draft.restaurantName)) { code in
                    draft.countryCode = code
                    cuisineTouched = true
                }
            }
            .fullScreenCover(item: $stampResult) { result in
                StampMomentView(codes: [result.memory.countryCode], number: result.countryNumber,
                                date: result.memory.date, tasted: true) { dismiss() }
            }
            .overlay { if saving { SavingOverlay(text: "Saving…") } }
            .task { await prepare() }
        }
    }

    // ── Sections ─────────────────────────────────────────────────────────────

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { showPicker = true } label: {
                    VStack(spacing: 6) {
                        if loadingPhotos {
                            ProgressView()
                        } else {
                            Image(systemName: "camera.fill").font(.title2)
                        }
                        Text(photos.isEmpty && draft.keptPhotos.isEmpty ? "Add photo" : "More")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.brand)
                    .frame(width: 104, height: 104)
                    .background(Color.brandSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(loadingPhotos || photos.count + draft.keptPhotos.count >= Self.maxPhotos)

                ForEach(draft.keptPhotos, id: \.self) { path in
                    StoragePhoto(path: path, maxPixel: 320)
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            removeButton { draft.keptPhotos.removeAll { $0 == path } }
                        }
                }
                ForEach(photos) { photo in
                    Image(uiImage: photo.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            removeButton { photos.removeAll { $0.id == photo.id } }
                        }
                }
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.5))
                .padding(4)
        }
        .accessibilityLabel("Remove photo")
    }

    private var restaurantButton: some View {
        Button { findingPlace = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 40, height: 40)
                    .background(Color.brandSoft, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.restaurantName.isEmpty ? "Where did you eat?" : draft.restaurantName)
                        .font(.headline)
                        .foregroundStyle(draft.restaurantName.isEmpty ? Color.inkSecondary : Color.ink)
                    if let guessedFromPhoto, !placeTouched {
                        Text("From your photo's location · \(guessedFromPhoto)")
                            .font(.caption)
                            .foregroundStyle(Color.inkSecondary)
                    } else if !draft.city.isEmpty {
                        Text(draft.city).font(.caption).foregroundStyle(Color.inkSecondary)
                    } else {
                        Text("Search restaurants nearby")
                            .font(.caption)
                            .foregroundStyle(Color.inkTertiary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.inkTertiary)
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
    }

    private var cuisineCard: some View {
        Button { pickingCuisine = true } label: {
            HStack(spacing: 14) {
                if draft.countryCode.isEmpty {
                    Image(systemName: "globe.europe.africa")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.inkTertiary)
                        .frame(width: 76, height: 76)
                        .background(Color.sunken, in: Circle())
                } else {
                    StampBadge(code: draft.countryCode, size: 76, tasted: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Cuisine")
                    Text(draft.countryCode.isEmpty ? "Which cuisine?" : Cuisine.name(for: draft.countryCode))
                        .font(.displayXSmall)
                        .foregroundStyle(draft.countryCode.isEmpty ? Color.inkSecondary : Color.ink)
                    if let tasteNote {
                        Text(tasteNote)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tasteNote.hasPrefix("First") ? Color.brand : Color.inkSecondary)
                    }
                }
                Spacer(minLength: 4)
                Text(draft.countryCode.isEmpty ? "Choose" : "Change")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brand)
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(draft.countryCode.isEmpty ? "Choose a cuisine"
                                                      : "Cuisine, \(Cuisine.name(for: draft.countryCode)). Change")
    }

    private var dishField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "What did you have?")
            TextField("Khachapuri, pad see ew, the tasting menu…", text: $draft.dish)
                .font(.headline)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            DatePicker("When", selection: Binding(get: { draft.date }, set: { draft.date = $0; dateTouched = true }),
                       in: ...Date(), displayedComponents: .date)
                .padding(12)
            Divider().padding(.leading, 12)
            TextField("A note, if it deserves one", text: $draft.notes, axis: .vertical)
                .lineLimit(2...6)
                .padding(12)
            Divider().padding(.leading, 12)
            HStack {
                Text("Who can see it")
                Spacer()
                Picker("Who can see it", selection: $draft.visibility) {
                    ForEach(Visibility.allCases) { option in
                        Label(option.label, systemImage: option.systemImage).tag(option)
                    }
                }
                .labelsHidden()
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 6)
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
            .strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        draft.kind = .meal
        draft.visibility = SettingsStore.defaultVisibility
        switch mode {
        case .new(let cuisine, let place):
            if let cuisine {
                draft.countryCode = cuisine
                cuisineTouched = true
            }
            if let place { apply(place, chosen: true) }
        case .edit(let meal):
            draft = MemoryDraft(memory: meal)
            cuisineTouched = true
            placeTouched = true
            dateTouched = true
        }
        // Where you are, for searching restaurants around you. Asked for
        // only here, when it's about to be useful.
        if original == nil, let location = await NearMe.shared.location() {
            near = location.coordinate
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        loadingPhotos = true
        defer {
            loadingPhotos = false
            pickerItems = []
        }
        for item in items {
            guard photos.count + draft.keptPhotos.count < Self.maxPhotos,
                  let data = try? await item.loadTransferable(type: Data.self) else { continue }
            var meta = PhotoMetadata.read(from: data)
            if !meta.hasLocation || meta.date == nil,
               let library = PhotoMetadata.read(assetIdentifier: item.itemIdentifier) {
                if !meta.hasLocation { meta.latitude = library.latitude; meta.longitude = library.longitude }
                if meta.date == nil { meta.date = library.date }
            }
            guard let upload = ImageTools.uploadJPEG(from: data) else { continue }
            photos.append(MealPhoto(preview: upload.preview, jpeg: upload.jpeg, meta: meta))
        }
        if !dateTouched, let earliest = photos.compactMap(\.meta.date).min() {
            draft.date = min(earliest, Date())
        }
        if !placeTouched, draft.restaurantName.isEmpty,
           let located = photos.first(where: { $0.meta.hasLocation }),
           let lat = located.meta.latitude, let lng = located.meta.longitude,
           let place = await Self.restaurant(at: CLLocationCoordinate2D(latitude: lat, longitude: lng)) {
            apply(place, chosen: false)
            guessedFromPhoto = place.city.isEmpty ? place.title : place.city
        }
    }

    /// The restaurant a photo was taken in: the nearest food place within a
    /// short walk of where it was taken.
    private static func restaurant(at coordinate: CLLocationCoordinate2D) async -> PlaceResult? {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 80)
        request.pointOfInterestFilter = PlaceSearch.foodFilter
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let nearest = response.mapItems.min(by: {
            ($0.placemark.location?.distance(from: here) ?? .infinity)
                < ($1.placemark.location?.distance(from: here) ?? .infinity)
        }), let name = nearest.name else { return nil }
        return PlaceResult(title: name,
                           city: nearest.placemark.locality ?? nearest.placemark.subAdministrativeArea ?? "",
                           countryCode: nearest.placemark.isoCountryCode,
                           latitude: nearest.placemark.coordinate.latitude,
                           longitude: nearest.placemark.coordinate.longitude)
    }

    private func apply(_ place: PlaceResult, chosen: Bool) {
        draft.restaurantName = place.title
        draft.city = place.city
        draft.lat = place.latitude
        draft.lng = place.longitude
        if chosen { placeTouched = true }
        if !cuisineTouched, let suggested = Cuisine.suggest(from: place.title) {
            draft.countryCode = suggested
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        defer { saving = false }
        do {
            let result = try await app.saveMemory(draft, editing: original, newId: newMemoryId,
                                                  newPhotos: photos.map(\.jpeg), shareTo: [])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if let fromPlace, !fromPlace.done { try? await app.updatePlace(fromPlace, done: true) }
            if result.isNewCountry {
                stampResult = result
            } else {
                app.celebrate(original == nil ? "\(Country.flag(for: draft.countryCode)) Meal logged" : "Meal updated")
                dismiss()
            }
        } catch {
            app.show(error)
        }
    }

    private static func suffix(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}

/// "Log it here" from a saved place: a meal for a restaurant, a memory for
/// anywhere else. Either way the place gets ticked off.
struct LogAtPlaceSheet: View {
    let place: SavedPlace

    var body: some View {
        if let cuisine = place.cuisineCode {
            MealEditorView(mode: .new(cuisine: cuisine,
                                      place: PlaceResult(title: place.title, city: place.city,
                                                         countryCode: place.countryCode,
                                                         latitude: place.lat, longitude: place.lng)),
                           fromPlace: place)
        } else {
            MemoryEditorView(mode: .atPlace(place))
        }
    }
}

extension AppModel.SaveResult: Identifiable {
    var id: UUID { memory.id }
}

/// Choose a cuisine: search by name or dish ("pho" finds Vietnamese), with
/// the one the restaurant's name suggests and the ones you eat most on top.
struct CuisinePickerSheet: View {
    var selected: String?
    var suggested: String?
    let onPick: (String) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var recent: [String] {
        Dictionary(grouping: app.meals, by: \.countryCode)
            .sorted { ($0.value.count, $0.key) > ($1.value.count, $1.key) }
            .map(\.key)
            .filter { $0 != suggested }
            .prefix(6)
            .map { $0 }
    }

    private var results: [String] { Cuisine.codes.filter { Cuisine.matches($0, query) } }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    if let suggested {
                        Section("From the restaurant's name") { row(suggested) }
                    }
                    if !recent.isEmpty {
                        Section("You eat these most") { ForEach(recent, id: \.self) { row($0) } }
                    }
                }
                Section(query.isEmpty ? "Every cuisine" : "Results") {
                    ForEach(results, id: \.self) { row($0) }
                }
            }
            .paperListStyle()
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Cuisine or dish — \"pho\", \"Georgian\"")
            .navigationTitle("Cuisine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ code: String) -> some View {
        Button {
            onPick(code)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                FlagTile(code: code, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Cuisine.name(for: code)).foregroundStyle(Color.ink)
                    if let country = CountryStore.byCode[code], country.name != Cuisine.name(for: code) {
                        Text(country.name).font(.caption).foregroundStyle(Color.inkSecondary)
                    }
                }
                Spacer()
                if code == selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.brand)
                } else if app.tastedCodes.contains(code) {
                    Image(systemName: "fork.knife.circle.fill")
                        .foregroundStyle(Color.brand.opacity(0.7))
                        .accessibilityLabel("Tasted")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.card)
    }
}
