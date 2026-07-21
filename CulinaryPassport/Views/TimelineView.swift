import SwiftUI

/// v1.1 item 9 — the Journal as a timeline. Ports the web TimelineView to a
/// native vertical layout: entries as
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

