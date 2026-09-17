import SwiftUI
import PhotosUI
import MapKit

/// Your passport: who you are, how much of the world you've seen, and every
/// stamp and memory — as a stamp book, a timeline of trips, or a map.
struct PassportView: View {
    enum Page: String, CaseIterable, Identifiable {
        case stamps = "Stamps"
        case trips = "Trips"
        case map = "Map"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @State private var page: Page = .stamps
    @State private var pickedItem: PhotosPickerItem?
    @State private var cropping: CropImage?
    @State private var uploadingAvatar = false
    @State private var showEdit = false
    @State private var showGoal = false
    @State private var showSettings = false
    @State private var showWrapped = false
    @State private var showImport = false
    @State private var showChecklist = false
    @State private var addingMemory = false
    @State private var country: String?
    @State private var trip: Trip?
    @State private var viewing: Memory?
    @State private var shareImage: UIImage?

    struct CropImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    worldCard
                    goalCard
                    bucketCard
                    Picker("View", selection: $page) {
                        ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 4)
                    sectionContent
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 30)
            }
            .paperBackground()
            .refreshable { await app.refresh() }
            .navigationTitle("Passport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showWrapped = true } label: { Image(systemName: "sparkles.rectangle.stack") }
                        .accessibilityLabel("Year in travel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { addingMemory = true } label: { Label("Add a memory", systemImage: "photo.badge.plus") }
                        Button { showImport = true } label: { Label("Find countries in my photos", systemImage: "sparkle.magnifyingglass") }
                        Button { showChecklist = true } label: { Label("Mark countries I've been to", systemImage: "checklist") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .onChange(of: pickedItem) { Task { await loadPicked() } }
            .sheet(item: $cropping) { crop in
                PhotoCropSheet(image: crop.image) { jpeg in Task { await uploadAvatar(jpeg) } }
            }
            .sheet(isPresented: $showEdit) { ProfileEditSheet() }
            .sheet(isPresented: $showGoal) { GoalEditorSheet() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWrapped) { NavigationStack { WrappedView() } }
            .sheet(isPresented: $showImport) { NavigationStack { PhotoImportView(onDone: { showImport = false }) } }
            .sheet(isPresented: $showChecklist) { NavigationStack { CountryChecklistView(onDone: { showChecklist = false }) } }
            .sheet(isPresented: $addingMemory) { MemoryEditorView(mode: .new(countryCode: nil, pickPhotosFirst: true)) }
            .sheet(item: Binding(get: { country.map(CountryRef.init) }, set: { country = $0?.code })) { ref in
                CountryMemoriesSheet(code: ref.code)
            }
            .sheet(item: $trip) { TripDetailSheet(trip: $0) }
            .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
            .task(id: app.stats) { renderShareCard() }
        }
    }

    // ── Header ───────────────────────────────────────────────────────────────

    private var header: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(profile: app.me, size: 96)
                    .overlay {
                        if uploadingAvatar {
                            ZStack {
                                Circle().fill(.black.opacity(0.35))
                                ProgressView().tint(.white)
                            }
                        }
                    }
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Image(systemName: "camera.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.onBrand)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.brand))
                        .overlay(Circle().stroke(Color.card, lineWidth: 3))
                }
                .disabled(uploadingAvatar)
                .accessibilityLabel("Change profile photo")
            }

            VStack(spacing: 4) {
                Text(app.me?.name ?? " ")
                    .font(.displaySmall)
                    .foregroundStyle(Color.ink)
                HStack(spacing: 6) {
                    if let handle = app.me?.handle { Text(handle) }
                    if let code = app.me?.homeCountry, let home = CountryStore.byCode[code] {
                        Text("· \(home.flag) \(app.me?.homeCity.flatMap { $0.isEmpty ? nil : $0 } ?? home.name)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.inkSecondary)
                if let bio = app.me?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: 10) {
                Button("Edit profile") { showEdit = true }
                    .buttonStyle(SecondaryButtonStyle())
                if let shareImage {
                    ShareLink(item: Image(uiImage: shareImage),
                              preview: SharePreview("My Stampd passport", image: Image(uiImage: shareImage))) {
                        Text("Share passport")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    // ── World progress ───────────────────────────────────────────────────────

    private var worldCard: some View {
        let stats = app.stats
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(stats.countries)")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .contentTransition(.numericText())
                    Text("countries of \(CountryStore.sovereignCount)\(stats.territories > 0 ? " · +\(stats.territories) territor\(stats.territories == 1 ? "y" : "ies")" : "")")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(stats.worldPercentText)
                        .font(.number(.title))
                        .foregroundStyle(Color.brand)
                    Text("of the world")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            ProgressLine(fraction: stats.worldFraction)
            HStack(spacing: 0) {
                StatTile(value: "\(stats.continents)/7", label: "Continents")
                StatTile(value: "\(stats.cities)", label: "Cities")
                StatTile(value: "\(stats.memories)", label: "Memories")
                StatTile(value: "\(stats.photos)", label: "Photos")
            }
            continentBars(stats)
        }
        .card()
        .animation(.snappy, value: stats.countries)
    }

    private func continentBars(_ stats: TravelStats) -> some View {
        VStack(spacing: 8) {
            ForEach(Continent.allCases.filter { (stats.continentProgress[$0]?.visited ?? 0) > 0 }) { continent in
                let progress = stats.continentProgress[continent] ?? (0, 1)
                HStack(spacing: 10) {
                    Text(continent.rawValue)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.ink)
                        .frame(width: 96, alignment: .leading)
                    ProgressLine(fraction: Double(progress.visited) / Double(max(1, progress.total)), tint: .brand.opacity(0.8))
                    Text("\(progress.visited)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    // ── Goal ─────────────────────────────────────────────────────────────────

    @ViewBuilder private var goalCard: some View {
        let year = Calendar.current.component(.year, from: Date())
        let newThisYear = TravelStats.newCountries(in: year, stamps: app.stamps)
        Button { showGoal = true } label: {
            HStack(spacing: 14) {
                if let goal = app.me?.yearlyGoal {
                    ZStack {
                        Circle().stroke(Color.sunken, lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: min(1, Double(newThisYear.count) / Double(max(1, goal))))
                            .stroke(Color.brand, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(newThisYear.count)").font(.number(.headline))
                    }
                    .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(String(year)): \(newThisYear.count) of \(goal) new countries")
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                        Text(newThisYear.count >= goal
                             ? "Goal smashed. Raise the bar?"
                             : (newThisYear.isEmpty ? "Your first new stamp of the year is out there." : newThisYear.map { Country.flag(for: $0.countryCode) }.joined(separator: " ")))
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "target")
                        .font(.title2)
                        .foregroundStyle(Color.brand)
                        .frame(width: 56, height: 56)
                        .background(Color.brandSoft, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Set a \(String(year)) travel goal")
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                        Text("How many new countries this year?")
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.inkTertiary)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
    }

    // ── Bucket list ──────────────────────────────────────────────────────────

    @ViewBuilder private var bucketCard: some View {
        let bucket = CountryStore.all.filter { app.bucketList.contains($0.code) && !app.visitedCodes.contains($0.code) }
        if !bucket.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Bucket list", subtitle: "\(bucket.count) place\(bucket.count == 1 ? "" : "s") to go")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(bucket) { place in
                            Button { country = place.code } label: {
                                HStack(spacing: 6) {
                                    Text(place.flag)
                                    Text(place.name).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.bucketSoft, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .card()
        }
    }

    // ── Sections ─────────────────────────────────────────────────────────────

    @ViewBuilder private var sectionContent: some View {
        switch page {
        case .stamps: stampBook
        case .trips: tripsList
        case .map: memoriesMap
        }
    }

    @ViewBuilder private var stampBook: some View {
        if app.stamps.isEmpty {
            EmptyStateView(systemImage: "seal", title: "Your passport is empty",
                           message: "Find the countries in your photos, or tap the ones you've been to.",
                           primaryTitle: "Scan my photos", primaryAction: { showImport = true },
                           secondaryTitle: "Pick countries", secondaryAction: { showChecklist = true })
                .padding(.vertical, 24)
        } else {
            let sorted = app.stamps.sorted {
                ($0.lastVisited ?? $0.firstVisited ?? "", $0.createdAt) > ($1.lastVisited ?? $1.firstVisited ?? "", $1.createdAt)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 14) {
                ForEach(sorted) { stamp in
                    Button { country = stamp.countryCode } label: {
                        VStack(spacing: 4) {
                            StampBadge(code: stamp.countryCode, subtitle: stamp.yearsText, size: 100)
                            let count = app.memoriesByCountry[stamp.countryCode]?.count ?? 0
                            Text(count > 0 ? "\(count) memor\(count == 1 ? "y" : "ies")" : " ")
                                .font(.caption2)
                                .foregroundStyle(Color.inkTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .background {
                // Passport page: faint guilloché lines.
                RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                    .fill(Color.card)
                    .overlay {
                        VStack(spacing: 22) {
                            ForEach(0..<40, id: \.self) { _ in
                                Rectangle().fill(Color.hairline.opacity(0.35)).frame(height: 0.5)
                            }
                        }
                        .clipped()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
            }
        }
    }

    @ViewBuilder private var tripsList: some View {
        let trips = TripBuilder.trips(from: app.memories)
        if trips.isEmpty {
            EmptyStateView(systemImage: "photo.stack", title: "No memories yet",
                           message: "Add photos from a trip — we'll group them into trips automatically.",
                           primaryTitle: "Add a memory", primaryAction: { addingMemory = true })
                .padding(.vertical, 24)
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(trips) { trip in
                    Button { self.trip = trip } label: { TripCard(trip: trip) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var memoriesMap: some View {
        let located = app.memories.filter(\.hasCoordinate)
        if located.isEmpty {
            EmptyStateView(systemImage: "map", title: "Nothing on the map yet",
                           message: "Memories with a place — from a photo's location or place search — get pinned here.")
                .padding(.vertical, 24)
        } else {
            Map(initialPosition: .automatic) {
                ForEach(located) { memory in
                    Annotation(memory.displayTitle,
                               coordinate: CLLocationCoordinate2D(latitude: memory.lat ?? 0, longitude: memory.lng ?? 0)) {
                        Button { viewing = memory } label: {
                            MapPin(memory: memory)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .frame(height: 460)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
        }
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func loadPicked() async {
        guard let pickedItem else { return }
        defer { self.pickedItem = nil }
        guard let data = try? await pickedItem.loadTransferable(type: Data.self),
              let image = ImagePipeline.downsample(data, maxPixel: 2048) else {
            app.show(AppError("Couldn't read that photo."))
            return
        }
        cropping = CropImage(image: image)
    }

    private func uploadAvatar(_ jpeg: Data) async {
        uploadingAvatar = true
        defer { uploadingAvatar = false }
        do {
            try await app.uploadAvatar(jpeg)
        } catch {
            app.show(error)
        }
    }

    @MainActor
    private func renderShareCard() {
        let stats = app.stats
        let codes = app.stamps.sorted { ($0.lastVisited ?? "") > ($1.lastVisited ?? "") }.prefix(9).map(\.countryCode)
        let card = ShareCard {
            VStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text("\(stats.countries)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                    Text("countries · \(stats.worldPercentText) of the world")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.33))
                }
                .foregroundStyle(Color(red: 0.12, green: 0.1, blue: 0.08))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(96)), count: 3), spacing: 6) {
                    ForEach(codes, id: \.self) { StampBadge(code: $0, size: 92) }
                }
            }
        }
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        shareImage = stats.countries > 0 ? renderer.uiImage : nil
    }
}

private struct CountryRef: Identifiable {
    let code: String
    var id: String { code }
}

private struct MapPin: View {
    let memory: Memory

    var body: some View {
        ZStack {
            Circle().fill(Color.card).frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            if let first = memory.photos.first {
                StoragePhoto(path: first, maxPixel: 160)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Text(memory.country?.flag ?? "📍").font(.title3)
            }
        }
        .overlay(Circle().strokeBorder(Color.brand, lineWidth: 2).frame(width: 46, height: 46))
    }
}

/// Everything in one country: its stamp, your memories, photos on this phone.
struct CountryMemoriesSheet: View {
    let code: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var viewing: Memory?
    @State private var adding: EditorRequest?
    @State private var localIds: [String] = []
    @State private var confirmRemove = false

    private var country: Country? { CountryStore.byCode[code] }
    private var memories: [Memory] { app.memoriesByCountry[code] ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        if app.visitedCodes.contains(code) {
                            StampBadge(code: code, subtitle: app.stampsByCode[code]?.yearsText, size: 110)
                        } else {
                            StampBadge(code: code, size: 110, inked: false)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(country?.name ?? code).font(.display).foregroundStyle(Color.ink)
                            Text(app.visitedCodes.contains(code)
                                 ? "\(memories.count) memor\(memories.count == 1 ? "y" : "ies")"
                                 : "On your bucket list")
                                .font(.subheadline)
                                .foregroundStyle(Color.inkSecondary)
                        }
                    }

                    Button {
                        adding = EditorRequest(mode: .new(countryCode: code, pickPhotosFirst: true))
                    } label: {
                        Label("Add a memory here", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.primary)

                    if !localIds.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("On this phone", subtitle: "Photos from \(country?.name ?? "here") — only you can see these")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(localIds.prefix(30), id: \.self) { id in
                                        Button {
                                            adding = EditorRequest(mode: .fromLibrary(assetIds: [id], countryCode: code))
                                        } label: {
                                            LocalAssetThumbnail(identifier: id, side: 96)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    if !memories.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                            ForEach(memories) { memory in
                                Button { viewing = memory } label: { MemoryTile(memory: memory) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(Metrics.gutter)
            }
            .paperBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if app.visitedCodes.contains(code) && memories.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive) { confirmRemove = true } label: {
                                Label("Remove stamp", systemImage: "minus.circle")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .confirmationDialog("Remove \(country?.name ?? code) from your passport?", isPresented: $confirmRemove,
                                titleVisibility: .visible) {
                Button("Remove stamp", role: .destructive) {
                    Task {
                        do {
                            try await app.removeStamp(code)
                            dismiss()
                        } catch {
                            app.show(error)
                        }
                    }
                }
            }
            .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
            // A stored request with a stable id. (Deriving the item in a
            // Binding getter minted a new id every render, so saving — which
            // re-renders this sheet — tore the editor down and reopened it.)
            .sheet(item: $adding) { request in
                MemoryEditorView(mode: request.mode)
            }
            .task { localIds = LocalPhotoIndex.assetIds(for: code) }
        }
    }
}

struct EditorRequest: Identifiable {
    let mode: MemoryEditorView.Mode
    let id = UUID()
}

struct LocalAssetThumbnail: View {
    let identifier: String
    var side: CGFloat = 80
    @State private var image: UIImage?

    var body: some View {
        Color.sunken
            .frame(width: side, height: side)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: identifier) { image = await LocalAssets.thumbnail(identifier, side: side) }
            .accessibilityLabel("Photo on this phone")
    }
}

/// A trip's memories, in order.
struct TripDetailSheet: View {
    let trip: Trip

    @Environment(\.dismiss) private var dismiss
    @State private var viewing: Memory?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trip.flags).font(.largeTitle)
                        Text(trip.title).font(.display).foregroundStyle(Color.ink)
                        Text("\(trip.dateRangeText) · \(trip.days) day\(trip.days == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSecondary)
                    }
                    ForEach(trip.memories) { memory in
                        Button { viewing = memory } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                PhotoPager(memory: memory, aspect: 4.0 / 3.0, cornerRadius: 16, maxPixel: 1200)
                                HStack {
                                    Text(memory.displayTitle).font(.headline).foregroundStyle(Color.ink)
                                    Spacer()
                                    Text(DayFormat.pretty(memory.date)).font(.caption).foregroundStyle(Color.inkSecondary)
                                }
                                if let notes = memory.notes, !notes.isEmpty {
                                    Text(notes).font(.subheadline).foregroundStyle(Color.inkSecondary).lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .card(padding: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Metrics.gutter)
            }
            .paperBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
        }
    }
}
