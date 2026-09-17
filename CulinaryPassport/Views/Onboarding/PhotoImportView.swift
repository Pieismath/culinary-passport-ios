import SwiftUI

/// "Find where you've been": scan photo locations on-device, review the
/// countries found, stamp the ones you pick. Nothing is uploaded.
struct PhotoImportView: View {
    var onDone: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var scanner = PhotoLibraryScanner()
    @State private var chosen: Set<String> = []
    @State private var chosenTrips: Set<UUID> = []
    @State private var saving = false
    @State private var celebrate: [String]?

    private var newFinds: [PhotoLibraryScanner.Found] {
        scanner.found.filter { !app.visitedCodes.contains($0.code) }
    }

    private var alreadyStamped: [PhotoLibraryScanner.Found] {
        scanner.found.filter { app.visitedCodes.contains($0.code) }
    }

    var body: some View {
        SwiftUI.Group {
            switch scanner.phase {
            case .idle: intro
            case .denied: denied
            case .scanning: scanning
            case .finished: results
            }
        }
        .paperBackground()
        .navigationTitle("Find your countries")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(scanner.phase == .finished ? "Skip" : "Cancel") { finish() }
            }
        }
        .fullScreenCover(item: Binding(
            get: { celebrate.map { StampBurst(codes: $0) } },
            set: { if $0 == nil { celebrate = nil } }
        )) { burst in
            StampMomentView(codes: burst.codes) { finish() }
        }
        #if DEBUG
        // Screenshot hook: `-open import -scan` runs the scan on arrival.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-scan"), scanner.phase == .idle else { return }
            await scanner.start(demo: app.isDemo)
        }
        #endif
        .onChange(of: scanner.phase) { _, phase in
            if phase == .finished {
                chosen = Set(newFinds.map(\.code))
                chosenTrips = Set(scanner.trips.map(\.id))
            }
        }
    }

    // ── Intro ────────────────────────────────────────────────────────────────

    private var intro: some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    ForEach(Array(["FR", "JP", "MX"].enumerated()), id: \.offset) { index, code in
                        StampBadge(code: code, size: 96)
                            .offset(x: CGFloat(index - 1) * 74, y: index == 1 ? -14 : 12)
                    }
                }
                .frame(height: 150)
                .padding(.top, 20)
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("Your photos know where you've been")
                        .font(.display)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.ink)
                    Text("Stampd looks at where your photos were taken and finds the countries in them. You choose what goes in your passport.")
                        .font(.body)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 14) {
                    promise("iphone", "Happens on your phone", "Photo locations are read on-device.")
                    promise("icloud.slash", "Nothing is uploaded", "Only the countries you pick — and when — are saved.")
                    promise("checkmark.circle", "You review everything", "Untick anything that doesn't belong.")
                }
                .card()

                Button {
                    Task { await scanner.start(demo: app.isDemo) }
                } label: {
                    Label("Scan my photos", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.primary)
            }
            .padding(24)
        }
    }

    private func promise(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 34, height: 34)
                .background(Color.brandSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Color.ink)
                Text(detail).font(.subheadline).foregroundStyle(Color.inkSecondary)
            }
        }
    }

    // ── Denied ───────────────────────────────────────────────────────────────

    private var denied: some View {
        EmptyStateView(
            systemImage: "photo.badge.exclamationmark",
            title: "Photos access is off",
            message: "To find countries automatically, allow Stampd to read your photos in Settings. Or tap the countries you've been to instead.",
            primaryTitle: "Open Settings",
            primaryAction: {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            },
            secondaryTitle: "Not now",
            secondaryAction: finish
        )
        .frame(maxHeight: .infinity)
    }

    // ── Scanning ─────────────────────────────────────────────────────────────

    private var scanning: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                Circle().stroke(Color.sunken, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: scanner.total > 0 ? Double(scanner.scanned) / Double(scanner.total) : 0.05)
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: scanner.scanned)
                VStack(spacing: 2) {
                    Text("\(scanner.found.count)")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(scanner.found.count == 1 ? "country" : "countries")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .frame(width: 200, height: 200)

            Text(scanner.total > 0
                 ? "Looking through \(scanner.scanned.formatted()) of \(scanner.total.formatted()) photos…"
                 : "Opening your library…")
                .font(.subheadline)
                .foregroundStyle(Color.inkSecondary)
                .monospacedDigit()

            FlowLayout(spacing: 6) {
                ForEach(scanner.found) { found in
                    Text(Country.flag(for: found.code))
                        .font(.system(size: 30))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: scanner.found.map(\.code))
            .padding(.horizontal, 30)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // ── Results ──────────────────────────────────────────────────────────────

    private var results: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scanner.found.isEmpty
                         ? "No locations found"
                         : headline)
                        .font(.display)
                        .foregroundStyle(Color.ink)
                    Text(scanner.found.isEmpty
                         ? "Your photos don't have location data (Settings → Privacy → Location Services → Camera). You can still tap the countries you've been to."
                         : "Untick anything that doesn't belong — a photo someone sent you, or a trip that wasn't yours. Nothing is uploaded, and everything lands private.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }

            if !scanner.trips.isEmpty {
                Section("Trips") {
                    ForEach(scanner.trips) { trip in
                        tripRow(trip)
                    }
                }
            }

            if !newFinds.isEmpty {
                Section("New stamps") {
                    ForEach(newFinds) { found in
                        foundRow(found, selectable: true)
                    }
                }
            }
            if !alreadyStamped.isEmpty {
                Section("Already in your passport") {
                    ForEach(alreadyStamped) { found in
                        foundRow(found, selectable: false)
                    }
                }
            }
        }
        .paperListStyle()
        .safeAreaInset(edge: .bottom) {
            if !newFinds.isEmpty || !chosenTrips.isEmpty {
                Button {
                    Task { await stamp() }
                } label: {
                    Text(saving ? "Filling your passport…" : actionTitle)
                }
                .buttonStyle(.primary)
                .disabled((chosen.isEmpty && chosenTrips.isEmpty) || saving)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private var headline: String {
        scanner.trips.isEmpty
            ? "Found \(scanner.found.count.counted("country", "countries"))"
            : "\(scanner.trips.count.counted("trip")) in \(scanner.found.count.counted("country", "countries"))"
    }

    private var actionTitle: String {
        switch (chosenTrips.count, chosen.count) {
        case (0, let stamps): "Stamp \(stamps.counted("country", "countries"))"
        case (let trips, 0): "Add \(trips.counted("trip"))"
        case (let trips, let stamps): "Add \(trips.counted("trip")) · \(stamps.counted("stamp"))"
        }
    }

    /// One trip the photos describe: where it went, when, and the places in it.
    private func tripRow(_ trip: PhotoTrip) -> some View {
        let isOn = chosenTrips.contains(trip.id)
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            if isOn { chosenTrips.remove(trip.id) } else { chosenTrips.insert(trip.id) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(trip.flags).font(.subheadline)
                        Text(trip.title)
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                    }
                    Text("\(trip.dateRangeText) · \(trip.days.counted("day"))")
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                    Text(trip.stops.map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Color.inkTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                HStack(spacing: -10) {
                    ForEach(trip.sampleIds.prefix(3), id: \.self) { id in
                        LocalAssetThumbnail(identifier: id, side: 34)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.card, lineWidth: 2))
                    }
                }
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.brand : Color.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.card)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func foundRow(_ found: PhotoLibraryScanner.Found, selectable: Bool) -> some View {
        let isOn = !selectable || chosen.contains(found.code)
        return Button {
            guard selectable else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            if chosen.contains(found.code) { chosen.remove(found.code) } else { chosen.insert(found.code) }
        } label: {
            HStack(spacing: 12) {
                FlagTile(code: found.code, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CountryStore.byCode[found.code]?.name ?? found.code)
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    Text(detail(found))
                        .font(.caption)
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer(minLength: 6)
                HStack(spacing: -10) {
                    ForEach(found.samples.prefix(3), id: \.self) { id in
                        LocalAssetThumbnail(identifier: id, side: 34)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.card, lineWidth: 2))
                    }
                }
                Image(systemName: selectable ? (isOn ? "checkmark.circle.fill" : "circle") : "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.brand : Color.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.card)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func detail(_ found: PhotoLibraryScanner.Found) -> String {
        let firstYear = Calendar.current.component(.year, from: found.first)
        let lastYear = Calendar.current.component(.year, from: found.last)
        let years = firstYear == lastYear ? String(firstYear) : "\(firstYear)–\(lastYear)"
        let trips = found.trips > 1 ? " · \(found.trips) trips" : ""
        return "\(found.photoCount.formatted()) photo\(found.photoCount == 1 ? "" : "s")\(trips) · \(years)"
    }

    private func stamp() async {
        saving = true
        defer { saving = false }
        let picks = newFinds.filter { chosen.contains($0.code) }
        do {
            try await app.addStamps(picks.map {
                StampInput(countryCode: $0.code,
                           firstVisited: DayFormat.string(from: $0.first),
                           lastVisited: DayFormat.string(from: $0.last),
                           source: .photos)
            })
            // Trips and the places in them, private and photo-less — the
            // pictures stay on the phone until they're added on purpose.
            try await app.importPhotoTrips(scanner.trips.filter { chosenTrips.contains($0.id) })
            // Refresh dates on countries already stamped too — photos often
            // know an earlier first visit than a manual stamp did.
            let known = alreadyStamped.map {
                StampInput(countryCode: $0.code, firstVisited: DayFormat.string(from: $0.first),
                           lastVisited: DayFormat.string(from: $0.last), source: .photos)
            }
            if !known.isEmpty { try? await app.addStamps(known) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if picks.isEmpty {
                // Nothing new to stamp — the trips are the news.
                app.celebrate("Added to your passport")
                finish()
            } else {
                celebrate = picks.map(\.code)
            }
        } catch {
            app.show(error)
        }
    }

    /// The presenter's onDone closes the sheet (and any cover on it) in one
    /// step; a running scan is cancelled first.
    private func finish() {
        scanner.cancel()
        onDone()
    }
}
