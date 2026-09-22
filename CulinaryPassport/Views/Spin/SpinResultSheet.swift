import SwiftUI
import MapKit

/// Where the spin landed, and who serves it near you: a map on a plate with
/// the restaurants pinned, and a ticket for each — directions, save it, put
/// it to your table, or log the meal once you've eaten.
struct SpinResultSheet: View {
    let code: String
    /// Spinning for a table: everyone's tastes count, and picks go to its chat.
    var tableId: UUID?
    /// Offered after a spin (not when browsing one cuisine).
    var onSpinAgain: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var places: [MKMapItem] = []
    @State private var searching = true
    @State private var here: CLLocation?
    @State private var locationOff = false
    @State private var current: Int?
    /// Automatic frames every pin and you; swiping a ticket zooms to it.
    @State private var camera: MapCameraPosition = .automatic
    @State private var logging: LogRequest?
    @State private var saved: Set<String> = []
    @State private var sent: [String: Set<UUID>] = [:]
    @State private var spinShared = false
    @State private var friendMeals: [Meal] = []

    private var table: Group? { tableId.flatMap { id in app.groups.first { $0.id == id } } }
    private var eaters: [UUID] { app.eaters(at: tableId) }
    private var ink: Color { StampInk.color(for: code) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    mapPlate
                        .padding(.horizontal, 22)
                    tickets
                }
                .padding(.vertical, 12)
                .padding(.bottom, 20)
            }
            .paperBackground()
            .navigationTitle(onSpinAgain == nil ? "Near you" : "Tonight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(item: $logging) { request in
                MealEditorView(mode: .new(cuisine: code, place: request.place))
            }
            .task { await load() }
        }
        .presentationDragIndicator(.visible)
    }

    // ── What it landed on ────────────────────────────────────────────────────

    private var header: some View {
        HStack(spacing: 14) {
            StampBadge(code: code, size: 92, inked: app.tastedCodes.contains(code), tasted: true)
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: onSpinAgain == nil ? "Find it tonight" : "The globe says", color: ink)
                Text("\(Country.flag(for: code)) \(Cuisine.name(for: code))")
                    .font(.display)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(whoHasHadIt)
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let table {
                    Button {
                        Task { await shareSpin(to: table) }
                    } label: {
                        Label(spinShared ? "Told \(table.name)" : "Tell \(table.name)",
                              systemImage: spinShared ? "checkmark" : "bubble.left.and.bubble.right.fill")
                    }
                    .buttonStyle(.capsuleProminent)
                    .disabled(spinShared)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var whoHasHadIt: String {
        let had = eaters.filter { app.tasted(by: [$0]).contains(code) }
        if had.isEmpty {
            return table == nil ? "You haven't tried it yet — its stamp is one dinner away."
                                : "None of you has had it yet."
        }
        guard table != nil else {
            let meals = app.mealsByCountry[code]?.count ?? 0
            return meals > 0 ? "You've had it \(meals.counted("time")). Somewhere new?" : "You've had it before."
        }
        let names = had.compactMap { $0 == app.myId ? "You" : app.profile($0)?.firstName }
        return "\(ListFormatter.localizedString(byJoining: names)) \(had.count == 1 && names.first != "You" ? "has" : "have") had it — lead the way."
    }

    // ── The map, served ──────────────────────────────────────────────────────

    @ViewBuilder private var mapPlate: some View {
        Plate(rim: 0.09, band: ink.opacity(0.4)) {
            if locationOff || (!searching && places.isEmpty) {
                ZStack {
                    ink.opacity(0.1)
                    VStack(spacing: 10) {
                        Text(Country.flag(for: code)).font(.system(size: 56))
                        Text(locationOff ? "Turn on location to see places near you."
                                         : "Nothing \(Cuisine.name(for: code)) close by.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button { openMapsSearch() } label: {
                            Label("Search Apple Maps", systemImage: "map")
                        }
                        .buttonStyle(.capsule)
                    }
                }
            } else {
                Map(position: $camera, interactionModes: [.pan, .zoom]) {
                    UserAnnotation()
                    ForEach(Array(places.enumerated()), id: \.offset) { index, item in
                        Annotation(item.name ?? "", coordinate: item.placemark.coordinate, anchor: .bottom) {
                            Button { select(index) } label: {
                                RestaurantPin(number: index + 1, ink: ink, selected: (current ?? 0) == index)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(index + 1), \(item.name ?? "Restaurant")")
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                // A round map clips its corners, where Apple Maps puts its
                // logo and Legal link — and where framing would put pins.
                // Pad both into the square the circle can show.
                .safeAreaPadding(48)
                .overlay {
                    if searching {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Looking for \(Cuisine.name(for: code)) food…")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.inkSecondary)
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
        .frame(maxWidth: 380)
    }

    // ── One ticket per restaurant ────────────────────────────────────────────

    @ViewBuilder private var tickets: some View {
        if searching {
            TicketCard(stubWidth: 78) {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock().frame(width: 60, height: 10)
                    SkeletonBlock().frame(height: 18)
                    SkeletonBlock().frame(width: 150, height: 12)
                }
            } stub: {
                SkeletonBlock(cornerRadius: 8).frame(width: 36, height: 36)
            }
            .frame(height: 136)
            .padding(.horizontal, 22)
        } else if !places.isEmpty {
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(places.enumerated()), id: \.offset) { index, item in
                            RestaurantTicket(
                                number: index + 1,
                                item: item,
                                ink: ink,
                                distance: distance(to: item),
                                friends: friends(at: item),
                                isSaved: saved.contains(key(item)),
                                table: table,
                                otherTables: table == nil ? app.groups : [],
                                sentTo: sent[key(item)] ?? [],
                                onDirections: { directions(to: item) },
                                onSave: { Task { await save(item) } },
                                onSend: { group in Task { await suggest(item, to: group) } },
                                onAte: { logging = LogRequest(place: place(of: item)) }
                            )
                            .containerRelativeFrame(.horizontal) { length, _ in length - 44 }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 22, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $current)
                .onChange(of: current) { old, index in
                    // The first ticket arriving isn't a choice: keep the overview.
                    guard old != nil, let index, places.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        camera = .region(MKCoordinateRegion(center: places[index].placemark.coordinate,
                                                            latitudinalMeters: 2400, longitudinalMeters: 2400))
                    }
                }

                HStack(spacing: 5) {
                    ForEach(places.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == (current ?? 0) ? ink : Color.hairline)
                            .frame(width: index == (current ?? 0) ? 14 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: current)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if let onSpinAgain {
            Button(action: onSpinAgain) {
                Label("Spin again", systemImage: "arrow.trianglehead.2.clockwise")
            }
            .buttonStyle(.secondary)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func load() async {
        async let found: Void = findPlaces()
        async let meals: Void = loadFriendMeals()
        _ = await (found, meals)
    }

    private func findPlaces() async {
        searching = true
        defer { searching = false }
        if here == nil { here = await NearMe.shared.location() }
        guard let here else {
            locationOff = true
            return
        }
        locationOff = false
        let found = await PlaceSearch.restaurants(serving: code, near: here.coordinate)
        places = found
        current = found.isEmpty ? nil : 0
        camera = .automatic
        app.backend.logEvent("spin_places", props: ["cuisine": code, "count": String(found.count)])
    }

    private func loadFriendMeals() async {
        let ids = Array(app.networkIds)
        guard !ids.isEmpty, let found = try? await app.backend.meals(countryCode: code, userIds: ids) else { return }
        _ = await app.profiles(for: found.map(\.userId))
        friendMeals = found.filter { !app.blocked.contains($0.userId) }
    }

    private func select(_ index: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy) { current = index }
    }

    /// Friends who've eaten at this restaurant: same name, or right there.
    private func friends(at item: MKMapItem) -> [Profile] {
        let name = (item.name ?? "").trimmed.lowercased()
        let there = item.placemark.location
        let ids = Set(friendMeals.filter { meal in
            if !name.isEmpty, meal.restaurantName.trimmed.lowercased() == name { return true }
            guard let there, let lat = meal.lat, let lng = meal.lng else { return false }
            return there.distance(from: CLLocation(latitude: lat, longitude: lng)) < 60
        }.map(\.userId))
        return ids.compactMap { app.profile($0) }.sorted { $0.name < $1.name }
    }

    private func distance(to item: MKMapItem) -> String? {
        guard let here, let there = item.placemark.location else { return nil }
        let meters = Measurement(value: there.distance(from: here), unit: UnitLength.meters)
        return meters.formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func key(_ item: MKMapItem) -> String {
        "\(item.name ?? "")|\(item.placemark.coordinate.latitude)|\(item.placemark.coordinate.longitude)"
    }

    private func place(of item: MKMapItem) -> PlaceResult {
        PlaceResult(title: item.name ?? "", city: item.placemark.locality ?? "",
                    countryCode: item.placemark.isoCountryCode,
                    latitude: item.placemark.coordinate.latitude,
                    longitude: item.placemark.coordinate.longitude)
    }

    private func pick(for item: MKMapItem) -> DinnerPick {
        DinnerPick(cuisineCode: code, placeName: item.name, placeAddress: Self.address(of: item),
                   placeLat: item.placemark.coordinate.latitude, placeLng: item.placemark.coordinate.longitude)
    }

    private func directions(to item: MKMapItem) {
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }

    /// A restaurant to try, kept under its cuisine.
    private func save(_ item: MKMapItem) async {
        let place = place(of: item)
        let where_ = place.countryCode ?? place.latitude.flatMap { lat in
            place.longitude.flatMap { PlaceLocator.country(lat: lat, lng: $0) }
        }
        do {
            try await app.savePlace(countryCode: where_ ?? app.me?.homeCountry ?? code, title: place.title,
                                    city: place.city, lat: place.latitude, lng: place.longitude,
                                    note: onSpinAgain == nil ? "" : "From a spin", cuisine: code)
            saved.insert(key(item))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.celebrate("Saved \(place.title)")
        } catch {
            app.show(error)
        }
    }

    private func suggest(_ item: MKMapItem, to group: Group) async {
        do {
            try await app.postPick(pick(for: item), to: group.id)
            sent[key(item), default: []].insert(group.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.celebrate("Sent to \(group.name)")
        } catch {
            app.show(error)
        }
    }

    private func shareSpin(to group: Group) async {
        do {
            try await app.postPick(DinnerPick(cuisineCode: code), to: group.id)
            spinShared = true
            app.celebrate("Told \(group.name)")
        } catch {
            app.show(error)
        }
    }

    private func openMapsSearch() {
        var components = URLComponents(string: "maps://")
        components?.queryItems = [URLQueryItem(name: "q", value: "\(Cuisine.name(for: code)) restaurant")]
        if let url = components?.url { openURL(url) }
    }

    static func address(of item: MKMapItem) -> String? {
        let mark = item.placemark
        let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street.isEmpty ? nil : street, mark.locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private struct LogRequest: Identifiable {
        let place: PlaceResult
        var id: String { "\(place.title)|\(place.latitude ?? 0)" }
    }
}

/// A numbered pin in the cuisine's ink; the one on the ticket in view grows.
struct RestaurantPin: View {
    let number: Int
    let ink: Color
    var selected = false

    var body: some View {
        VStack(spacing: -3) {
            Text("\(number)")
                .font(.system(size: selected ? 15 : 12, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: selected ? 34 : 26, height: selected ? 34 : 26)
                .background(ink, in: Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            Image(systemName: "triangle.fill")
                .font(.system(size: selected ? 10 : 8))
                .foregroundStyle(ink)
                .rotationEffect(.degrees(180))
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: selected)
    }
}

/// Tonight's ticket: the restaurant on the ticket, how far on the stub.
struct RestaurantTicket: View {
    let number: Int
    let item: MKMapItem
    let ink: Color
    let distance: String?
    let friends: [Profile]
    let isSaved: Bool
    /// The table this spin is for, if any.
    let table: Group?
    /// Tables it could go to, for a spin of your own.
    let otherTables: [Group]
    let sentTo: Set<UUID>
    let onDirections: () -> Void
    let onSave: () -> Void
    let onSend: (Group) -> Void
    let onAte: () -> Void

    private var distanceParts: (value: String, unit: String)? {
        guard let distance else { return nil }
        let parts = distance.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1].uppercased()) : (distance, "")
    }

    var body: some View {
        TicketCard(stubWidth: 78, stubTint: ink.opacity(0.12)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Nº \(number)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(ink)
                    if let first = friends.first {
                        AvatarStack(profiles: friends, size: 16, max: 3)
                        Text(friends.count == 1 ? "\(first.firstName) ate here" : "\(friends.count) friends ate here")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(1)
                    }
                }
                Text(item.name ?? "Restaurant")
                    .font(.displayXSmall)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let address = SpinResultSheet.address(of: item) {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                }
                // One worded action — the one that matters here — and the
                // rest as round buttons, so the row never wraps.
                HStack(spacing: 6) {
                    if let table {
                        let done = sentTo.contains(table.id)
                        chip(done ? "Sent" : "Suggest", done ? "checkmark" : "paperplane.fill", on: done) { onSend(table) }
                            .disabled(done)
                            .accessibilityLabel(done ? "Suggested to \(table.name)" : "Suggest to \(table.name)")
                        round("fork.knife", on: false, label: "I ate here — log it", action: onAte)
                    } else {
                        chip("Ate here", "fork.knife", on: false, action: onAte)
                            .accessibilityLabel("I ate here — log it")
                        if !otherTables.isEmpty {
                            Menu {
                                Section("Suggest to a table") {
                                    ForEach(otherTables) { group in
                                        Button { onSend(group) } label: {
                                            Label(group.name, systemImage: sentTo.contains(group.id) ? "checkmark" : "person.3")
                                        }
                                        .disabled(sentTo.contains(group.id))
                                    }
                                }
                            } label: {
                                roundLabel(sentTo.isEmpty ? "paperplane" : "checkmark", on: !sentTo.isEmpty)
                            }
                            .accessibilityLabel("Suggest to a table")
                        }
                    }
                    round(isSaved ? "bookmark.fill" : "bookmark", on: isSaved,
                          label: isSaved ? "Saved to try" : "Save to try", action: onSave)
                        .disabled(isSaved)
                }
                .padding(.top, 2)
            }
        } stub: {
            Button(action: onDirections) {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(ink)
                    if let parts = distanceParts {
                        Text(parts.value)
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.ink)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text(parts.unit)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Color.inkTertiary)
                    }
                    Text("GO")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(ink)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Directions\(distance.map { ", \($0)" } ?? "")")
        }
    }

    private func chip(_ title: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, icon, on: on) }
            .buttonStyle(.plain)
    }

    private func round(_ icon: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(icon, on: on) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func roundLabel(_ icon: String, on: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(on ? Color.brand : Color.ink)
            .frame(width: 32, height: 32)
            .background(on ? Color.brandSoft : Color.sunken, in: Circle())
    }

    private func chipLabel(_ title: String, _ icon: String, on: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(on ? Color.brand : Color.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(on ? Color.brandSoft : Color.sunken, in: Capsule())
            .fixedSize()
    }
}
