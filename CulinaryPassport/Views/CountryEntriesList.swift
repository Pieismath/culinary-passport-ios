import SwiftUI

/// The scrollable "what we've eaten from this country" log inside the globe
/// panels — every entry with who logged it, the restaurant, when, and stars.
/// Shared by the personal globe and the group globe.
struct CountryEntriesList: View {
    let entries: [Entry]
    /// Author profiles for name + color dot; rows hide the author when the
    /// list only contains one person's meals.
    let authors: [UUID: Profile]

    private var sorted: [Entry] {
        entries.sorted { $0.dateTried > $1.dateTried } // ISO dates sort lexically
    }

    private var showAuthors: Bool {
        Set(entries.map(\.userId)).count > 1
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(sorted) { entry in
                    row(entry)
                }
            }
            .padding(.trailing, 2)
        }
        .frame(maxHeight: 185)
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.restaurantName).font(.subheadline)
                HStack(spacing: 5) {
                    if showAuthors, let author = authors[entry.userId] {
                        Circle()
                            .fill(Color(uiColor: UIColor(hex: author.color) ?? .systemGray))
                            .frame(width: 7, height: 7)
                        Text(author.name)
                    }
                    Text(Self.pretty(entry.dateTried))
                    if let dish = entry.signatureDish, !dish.isEmpty {
                        Text("· \(dish)").lineLimit(1)
                    }
                }
                .font(.caption)
                // Concrete color, NOT .secondary: hierarchical styles get the
                // material-vibrancy treatment inside this panel and vanish.
                .foregroundStyle(Color(.secondaryLabel))
            }
            Spacer()
            Text(String(repeating: "★", count: entry.rating))
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // dateTried is "yyyy-MM-dd" from Postgres
    private static let parse: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func pretty(_ raw: String) -> String {
        guard let date = parse.date(from: raw) else { return raw }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
