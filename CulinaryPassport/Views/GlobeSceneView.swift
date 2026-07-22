import SwiftUI
import SceneKit

/// The globe tab. Real Natural Earth polygons on a SceneKit sphere over a warm
/// paper backdrop — tap a country for its panel, long-press to log it straight
/// away, dice to spin the globe onto tonight's cuisine.
struct GlobeSceneView: View {
    @StateObject private var vm = GlobeViewModel()
    @State private var selectedCode: String?
    @State private var focusTarget: GlobeCanvas.FocusRequest?
    @State private var focusing = false
    @State private var logCountry: Country?
    @State private var viewingEntry: Entry?
    @State private var showSearch = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobeBackdrop(triedCount: triedCount)

            GlobeCanvas(
                color: { code, selected in vm.color(for: code, selected: selected) },
                selected: $selectedCode,
                focusOn: $focusTarget,
                onFocusLanded: { code in
                    focusing = false
                    focusTarget = nil
                    if let code { selectedCode = code } // nil = user grabbed the globe mid-flight
                },
                onLongPress: { code in
                    logCountry = CountryStore.byCode[code]
                }
            )
            .ignoresSafeArea()

            if vm.loading {
                ProgressView().padding(.bottom, 40)
            }

            if let code = selectedCode, let country = CountryStore.byCode[code] {
                CountryPanel(
                    country: country,
                    tasters: vm.tasterNames(for: code),
                    entries: vm.entriesByCountry[code] ?? [],
                    authors: vm.usersById,
                    wishlisted: vm.wishlisted.contains(code),
                    onClose: { selectedCode = nil },
                    onLog: { logCountry = country },
                    onFindNearby: { findNearby(country) },
                    onToggleWishlist: { vm.toggleWishlist(code) },
                    onSelectEntry: { viewingEntry = $0 }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding()
            } else if !vm.loading && !focusing {
                GlobeExploreCue()
                    .padding(.horizontal, 54)
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .overlay(alignment: .topLeading) { progressChips.padding(.leading, 16) }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 12) {
                spinButton
                searchButton
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedCode)
        // Same reason as ProfileView: a single on-appear load can lose the race
        // with sign-in and leave an empty globe.
        .task {
            for await state in SupabaseService.shared.client.auth.authStateChanges
            where state.session != nil {
                await vm.load()
            }
        }
        #if DEBUG
        // Headless smoke tests: `-spin` runs the dice flow; `-fly XX` flies to
        // a country code the way a search pick does; `-search` opens the sheet.
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-spin") {
                try? await Task.sleep(for: .seconds(2))
                spinGlobe()
            } else if let i = args.firstIndex(of: "-fly"), i + 1 < args.count {
                try? await Task.sleep(for: .seconds(2))
                flyTo(code: args[i + 1])
            } else if args.contains("-search") {
                try? await Task.sleep(for: .seconds(1.5))
                showSearch = true
            }
        }
        #endif
        .sheet(item: $logCountry) { country in
            EntrySheet(mode: .add, presetCountryCode: country.code) {
                await vm.load()
            }
        }
        .sheet(item: $viewingEntry) { entry in
            EntryDetailView(entry: entry) { await vm.load() }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSearch) {
            CountrySearchSheet(
                tried: Set(vm.statusByCountry.keys),
                wishlisted: vm.wishlisted,
                onToggleWishlist: { vm.toggleWishlist($0) }
            ) { country in
                flyTo(code: country.code)
            }
        }
        .overlay(alignment: .top) {
            if let error = vm.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(8).background(.thinMaterial, in: Capsule())
            }
        }
    }

    // ── Progress chips (web header rings, phone-sized) ───────────────────────

    private var triedCount: Int { vm.statusByCountry.count }

    private var progressChips: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Stampd")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(Color("BrandGreen"))
            ChipLabel(text: "\(triedCount) of \(CountryStore.all.count) cuisines")
        }
    }

    // ── Spin ─────────────────────────────────────────────────────────────────

    private var spinButton: some View {
        Menu {
            Button {
                spinGlobe()
            } label: {
                Label("Spin anywhere new", systemImage: "globe")
            }
            Button {
                spinGlobe(pool: .wishlist)
            } label: {
                Label("Spin my Want to Try", systemImage: "bookmark")
            }
            .disabled(vm.wishlisted.isEmpty)
        } label: {
            Image("action-spin")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 26, height: 26)
                .symbolEffect(.pulse, isActive: focusing)
                .padding(14)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        } primaryAction: {
            spinGlobe()
        }
        .disabled(focusing)
        .accessibilityLabel("Spin for tonight's cuisine")
    }

    enum SpinPool { case untried, wishlist }

    private var searchButton: some View {
        Button {
            showSearch = true
        } label: {
            Image("action-search")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 25, height: 25)
                .padding(15)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .disabled(focusing)
        .accessibilityLabel("Find a country or cuisine")
    }

    /// Land on a random cuisine — anywhere new, or restricted to the user's
    /// Want to Try queue. The globe physically spins there.
    private func spinGlobe(pool: SpinPool = .untried) {
        let withGeometry = CountryStore.all.filter { CountryGeometry.rings[$0.code] != nil }
        let candidates: [Country]
        switch pool {
        case .wishlist:
            candidates = withGeometry.filter { vm.wishlisted.contains($0.code) }
        case .untried:
            let untried = withGeometry.filter { vm.statusByCountry[$0.code] == nil }
            candidates = untried.isEmpty ? withGeometry : untried
        }
        guard let pick = candidates.randomElement() else { return }
        selectedCode = nil
        focusing = true
        focusTarget = .init(id: UUID(), code: pick.code, style: .spin)
    }

    /// Rotate straight to a chosen country (search pick / deep link) and open
    /// its panel — the "find a cuisine to log" path.
    private func flyTo(code: String) {
        guard CountryGeometry.rings[code] != nil else {
            selectedCode = code // no polygon to fly to; still show the panel
            return
        }
        selectedCode = nil
        focusing = true
        focusTarget = .init(id: UUID(), code: code, style: .fly)
    }

    private func findNearby(_ country: Country) {
        let query = "\(country.cuisineName) restaurant"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "restaurant"
        if let url = URL(string: "maps://?q=\(query)") { openURL(url) }
    }
}

