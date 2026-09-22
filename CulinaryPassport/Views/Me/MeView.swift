import SwiftUI
import PhotosUI

/// Your food passport: the cover, your data page, the world continent by
/// continent as six plates, a stamp for every cuisine you've tasted, your
/// meals as plates, and the restaurants you're saving for later.
struct MeView: View {
    @Environment(AppModel.self) private var app
    @State private var pickedItem: PhotosPickerItem?
    @State private var cropping: CropImage?
    @State private var uploadingAvatar = false
    @State private var showEdit = false
    @State private var showGoal = false
    @State private var showSettings = false
    @State private var tickingCuisines = false
    @State private var loggingMeal = false
    @State private var cuisine: CuisineRef?
    @State private var continent: Continent?
    @State private var viewing: Meal?
    @State private var loggingAt: SavedPlace?
    @State private var editingPlace: SavedPlace?
    @State private var shareImage: UIImage?

    struct CropImage: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    PassportCover(name: app.me?.name ?? "", cuisines: app.stats.cuisines,
                                  percent: app.stats.worldPercentText)
                    dataPage
                    identityActions
                    worldPage
                    goal
                    stampPages
                    plates
                    toTry
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 30)
            }
            .paperBackground()
            .refreshable { await app.refresh() }
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { loggingMeal = true } label: { Label("Log a meal", systemImage: "fork.knife") }
                        Button { tickingCuisines = true } label: { Label("Mark cuisines I've tried", systemImage: "checklist") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
            }
            .navigationDestination(for: PlatesDestination.self) { _ in AllPlatesView() }
            .onChange(of: pickedItem) { Task { await loadPicked() } }
            .sheet(item: $cropping) { crop in
                PhotoCropSheet(image: crop.image) { jpeg in Task { await uploadAvatar(jpeg) } }
            }
            .sheet(isPresented: $showEdit) { ProfileEditSheet() }
            .sheet(isPresented: $showGoal) { GoalEditorSheet() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $tickingCuisines) {
                NavigationStack { CuisineChecklistView(onDone: { tickingCuisines = false }) }
            }
            .sheet(isPresented: $loggingMeal) { MealEditorView(mode: .new(cuisine: nil, place: nil)) }
            .sheet(item: $cuisine) { CuisineSheet(code: $0.code) }
            .sheet(item: $continent) { ContinentSheet(continent: $0) }
            .sheet(item: $viewing) { MealDetailView(meal: $0) }
            .sheet(item: $loggingAt) { LogAtPlaceSheet(place: $0) }
            .sheet(item: $editingPlace) { RestaurantEditorSheet(place: $0) }
            .task(id: app.stats) { renderShareCard() }
        }
    }

    // ── Data page ────────────────────────────────────────────────────────────

    private var dataPage: some View {
        PassportDataPage(profile: app.me, stats: app.stats) {
            ZStack(alignment: .bottomTrailing) {
                PassportPhoto(profile: app.me)
                    .overlay {
                        if uploadingAvatar {
                            ZStack {
                                Rectangle().fill(.black.opacity(0.35))
                                ProgressView().tint(.white)
                            }
                        }
                    }
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Image(systemName: "camera.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.onBrand)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.brand))
                        .overlay(Circle().stroke(Color.card, lineWidth: 2))
                }
                .disabled(uploadingAvatar)
                .accessibilityLabel("Change profile photo")
                .padding(3)
            }
        }
    }

    private var identityActions: some View {
        HStack(spacing: 10) {
            Button("Edit profile") { showEdit = true }
                .buttonStyle(SecondaryButtonStyle())
            if let shareImage {
                ShareLink(item: Image(uiImage: shareImage),
                          preview: SharePreview("My food passport", image: Image(uiImage: shareImage))) {
                    Text("Share passport")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    // ── The world, by the plate ──────────────────────────────────────────────

    private var worldPage: some View {
        let stats = app.stats
        let tint = Color(hex: app.me?.color ?? "#2f5a45", fallback: Palette.brand)
        return StampPage(number: 1) {
            VStack(alignment: .leading, spacing: 14) {
                Text("ENDORSEMENTS · THE WORLD BY THE PLATE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.inkTertiary)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(stats.cuisines)")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink)
                            .contentTransition(.numericText())
                        Text("of \(Cuisine.codes.count) cuisines")
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(stats.worldPercentText)
                            .font(.system(size: 34, weight: .semibold, design: .serif))
                            .foregroundStyle(tint)
                        Text("of the world, eaten")
                            .font(.caption)
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 14) {
                    ForEach(FoodStats.continents) { continent in
                        Button { self.continent = continent } label: {
                            ContinentPlate(continent: continent,
                                           progress: stats.continentProgress[continent] ?? .init(tasted: 0, total: 0),
                                           tint: tint)
                        }
                        .buttonStyle(PressScale())
                    }
                }
            }
        }
        .animation(.snappy, value: stats.cuisines)
    }

    // ── Goal ─────────────────────────────────────────────────────────────────

    @ViewBuilder private var goal: some View {
        let year = Calendar.current.component(.year, from: Date())
        let fresh = FoodStats.newCuisines(in: year, tastes: app.tastes)
        Button { showGoal = true } label: {
            HStack(spacing: 14) {
                if let goal = app.me?.yearlyGoal {
                    ZStack {
                        Plate(rim: 0.2, band: .clear, shadow: false) { Color.clear }
                        Circle()
                            .trim(from: 0, to: min(1, Double(fresh.count) / Double(max(1, goal))))
                            .stroke(Color.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(3)
                        Text("\(fresh.count)").font(.number(.headline))
                    }
                    .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(String(year)): \(fresh.count) of \(goal) new cuisines")
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                        Text(fresh.count >= goal
                             ? "Goal eaten. Raise the bar?"
                             : (fresh.isEmpty ? "Your first new cuisine of the year is a spin away."
                                              : fresh.map { Country.flag(for: $0.countryCode) }.joined(separator: " ")))
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "target")
                        .font(.title2)
                        .foregroundStyle(Color.brand)
                        .frame(width: 58, height: 58)
                        .background(Color.brandSoft, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Set a \(String(year)) goal")
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                        Text("How many new cuisines this year?")
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.inkTertiary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // ── Stamps ───────────────────────────────────────────────────────────────

    @ViewBuilder private var stampPages: some View {
        if app.tastes.isEmpty {
            StampPage(number: 2) {
                VStack(spacing: 12) {
                    StampBadge(code: "IT", size: 96, inked: false, tasted: true)
                    Text("Every cuisine you taste gets a stamp here.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button("Cuisines I've tried") { tickingCuisines = true }
                            .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                        Button("Log a meal") { loggingMeal = true }
                            .buttonStyle(SecondaryButtonStyle(fullWidth: false))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        } else {
            let sorted = app.tastes.filter { Cuisine.isCuisine($0.countryCode) }.sorted {
                ($0.lastTasted ?? "", $0.createdAt) > ($1.lastTasted ?? "", $1.createdAt)
            }
            let pages = stride(from: 0, to: sorted.count, by: 9).map { Array(sorted[$0..<min($0 + 9, sorted.count)]) }
            LazyVStack(spacing: 14) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    StampPage(number: index + 2) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 14) {
                            ForEach(page) { taste in
                                Button { cuisine = CuisineRef(code: taste.countryCode) } label: {
                                    VStack(spacing: 4) {
                                        StampBadge(code: taste.countryCode, subtitle: taste.yearsText, size: 96, tasted: true)
                                        Text(taste.meals > 0 ? taste.meals.counted("meal") : " ")
                                            .font(.caption2)
                                            .foregroundStyle(Color.inkTertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button { tickingCuisines = true } label: {
                    Label("Add cuisines I've tried", systemImage: "checklist")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    // ── Plates ───────────────────────────────────────────────────────────────

    @ViewBuilder private var plates: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Your plates", subtitle: app.meals.isEmpty ? nil : app.meals.count.counted("meal")) {
                if app.meals.count > 12 {
                    NavigationLink(value: PlatesDestination.all) {
                        Text("All").font(.subheadline.weight(.semibold))
                    }
                }
            }
            if app.meals.isEmpty {
                HStack(spacing: 14) {
                    Plate(rim: 0.16, band: .clear) {
                        Image(systemName: "camera")
                            .font(.title2)
                            .foregroundStyle(Color.inkTertiary)
                    }
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Snap tonight's dinner — the photo finds the restaurant for you.")
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSecondary)
                        Button("Log a meal") { loggingMeal = true }
                            .buttonStyle(.capsuleProminent)
                    }
                }
            } else {
                PlateStack(columns: 3, spacing: 10) {
                    ForEach(app.meals.prefix(12)) { meal in
                        Button { viewing = meal } label: { MealPlate(meal: meal) }
                            .buttonStyle(PressScale())
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    // ── To try ───────────────────────────────────────────────────────────────

    @ViewBuilder private var toTry: some View {
        if !app.toTry.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Restaurants to try", subtitle: app.toTry.count.counted("place"))
                ForEach(app.toTry.prefix(10)) { place in
                    RestaurantTag(place: place, onLog: { loggingAt = place }, onEdit: { editingPlace = place })
                }
            }
            .padding(.top, 6)
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
        let recent = app.tastes.sorted { ($0.lastTasted ?? "", $0.createdAt) > ($1.lastTasted ?? "", $1.createdAt) }
        let renderer = ImageRenderer(content: ShareCard {
            PassportShareCard(profile: app.me, stats: stats, tastes: recent)
        })
        renderer.scale = 3
        shareImage = stats.cuisines > 0 ? renderer.uiImage : nil
    }
}

enum PlatesDestination: Hashable { case all }

struct CuisineRef: Identifiable {
    let code: String
    var id: String { code }
}

/// One continent as a plate: its rim inked as far round as you've eaten.
struct ContinentPlate: View {
    let continent: Continent
    let progress: FoodStats.Progress
    var tint: Color = .brand

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Plate(rim: 0.16, band: .clear) { Color.clear }
                Circle()
                    .stroke(Color.hairline, lineWidth: 4)
                    .padding(3)
                Circle()
                    .trim(from: 0, to: max(progress.fraction, progress.tasted > 0 ? 0.02 : 0))
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
                VStack(spacing: -1) {
                    Text("\(progress.tasted)")
                        .font(.number(.title3))
                        .foregroundStyle(Color.ink)
                    Text("of \(progress.total)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .frame(width: 82, height: 82)
            Text(continent.shortName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(continent.rawValue): \(progress.tasted) of \(progress.total) cuisines")
        .accessibilityAddTraits(.isButton)
    }
}

/// Every meal you've logged, as plates.
struct AllPlatesView: View {
    @Environment(AppModel.self) private var app
    @State private var viewing: Meal?

    var body: some View {
        ScrollView {
            PlateStack(columns: 3, spacing: 10) {
                ForEach(app.meals) { meal in
                    Button { viewing = meal } label: { MealPlate(meal: meal) }
                        .buttonStyle(PressScale())
                }
            }
            .padding(Metrics.gutter)
        }
        .paperBackground()
        .navigationTitle("Your plates")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $viewing) { MealDetailView(meal: $0) }
    }
}
