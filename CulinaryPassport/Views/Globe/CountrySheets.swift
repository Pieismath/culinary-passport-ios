import SwiftUI

/// "Where's Bhutan?" — search every stampable place and fly there.
struct CountrySearchSheet: View {
    let onPick: (String) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Country] {
        CountryStore.all.filter { $0.matches(query) }
    }

    private var bucket: [Country] {
        CountryStore.all.filter { app.bucketList.contains($0.code) && !app.visitedCodes.contains($0.code) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty && !bucket.isEmpty {
                    Section("Bucket list") {
                        ForEach(bucket) { row($0) }
                    }
                }
                Section(query.isEmpty ? "Everywhere" : "Results") {
                    ForEach(results) { row($0) }
                }
            }
            .listStyle(.insetGrouped)
            .paperListStyle()
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Country or territory")
            .navigationTitle("Find a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ country: Country) -> some View {
        HStack(spacing: 12) {
            // Two sibling buttons (fly / bookmark). A button nested inside a
            // row button's label can swallow the inner tap.
            Button {
                dismiss()
                onPick(country.code)
            } label: {
                HStack(spacing: 12) {
                    FlagTile(code: country.code, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(country.name).foregroundStyle(Color.ink)
                        Text(country.isSovereign ? country.continent.rawValue : "Territory · \(country.continent.rawValue)")
                            .font(.caption)
                            .foregroundStyle(Color.inkSecondary)
                    }
                    Spacer()
                    if app.visitedCodes.contains(country.code) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Color.brand)
                            .accessibilityLabel("Visited")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button {
                app.toggleBucketList(country.code)
            } label: {
                Image(systemName: app.bucketList.contains(country.code) ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(app.bucketList.contains(country.code) ? Color.bucket : Color.inkTertiary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(app.bucketList.contains(country.code) ? "Remove from bucket list" : "Add to bucket list")
        }
        .listRowBackground(Color.card)
    }
}

/// Choose one country (memory editor, home country).
struct CountryPickerSheet: View {
    var title = "Country"
    var selected: String?
    let onPick: (String) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    let visited = CountryStore.all.filter { app.visitedCodes.contains($0.code) }
                    if !visited.isEmpty {
                        Section("In your passport") {
                            ForEach(visited) { row($0) }
                        }
                    }
                }
                Section(query.isEmpty ? "All places" : "Results") {
                    ForEach(CountryStore.all.filter { $0.matches(query) }) { row($0) }
                }
            }
            .listStyle(.insetGrouped)
            .paperListStyle()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ country: Country) -> some View {
        Button {
            onPick(country.code)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(country.flag).font(.title2)
                Text(country.name).foregroundStyle(Color.ink)
                Spacer()
                if country.code == selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.brand).fontWeight(.semibold)
                }
            }
        }
        .listRowBackground(Color.card)
    }
}

/// Tap every country you've been to. Countries with memories stay checked —
/// their memories are what stamp them.
struct CountryChecklistView: View {
    var onDone: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var checked: Set<String> = []
    @State private var loaded = false
    @State private var saving = false
    @State private var celebrate: [String]?

    private var locked: Set<String> { Set(app.memoriesByCountry.keys) }

    private var added: [String] { checked.subtracting(app.visitedCodes).sorted() }
    private var removed: [String] { app.visitedCodes.subtracting(checked).subtracting(locked).sorted() }

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(checked.filter { CountryStore.byCode[$0]?.isSovereign == true }.count) countries")
                            .font(.number(.title2))
                            .contentTransition(.numericText())
                        Text("of \(CountryStore.sovereignCount) · tap to stamp")
                            .font(.caption)
                            .foregroundStyle(Color.inkSecondary)
                    }
                    Spacer()
                    Text("🌍").font(.system(size: 36))
                }
                .listRowBackground(Color.card)
            }
            ForEach(Continent.allCases) { continent in
                let places = CountryStore.byContinent(continent).filter { $0.matches(query) }
                if !places.isEmpty {
                    Section {
                        ForEach(places) { row($0) }
                    } header: {
                        HStack {
                            Text(continent.rawValue)
                            Spacer()
                            Text("\(places.filter { checked.contains($0.code) }.count)/\(places.count)")
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .paperListStyle()
        .animation(.snappy, value: checked)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search countries")
        .navigationTitle("Where have you been?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss(); onDone() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(saving || (added.isEmpty && removed.isEmpty))
            }
        }
        .onAppear {
            guard !loaded else { return }
            checked = app.visitedCodes
            loaded = true
        }
        .fullScreenCover(item: Binding(
            get: { celebrate.map { StampBurst(codes: $0) } },
            set: { if $0 == nil { celebrate = nil } }
        )) { burst in
            StampMomentView(codes: burst.codes) {
                celebrate = nil
                dismiss()
                onDone()
            }
        }
    }

    private func row(_ country: Country) -> some View {
        let isChecked = checked.contains(country.code)
        let isLocked = locked.contains(country.code)
        return Button {
            guard !isLocked else {
                app.toast = Toast(message: "\(country.name) has memories — they keep it stamped.")
                return
            }
            UISelectionFeedbackGenerator().selectionChanged()
            if isChecked { checked.remove(country.code) } else { checked.insert(country.code) }
        } label: {
            HStack(spacing: 12) {
                Text(country.flag).font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(country.name).foregroundStyle(Color.ink)
                    if !country.isSovereign {
                        Text("Territory").font(.caption2).foregroundStyle(Color.inkTertiary)
                    }
                }
                Spacer()
                Image(systemName: isChecked ? (isLocked ? "lock.circle.fill" : "checkmark.circle.fill") : "circle")
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
        saving = true
        defer { saving = false }
        do {
            if !added.isEmpty {
                try await app.addStamps(added.map {
                    StampInput(countryCode: $0, firstVisited: nil, lastVisited: nil, source: .manual)
                })
            }
            for code in removed {
                try await app.removeStamp(code)
            }
            if added.isEmpty {
                dismiss()
                onDone()
            } else {
                celebrate = added
            }
        } catch {
            app.show(error)
        }
    }
}

struct StampBurst: Identifiable {
    let codes: [String]
    var id: String { codes.joined(separator: ",") }
}