private struct ChipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

// ── Backdrop ─────────────────────────────────────────────────────────────────

/// Warm paper behind the transparent SCNView: soft radial light and a porcelain
/// halo. The useful editorial copy supplies structure; decorative orbit/grid
/// lines deliberately stay out so the globe remains the one visual focus.
private struct GlobeBackdrop: View {
    let triedCount: Int

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let ink = Color(red: 0.42, green: 0.37, blue: 0.29)
            ZStack {
                RadialGradient(
                    colors: [Color(red: 0.985, green: 0.972, blue: 0.945),
                             Color(red: 0.945, green: 0.925, blue: 0.882)],
                    center: .center,
                    startRadius: side * 0.1,
                    endRadius: side * 1.1
                )

                // halo the globe floats in
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: side * 1.02, height: side * 1.02)
                    .blur(radius: 28)

                // The Stampd wordmark (top-left overlay) is the page brand;
                // this is just the tagline, kept clear of the chip row.
                Text(triedCount == 0 ? "Every journey starts with one plate." : "Every meal leaves a mark.")
                    .font(.system(.subheadline, design: .serif))
                    .italic()
                    .foregroundStyle(ink.opacity(0.72))
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.158)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }
}

/// Persistent, non-interactive gesture teaching. The globe has intentionally
/// custom controls, so first-time users should not have to discover long-press
/// logging by accident.
private struct GlobeExploreCue: View {
    var body: some View {
        HStack(spacing: 11) {
            Image("action-drag")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 25, height: 25)
                .foregroundStyle(Color(red: 0.36, green: 0.31, blue: 0.24))

            VStack(alignment: .leading, spacing: 2) {
                Text("Drag to explore")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(.label))
                Text("Press and hold a country to log a meal")
                    .font(.caption)
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

// MARK: - Detail panel

private struct CountryPanel: View {
    let country: Country
    let tasters: [String]
    let entries: [Entry]
    let authors: [UUID: Profile]
    let wishlisted: Bool
    let onClose: () -> Void
    let onLog: () -> Void
    let onFindNearby: () -> Void
    let onToggleWishlist: () -> Void
    let onSelectEntry: (Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(country.flagEmoji).font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(country.cuisineName).font(.headline)
                        if country.rare {
                            Image(systemName: "sparkles").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text(country.subregion.isEmpty ? country.continent : country.subregion)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if entries.count > 1 {
                    Text("\(entries.count) meals")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(.systemGray5), in: Capsule())
                }
                // Want to Try — the bookmark survives even after you've eaten
                // there (maybe you want to go back properly).
                Button(action: onToggleWishlist) {
                    Image(systemName: wishlisted ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(wishlisted ? Color(uiColor: GlobeViewModel.queueAmber) : Color(.secondaryLabel))
                }
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }

            if tasters.isEmpty {
                Label("Not tried yet", systemImage: "circle.dashed")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Label(tasters.joined(separator: " & "), systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                if !entries.isEmpty {
                    Divider()
                    // Every meal from this country — scrolls when it outgrows
                    // the card; tap one for photos/rating/edit.
                    CountryEntriesList(entries: entries, authors: authors, onSelect: onSelectEntry)
                }
            }

            HStack(spacing: 10) {
                Button(action: onLog) {
                    Label {
                        Text(tasters.isEmpty ? "Log \(country.cuisineName) meal" : "Add another meal")
                    } icon: {
                        BrandedIcon(name: "action-add", size: 19)
                    }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: onFindNearby) {
                    Label {
                        Text("Nearby")
                    } icon: {
                        BrandedIcon(name: "action-nearby", size: 20)
                    }
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// A vector asset rendered as a template so every branded icon inherits the
/// surrounding control's tint and behaves like a native symbol.
struct BrandedIcon: View {
    let name: String
    var size: CGFloat = 22

    var body: some View {
        Image(name)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
