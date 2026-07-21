import Foundation

/// "What should I eat next?" — computed on-device from what you've logged.
///
/// Signals, in rough order of weight:
///  * **Taste neighbourhoods** — you rated Thai and Vietnamese highly, so
///    other Southeast Asian cuisines score up. Ratings above 3 add weight,
///    below 3 subtract it, and "would return" counts for a little more.
///  * **What you write** — notes and signature dishes are scanned for flavour
///    words ("spicy", "noodles", "grilled") which map to cuisines known for
///    them. This is why the reasons can say *why* you'd like it.
///  * **Blank spots** — a continent you've never eaten from is worth more
///    than a fifth cuisine from one you know well.
///  * **Rare finds** — if you enjoy the obscure ones, you get more of them.
///
/// Deterministic: same journal in, same list out (ties break on country name),
/// so the suggestions don't shuffle underneath you.
enum Recommender {
    struct Suggestion: Identifiable {
        let country: Country
        let reason: String
        let score: Double
        var id: String { country.code }
    }

    /// Flavour words → cuisines people reach for when they want that.
    private static let flavourMap: [String: [String]] = [
        "spicy": ["TH", "IN", "MX", "KR", "ET", "LK", "MY"],
        "chilli": ["TH", "MX", "IN", "KR", "CN"],
        "noodle": ["JP", "VN", "CN", "TH", "KR", "MY"],
        "ramen": ["JP", "KR", "CN"],
        "dumpling": ["CN", "NP", "KR", "PL", "GE"],
        "grill": ["KR", "BR", "AR", "TR", "ZA", "GR"],
        "bbq": ["KR", "BR", "US", "ZA", "AR"],
        "seafood": ["PT", "GR", "JP", "NO", "PE", "ES", "IS"],
        "fish": ["JP", "NO", "PE", "PT", "IS", "SN"],
        "curry": ["IN", "TH", "LK", "MY", "JP", "ID"],
        "rice": ["JP", "ID", "IN", "ES", "SN", "MY"],
        "bread": ["TR", "MA", "FR", "GE", "ET", "IN"],
        "pastry": ["FR", "AT", "PT", "MA", "HU"],
        "cheese": ["FR", "CH", "IT", "GR", "NL"],
        "vegetarian": ["IN", "ET", "LB", "TH", "IL"],
        "vegan": ["ET", "IN", "LB", "TH"],
        "sour": ["VN", "TH", "GE", "PE", "PH"],
        "fresh": ["VN", "GR", "LB", "PE", "TH"],
        "herb": ["VN", "GR", "LB", "MA", "TH"],
        "stew": ["MA", "ET", "HU", "IE", "KR", "NG"],
        "soup": ["VN", "JP", "PL", "TH", "KR", "HU"],
        "street": ["TH", "MX", "VN", "IN", "TR", "MY"],
        "smoky": ["MX", "TR", "ZA", "BR", "KR"],
        "sweet": ["FR", "AT", "TR", "MA", "PH"],
        "comfort": ["IT", "PL", "IE", "HU", "US"],
        "hearty": ["PL", "HU", "DE", "IE", "AR"],
        "fermented": ["KR", "JP", "GE", "IS", "DE"],
        "wine": ["FR", "IT", "ES", "PT", "GE", "AR"],
    ]

