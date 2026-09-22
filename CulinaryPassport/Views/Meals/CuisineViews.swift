import SwiftUI
import MapKit

/// One cuisine's page: its stamp, your meals of it, the restaurants you've
/// saved for it, who's had it, and where friends ate it.
struct CuisineSheet: View {
    let code: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var viewing: Meal?
    @State private var logging = false
    @State private var finding = false
    @State private var loggingAt: SavedPlace?
    @State private var editingPlace: SavedPlace?
    @State private var friendMeals: [Meal] = []
    @State private var confirmRemove = false

    private var meals: [Meal] { app.mealsByCountry[code] ?? [] }
    private var saved: [SavedPlace] { app.restaurantsByCuisine[code] ?? [] }
    private var taste: Taste? { app.tastesByCode[code] }
    private var country: Country? { CountryStore.byCode[code] }

    private var whoHasHadIt: [Profile] {
        app.networkIds.filter { app.peopleTastes[$0]?.contains(code) == true }
            .compactMap { app.profile($0) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        StampBadge(code: code, subtitle: taste?.yearsText, size: 112, inked: taste != nil, tasted: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Cuisine.name(for: code)).font(.display).foregroundStyle(Color.ink)
                            if let country {
                                Text("\(country.flag) \(country.name) · \(country.continent.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(Color.inkSecondary)
                            }
                            Text(taste == nil ? "Not tried yet"
                                 : meals.isEmpty ? "Tasted" : "Tasted · \(meals.count.counted("meal"))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(taste == nil ? Color.inkSecondary : Color.brand)
                        }
                    }

                    HStack(spacing: 10) {
                        Button { finding = true } label: {
                            Label("Find it near me", systemImage: "map")
                        }
                        .buttonStyle(.primary)
                        Button { logging = true } label: {
                            Label("Log", systemImage: "fork.knife")
                        }
                        .buttonStyle(SecondaryButtonStyle(fullWidth: false))
                    }

                    if !meals.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("Your plates", subtitle: meals.count.counted("meal"))
                            PlateStack(columns: 3, spacing: 10) {
                                ForEach(meals) { meal in
                                    Button { viewing = meal } label: { MealPlate(meal: meal, showsFlag: false) }
                                        .buttonStyle(PressScale())
                                }
                            }
                        }
                    }

                    if !saved.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("Restaurants to try", subtitle: saved.count.counted("place"))
                            ForEach(saved) { place in
                                RestaurantTag(place: place, onLog: { loggingAt = place }, onEdit: { editingPlace = place })
                            }
                        }
                    }

                    if !whoHasHadIt.isEmpty {
                        HStack(spacing: 10) {
                            FacePile(profiles: whoHasHadIt, size: 30, limit: 5)
                            Text(whoText)
                                .font(.subheadline)
                                .foregroundStyle(Color.ink)
                        }
                    }

                    if !friendMeals.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("Where friends ate it", subtitle: "Save one to try")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(friendMeals) { meal in
                                        FriendMealPlate(meal: meal) { viewing = meal }
                                    }
                                }
                                .padding(.horizontal, 2)
                                .padding(.vertical, 4)
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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if taste == nil {
                            Button { Task { await markTasted() } } label: {
                                Label("I've had it", systemImage: "checkmark.seal")
                            }
                        } else if meals.isEmpty {
                            Button(role: .destructive) { confirmRemove = true } label: {
                                Label("Remove the stamp", systemImage: "minus.circle")
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(taste != nil && !meals.isEmpty)
                }
            }
            .confirmationDialog("Remove \(Cuisine.name(for: code)) from your passport?", isPresented: $confirmRemove,
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
            .sheet(item: $viewing) { MealDetailView(meal: $0) }
            .sheet(isPresented: $logging) { MealEditorView(mode: .new(cuisine: code, place: nil)) }
            .sheet(isPresented: $finding) { SpinResultSheet(code: code, tableId: nil) }
            .sheet(item: $loggingAt) { LogAtPlaceSheet(place: $0) }
            .sheet(item: $editingPlace) { RestaurantEditorSheet(place: $0) }
            .task { await load() }
        }
    }

    private var whoText: String {
        let names = whoHasHadIt.map(\.firstName)
        switch names.count {
        case 1: return "\(names[0]) has had it"
        case 2: return "\(names[0]) and \(names[1]) have had it"
        default: return "\(names[0]), \(names[1]) and \((names.count - 2).counted("other")) have had it"
        }
    }

    private func load() async {
        let ids = Array(app.networkIds)
        guard !ids.isEmpty, let found = try? await app.backend.meals(countryCode: code, userIds: ids) else { return }
        _ = await app.profiles(for: found.map(\.userId))
        friendMeals = Array(found.filter { !app.blocked.contains($0.userId) }.prefix(12))
    }

    private func markTasted() async {
        do {
            try await app.addTastes([code])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            app.show(error)
        }
    }
}

