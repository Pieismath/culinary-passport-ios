import SwiftUI
import PhotosUI

/// The Journal: your meals as a timeline or on the map — tap any meal to see
/// it in full (photos, rating, notes) and edit or delete it from there.
/// (The plain list view is gone by design: the timeline IS the log.)
struct EntriesView: View {
    enum Mode: String, CaseIterable { case timeline = "Timeline", map = "Map" }

    @State private var entries: [Entry] = []
    @State private var mode: Mode = EntriesView.initialMode
    @State private var showAdd = false
    @State private var showQuick = false
    @State private var viewing: Entry?
    @State private var error: String?

    /// Headless test hook: `-journalMode timeline|map` opens that view.
    private static var initialMode: Mode {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-journalMode"), i + 1 < args.count,
           let m = Mode(rawValue: args[i + 1].capitalized) { return m }
        #endif
        return .timeline
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Journal")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { showQuick = true } label: {
                                Label("Quick log", systemImage: "bolt")
                            }
                            Button { showAdd = true } label: {
                                Label("Log with details", systemImage: "square.and.pencil")
                            }
                        } label: {
                            BrandedIcon(name: "action-add", size: 22)
                        } primaryAction: {
                            showQuick = true
                        }
                    }
                }
                .sheet(isPresented: $showAdd) {
                    EntrySheet(mode: .add) { await reload() }
                }
                .sheet(isPresented: $showQuick) {
                    QuickLogView { await reload() }
                }
                .sheet(item: $viewing) { entry in
                    EntryDetailView(entry: entry) { await reload() }
                        .presentationDetents([.medium, .large])
                }
                .overlay(alignment: .bottom) {
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .task { await reload() }
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .timeline:
            TimelineView(entries: entries) { viewing = $0 }
        case .map:
            PhotoMapView(entries: entries) { await reload() }
        }
    }

    private func reload() async {
        let uid = try? await SupabaseService.shared.client.auth.session.user.id
        if entries.isEmpty,
           let cached = DiskCache.load("journal", user: uid, as: [Entry].self) {
            entries = cached
        }
        do {
            entries = try await SupabaseService.shared.myEntries()
            DiskCache.save(entries, key: "journal", user: uid)
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Add / edit sheet

struct EntrySheet: View {
    enum Mode {
        case add
        case edit(Entry)
    }

    let mode: Mode
    /// Preselect a cuisine on a fresh log (used by the dinner picker).
    var presetCountryCode: String? = nil
    var onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var country: Country?
    @State private var restaurantName = ""
    @State private var city = ""
    @State private var date = Date()
    @State private var rating = 4
    @State private var notes = ""
    @State private var signatureDish = ""
    @State private var wouldReturn = true
    @State private var placeId: String?
    @State private var lat: Double?
    @State private var lng: Double?
    @State private var visibility: Entry.Visibility = .groups
    @State private var saving = false
    @State private var error: String?

    // Places autocomplete state
    @State private var suggestions: [PlacesService.Suggestion] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var suppressSearch = false
    @State private var places = PlacesService.Session()

    // Photos: existing stored paths (edit) + newly picked images pending upload.
    @State private var existingPhotos: [String] = []
    @State private var stamp: StampInfo?

    struct StampInfo: Identifiable {
        let country: Country
        let number: Int
        var id: String { country.code }
    }
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var newPhotos: [PickedPhoto] = []

    private struct PickedPhoto: Identifiable { let id = UUID(); let image: UIImage; let jpeg: Data }

    private var isEdit: Bool { if case .edit = mode { return true } else { return false } }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Cuisine", selection: $country) {
                    Text("Pick a country…").tag(nil as Country?)
                    ForEach(CountryStore.all) { c in
                        Text("\(c.flagEmoji) \(c.name)\(c.rare ? " ✦" : "")").tag(c as Country?)
                    }
                }

                Section {
                    TextField("Restaurant", text: $restaurantName)
                        .onChange(of: restaurantName) { _, newValue in scheduleSearch(newValue) }
                    if !suggestions.isEmpty {
                        ForEach(suggestions) { s in
                            Button { pick(s) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.mainText).font(.subheadline).foregroundStyle(.primary)
                                    if !s.secondaryText.isEmpty {
                                        Text(s.secondaryText).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    TextField("City", text: $city)
                }

                Section("Photos") {
                    if !existingPhotos.isEmpty || !newPhotos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(existingPhotos, id: \.self) { path in
                                    PhotoThumb(path: path) {
                                        existingPhotos.removeAll { $0 == path }
                                    }
                                }
                                ForEach(newPhotos) { photo in
                                    PhotoThumb(image: photo.image) {
                                        newPhotos.removeAll { $0.id == photo.id }
                                    }
                                }
                            }
                        }
                    }
                    PhotosPicker(selection: $pickedItems, maxSelectionCount: 3, matching: .images) {
                        Label("Add photos", systemImage: "photo.on.rectangle")
                    }
                    .onChange(of: pickedItems) { _, items in Task { await loadPicked(items) } }
                }

                DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                Picker("Rating", selection: $rating) {
                    ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
                }
                TextField("Signature dish", text: $signatureDish)
                TextField("Notes", text: $notes, axis: .vertical)
                Toggle("Would return?", isOn: $wouldReturn)

                Picker("Who can see this", selection: $visibility) {
                    Label("Public", systemImage: "globe").tag(Entry.Visibility.public)
                    Label("My groups", systemImage: "person.3").tag(Entry.Visibility.groups)
                    Label("Only me", systemImage: "lock").tag(Entry.Visibility.private)
                }

                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle(isEdit ? "Edit meal" : "Log a meal")
            .fullScreenCover(item: $stamp) { info in
                StampMomentView(country: info.country, cuisineNumber: info.number) {
                    stamp = nil
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Stamping…" : (isEdit ? "Save" : "Stamp it")) { Task { await save() } }
                        .disabled(country == nil || restaurantName.isEmpty || saving)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private func prefill() {
        guard case .edit(let entry) = mode else {
            // Fresh log: honor a preset cuisine from the dinner picker.
            if let code = presetCountryCode { country = CountryStore.byCode[code] }
            return
        }
        country = CountryStore.byCode[entry.countryCode]
        restaurantName = entry.restaurantName
        city = entry.city ?? ""
        rating = entry.rating
        notes = entry.notes ?? ""
        signatureDish = entry.signatureDish ?? ""
        wouldReturn = entry.wouldReturn
        placeId = entry.placeId
        lat = entry.lat
        lng = entry.lng
        visibility = entry.visibility ?? .groups
        existingPhotos = entry.photos
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        if let d = fmt.date(from: entry.dateTried) { date = d }
    }

    // MARK: Photos

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        var loaded: [PickedPhoto] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data),
               let jpeg = ImageScaler.jpeg(image) {
                loaded.append(PickedPhoto(image: UIImage(data: jpeg) ?? image, jpeg: jpeg))
            }
        }
        await MainActor.run {
            newPhotos.append(contentsOf: loaded)
            pickedItems = []
        }
    }

    /// Upload any newly-picked photos and return the full path list (existing + new).
    private func uploadPhotos() async throws -> [String] {
        var paths = existingPhotos
        for photo in newPhotos {
            paths.append(try await SupabaseService.shared.uploadPhoto(photo.jpeg))
        }
        return paths
    }

    // MARK: Places autocomplete

    private func scheduleSearch(_ text: String) {
        if suppressSearch { suppressSearch = false; return }
        placeId = nil // user is typing freehand again; drop the resolved place
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // debounce
            if Task.isCancelled { return }
            let bias = country.map { (lat: $0.centroid.lat, lng: $0.centroid.lng) }
            let results = (try? await places.autocomplete(text, near: bias)) ?? []
            if Task.isCancelled { return }
            await MainActor.run { suggestions = results }
        }
    }

    private func pick(_ s: PlacesService.Suggestion) {
        suppressSearch = true
        restaurantName = s.mainText
        suggestions = []
        Task {
            if let d = try? await places.details(placeId: s.placeId) {
                await MainActor.run {
                    if let c = d.city, !c.isEmpty { city = c }
                    placeId = s.placeId
                    lat = d.lat
                    lng = d.lng
                }
            }
        }
    }

    private func save() async {
        guard let country else { return }
        saving = true
        defer { saving = false }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: date)
        do {
            let photos = try await uploadPhotos()
            switch mode {
            case .add:
                // Before the insert: is this the first-ever meal from this
                // cuisine? That's a stamp moment.
                let priorCodes = Set(((try? await SupabaseService.shared.myEntries()) ?? [])
                    .map(\.countryCode))
                let session = try await SupabaseService.shared.client.auth.session
                try await SupabaseService.shared.addEntry(NewEntry(
                    userId: session.user.id,
                    countryCode: country.code,
                    restaurantName: restaurantName,
                    city: city,
                    dateTried: dateStr,
                    rating: rating,
                    notes: notes,
                    signatureDish: signatureDish,
                    wouldReturn: wouldReturn,
                    placeId: placeId,
                    lat: lat,
                    lng: lng,
                    photos: photos,
                    visibility: visibility.rawValue
                ))
                SupabaseService.shared.logEvent("meal_logged", props: ["country": country.code])
                if !priorCodes.contains(country.code) {
                    stamp = StampInfo(country: country, number: priorCodes.count + 1)
                    await onSave()
                    return // the stamp cover owns dismissal now
                }
            case .edit(let entry):
                try await SupabaseService.shared.updateEntry(id: entry.id, EntryUpdate(
                    countryCode: country.code,
                    restaurantName: restaurantName,
                    city: city,
                    dateTried: dateStr,
                    rating: rating,
                    notes: notes,
                    signatureDish: signatureDish,
                    wouldReturn: wouldReturn,
                    placeId: placeId,
                    lat: lat,
                    lng: lng,
                    photos: photos,
                    visibility: visibility.rawValue
                ))
                // Photos removed during the edit are gone from the entry row;
                // clean their storage objects too (best-effort).
                let dropped = Set(entry.photos).subtracting(photos)
                if !dropped.isEmpty {
                    _ = try? await SupabaseService.shared.client.storage
                        .from("photos").remove(paths: Array(dropped))
                }
            }
            await onSave()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Photo helpers

private struct PhotoThumb: View {
    var path: String? = nil
    var image: UIImage? = nil
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SwiftUI.Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let path {
                    SignedPhotoImage(path: path) { $0.resizable().scaledToFill() } placeholder: {
                        Color(.secondarySystemBackground)
                    }
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .padding(3)
        }
    }
}

/// Downscale + JPEG-encode a picked photo to keep uploads small (mirrors the
/// web app's compressPhoto: longest edge capped, quality ~0.82).
enum ImageScaler {
    static func jpeg(_ image: UIImage, maxDim: CGFloat = 1400, quality: CGFloat = 0.82) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxDim / max(longest, 1))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target, format: .pixels)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return scaled.jpegData(compressionQuality: quality)
    }
}
