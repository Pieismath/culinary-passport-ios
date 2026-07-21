import Foundation

/// Specific places to eat, not just "try Filipino food".
///
/// Candidates are restaurants your people (anyone you follow, plus everyone in
/// your groups) rated 4★ or better and that you haven't logged yourself. Each
/// is scored by how much you'd like it — the cuisine's standing in your own
/// journal via `Recommender`, how many of your people rated it, how highly,
/// and whether it's a cuisine that's new to you — and carries the human reason
/// why it's on the list.
enum RestaurantRecommender {
    struct Pick: Identifiable {
        let restaurant: String
        let city: String?
        let country: Country
        let entries: [Entry]
        let endorsers: [Profile]
        let averageRating: Double
        let signatureDish: String?
        let reason: String
        var id: String { "\(restaurant)|\(country.code)" }
    }

    static func picks(mine: [Entry],
                      theirs: [Entry],
                      people: [UUID: Profile],
                      limit: Int = 8) -> [Pick] {
        let myPlaces = Set(mine.map { normalized($0.restaurantName) })
        let myCuisines = Set(mine.map(\.countryCode))

        // How much each cuisine appeals to me, from my own journal.
        var cuisineAppeal: [String: Double] = [:]
        for (index, suggestion) in Recommender.suggestions(entries: mine, limit: 40).enumerated() {
            cuisineAppeal[suggestion.country.code] = 3.0 - Double(index) * 0.05
        }
        // Cuisines I already love count too — a great Thai place is still welcome.
        for entry in mine where entry.rating >= 4 {
            cuisineAppeal[entry.countryCode, default: 0] += 0.6
        }

        // Group the candidates by restaurant.
        var byPlace: [String: [Entry]] = [:]
        for entry in theirs where !myPlaces.contains(normalized(entry.restaurantName)) {
            byPlace[normalized(entry.restaurantName), default: []].append(entry)
        }

        var picks: [(Pick, Double)] = []
        for (_, rows) in byPlace {
            guard let first = rows.first,
                  let country = CountryStore.byCode[first.countryCode] else { continue }
            let endorsers = Array(Set(rows.map(\.userId))).compactMap { people[$0] }
                .sorted { $0.name < $1.name }
            guard !endorsers.isEmpty else { continue }

            let average = Double(rows.map(\.rating).reduce(0, +)) / Double(rows.count)
            var score = (average - 3.5) * 2.0                     // 4★ → 1.0, 5★ → 3.0
            score += Double(endorsers.count - 1) * 2.5            // several friends agreeing is strong
            score += cuisineAppeal[country.code] ?? 0
            if !myCuisines.contains(country.code) { score += 1.5 } // also fills the globe

            let reason: String
            if endorsers.count > 1 {
                let names = endorsers.prefix(2).map(\.name).joined(separator: " and ")
                let extra = endorsers.count > 2 ? " +\(endorsers.count - 2)" : ""
                reason = "\(names)\(extra) both rated it \(stars(average))"
            } else if !myCuisines.contains(country.code) {
                reason = "\(endorsers[0].name) loved it — and you've never had \(country.cuisineName)"
            } else if let note = rows.compactMap({ $0.notes }).first(where: { !$0.isEmpty }) {
                reason = "\(endorsers[0].name): \"\(note.prefix(60))\""
            } else {
                reason = "\(endorsers[0].name) rated it \(stars(average))"
            }

            picks.append((
                Pick(restaurant: first.restaurantName,
                     city: first.city,
                     country: country,
                     entries: rows,
                     endorsers: endorsers,
                     averageRating: average,
                     signatureDish: rows.compactMap(\.signatureDish).first { !$0.isEmpty },
                     reason: reason),
                score
            ))
        }

        return picks
            .sorted { a, b in
                a.1 == b.1 ? a.0.restaurant < b.0.restaurant : a.1 > b.1
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func stars(_ average: Double) -> String {
        average >= 4.75 ? "5★" : "\(String(format: "%.1f", average))★"
    }
}
