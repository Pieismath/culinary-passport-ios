import SwiftUI

/// v1.1 item 9 — the Journal as a timeline. Ports the web TimelineView to a
/// native vertical layout: a meal-frequency sparkline on top, then entries as
/// ticks grouped under sticky year headers.
struct TimelineView: View {
    let entries: [Entry]
    /// Tap a tick to open the meal (detail sheet with edit/delete).
    var onSelect: ((Entry) -> Void)? = nil

    private var sorted: [Entry] {
        entries.sorted { ($0.dateTried, $0.createdAt) > ($1.dateTried, $1.createdAt) }
    }
    private var years: [String] {
        var seen: [String] = []
        for e in sorted { let y = String(e.dateTried.prefix(4)); if !seen.contains(y) { seen.append(y) } }
        return seen
    }
    private func entries(in year: String) -> [Entry] {
        sorted.filter { $0.dateTried.hasPrefix(year) }
    }

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("No meals yet", systemImage: "clock",
                                   description: Text("Your timeline fills in as you log."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Sparkline(entries: entries)
                        .frame(height: 56)
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    ForEach(years, id: \.self) { year in
                        Section {
                            ForEach(entries(in: year)) { entry in
                                if let onSelect {
                                    Button {
                                        onSelect(entry)
                                    } label: {
                                        TimelineTick(entry: entry)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    TimelineTick(entry: entry)
                                }
                            }
                        } header: {
                            Text(year)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .background(.regularMaterial)
                        }
                    }
                }
            }
        }
    }
}

private struct TimelineTick: View {
    let entry: Entry
    private var country: Country? { CountryStore.byCode[entry.countryCode] }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Tick line + dot.
            VStack(spacing: 0) {
                Circle().fill(Color.accentColor).frame(width: 9, height: 9).padding(.top, 5)
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2)
            }
            .frame(width: 9)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(country?.flagEmoji ?? "🌍") \(entry.restaurantName)")
                        .font(.subheadline).bold()
                    Spacer()
                    Text(String(repeating: "★", count: entry.rating))
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("\(country?.cuisineName ?? entry.countryCode) · \(monthDay(entry.dateTried))\(entry.city.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal)
    }

    private func monthDay(_ iso: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter(); out.dateFormat = "d MMM"
        return out.string(from: d)
    }
}

/// Meals-per-month area sparkline across the full logged span.
private struct Sparkline: View {
    let entries: [Entry]

    var body: some View {
        let counts = monthlyCounts()
        Canvas { context, size in
            guard counts.count > 1, let maxC = counts.map(\.1).max(), maxC > 0 else { return }
            let stepX = size.width / CGFloat(counts.count - 1)
            func point(_ i: Int) -> CGPoint {
                let v = CGFloat(counts[i].1) / CGFloat(maxC)
                return CGPoint(x: CGFloat(i) * stepX, y: size.height - v * (size.height - 4) - 2)
            }
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for i in counts.indices { area.addLine(to: point(i)) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(.accentColor.opacity(0.18)))

            var line = Path()
            for i in counts.indices { i == 0 ? line.move(to: point(i)) : line.addLine(to: point(i)) }
            context.stroke(line, with: .color(.accentColor), lineWidth: 2)
        }
        .overlay(alignment: .topLeading) {
            Text("\(entries.count) meals · meals per month")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Continuous month buckets from first to last entry (gaps count as 0).
    private func monthlyCounts() -> [(String, Int)] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let dates = entries.compactMap { f.date(from: $0.dateTried) }.sorted()
        guard let first = dates.first, let last = dates.last else { return [] }
        let cal = Calendar.current
        var counts: [String: Int] = [:]
        let key = DateFormatter(); key.dateFormat = "yyyy-MM"
        for d in dates { counts[key.string(from: d), default: 0] += 1 }

        var result: [(String, Int)] = []
        var cursor = cal.date(from: cal.dateComponents([.year, .month], from: first)) ?? first
        let end = cal.date(from: cal.dateComponents([.year, .month], from: last)) ?? last
        while cursor <= end {
            let k = key.string(from: cursor)
            result.append((k, counts[k] ?? 0))
            cursor = cal.date(byAdding: .month, value: 1, to: cursor) ?? end.addingTimeInterval(1)
        }
        return result
    }
}
