import SwiftUI
import PhotosUI
import MapKit

/// Log a meal in a few taps: a photo, where, which cuisine, what you had.
/// The photo's location finds the restaurant, the restaurant's name suggests
/// the cuisine, and a first taste plays the stamp moment.
struct MealEditorView: View {
    enum Mode {
        /// Optionally pre-filled: from a spin's restaurants or a cuisine's page.
        case new(cuisine: String?, place: PlaceResult?)
        case edit(Meal)
    }

    let mode: Mode
    /// The restaurant on your list this meal came from — ticked off on save.
    var fromPlace: SavedPlace?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MealDraft()
    /// Stable across retries: a save whose response was lost can't land twice.
    @State private var newMealId = UUID()
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

    private var original: Meal? {
        if case .edit(let meal) = mode { return meal }
        return nil
    }

    private var canSave: Bool { !draft.countryCode.isEmpty && !saving && !loadingPhotos }

    private var isDirty: Bool {
        if let original { return draft != MealDraft(meal: original) || !photos.isEmpty }
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
                VStack(spacing: 22) {
                    plated
                    receipt
                }
                .padding(Metrics.gutter)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(TableclothBackdrop())
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
                StampMomentView(codes: [result.meal.countryCode], number: result.cuisineNumber,
                                date: result.meal.date, tasted: true) { dismiss() }
            }
            .overlay { if saving { SavingOverlay(text: "Saving…") } }
            .task { await prepare() }
        }
    }

    // ── The plate: your photo on it, the cuisine's stamp beside it ────────────

    private var photoCount: Int { draft.keptPhotos.count + photos.count }
    private var ink: Color { draft.countryCode.isEmpty ? .brand : StampInk.color(for: draft.countryCode) }

    private var plated: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Button { showPicker = true } label: {
                    Plate(rim: 0.13, band: ink.opacity(0.45)) {
                        if let path = draft.keptPhotos.first {
                            StoragePhoto(path: path, maxPixel: 900)
                        } else if let photo = photos.first {
                            Image(uiImage: photo.preview).resizable().scaledToFill()
                        } else {
                            VStack(spacing: 8) {
                                if loadingPhotos {
                                    ProgressView()
                                } else {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 30))
                                        .foregroundStyle(Color.brand)
                                }
                                Text("Add a photo")
                                    .font(.headline)
                                    .foregroundStyle(Color.ink)
                                Text("Its location finds the restaurant")
                                    .font(.caption)
                                    .foregroundStyle(Color.inkSecondary)
                            }
                        }
                    }
                    .frame(width: 250, height: 250)
                }
                .buttonStyle(PressScale())
                .disabled(loadingPhotos || photoCount >= Self.maxPhotos)
                .accessibilityLabel(photoCount == 0 ? "Add a photo" : "Add more photos")

                Button { pickingCuisine = true } label: {
                    if draft.countryCode.isEmpty {
                        VStack(spacing: 2) {
                            Image(systemName: "globe.europe.africa")
                                .font(.system(size: 22, weight: .light))
                            Text("CUISINE?")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .tracking(0.8)
                        }
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 92, height: 92)
                        .background(Color.paper, in: Circle())
                        .overlay(Circle().strokeBorder(Color.inkTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    } else {
                        StampBadge(code: draft.countryCode, size: 104, tasted: true)
                            .background(Circle().fill(Color.card.opacity(0.9)).padding(6))
                    }
                }
                .buttonStyle(PressScale())
                .offset(x: 34, y: 14)
                .accessibilityLabel(draft.countryCode.isEmpty ? "Choose a cuisine"
                                                              : "Cuisine, \(Cuisine.name(for: draft.countryCode)). Change")
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 30)

            if photoCount > 0 {
                HStack(spacing: 10) {
                    ForEach(draft.keptPhotos, id: \.self) { path in
                        smallPlate { StoragePhoto(path: path, maxPixel: 200) } remove: {
                            draft.keptPhotos.removeAll { $0 == path }
                        }
                    }
                    ForEach(photos) { photo in
                        smallPlate { Image(uiImage: photo.preview).resizable().scaledToFill() } remove: {
                            photos.removeAll { $0.id == photo.id }
                        }
                    }
                    if photoCount < Self.maxPhotos {
                        Button { showPicker = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.brand)
                                .frame(width: 50, height: 50)
                                .background(Color.paper, in: Circle())
                                .overlay(Circle().strokeBorder(Color.brand.opacity(0.4),
                                                               style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add more photos")
                    }
                }
            }
        }
    }

    private func smallPlate<Photo: View>(@ViewBuilder _ photo: () -> Photo,
                                         remove: @escaping () -> Void) -> some View {
        let image = photo()
        return Plate(rim: 0.16, band: .clear) { image }
            .frame(width: 54, height: 54)
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .offset(x: 4, y: -4)
                .accessibilityLabel("Remove photo")
            }
    }

    // ── The receipt: where, what, when ───────────────────────────────────────

    private var receipt: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("STAMPD")
                Spacer()
                Text(original == nil ? "MEAL RECEIPT" : "AMENDED RECEIPT")
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(Color.inkTertiary)
            .padding(.bottom, 10)

            DashedRule()

            receiptRow("AT") {
                Button { findingPlace = true } label: {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(draft.restaurantName.isEmpty ? "Where did you eat?" : draft.restaurantName)
                            .font(.system(.headline, design: .serif))
                            .foregroundStyle(draft.restaurantName.isEmpty ? Color.brand : Color.ink)
                            .multilineTextAlignment(.trailing)
                        if let guessedFromPhoto, !placeTouched {
                            Text("from your photo · \(guessedFromPhoto)")
                                .font(.caption2)
                                .foregroundStyle(Color.inkSecondary)
                        } else if !draft.city.isEmpty {
                            Text(draft.city).font(.caption2).foregroundStyle(Color.inkSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            receiptRow("CUISINE") {
                Button { pickingCuisine = true } label: {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(draft.countryCode.isEmpty ? "Choose"
                             : "\(Country.flag(for: draft.countryCode)) \(Cuisine.name(for: draft.countryCode))")
                            .font(.system(.headline, design: .serif))
                            .foregroundStyle(draft.countryCode.isEmpty ? Color.brand : Color.ink)
                        if let tasteNote {
                            Text(tasteNote)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tasteNote.hasPrefix("First") ? Color.brand : Color.inkSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            receiptRow("DISH") {
                TextField("Khachapuri, pad see ew…", text: $draft.dish)
                    .font(.system(.headline, design: .serif))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }

            receiptRow("DATE", control: true) {
                DatePicker("When", selection: Binding(get: { draft.date }, set: { draft.date = $0; dateTouched = true }),
                           in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
            }

            receiptRow("SEEN BY", control: true) {
                Picker("Who can see it", selection: $draft.visibility) {
                    ForEach(Visibility.allCases) { option in
                        Label(option.label, systemImage: option.systemImage).tag(option)
                    }
                }
                .labelsHidden()
                .tint(Color.ink)
            }

            DashedRule().padding(.top, 4)

            Text("NOTE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.inkTertiary)
                .padding(.top, 12)
            TextField("A note, if it deserves one", text: $draft.notes, axis: .vertical)
                .font(.system(.body, design: .serif))
                .lineLimit(2...6)
                .padding(.vertical, 8)

            DashedRule()
            Text("THANK YOU · COME AGAIN")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Color.inkTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background {
            ReceiptShape()
                .fill(Color.card)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }

    /// Controls (a date, a menu) centre on their row; text sits on its baseline.
    private func receiptRow<Value: View>(_ label: String, control: Bool = false,
                                         @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: control ? .center : .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.inkSecondary)
                .fixedSize()
            // Dotted leader, the way a menu joins a dish to its price.
            DottedLeader()
                .frame(height: 1)
                .frame(minWidth: 12)
            value()
                .layoutPriority(1)
        }
        .padding(.vertical, control ? 5 : 11)
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        draft.visibility = SettingsStore.defaultVisibility
        switch mode {
        case .new(let cuisine, let place):
            if let cuisine {
                draft.countryCode = cuisine
                cuisineTouched = true
            }
            if let place { apply(place, chosen: true) }
        case .edit(let meal):
            draft = MealDraft(meal: meal)
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
            let result = try await app.saveMeal(draft, editing: original, newId: newMealId,
                                                newPhotos: photos.map(\.jpeg), shareTo: [])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if let fromPlace, !fromPlace.done { try? await app.updatePlace(fromPlace, done: true) }
            if result.isFirstTaste {
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

/// "I ate here" from a saved restaurant: a meal there, and the restaurant
/// gets ticked off.
struct LogAtPlaceSheet: View {
    let place: SavedPlace

    var body: some View {
        MealEditorView(mode: .new(cuisine: place.cuisineCode,
                                  place: PlaceResult(title: place.title, city: place.city,
                                                     countryCode: place.countryCode,
                                                     latitude: place.lat, longitude: place.lng)),
                       fromPlace: place)
    }
}

extension AppModel.SaveResult: Identifiable {
    var id: UUID { meal.id }
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
