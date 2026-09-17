import SwiftUI
import PhotosUI
import CoreLocation
import MapKit

/// Create or edit a memory. Photos come first: their location and date fill
/// in the place and day (on-device), so most memories are "pick photos →
/// check the suggestion → save".
struct MemoryEditorView: View {
    enum Mode {
        case new(countryCode: String?, pickPhotosFirst: Bool)
        case edit(Memory)
        case fromLibrary(assetIds: [String], countryCode: String?)
    }

    let mode: Mode

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MemoryDraft()
    /// Stable across retries: a save whose response was lost can't land twice.
    @State private var newMemoryId = UUID()
    @State private var newPhotos: [PickedPhoto] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var loadingPhotos = false
    @State private var showPlaceSearch = false
    @State private var showCountryPicker = false
    @State private var suggestion: PlaceResult?
    @State private var placeTouched = false
    @State private var dateTouched = false
    @State private var shareGroups: Set<UUID> = []
    @State private var saving = false
    @State private var stampResult: AppModel.SaveResult?
    @State private var prepared = false
    @State private var confirmDiscard = false
    @FocusState private var focused: Field?

    enum Field { case title, city, notes }

    struct PickedPhoto: Identifiable {
        let id = UUID()
        let preview: UIImage
        let jpeg: Data
        let meta: PhotoMetadata
    }

    private static let maxPhotos = 10

    private var original: Memory? {
        if case .edit(let memory) = mode { return memory }
        return nil
    }

    private var photoCount: Int { draft.keptPhotos.count + newPhotos.count }

    private var canSave: Bool {
        !draft.countryCode.isEmpty && !saving && !loadingPhotos
            && (photoCount > 0 || !draft.title.trimmed.isEmpty || !draft.notes.trimmed.isEmpty || !draft.city.trimmed.isEmpty)
    }

    private var isDirty: Bool {
        if let original { return draft != MemoryDraft(memory: original) || !newPhotos.isEmpty }
        return !newPhotos.isEmpty || !draft.title.isEmpty || !draft.notes.isEmpty
    }

