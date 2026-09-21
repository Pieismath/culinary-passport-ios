import SwiftUI
import MapKit

/// "What's for dinner?" — the weekly reason to open the app. Rolls a cuisine
/// you haven't tasted (none of you, for a group), then shows who serves it
/// near you. The everyday version of spinning the globe.
struct DinnerDiceSheet: View {
    /// Other people whose tastes count too — a group rolling together.
    var people: [UUID] = []
    /// Where it lands, so the globe behind can turn to it.
    var onLanded: (String) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var theirs: Set<String> = []
    @State private var face: String?
    @State private var landed: String?
    @State private var rolling = false
    @State private var places: [MKMapItem] = []
    @State private var searching = false
    @State private var here: CLLocation?
    @State private var locationOff = false
    @State private var logging: PlaceResult?
    @State private var savedNames: Set<String> = []

    private var untasted: [String] {
        Cuisine.dinnerPool(tastedByTable: app.tastedCodes.union(theirs), tastedByMe: app.tastedCodes)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    stamp
                    if let landed, !rolling {
                        restaurants(for: landed)
                    }
                }
                .padding(Metrics.gutter)
                .padding(.bottom, 24)
            }
            .paperBackground()
            .navigationTitle("What's for dinner?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await roll() }
                } label: {
                    Label(landed == nil ? "Roll" : "Roll again", systemImage: "dice")
                }
                .buttonStyle(.primary)
                .disabled(rolling)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .sheet(item: Binding(get: { logging.map(LogRequest.init) }, set: { if $0 == nil { logging = nil } })) {
                MealEditorView(mode: .new(cuisine: landed, place: $0.place))
            }
            .task { await start() }
        }
    }

    // ── The stamp you're rolling for ─────────────────────────────────────────

    private var stamp: some View {
        VStack(spacing: 14) {
            ZStack {
                if let code = face ?? landed {
                    // Not yours yet: a ghost stamp, dashed, waiting for ink.
                    StampBadge(code: code, size: 170, inked: false, tasted: true)
                        .id(code)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    Image(systemName: "dice")
                        .font(.system(size: 60, weight: .light))
                        .foregroundStyle(Color.inkTertiary)
                        .frame(width: 170, height: 170)
                }
            }
            .animation(.snappy(duration: 0.12), value: face)
            .padding(.top, 10)

            VStack(spacing: 6) {
                if let landed, !rolling {
                    Eyebrow(text: "Tonight", color: .brand)
                    Text("\(Country.flag(for: landed)) \(Cuisine.name(for: landed))")
                        .font(.display)
                        .foregroundStyle(Color.ink)
                    Text(people.isEmpty ? "You haven't tried it yet. Its stamp is one dinner away."
                                        : "None of you has tried it yet.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                } else if rolling {
                    Text("Rolling…")
                        .font(.headline)
                        .foregroundStyle(Color.inkSecondary)
                } else {
                    Text("A cuisine you haven't tried, and where to find it tonight.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // ── Where to get it ──────────────────────────────────────────────────────

    @ViewBuilder private func restaurants(for code: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Near you", subtitle: searching ? "Looking…" : places.isEmpty ? nil : places.count.counted("place"))
            if searching {
                ForEach(0..<3, id: \.self) { _ in SkeletonBlock().frame(height: 62) }
            } else if locationOff {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Turn on location to see places near you — or look in Maps.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                    Button { openMapsSearch(code) } label: {
                        Label("Search Maps for \(Cuisine.name(for: code)) food", systemImage: "map")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .card(padding: 14)
            } else if places.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nothing \(Cuisine.name(for: code)) close by. Roll again, or try further out.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                    Button { openMapsSearch(code) } label: {
                        Label("Search Maps", systemImage: "map")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .card(padding: 14)
            } else {
                ForEach(places, id: \.self) { item in
                    placeRow(item)
                }
            }
        }
    }

    private func placeRow(_ item: MKMapItem) -> some View {
        let name = item.name ?? "Restaurant"
        let saved = savedNames.contains(name)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline).foregroundStyle(Color.ink).lineLimit(1)
                Text([distance(to: item), item.placemark.thoroughfare ?? item.placemark.locality]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Menu {
                Button { item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault]) } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle")
                }
                Button { Task { await save(item) } } label: {
                    Label(saved ? "Saved" : "Save for later", systemImage: saved ? "bookmark.fill" : "bookmark")
                }
                .disabled(saved)
                Button { logging = place(of: item) } label: {
                    Label("I ate here — log it", systemImage: "fork.knife")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.brand)
            }
            .accessibilityLabel("Options for \(name)")
        }
        .padding(.leading, 34)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(Color.card, in: LuggageTagShape())
        .overlay { LuggageTagShape().strokeBorder(Color.hairline.opacity(0.8), lineWidth: 0.5) }
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func start() async {
        if !people.isEmpty, let found = try? await app.backend.tastes(userIds: people) {
            theirs = Set(found.map(\.countryCode))
        }
        await roll()
    }

    private func roll() async {
        guard !rolling else { return }
        rolling = true
        places = []
        let pool = untasted
        guard let pick = pool.randomElement() else {
            rolling = false
            return
        }
        // A slot machine that slows down before it lands.
        for delay in [70, 70, 80, 90, 100, 120, 150, 190, 240] {
            face = pool.randomElement()
            UISelectionFeedbackGenerator().selectionChanged()
            try? await Task.sleep(for: .milliseconds(delay))
        }
        face = nil
        landed = pick
        rolling = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        app.backend.logEvent("dinner_rolled", props: ["cuisine": pick, "group": String(!people.isEmpty)])
        onLanded(pick)
        await findPlaces(for: pick)
    }

    private func findPlaces(for code: String) async {
        searching = true
        defer { searching = false }
        if here == nil { here = await NearMe.shared.location() }
        guard let here else {
            locationOff = true
            return
        }
        locationOff = false
        let found = await PlaceSearch.restaurants(serving: code, near: here.coordinate)
        guard landed == code else { return }       // rolled again meanwhile
        places = found
    }

    private func distance(to item: MKMapItem) -> String? {
        guard let here, let there = item.placemark.location else { return nil }
        let meters = Measurement(value: there.distance(from: here), unit: UnitLength.meters)
        return meters.formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func place(of item: MKMapItem) -> PlaceResult {
        PlaceResult(title: item.name ?? "", city: item.placemark.locality ?? "",
                    countryCode: item.placemark.isoCountryCode,
                    latitude: item.placemark.coordinate.latitude,
                    longitude: item.placemark.coordinate.longitude)
    }

    /// A restaurant to try, kept on your list under its cuisine.
    private func save(_ item: MKMapItem) async {
        guard let landed else { return }
        let place = place(of: item)
        let here = place.countryCode ?? place.latitude.flatMap { lat in
            place.longitude.flatMap { PlaceLocator.country(lat: lat, lng: $0) }
        }
        do {
            try await app.savePlace(countryCode: here ?? app.me?.homeCountry ?? landed, title: place.title,
                                    city: place.city, lat: place.latitude, lng: place.longitude,
                                    note: "From a dinner roll", cuisine: landed)
            savedNames.insert(place.title)
            app.celebrate("Saved \(place.title)")
        } catch {
            app.show(error)
        }
    }

    private func openMapsSearch(_ code: String) {
        let query = "\(Cuisine.name(for: code)) restaurant"
        var components = URLComponents(string: "maps://")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = components?.url { openURL(url) }
    }

    private struct LogRequest: Identifiable {
        let place: PlaceResult
        var id: String { "\(place.title)|\(place.latitude ?? 0)" }
    }
}

/// "Which cuisines have you tried?" — the fastest way to fill the Tasted half
/// of a new passport. Popular cuisines first, everything else by continent.
struct CuisineChecklistView: View {
    var onDone: () -> Void

    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var checked: Set<String> = []
    @State private var loaded = false
    @State private var saving = false
    @State private var celebrate: [String]?

    private var added: [String] { checked.subtracting(app.tastedCodes).sorted() }

    private var popular: [String] {
        Cuisine.dicePool.sorted { Cuisine.name(for: $0) < Cuisine.name(for: $1) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(checked.count.counted("cuisine"))
                            .font(.number(.title2))
                            .contentTransition(.numericText())
                        Text("tasted · tap the ones you've tried")
                            .font(.caption)
                            .foregroundStyle(Color.inkSecondary)
                    }
                    Spacer()
                    Image(systemName: "fork.knife.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.brand)
                }
                .listRowBackground(Color.card)
            }
            if query.isEmpty {
                Section("Most people have tried") {
                    ForEach(popular, id: \.self) { row($0) }
                }
            }
            ForEach(Continent.allCases.filter { $0 != .antarctica }) { continent in
                let codes = Cuisine.codes.filter {
                    CountryStore.byCode[$0]?.continent == continent
                        && (query.isEmpty ? !Cuisine.dicePool.contains($0) : Cuisine.matches($0, query))
                }
                if !codes.isEmpty {
                    Section(continent.rawValue) {
                        ForEach(codes, id: \.self) { row($0) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .paperListStyle()
        .animation(.snappy, value: checked)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Cuisine or dish")
        .navigationTitle("What have you tasted?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(saving || added.isEmpty)
            }
        }
        .onAppear {
            guard !loaded else { return }
            checked = app.tastedCodes
            loaded = true
        }
        .fullScreenCover(item: Binding(
            get: { celebrate.map { StampBurst(codes: $0) } },
            set: { if $0 == nil { celebrate = nil } }
        )) { burst in
            StampMomentView(codes: burst.codes, tasted: true) { onDone() }
        }
    }

    private func row(_ code: String) -> some View {
        let isChecked = checked.contains(code)
        let hasMeals = !(app.mealsByCountry[code] ?? []).isEmpty
        return Button {
            guard !(hasMeals && isChecked) else {
                app.toast = Toast(message: "You've logged \(Cuisine.name(for: code)) meals — they keep it tasted.")
                return
            }
            UISelectionFeedbackGenerator().selectionChanged()
            if isChecked {
                // Only fresh ticks can be undone here; removing an existing
                // taste lives on the country's page.
                if !app.tastedCodes.contains(code) { checked.remove(code) }
            } else {
                checked.insert(code)
            }
        } label: {
            HStack(spacing: 12) {
                Text(Country.flag(for: code)).font(.title2)
                Text(Cuisine.name(for: code)).foregroundStyle(Color.ink)
                Spacer()
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? Color.brand : Color.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.card)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }

    private func save() async {
        let fresh = added
        saving = true
        defer { saving = false }
        do {
            try await app.addTastes(fresh)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            celebrate = fresh
        } catch {
            app.show(error)
        }
    }
}

/// One cuisine's page: its stamp, your meals, the restaurants you've saved
/// for it, what friends ate, and who serves it near you.
struct CuisineSheet: View {
    let code: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var viewing: Memory?
    @State private var logging = false
    @State private var loggingAt: SavedPlace?
    @State private var editingPlace: SavedPlace?
    @State private var friendMeals: [Memory] = []
    @State private var nearby: [MKMapItem] = []
    @State private var here: CLLocation?
    @State private var confirmRemove = false

    private var meals: [Memory] { app.mealsByCountry[code] ?? [] }
    private var saved: [SavedPlace] { app.restaurantsByCuisine[code] ?? [] }
    private var taste: Taste? { app.tastesByCode[code] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        StampBadge(code: code, subtitle: taste?.yearsText, size: 110,
                                   inked: taste != nil, tasted: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Cuisine.name(for: code)).font(.display).foregroundStyle(Color.ink)
                            Text(taste == nil ? "Not tasted yet"
                                 : meals.isEmpty ? "Tasted" : meals.count.counted("meal"))
                                .font(.subheadline)
                                .foregroundStyle(Color.inkSecondary)
                        }
                    }

                    Button { logging = true } label: {
                        Label("Log \(Cuisine.withArticle(code)) meal", systemImage: "fork.knife")
                    }
                    .buttonStyle(.primary)

                    if !meals.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                            ForEach(meals) { meal in
                                Button { viewing = meal } label: { MemoryTile(memory: meal) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }

                    if !saved.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("Restaurants to try", subtitle: saved.count.counted("place"))
                            ForEach(saved) { place in
                                SavedPlaceTag(place: place, onLog: { loggingAt = place },
                                              onEdit: { editingPlace = place })
                            }
                        }
                    }

                    if !friendMeals.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("Where friends ate it", subtitle: "Save one to try")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 10) {
                                    ForEach(friendMeals) { meal in
                                        FriendPlaceCard(memory: meal) { viewing = meal }
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                    }

                    if !nearby.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("Near you", subtitle: nil)
                            ForEach(nearby.prefix(4), id: \.self) { item in
                                Button {
                                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name ?? "Restaurant").font(.headline).foregroundStyle(Color.ink)
                                            if let street = item.placemark.thoroughfare {
                                                Text(street).font(.caption).foregroundStyle(Color.inkSecondary)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(Color.brand)
                                    }
                                    .card(padding: 12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(Metrics.gutter)
                .padding(.bottom, 24)
            }
            .paperBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if taste != nil && meals.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive) { confirmRemove = true } label: {
                                Label("Remove tasted stamp", systemImage: "minus.circle")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .confirmationDialog("Remove \(Cuisine.name(for: code)) from your tastes?", isPresented: $confirmRemove,
                                titleVisibility: .visible) {
                Button("Remove stamp", role: .destructive) {
                    Task {
                        do {
                            try await app.removeTaste(code)
                            dismiss()
                        } catch {
                            app.show(error)
                        }
                    }
                }
            }
            .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
            .sheet(isPresented: $logging) { MealEditorView(mode: .new(cuisine: code, place: nil)) }
            .sheet(item: $loggingAt) { LogAtPlaceSheet(place: $0) }
            .sheet(item: $editingPlace) { SavedPlaceEditorSheet(place: $0) }
            .task { await load() }
        }
    }

    private func load() async {
        let ids = Array(app.networkIds)
        if !ids.isEmpty, let found = try? await app.backend.meals(countryCode: code, userIds: ids) {
            _ = await app.profiles(for: found.map(\.userId))
            friendMeals = Array(found.filter { !app.blocked.contains($0.userId) }.prefix(12))
        }
        if let location = await NearMe.shared.location() {
            here = location
            nearby = await PlaceSearch.restaurants(serving: code, near: location.coordinate, limit: 4)
        }
    }
}
