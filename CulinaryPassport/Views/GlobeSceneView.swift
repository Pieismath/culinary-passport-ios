import SwiftUI
import SceneKit

/// MVP step 2 — the globe. Real Natural Earth country polygons projected onto a
/// SceneKit sphere, tinted by try-status (port of the web GlobeView.tsx). Tap a
/// country for its panel; drag to spin, pinch to zoom (SceneKit camera control).
struct GlobeSceneView: View {
    @StateObject private var vm = GlobeViewModel()
    @State private var selectedCode: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobeCanvas(color: { code, selected in vm.color(for: code, selected: selected) },
                        selected: $selectedCode)
                .ignoresSafeArea()

            if vm.loading {
                ProgressView().padding(.bottom, 40)
            }

            if let code = selectedCode, let country = CountryStore.byCode[code] {
                CountryPanel(
                    country: country,
                    tasters: vm.tasterNames(for: code),
                    entries: vm.entriesByCountry[code] ?? [],
                    onClose: { selectedCode = nil }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedCode)
        .task { await vm.load() }
        .overlay(alignment: .top) {
            if let error = vm.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(8).background(.thinMaterial, in: Capsule())
            }
        }
    }
}

// MARK: - SceneKit bridge

// MARK: - Detail panel

private struct CountryPanel: View {
    let country: Country
    let tasters: [String]
    let entries: [Entry]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(country.flagEmoji).font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(country.cuisineName).font(.headline)
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
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 12, y: 4)
    }
}