    private var country: Country? { CountryStore.byCode[draft.countryCode] }
    private var isNewCountry: Bool { original == nil && !draft.countryCode.isEmpty && !app.visitedCodes.contains(draft.countryCode) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    photosSection
                    if let suggestion, !placeTouched, !matchesDraft(suggestion) {
                        suggestionBanner(suggestion)
                    }
                    whereCard
                    whenCard
                    storyCard
                    visibilityCard
                    if !app.groups.isEmpty && draft.visibility != .private {
                        groupsCard
                    }
                }
                .padding(Metrics.gutter)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .paperBackground()
            .navigationTitle(original == nil ? "New memory" : "Edit memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Disabled mid-save: discarding couldn't stop the upload,
                    // so the "discarded" memory still appeared.
                    Button("Cancel") {
                        if isDirty { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNewCountry ? "Stamp it" : "Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
            .overlay {
                if saving {
                    SavingOverlay(text: newPhotos.isEmpty ? "Saving…" : "Uploading \(newPhotos.count) photo\(newPhotos.count == 1 ? "" : "s")…")
                }
            }
            .photosPicker(isPresented: $showPicker, selection: $pickerItems,
                          maxSelectionCount: max(1, Self.maxPhotos - photoCount),
                          selectionBehavior: .ordered, matching: .images, photoLibrary: .shared())
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await load(items) }
            }
            .sheet(isPresented: $showPlaceSearch) {
                PlaceSearchSheet(near: searchHint) { place in apply(place, userChosen: true) }
            }
            .sheet(isPresented: $showCountryPicker) {
                CountryPickerSheet(title: "Country", selected: draft.countryCode) { code in
                    draft.countryCode = code
                    placeTouched = true
                }
            }
            .confirmationDialog("Discard this memory?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .fullScreenCover(item: Binding(
                get: { stampResult.map { StampBurst(codes: [$0.memory.countryCode]) } },
                set: { if $0 == nil { stampResult = nil } }
            )) { _ in
                StampMomentView(codes: [stampResult?.memory.countryCode ?? draft.countryCode],
                                number: stampResult?.countryNumber,
                                date: stampResult?.memory.date) {
                    stampResult = nil
                    dismiss()
                }
            }
        }
        .interactiveDismissDisabled(isDirty || saving)
        .task { await prepare() }
    }

    // ── Sections ─────────────────────────────────────────────────────────────

    @ViewBuilder private var photosSection: some View {
        if photoCount == 0 {
            Button { showPicker = true } label: {
                VStack(spacing: 10) {
                    if loadingPhotos {
                        ProgressView()
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Color.brand)
                    }
                    Text(loadingPhotos ? "Adding photos…" : "Add photos")
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    Text("We'll use where and when they were taken.")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                        .strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
            }
            .buttonStyle(.plain)
            .disabled(loadingPhotos)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(draft.keptPhotos, id: \.self) { path in
                        thumb {
                            StoragePhoto(path: path, maxPixel: 400)
                        } onRemove: {
                            withAnimation { draft.keptPhotos.removeAll { $0 == path } }
                        }
                    }
                    ForEach(newPhotos) { photo in
                        thumb {
                            Image(uiImage: photo.preview).resizable().scaledToFill()
                        } onRemove: {
                            withAnimation { newPhotos.removeAll { $0.id == photo.id } }
                        }
                    }
                    if photoCount < Self.maxPhotos {
                        Button { showPicker = true } label: {
                            VStack(spacing: 6) {
                                if loadingPhotos { ProgressView() } else {
                                    Image(systemName: "plus").font(.title2.weight(.semibold))
                                }
                                Text("Add").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(Color.brand)
                            .frame(width: 104, height: 130)
                            .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
                        }
                        .buttonStyle(.plain)
                        .disabled(loadingPhotos)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func thumb<Content: View>(@ViewBuilder _ content: () -> Content, onRemove: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: 104, height: 130)
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .padding(4)
                .accessibilityLabel("Remove photo")
            }
    }

    private func suggestionBanner(_ place: PlaceResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "location.fill")
                .foregroundStyle(Color.brand)
                .frame(width: 34, height: 34)
                .background(Color.brandSoft, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestionText(place))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                Text("From your photo's location")
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
            }
            Spacer()
            Button("Use") { apply(place, userChosen: true) }
                .buttonStyle(.capsuleProminent)
        }
        .card(padding: 12)
    }

    private var whereCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // No autocorrect on place names: "Preikestolen" is not a typo.
                TextField("Name it — “Sunset at Oia”", text: $draft.title)
                    .font(.headline)
                    .focused($focused, equals: .title)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                Button { showPlaceSearch = true } label: {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 36, height: 36)
                        .background(Color.brandSoft, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search places")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().padding(.leading, 14)

            Button { showCountryPicker = true } label: {
                HStack(spacing: 12) {
                    Text(country?.flag ?? "🌐").font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(country?.name ?? "Choose a country")
                            .foregroundStyle(country == nil ? Color.inkSecondary : Color.ink)
                        if country == nil {
                            Text("Required").font(.caption).foregroundStyle(Color.stampRed)
                        } else if isNewCountry {
                            Text("New to your passport").font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.inkTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 14)

            HStack(spacing: 12) {
                Image(systemName: "building.2")
                    .foregroundStyle(Color.inkSecondary)
                    .frame(width: 26)
                TextField("City (optional)", text: $draft.city)
                    .focused($focused, equals: .city)
                    .textContentType(.addressCity)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
            .strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
    }

    private var whenCard: some View {
        DatePicker(selection: Binding(get: { draft.date }, set: { draft.date = $0; dateTouched = true }),
                   in: ...Date(), displayedComponents: .date) {
            Label("When", systemImage: "calendar")
                .foregroundStyle(Color.ink)
        }
        .card(padding: 14)
    }

    private var storyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "The story")
            TextField("What happened here? What should friends not miss?", text: $draft.notes, axis: .vertical)
                .lineLimit(3...10)
                .focused($focused, equals: .notes)
        }
        .card(padding: 14)
    }

    private var visibilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Who can see this")
            Picker("Visibility", selection: $draft.visibility) {
                ForEach(Visibility.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Label(draft.visibility.explanation, systemImage: draft.visibility.systemImage)
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
        }
        .card(padding: 14)
    }

    private var groupsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Also share to")
            ForEach(app.groups) { group in
                Toggle(isOn: Binding(
                    get: { shareGroups.contains(group.id) },
                    set: { on in if on { shareGroups.insert(group.id) } else { shareGroups.remove(group.id) } }
                )) {
                    HStack(spacing: 10) {
                        GroupAvatarView(group: group, size: 30)
                        Text(group.name).foregroundStyle(Color.ink)
                    }
                }
                .tint(Color.brand)
            }
        }
        .card(padding: 14)
    }

    // ── Logic ────────────────────────────────────────────────────────────────

    private var searchHint: CLLocationCoordinate2D? {
        if let lat = draft.lat, let lng = draft.lng { return .init(latitude: lat, longitude: lng) }
        if let country { return .init(latitude: country.centroid.lat, longitude: country.centroid.lng) }
        return nil
    }

    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        draft.visibility = SettingsStore.defaultVisibility
        switch mode {
        case .new(let code, let pickFirst):
            if let code { draft.countryCode = code; placeTouched = true }
            if pickFirst {
                try? await Task.sleep(for: .milliseconds(350))
                showPicker = true
            }
        case .edit(let memory):
            draft = MemoryDraft(memory: memory)
            placeTouched = true
            dateTouched = true
        case .fromLibrary(let ids, let code):
            if let code { draft.countryCode = code }
            loadingPhotos = true
            var loaded: [PickedPhoto] = []
            for id in ids.prefix(Self.maxPhotos) {
                if let (data, meta) = await LocalAssets.imageData(id),
                   let upload = ImageTools.uploadJPEG(from: data) {
                    loaded.append(PickedPhoto(preview: upload.preview, jpeg: upload.jpeg, meta: meta))
                }
            }
            newPhotos = loaded
            loadingPhotos = false
            await suggestFromPhotos()
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        loadingPhotos = true
        defer {
            loadingPhotos = false
            pickerItems = []
        }
        for item in items {
            guard photoCount < Self.maxPhotos,
                  let data = try? await item.loadTransferable(type: Data.self) else { continue }
            var meta = PhotoMetadata.read(from: data)
            if !meta.hasLocation || meta.date == nil, let library = PhotoMetadata.read(assetIdentifier: item.itemIdentifier) {
                if !meta.hasLocation { meta.latitude = library.latitude; meta.longitude = library.longitude }
                if meta.date == nil { meta.date = library.date }
            }
            guard let upload = ImageTools.uploadJPEG(from: data) else { continue }
            newPhotos.append(PickedPhoto(preview: upload.preview, jpeg: upload.jpeg, meta: meta))
        }
        await suggestFromPhotos()
    }

    /// Earliest photo date → the day; first located photo → the place.
    private func suggestFromPhotos() async {
        if !dateTouched, let earliest = newPhotos.compactMap(\.meta.date).min() {
            draft.date = min(earliest, Date())
        }
        guard suggestion == nil,
              let located = newPhotos.first(where: { $0.meta.hasLocation }),
              let lat = located.meta.latitude, let lng = located.meta.longitude else { return }
        let place = await PlaceSearch.reverseGeocode(latitude: lat, longitude: lng)
        suggestion = place
        // Fill empty fields straight away; a banner still offers the full place.
        if !placeTouched && draft.countryCode.isEmpty {
            apply(place, userChosen: false)
        }
    }

    private func apply(_ place: PlaceResult, userChosen: Bool) {
        if let code = place.countryCode, CountryStore.byCode[code] != nil { draft.countryCode = code }
        if !place.title.isEmpty && (userChosen || draft.title.isEmpty) { draft.title = place.title }
        if !place.city.isEmpty && (userChosen || draft.city.isEmpty) { draft.city = place.city }
        if place.latitude != nil {
            draft.lat = place.latitude
            draft.lng = place.longitude
        }
        if userChosen { placeTouched = true }
    }

    private func matchesDraft(_ place: PlaceResult) -> Bool {
        (place.countryCode ?? draft.countryCode) == draft.countryCode
            && (place.city.isEmpty || place.city == draft.city)
            && (place.title.isEmpty || place.title == draft.title)
    }

    private func suggestionText(_ place: PlaceResult) -> String {
        let name = CountryStore.byCode[place.countryCode ?? ""]?.name
        return [place.title, place.city, name ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func save() async {
        guard canSave else { return }
        focused = nil
        saving = true
        defer { saving = false }
        do {
            let result = try await app.saveMemory(draft, editing: original, newId: newMemoryId,
                                                  newPhotos: newPhotos.map(\.jpeg),
                                                  shareTo: draft.visibility == .private ? [] : shareGroups)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if result.isNewCountry {
                stampResult = result
            } else {
                app.celebrate(original == nil ? "Memory saved" : "Memory updated")
                dismiss()
            }
        } catch {
            app.show(error)
        }
    }
}

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

    @Environment(\.dismiss) private var dismiss
    @State private var search: PlaceSearch
    @State private var resolving = false

    init(near: CLLocationCoordinate2D?, onPick: @escaping (PlaceResult) -> Void) {
        self.onPick = onPick
        _search = State(initialValue: PlaceSearch(near: near))
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
                    ContentUnavailableView("Search places", systemImage: "mappin.and.ellipse",
                                           description: Text("Landmarks, restaurants, hotels, towns…"))
                }
            }
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Where was this?")
            .navigationTitle("Place")
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
