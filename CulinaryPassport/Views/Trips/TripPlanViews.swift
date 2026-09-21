import SwiftUI
import CoreLocation

// Planning lives in the same place as the log. A trip starts as a boarding
// pass with a countdown and a list of places; when its dates arrive, the
// memories you post fill it in; afterwards it's the chapter it always was.

// ── Trip detail ─────────────────────────────────────────────────────────────

struct TripPlanDetailSheet: View {
    let plan: TripPlan

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var addingPlace = false
    @State private var editingPlace: SavedPlace?
    @State private var loggingAt: SavedPlace?
    @State private var addingMemory = false
    @State private var confirmDelete = false
    @State private var viewing: Memory?

    private var current: TripPlan { app.tripPlans.first { $0.id == plan.id } ?? plan }
    private var isMine: Bool { current.userId == app.myId }
    private var places: [SavedPlace] { app.places(on: current) }
    private var memories: [Memory] { app.memories(on: current) }
    private var members: [Profile] {
        guard let groupId = current.groupId else { return [] }
        return app.members(of: groupId).compactMap { app.profile($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TripPlanCard(plan: current, members: members, savedCount: places.count)

                    if !current.notes.isEmpty {
                        Text(current.notes)
                            .font(.body)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card(padding: 14)
                    }

                    if let groupId = current.groupId, let group = app.groups.first(where: { $0.id == groupId }) {
                        Label("Planning with \(group.name)", systemImage: "person.2.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.inkSecondary)
                    }

                    placesSection
                    if !memories.isEmpty { memoriesSection }
                }
                .padding(Metrics.gutter)
                .padding(.bottom, 30)
            }
            .paperBackground()
            .navigationTitle(current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if isMine {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { editing = true } label: { Label("Edit trip", systemImage: "pencil") }
                            Button { addingMemory = true } label: {
                                Label("Add a memory", systemImage: "photo.badge.plus")
                            }
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Label("Delete trip", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
            .sheet(isPresented: $editing) { TripPlanEditorSheet(mode: .edit(current)) }
            .sheet(isPresented: $addingPlace) {
                // Bias the search to the first country on the trip.
                PlaceSearchSheet(near: current.countries.first.map {
                    CLLocationCoordinate2D(latitude: $0.centroid.lat, longitude: $0.centroid.lng)
                }) { result in
                    Task { await save(result) }
                }
            }
            .sheet(item: $editingPlace) { SavedPlaceEditorSheet(place: $0) }
            .sheet(item: $loggingAt) { LogAtPlaceSheet(place: $0) }
            .sheet(isPresented: $addingMemory) {
                MemoryEditorView(mode: .new(countryCode: current.countryCodes.first, pickPhotosFirst: true))
            }
            .sheet(item: $viewing) { MemoryDetailView(memory: $0) }
            .confirmationDialog("Delete \(current.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete trip", role: .destructive) {
                    Task {
                        do {
                            try await app.deleteTrip(current)
                            dismiss()
                        } catch {
                            app.show(error)
                        }
                    }
                }
            } message: {
                Text("The places you saved for it stay on your list. Memories are never deleted.")
            }
        }
    }

    @ViewBuilder private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Places", subtitle: places.isEmpty
                          ? "Save somewhere you want to go"
                          : "\(places.filter { !$0.done }.count) to go · \(places.filter(\.done).count) ticked")
            ForEach(places) { place in
                SavedPlaceTag(place: place,
                              onLog: { loggingAt = place },
                              onEdit: { editingPlace = place })
            }
            Button { addingPlace = true } label: {
                Label("Add a place", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brand)
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("From this trip", subtitle: memories.count.counted("memory", "memories"))
            ForEach(memories) { memory in
                Button { viewing = memory } label: {
                    HStack(spacing: 12) {
                        MemoryTile(memory: memory, showTitle: false)
                            .frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memory.displayTitle).font(.headline).foregroundStyle(Color.ink)
                            Text("\(memory.country?.flag ?? "") \(memory.placeLine) · \(DayFormat.pretty(memory.date))")
                                .font(.caption)
                                .foregroundStyle(Color.inkSecondary)
                        }
                        Spacer(minLength: 4)
                    }
                    .card(padding: 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func save(_ result: PlaceResult) async {
        guard let code = result.countryCode ?? current.countryCodes.first else {
            app.show(AppError("Pick a place inside a country."))
            return
        }
        do {
            try await app.savePlace(countryCode: code, title: result.title.isEmpty ? result.city : result.title,
                                    city: result.city, lat: result.latitude, lng: result.longitude,
                                    tripId: current.id)
        } catch {
            app.show(error)
        }
    }
}

// ── A saved place, as a luggage tag ─────────────────────────────────────────

struct SavedPlaceTag: View {
    let place: SavedPlace
    var onLog: (() -> Void)?
    var onEdit: (() -> Void)?

    @Environment(AppModel.self) private var app

    /// "From Hana's memory" — only when that memory (and its author) is
    /// already loaded; a saved place stands on its own otherwise.
    private var credit: String? {
        guard let id = place.sourceEntryId,
              let memory = app.memories.first(where: { $0.id == id }),
              memory.userId != app.myId,
              let name = app.profile(memory.userId)?.firstName else { return nil }
        return "From \(name)'s memory"
    }

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
            .accessibilityLabel(place.done ? "Ticked off" : "Tick off")

            VStack(alignment: .leading, spacing: 2) {
                Text(place.displayTitle)
                    .font(.headline)
                    .foregroundStyle(place.done ? Color.inkTertiary : Color.ink)
                    .strikethrough(place.done, color: Color.inkTertiary)
                Text(place.cuisineCode.map { "\(Country.flag(for: $0)) \(Cuisine.name(for: $0)) · \(place.city.isEmpty ? place.placeLine : place.city)" }
                     ?? "\(place.country?.flag ?? "") \(place.placeLine)")
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
                if !place.note.isEmpty {
                    Text(place.note)
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(2)
                }
                if let credit {
                    Label(credit, systemImage: "quote.opening")
                        .font(.caption2)
                        .foregroundStyle(Color.inkTertiary)
                }
            }
            Spacer(minLength: 4)

            Menu {
                Button { onLog?() } label: {
                    Label(place.isRestaurant ? "Log a meal here" : "Log a memory here",
                          systemImage: place.isRestaurant ? "fork.knife" : "photo.badge.plus")
                }
                Button { onEdit?() } label: { Label("Edit", systemImage: "pencil") }
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

// ── Editors ─────────────────────────────────────────────────────────────────

struct TripPlanEditorSheet: View {
    enum Mode {
        case new(countryCode: String?)
        case edit(TripPlan)
    }

    let mode: Mode

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var countries: [String] = []
    @State private var hasDates = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(7 * 86400)
    @State private var groupId: UUID?
    @State private var notes = ""
    @State private var pickingCountry = false
    @State private var saving = false
    @State private var prepared = false

    private var editing: TripPlan? {
        if case .edit(let plan) = mode { return plan }
        return nil
    }

    private var canSave: Bool {
        !saving && (!name.trimmed.isEmpty || !countries.isEmpty)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Trip name", text: $name)
                        .autocorrectionDisabled()
                        .listRowBackground(Color.card)
                } header: {
                    Text("Trip")
                } footer: {
                    Text("Leave it blank and it takes the name of the countries.")
                }

                Section("Where") {
                    if !countries.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(countries, id: \.self) { code in
                                Button {
                                    countries.removeAll { $0 == code }
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(Country.flag(for: code))
                                        Text(CountryStore.byCode[code]?.name ?? code)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Color.ink)
                                        Image(systemName: "xmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(Color.inkTertiary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.sunken, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(CountryStore.byCode[code]?.name ?? code)")
                            }
                        }
                        .listRowBackground(Color.card)
                    }
                    Button { pickingCountry = true } label: {
                        Label("Add a country", systemImage: "globe")
                    }
                    .listRowBackground(Color.card)
                }

                Section("When") {
                    Toggle("I know the dates", isOn: $hasDates.animation())
                        .listRowBackground(Color.card)
                    if hasDates {
                        DatePicker("Leaving", selection: $start, displayedComponents: .date)
                            .listRowBackground(Color.card)
                        DatePicker("Back", selection: $end, in: start..., displayedComponents: .date)
                            .listRowBackground(Color.card)
                    }
                }

                if !app.groups.isEmpty {
                    Section {
                        Picker("Who's coming", selection: $groupId) {
                            Text("Just me").tag(UUID?.none)
                            ForEach(app.groups) { group in
                                Text(group.name).tag(UUID?.some(group.id))
                            }
                        }
                        .listRowBackground(Color.card)
                    } footer: {
                        Text("A group can see the trip and add places to it.")
                    }
                }

                Section("Notes") {
                    TextField("Ideas, bookings, anything", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .listRowBackground(Color.card)
                }
            }
            .paperListStyle()
            .navigationTitle(editing == nil ? "Plan a trip" : "Edit trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $pickingCountry) {
                CountryPickerSheet(title: "Add a country") { code in
                    if !countries.contains(code) { countries.append(code) }
                }
            }
            .task {
                guard !prepared else { return }
                prepared = true
                switch mode {
                case .new(let code):
                    if let code { countries = [code] }
                case .edit(let plan):
                    name = plan.name
                    countries = plan.countryCodes
                    groupId = plan.groupId
                    notes = plan.notes
                    if let from = plan.start {
                        hasDates = true
                        start = from
                        end = plan.end ?? from
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let startsOn = hasDates ? DayFormat.string(from: start) : nil
        let endsOn = hasDates ? DayFormat.string(from: max(start, end)) : nil
        do {
            if let editing {
                try await app.updateTrip(editing, name: name, countries: countries, startsOn: startsOn,
                                         endsOn: endsOn, groupId: groupId, notes: notes)
            } else {
                try await app.createTrip(name: name, countries: countries, startsOn: startsOn,
                                         endsOn: endsOn, groupId: groupId, notes: notes)
            }
            dismiss()
        } catch {
            app.show(error)
        }
    }
}

struct SavedPlaceEditorSheet: View {
    let place: SavedPlace

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var city = ""
    @State private var note = ""
    @State private var tripId: UUID?
    @State private var saving = false
    @State private var prepared = false

    var body: some View {
        NavigationStack {
            List {
                Section("Place") {
                    TextField("Name", text: $title)
                        .autocorrectionDisabled()
                        .listRowBackground(Color.card)
                    TextField("City", text: $city)
                        .autocorrectionDisabled()
                        .listRowBackground(Color.card)
                }
                Section("Note") {
                    TextField("Why you saved it", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                        .listRowBackground(Color.card)
                }
                Section {
                    Picker("Trip", selection: $tripId) {
                        Text("No trip yet").tag(UUID?.none)
                        ForEach(app.tripPlans) { plan in
                            Text(plan.title).tag(UUID?.some(plan.id))
                        }
                    }
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
                                try await app.updatePlace(place, title: title, city: city,
                                                          note: note, tripId: .some(tripId))
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
                tripId = place.tripId
            }
        }
    }
}
