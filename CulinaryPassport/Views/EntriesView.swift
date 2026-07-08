import SwiftUI
import PhotosUI

/// MVP step 3: personal entries — list, add, edit, delete, with photos. Restaurant
/// field is backed by Google Places autocomplete through the places-proxy function.
struct EntriesView: View {
    @State private var entries: [Entry] = []
    @State private var showAdd = false
    @State private var editing: Entry?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    Button { editing = entry } label: {
                        EntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    Task { await delete(at: indexSet) }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No meals yet",
                        systemImage: "fork.knife",
                        description: Text("The journal starts with dinner.")
                    )
                }
            }
            .navigationTitle("Journal")
            .toolbar {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showAdd) {
                EntrySheet(mode: .add) { await reload() }
            }
            .sheet(item: $editing) { entry in
                EntrySheet(mode: .edit(entry)) { await reload() }
            }
            .task { await reload() }
            .refreshable { await reload() }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func reload() async {
        do { entries = try await SupabaseService.shared.myEntries() }
        catch { self.error = error.localizedDescription }
    }

    private func delete(at indexSet: IndexSet) async {
        for index in indexSet {
            try? await SupabaseService.shared.deleteEntry(id: entries[index].id)
        }
        await reload()
    }
}

struct EntryRow: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 12) {
            if let first = entry.photos.first, let url = SupabaseService.shared.photoURL(first) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.secondarySystemBackground)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text(CountryStore.byCode[entry.countryCode]?.flagEmoji ?? "🌍")
                        .font(.caption2)
                }
            } else {
                Text(CountryStore.byCode[entry.countryCode]?.flagEmoji ?? "🌍")
                    .font(.title2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.restaurantName).font(.headline)
                Text("\(CountryStore.byCode[entry.countryCode]?.cuisineName ?? entry.countryCode) · \(entry.dateTried)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(repeating: "★", count: entry.rating))
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Add / edit sheet

struct EntrySheet: View {
    enum Mode {
        case add
        case edit(Entry)
    }

    let mode: Mode
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
    @State private var saving = false
    @State private var error: String?

    // Places autocomplete state
    @State private var suggestions: [PlacesService.Suggestion] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var suppressSearch = false

    // Photos: existing stored paths (edit) + newly picked images pending upload.
    @State private var existingPhotos: [String] = []
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
                                    PhotoThumb(url: SupabaseService.shared.photoURL(path)) {
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
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle(isEdit ? "Edit meal" : "Log a meal")
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
        guard case .edit(let entry) = mode else { return }
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
            let results = (try? await PlacesService.shared.autocomplete(text, near: bias)) ?? []
            if Task.isCancelled { return }
            await MainActor.run { suggestions = results }
        }
    }

    private func pick(_ s: PlacesService.Suggestion) {
        suppressSearch = true
        restaurantName = s.mainText
        suggestions = []
        Task {
            if let d = try? await PlacesService.shared.details(placeId: s.placeId) {
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
                    photos: photos
                ))
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
                    photos: photos
                ))
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
    var url: URL? = nil
    var image: UIImage? = nil
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SwiftUI.Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                        Color(.secondarySystemBackground)
                    }
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
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return scaled.jpegData(compressionQuality: quality)
    }
}
