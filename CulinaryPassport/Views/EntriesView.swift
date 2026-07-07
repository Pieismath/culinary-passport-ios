import SwiftUI

/// MVP step 3: personal entries — list, add, delete. (Edit + photos next.)
struct EntriesView: View {
    @State private var entries: [Entry] = []
    @State private var showAdd = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    EntryRow(entry: entry)
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
                AddEntrySheet { await reload() }
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
            Text(CountryStore.byCode[entry.countryCode]?.flagEmoji ?? "🌍")
                .font(.title2)
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

struct AddEntrySheet: View {
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
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Cuisine", selection: $country) {
                    Text("Pick a country…").tag(nil as Country?)
                    ForEach(CountryStore.all) { c in
                        Text("\(c.flagEmoji) \(c.name)\(c.rare ? " ✦" : "")").tag(c as Country?)
                    }
                }
                // TODO(MVP-3): Google Places autocomplete via the places-proxy edge function
                TextField("Restaurant", text: $restaurantName)
                TextField("City", text: $city)
                DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                Picker("Rating", selection: $rating) {
                    ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
                }
                TextField("Signature dish", text: $signatureDish)
                TextField("Notes", text: $notes, axis: .vertical)
                Toggle("Would return?", isOn: $wouldReturn)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("Log a meal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Stamping…" : "Stamp it") { Task { await save() } }
                        .disabled(country == nil || restaurantName.isEmpty || saving)
                }
            }
        }
    }

    private func save() async {
        guard let country else { return }
        saving = true
        defer { saving = false }
        do {
            let session = try await SupabaseService.shared.client.auth.session
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            try await SupabaseService.shared.addEntry(NewEntry(
                userId: session.user.id,
                countryCode: country.code,
                restaurantName: restaurantName,
                city: city,
                dateTried: fmt.string(from: date),
                rating: rating,
                notes: notes,
                signatureDish: signatureDish,
                wouldReturn: wouldReturn
            ))
            await onSave()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
