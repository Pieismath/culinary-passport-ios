import SwiftUI

/// v1.3 item 18 — Yearly Wrapped. A Spotify-Wrapped-style year in review built
/// entirely from the user's own entries.
struct WrappedView: View {
    @State private var allEntries: [Entry] = []
    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var loaded = false

    private var years: [Int] {
        let ys = Set(allEntries.compactMap { Int($0.dateTried.prefix(4)) })
        return ys.sorted(by: >)
    }
    private var stats: WrappedStats { WrappedStats(entries: allEntries, year: year) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if years.count > 1 {
                    Picker("Year", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if stats.total == 0 {
                    ContentUnavailableView("No meals in \(String(year))", systemImage: "calendar",
                                           description: Text("Log some dinners and check back."))
                        .padding(.top, 40)
                } else {
                    WrapCard(tint: .orange) {
                        Text("\(stats.total)").font(.system(size: 64, weight: .heavy))
                        Text("meals logged in \(String(year))").font(.headline)
                    }
                    HStack(spacing: 16) {
                        WrapCard(tint: .blue) {
                            Text("\(stats.cuisines)").font(.system(size: 44, weight: .heavy))
                            Text("cuisines").font(.subheadline)
                        }
                        WrapCard(tint: .green) {
                            Text("\(stats.continents)").font(.system(size: 44, weight: .heavy))
                            Text("continents").font(.subheadline)
                        }
                    }
                    if let top = stats.topCuisine {
                        WrapCard(tint: .purple) {
                            Text(top.flag).font(.system(size: 52))
                            Text("Your top cuisine").font(.subheadline)
                            Text("\(top.name) · \(top.count)×").font(.title3).bold()
                        }
                    }
                    HStack(spacing: 16) {
                        WrapCard(tint: .pink) {
                            Text("\(stats.newCuisines)").font(.system(size: 44, weight: .heavy))
                            Text("new cuisines").font(.subheadline)
                        }
                        WrapCard(tint: .teal) {
                            Text(String(format: "%.1f", stats.avgRating)).font(.system(size: 44, weight: .heavy))
                            Text("avg rating").font(.subheadline)
                        }
                    }
                    if let city = stats.topCity {
                        WrapCard(tint: .indigo) {
                            Text("Most meals in").font(.subheadline)
                            Text(city).font(.title2).bold()
                        }
                    }
                    if stats.rareFinds > 0 {
                        WrapCard(tint: .brown) {
                            Label("\(stats.rareFinds) rare finds", systemImage: "sparkles")
                                .font(.title3).bold()
                        }
                    }
                    if let best = stats.topRated {
                        WrapCard(tint: .orange) {
                            Text("Favourite of the year").font(.subheadline)
                            Text("\(best.flag) \(best.name)").font(.title3).bold()
                            Text(String(repeating: "★", count: best.rating)).foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Wrapped")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if stats.total > 0 {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shareImage(),
                              preview: SharePreview("My \(String(year)) in food", image: shareImage())) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            allEntries = (try? await SupabaseService.shared.myEntries()) ?? []
            if let latest = years.first { year = latest }
            loaded = true
        }
        .overlay { if !loaded { ProgressView() } }
    }

    /// The year, as one story-sized card.
    private func shareImage() -> Image {
        let s = stats
        let renderer = ImageRenderer(content:
            VStack(spacing: 14) {
                Text("MY \(String(year)) IN FOOD")
                    .font(.caption.weight(.bold)).tracking(3)
                    .foregroundStyle(Color(.secondaryLabel))
                Text("\(s.total)").font(.system(size: 88, weight: .heavy))
                Text("meals · \(s.cuisines) cuisines · \(s.continents) continents")
                    .font(.headline)
                if let top = s.topCuisine {
                    Text("Top cuisine: \(top.flag) \(top.name) ×\(top.count)")
                        .font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                }
                Text("· CULINARY PASSPORT ·")
                    .font(.system(size: 10, weight: .semibold)).tracking(2.5)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(48)
            .background(Color(red: 0.972, green: 0.960, blue: 0.930))
        )
        renderer.scale = 3
        return renderer.uiImage.map(Image.init(uiImage:)) ?? Image(systemName: "sparkles")
    }
}

private struct WrapCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 6) { content }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 16)
            .background(
                LinearGradient(colors: [tint, tint.opacity(0.7)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 22)
            )
    }
}

/// Pure computation of a year's stats from all entries.
struct WrappedStats {
    let total: Int
    let cuisines: Int
    let continents: Int
    let newCuisines: Int
    let avgRating: Double
    let rareFinds: Int
    let topCuisine: (flag: String, name: String, count: Int)?
    let topCity: String?
    let topRated: (flag: String, name: String, rating: Int)?

    init(entries: [Entry], year: Int) {
        let prefix = String(year)
        let yearly = entries.filter { $0.dateTried.hasPrefix(prefix) }
        total = yearly.count

        let codes = yearly.map(\.countryCode)
        cuisines = Set(codes).count
        continents = Set(codes.compactMap { CountryStore.byCode[$0]?.continent }.filter { !$0.isEmpty }).count
        rareFinds = Set(codes.filter { Country.rareCodes.contains($0) }).count
        avgRating = yearly.isEmpty ? 0 : Double(yearly.map(\.rating).reduce(0, +)) / Double(yearly.count)

        // New cuisines: first-ever tried this year (earliest entry for the code is this year).
        var earliest: [String: String] = [:]
        for e in entries {
            if let cur = earliest[e.countryCode] { if e.dateTried < cur { earliest[e.countryCode] = e.dateTried } }
            else { earliest[e.countryCode] = e.dateTried }
        }
        newCuisines = Set(codes).filter { earliest[$0]?.hasPrefix(prefix) == true }.count

        // Top cuisine by frequency.
        let counts = Dictionary(grouping: codes, by: { $0 }).mapValues(\.count)
        if let (code, count) = counts.max(by: { $0.value < $1.value }), let c = CountryStore.byCode[code] {
            topCuisine = (c.flagEmoji, c.cuisineName, count)
        } else { topCuisine = nil }

        // Top city by frequency.
        let cities = yearly.compactMap { $0.city }.filter { !$0.isEmpty }
        topCity = Dictionary(grouping: cities, by: { $0 }).mapValues(\.count).max { $0.value < $1.value }?.key

        // Highest-rated meal (ties → first).
        if let best = yearly.max(by: { $0.rating < $1.rating }), let c = CountryStore.byCode[best.countryCode] {
            topRated = (c.flagEmoji, best.restaurantName, best.rating)
        } else { topRated = nil }
    }
}