    static func suggestions(entries: [Entry], limit: Int = 6) -> [Suggestion] {
        let tried = Set(entries.map(\.countryCode))
        let candidates = CountryStore.all.filter { !tried.contains($0.code) }
        guard !candidates.isEmpty else { return [] }

        // ── What the journal says about your taste ───────────────────────────
        var subregionScore: [String: Double] = [:]
        var continentScore: [String: Double] = [:]
        var flavourScore: [String: Double] = [:]   // country code → weight
        var lovedBySubregion: [String: [String]] = [:]  // subregion → country names
        var rareAffinity = 0.0

        for entry in entries {
            guard let country = CountryStore.byCode[entry.countryCode] else { continue }
            // 5★ → +2, 4★ → +1, 3★ → 0, 2★ → −1, 1★ → −2
            var weight = Double(entry.rating - 3)
            if entry.wouldReturn { weight += 0.5 }
            subregionScore[country.subregion, default: 0] += weight
            continentScore[country.continent, default: 0] += weight * 0.6
            if country.rare { rareAffinity += weight }
            if weight > 0 {
                lovedBySubregion[country.subregion, default: []].append(country.cuisineName)
            }

            guard weight > 0 else { continue }
            let text = "\(entry.notes ?? "") \(entry.signatureDish ?? "")".lowercased()
            for (word, codes) in flavourMap where text.contains(word) {
                for code in codes { flavourScore[code, default: 0] += weight * 0.8 }
            }
        }

        let triedContinents = Set(entries.compactMap { CountryStore.byCode[$0.countryCode]?.continent })
        let triedSubregions = Set(entries.compactMap { CountryStore.byCode[$0.countryCode]?.subregion })

        // ── Score every cuisine you haven't had ──────────────────────────────
        var scored: [(Suggestion, Double)] = []
        for country in candidates {
            var score = 0.0
            var reasons: [(String, Double)] = []

            if let s = subregionScore[country.subregion], s > 0 {
                let value = s * 1.6
                score += value
                let loved = (lovedBySubregion[country.subregion] ?? []).prefix(2).joined(separator: " and ")
                reasons.append((loved.isEmpty ? "Close to cuisines you rate highly"
                                              : "You loved \(loved)", value))
            }
            if let c = continentScore[country.continent], c > 0 {
                score += c * 0.7
            }
            if let f = flavourScore[country.code], f > 0 {
                // Weighted above raw regional affinity: what you *say* you liked
                // is a sharper signal than where the restaurant happened to be.
                let value = f * 2.2
                score += value
                let word = flavourWord(for: country.code, entries: entries) ?? "what you order"
                reasons.append(("You keep going back to \(word)", value))
            }
            if !triedContinents.contains(country.continent) {
                let value = 2.2
                score += value
                reasons.append(("You've never eaten from \(country.continent)", value))
            } else if !triedSubregions.contains(country.subregion) {
                let value = 1.0
                score += value
                reasons.append(("New corner of \(country.continent)", value))
            }
            if country.rare {
                // Only a real nudge once you've shown you enjoy the obscure
                // ones — otherwise it's a faint tiebreak, so a first-time list
                // suggests Malaysian before Bruneian.
                let value = rareAffinity > 0 ? 1.4 : 0.15
                score += value
                if rareAffinity > 0 {
                    reasons.append(("A rare find, and you go for those", value))
                } else {
                    reasons.append(("A rare find — few people log it", value))
                }
            }

            guard score > 0 else { continue }
            let reason = reasons.max { $0.1 < $1.1 }?.0 ?? "Somewhere new"
            scored.append((Suggestion(country: country, reason: reason, score: score), score))
        }

        // Spread the list out: one adored cuisine shouldn't return six
        // neighbours of itself. At most two picks per subregion.
        var perSubregion: [String: Int] = [:]
        var result: [Suggestion] = []
        let ranked = scored.sorted { a, b in
            a.1 == b.1 ? a.0.country.name < b.0.country.name : a.1 > b.1
        }
        for (suggestion, _) in ranked {
            let subregion = suggestion.country.subregion
            guard perSubregion[subregion, default: 0] < 2 else { continue }
            perSubregion[subregion, default: 0] += 1
            result.append(suggestion)
            if result.count == limit { break }
        }
        return result
    }

    /// The flavour word from the user's own notes that pointed at this cuisine.
    private static func flavourWord(for code: String, entries: [Entry]) -> String? {
        let text = entries
            .filter { $0.rating >= 4 }
            .map { "\($0.notes ?? "") \($0.signatureDish ?? "")".lowercased() }
            .joined(separator: " ")
        return flavourMap
            .filter { $0.value.contains(code) && text.contains($0.key) }
            .keys
            .sorted()
            .first
    }
}
