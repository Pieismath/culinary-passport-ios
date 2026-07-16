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
    @State private var showSearch = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobeBackdrop()

            GlobeCanvas(
                color: { code, selected in vm.color(for: code, selected: selected) },
                selected: $selectedCode,
                focusOn: $focusTarget,
                onFocusLanded: { code in
                    focusing = false
                    focusTarget = nil
                    selectedCode = code
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
                    onClose: { selectedCode = nil },
                    onLog: { logCountry = country },
                    onFindNearby: { findNearby(country) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding()
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
        .task { await vm.load() }
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
        .sheet(isPresented: $showSearch) {
            CountrySearchSheet(tried: Set(vm.statusByCountry.keys)) { country in
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
    private var togetherCount: Int { vm.statusByCountry.values.filter { $0.count >= 2 }.count }

    private var progressChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChipLabel(text: "\(triedCount) of \(CountryStore.all.count) cuisines")
            if togetherCount > 0 {
                ChipLabel(text: "💜 \(togetherCount) together")
            }
        }
    }

    // ── Spin ─────────────────────────────────────────────────────────────────

    private var spinButton: some View {
        Button {
            spinGlobe()
        } label: {
            Image(systemName: "dice.fill")
                .font(.title2)
                .symbolEffect(.pulse, isActive: focusing)
                .padding(14)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .disabled(focusing)
        .accessibilityLabel("Spin for tonight's cuisine")
    }

    private var searchButton: some View {
        Button {
            showSearch = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.semibold))
                .padding(15)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .disabled(focusing)
        .accessibilityLabel("Find a country or cuisine")
    }

    /// Land on a random cuisine you haven't tried (anywhere, once you've tried
    /// them all). The globe physically spins there — no flag slot machine.
    private func spinGlobe() {
        let withGeometry = CountryStore.all.filter { CountryGeometry.rings[$0.code] != nil }
        let untried = withGeometry.filter { vm.statusByCountry[$0.code] == nil }
        guard let pick = (untried.isEmpty ? withGeometry : untried).randomElement() else { return }
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

/// Warm paper behind the transparent SCNView: soft radial light, a halo the
/// globe sits in, and faint dashed "orbit" rings. Light and clean — no glow.
private struct GlobeBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
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

                // faint orbit rings
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 7]))
                    .foregroundStyle(Color(red: 0.72, green: 0.66, blue: 0.55).opacity(0.35))
                    .frame(width: side * 1.14, height: side * 1.14)
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 9]))
                    .foregroundStyle(Color(red: 0.72, green: 0.66, blue: 0.55).opacity(0.22))
                    .frame(width: side * 1.3, height: side * 1.3)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Detail panel

private struct CountryPanel: View {
    let country: Country
    let tasters: [String]
    let entries: [Entry]
    let onClose: () -> Void
    let onLog: () -> Void
    let onFindNearby: () -> Void

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
                    ForEach(entries.prefix(3)) { entry in
                        HStack {
                            Text(entry.restaurantName).font(.subheadline)
                            Spacer()
                            Text(String(repeating: "★", count: entry.rating))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if entries.count > 3 {
                        Text("+\(entries.count - 3) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                Button(action: onLog) {
                    Label(tasters.isEmpty ? "Log \(country.cuisineName) meal" : "Add another meal",
                          systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: onFindNearby) {
                    Label("Nearby", systemImage: "map")
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