/// A friend's meal as a restaurant you could save: the plate, what it was,
/// who ate it.
struct FriendMealPlate: View {
    let meal: Meal
    let onOpen: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                MealPlate(meal: meal, size: 128, showsFlag: false)
                    .overlay(alignment: .topLeading) {
                        AvatarView(profile: app.profile(meal.userId), size: 30)
                            .overlay(Circle().strokeBorder(Color.card, lineWidth: 2))
                    }
            }
            .buttonStyle(PressScale())
            Text(meal.restaurantName.isEmpty ? meal.displayTitle : meal.restaurantName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(app.profile(meal.userId)?.firstName ?? "A friend")
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SavePlaceButton(meal: meal)
            }
        }
        .frame(width: 136)
    }
}

/// "Which cuisines have you tried?" — every cuisine as a plate with its
/// flag; tap the ones you've had and they're inked. Popular ones first, the
/// rest continent by continent.
struct CuisineChecklistView: View {
    var onDone: () -> Void
    /// Onboarding embeds the grid without its own save button.
    var embedded = false
    @Binding var picked: Set<String>

    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var ownChecked: Set<String> = []
    @State private var loaded = false
    @State private var saving = false
    @State private var celebrate: [String]?

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        _picked = .constant([])
    }

    init(picked: Binding<Set<String>>) {
        onDone = {}
        embedded = true
        _picked = picked
    }

    private var checked: Set<String> { embedded ? picked : ownChecked }
    private var added: [String] { checked.subtracting(app.tastedCodes).sorted() }

    private var popular: [String] {
        Cuisine.dicePool.filter { query.isEmpty || Cuisine.matches($0, query) }
            .sorted { Cuisine.name(for: $0) < Cuisine.name(for: $1) }
    }

    var body: some View {
        SwiftUI.Group {
            if embedded {
                grid
            } else {
                ScrollView { grid.padding(Metrics.gutter) }
                    .paperBackground()
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: "Cuisine or dish")
                    .navigationTitle("What have you eaten?")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(saving ? "Saving…" : "Save") { Task { await save() } }
                                .fontWeight(.semibold)
                                .disabled(saving || added.isEmpty)
                        }
                    }
            }
        }
        .onAppear {
            guard !loaded else { return }
            if embedded { picked.formUnion(app.tastedCodes) } else { ownChecked = app.tastedCodes }
            loaded = true
        }
        .fullScreenCover(item: Binding(
            get: { celebrate.map { StampBurst(codes: $0) } },
            set: { if $0 == nil { celebrate = nil } }
        )) { burst in
            StampMomentView(codes: burst.codes, tasted: true) { onDone() }
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text(checked.count.counted("cuisine"))
                    .font(.number(.title2))
                    .contentTransition(.numericText())
                Text("· \(FoodStats.percentText(checked.count)) of the world")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
                Spacer()
            }
            .animation(.snappy, value: checked.count)
            if !popular.isEmpty {
                section(query.isEmpty ? "Most people have tried" : "Popular", popular)
            }
            ForEach(FoodStats.continents) { continent in
                let codes = Cuisine.codes.filter {
                    CountryStore.byCode[$0]?.continent == continent && !Cuisine.dicePool.contains($0)
                        && (query.isEmpty || Cuisine.matches($0, query))
                }
                if !codes.isEmpty { section(continent.rawValue, codes) }
            }
        }
    }

    private func section(_ title: String, _ codes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 14) {
                ForEach(codes, id: \.self) { code in
                    CuisineChip(code: code, checked: checked.contains(code)) { toggle(code) }
                }
            }
        }
    }

    private func toggle(_ code: String) {
        let isChecked = checked.contains(code)
        if isChecked, !(app.mealsByCountry[code] ?? []).isEmpty {
            app.toast = Toast(message: "You've logged \(Cuisine.name(for: code)) meals — they keep it tasted.")
            return
        }
        // Only fresh ticks come off here; removing a stamp lives on its page.
        if isChecked, app.tastedCodes.contains(code) { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            if embedded {
                if isChecked { picked.remove(code) } else { picked.insert(code) }
            } else {
                if isChecked { ownChecked.remove(code) } else { ownChecked.insert(code) }
            }
        }
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

/// One cuisine to tick: its flag on a plate, inked with a stamp once tried.
struct CuisineChip: View {
    let code: String
    let checked: Bool
    let action: () -> Void

    private var ink: Color { StampInk.color(for: code) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Plate(rim: 0.2, band: checked ? ink.opacity(0.6) : .clear, shadow: checked) {
                        Text(Country.flag(for: code))
                            .font(.system(size: 26))
                            .opacity(checked ? 1 : 0.75)
                    }
                    if checked {
                        Circle()
                            .strokeBorder(ink, lineWidth: 2.5)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(ink, in: Circle())
                            .offset(x: 22, y: -22)
                    }
                }
                .frame(width: 62, height: 62)
                .rotationEffect(.degrees(checked ? StampInk.tilt(for: code) : 0))
                .scaleEffect(checked ? 1.04 : 1)
                Text(Cuisine.name(for: code))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(checked ? Color.ink : Color.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Cuisine.name(for: code))
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// One continent: what you've tasted, and what's still waiting.
struct ContinentSheet: View {
    let continent: Continent

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var cuisine: CuisineRef?

    private var codes: [String] {
        Cuisine.codes.filter { CountryStore.byCode[$0]?.continent == continent }
    }

    var body: some View {
        let tasted = codes.filter(app.tastedCodes.contains)
        let waiting = codes.filter { !app.tastedCodes.contains($0) }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        ContinentPlate(continent: continent,
                                       progress: app.stats.continentProgress[continent] ?? .init(tasted: 0, total: 0),
                                       tint: Color(hex: app.me?.color ?? "#2f5a45", fallback: Palette.brand))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(continent.rawValue).font(.display).foregroundStyle(Color.ink)
                            Text("\(tasted.count) of \(codes.count) cuisines tasted")
                                .font(.subheadline)
                                .foregroundStyle(Color.inkSecondary)
                        }
                    }
                    if !tasted.isEmpty { grid("Tasted", tasted, inked: true) }
                    if !waiting.isEmpty { grid("Still to taste", waiting, inked: false) }
                }
                .padding(Metrics.gutter)
            }
            .paperBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $cuisine) { CuisineSheet(code: $0.code) }
        }
    }

    private func grid(_ title: String, _ codes: [String], inked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "\(title) · \(codes.count)")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 10) {
                ForEach(codes, id: \.self) { code in
                    Button { cuisine = CuisineRef(code: code) } label: {
                        StampBadge(code: code, size: 96, inked: inked, tasted: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// ── Restaurants to try ──────────────────────────────────────────────────────

/// A restaurant you've saved, as a tag on a string.
struct RestaurantTag: View {
    let place: SavedPlace
    var onLog: () -> Void
    var onEdit: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                Task {
                    do { try await app.updatePlace(place, done: !place.done) } catch { app.show(error) }
                }
            } label: {
                Image(systemName: place.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(place.done ? Color.brand : Color.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(place.done ? "Been" : "Mark as been")

            VStack(alignment: .leading, spacing: 2) {
                Text(place.displayTitle)
                    .font(.headline)
                    .foregroundStyle(place.done ? Color.inkTertiary : Color.ink)
                    .strikethrough(place.done, color: Color.inkTertiary)
                Text(place.cuisineLine)
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                if !place.note.isEmpty {
                    Text(place.note)
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)

            Menu {
                if let lat = place.lat, let lng = place.lng {
                    Button {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)))
                        item.name = place.title
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle")
                    }
                }
                Button(action: onLog) { Label("I ate here — log it", systemImage: "fork.knife") }
                Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) {
                    Task {
                        do { try await app.deletePlace(place) } catch { app.show(error) }
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.inkTertiary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .padding(.leading, 34)
        .padding(.trailing, 6)
        .padding(.vertical, 11)
        .background(Color.card, in: LuggageTagShape())
        .overlay { LuggageTagShape().strokeBorder(Color.hairline.opacity(0.8), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

struct RestaurantEditorSheet: View {
    let place: SavedPlace

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var city = ""
    @State private var note = ""
    @State private var saving = false
    @State private var prepared = false

    var body: some View {
        NavigationStack {
            List {
                Section("Restaurant") {
                    TextField("Name", text: $title)
                        .autocorrectionDisabled()
                        .listRowBackground(Color.card)
                    TextField("City", text: $city)
                        .autocorrectionDisabled()
                        .listRowBackground(Color.card)
                }
                Section("Note") {
                    TextField("What to order, who recommended it", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                        .listRowBackground(Color.card)
                }
            }
            .paperListStyle()
            .navigationTitle(place.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await app.updatePlace(place, title: title, city: city, note: note)
                                dismiss()
                            } catch {
                                app.show(error)
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(saving)
                }
            }
            .task {
                guard !prepared else { return }
                prepared = true
                title = place.title
                city = place.city
                note = place.note
            }
        }
    }
}
