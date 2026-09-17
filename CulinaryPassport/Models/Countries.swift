import Foundation

enum Continent: String, CaseIterable, Codable, Identifiable {
    case africa = "Africa"
    case antarctica = "Antarctica"
    case asia = "Asia"
    case europe = "Europe"
    case northAmerica = "North America"
    case oceania = "Oceania"
    case southAmerica = "South America"

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .africa: "🌍"
        case .antarctica: "🧊"
        case .asia: "🌏"
        case .europe: "🌍"
        case .northAmerica: "🌎"
        case .oceania: "🌏"
        case .southAmerica: "🌎"
        }
    }
}

/// A stampable place. Most come from the bundled Natural Earth 110m polygons;
/// countries too small for that dataset (Singapore, Malta, the Maldives…) and
/// popular destination territories (Hong Kong, Tahiti, Aruba…) are added from
/// `CountryStore.smallPlaces` and drawn on the globe as dots.
struct Country: Identifiable, Hashable {
    let code: String       // ISO 3166-1 alpha-2
    let name: String
    let continent: Continent
    let subregion: String
    let centroid: (lat: Double, lng: Double)
    /// Counts toward "N of 197 countries". Territories are stampable but
    /// don't change the headline count.
    let isSovereign: Bool
    /// Has a polygon on the globe (false → rendered as a marker dot).
    let hasShape: Bool

    var id: String { code }
    var flag: String { Self.flag(for: code) }

    static func == (lhs: Country, rhs: Country) -> Bool { lhs.code == rhs.code }
    func hash(into hasher: inout Hasher) { hasher.combine(code) }

    static func flag(for code: String) -> String {
        code.uppercased().unicodeScalars.reduce(into: "") { result, scalar in
            if let flag = UnicodeScalar(127397 + scalar.value) { result.unicodeScalars.append(flag) }
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if name.localizedCaseInsensitiveContains(q) { return true }
        if code.caseInsensitiveCompare(q) == .orderedSame { return true }
        return (CountryStore.aliases[code] ?? []).contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

enum CountryStore {
    /// Every stampable place, name-sorted. Loaded once.
    static let all: [Country] = load()
    static let byCode: [String: Country] = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })

    /// Places without a polygon — drawn as dots on the globe.
    static let markers: [Country] = all.filter { !$0.hasShape }

    static let sovereignCount = all.filter(\.isSovereign).count

    static func byContinent(_ continent: Continent) -> [Country] {
        all.filter { $0.continent == continent }
    }

    // Natural Earth 110m sets ISO_A2 = -99 for these.
    static let isoFix = ["France": "FR", "Norway": "NO", "Kosovo": "XK"]

    /// Non-sovereign polygons in the 110m data.
    private static let territoryShapes: Set<String> = ["GL", "PR", "NC", "FK", "TF", "EH", "AQ"]

    /// Natural Earth's short labels ("Dem. Rep. Congo") → what people say.
    private static let displayNames: [String: String] = [
        "AQ": "Antarctica", "BA": "Bosnia and Herzegovina", "CD": "DR Congo",
        "CF": "Central African Republic", "CG": "Republic of the Congo",
        "DO": "Dominican Republic", "EH": "Western Sahara", "FK": "Falkland Islands",
        "GQ": "Equatorial Guinea", "SB": "Solomon Islands", "SS": "South Sudan",
        "SZ": "Eswatini", "TF": "French Southern Lands", "US": "United States",
        "MK": "North Macedonia", "PS": "Palestine", "TW": "Taiwan", "XK": "Kosovo",
        "GB": "United Kingdom", "AE": "United Arab Emirates", "CZ": "Czechia",
    ]

    static let aliases: [String: [String]] = [
        "US": ["USA", "America", "United States of America"],
        "GB": ["UK", "Britain", "England", "Scotland", "Wales", "Northern Ireland"],
        "NL": ["Holland"], "MM": ["Burma"], "CZ": ["Czech Republic"],
        "CI": ["Ivory Coast"], "TL": ["East Timor"], "SZ": ["Swaziland"],
        "MK": ["Macedonia"], "CD": ["Congo", "Zaire"], "CG": ["Congo"],
        "KR": ["Korea"], "KP": ["Korea"], "AE": ["UAE", "Dubai", "Abu Dhabi"],
        "VA": ["Holy See", "Vatican"], "CV": ["Cape Verde"], "TR": ["Türkiye", "Turkiye"],
        "PF": ["Tahiti", "Bora Bora"], "RU": ["Russian Federation"], "VN": ["Viet Nam"],
        "LA": ["Lao"], "IR": ["Persia"], "BO": ["Bolivia"], "HK": ["Hong Kong SAR"],
        "MO": ["Macao"], "FM": ["Micronesia"], "KN": ["St Kitts"], "LC": ["St Lucia"],
        "VC": ["St Vincent"], "ST": ["Sao Tome"], "BQ": ["Bonaire"], "SX": ["St Maarten"],
    ]

    /// (code, name, lat, lng, continent, subregion, sovereign)
    static let smallPlaces: [(String, String, Double, Double, Continent, String, Bool)] = [
        // Sovereign states missing from the 110m dataset
        ("AD", "Andorra", 42.546, 1.601, .europe, "Southern Europe", true),
        ("AG", "Antigua and Barbuda", 17.06, -61.80, .northAmerica, "Caribbean", true),
        ("BB", "Barbados", 13.19, -59.54, .northAmerica, "Caribbean", true),
        ("BH", "Bahrain", 26.07, 50.55, .asia, "Western Asia", true),
        ("CV", "Cabo Verde", 16.00, -24.01, .africa, "Western Africa", true),
        ("DM", "Dominica", 15.41, -61.37, .northAmerica, "Caribbean", true),
        ("FM", "Micronesia", 6.92, 158.16, .oceania, "Micronesia", true),
        ("GD", "Grenada", 12.12, -61.68, .northAmerica, "Caribbean", true),
        ("KI", "Kiribati", 1.45, 173.00, .oceania, "Micronesia", true),
        ("KM", "Comoros", -11.88, 43.87, .africa, "Eastern Africa", true),
        ("KN", "Saint Kitts and Nevis", 17.36, -62.78, .northAmerica, "Caribbean", true),
        ("LC", "Saint Lucia", 13.91, -60.98, .northAmerica, "Caribbean", true),
        ("LI", "Liechtenstein", 47.17, 9.56, .europe, "Western Europe", true),
        ("MC", "Monaco", 43.74, 7.42, .europe, "Western Europe", true),
        ("MH", "Marshall Islands", 7.13, 171.18, .oceania, "Micronesia", true),
        ("MT", "Malta", 35.94, 14.38, .europe, "Southern Europe", true),
        ("MU", "Mauritius", -20.35, 57.55, .africa, "Eastern Africa", true),
        ("MV", "Maldives", 3.20, 73.22, .asia, "Southern Asia", true),
        ("NR", "Nauru", -0.52, 166.93, .oceania, "Micronesia", true),
        ("PW", "Palau", 7.51, 134.58, .oceania, "Micronesia", true),
        ("SC", "Seychelles", -4.68, 55.49, .africa, "Eastern Africa", true),
        ("SG", "Singapore", 1.35, 103.82, .asia, "South-Eastern Asia", true),
        ("SM", "San Marino", 43.94, 12.46, .europe, "Southern Europe", true),
        ("ST", "São Tomé and Príncipe", 0.19, 6.61, .africa, "Middle Africa", true),
        ("TO", "Tonga", -21.18, -175.20, .oceania, "Polynesia", true),
        ("TV", "Tuvalu", -7.11, 177.65, .oceania, "Polynesia", true),
        ("VA", "Vatican City", 41.90, 12.45, .europe, "Southern Europe", true),
        ("VC", "Saint Vincent and the Grenadines", 13.25, -61.20, .northAmerica, "Caribbean", true),
        ("WS", "Samoa", -13.76, -172.10, .oceania, "Polynesia", true),
        // Territories people travel to and count
        ("AW", "Aruba", 12.52, -69.97, .northAmerica, "Caribbean", false),
        ("AS", "American Samoa", -14.27, -170.70, .oceania, "Polynesia", false),
        ("AX", "Åland Islands", 60.18, 19.92, .europe, "Northern Europe", false),
        ("BM", "Bermuda", 32.31, -64.75, .northAmerica, "Northern America", false),
        ("BQ", "Caribbean Netherlands", 12.18, -68.26, .northAmerica, "Caribbean", false),
        ("CK", "Cook Islands", -21.24, -159.78, .oceania, "Polynesia", false),
        ("CW", "Curaçao", 12.17, -68.99, .northAmerica, "Caribbean", false),
        ("FO", "Faroe Islands", 62.01, -6.77, .europe, "Northern Europe", false),
        ("GG", "Guernsey", 49.45, -2.58, .europe, "Northern Europe", false),
        ("GI", "Gibraltar", 36.14, -5.35, .europe, "Southern Europe", false),
        ("GP", "Guadeloupe", 16.27, -61.55, .northAmerica, "Caribbean", false),
        ("GU", "Guam", 13.44, 144.79, .oceania, "Micronesia", false),
        ("HK", "Hong Kong", 22.32, 114.17, .asia, "Eastern Asia", false),
        ("IM", "Isle of Man", 54.24, -4.55, .europe, "Northern Europe", false),
        ("JE", "Jersey", 49.21, -2.13, .europe, "Northern Europe", false),
        ("KY", "Cayman Islands", 19.31, -81.25, .northAmerica, "Caribbean", false),
        ("MO", "Macau", 22.20, 113.54, .asia, "Eastern Asia", false),
        ("MP", "Northern Mariana Islands", 15.18, 145.75, .oceania, "Micronesia", false),
        ("MQ", "Martinique", 14.64, -61.02, .northAmerica, "Caribbean", false),
        ("PF", "French Polynesia", -17.65, -149.43, .oceania, "Polynesia", false),
        ("RE", "Réunion", -21.12, 55.54, .africa, "Eastern Africa", false),
        ("SJ", "Svalbard", 78.22, 15.65, .europe, "Northern Europe", false),
        ("SX", "Sint Maarten", 18.04, -63.05, .northAmerica, "Caribbean", false),
        ("TC", "Turks and Caicos Islands", 21.69, -71.80, .northAmerica, "Caribbean", false),
        ("VG", "British Virgin Islands", 18.42, -64.64, .northAmerica, "Caribbean", false),
        ("VI", "U.S. Virgin Islands", 18.34, -64.90, .northAmerica, "Caribbean", false),
    ]

    private static func load() -> [Country] {
        var countries: [Country] = []
        var seen = Set<String>()

        if let url = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
           let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let features = root["features"] as? [[String: Any]] {
            for feature in features {
                guard let props = feature["properties"] as? [String: Any] else { continue }
                var code = props["ISO_A2"] as? String ?? ""
                if code.count != 2 || code == "-9" {
                    code = isoFix[props["ADMIN"] as? String ?? ""] ?? ""
                }
                guard code.count == 2, code.allSatisfy({ $0.isUppercase }), !seen.contains(code) else { continue }
                seen.insert(code)
                let rawContinent = props["CONTINENT"] as? String ?? ""
                countries.append(Country(
                    code: code,
                    name: displayNames[code] ?? props["NAME"] as? String ?? props["ADMIN"] as? String ?? code,
                    // "Seven seas (open ocean)" is only the French Southern
                    // Lands — sub-Antarctic islands.
                    continent: Continent(rawValue: rawContinent) ?? .antarctica,
                    subregion: props["SUBREGION"] as? String ?? "",
                    centroid: centroid(of: feature["geometry"] as? [String: Any]),
                    isSovereign: !territoryShapes.contains(code),
                    hasShape: true
                ))
            }
        } else {
            assertionFailure("countries.geojson missing from bundle")
        }

        for (code, name, lat, lng, continent, subregion, sovereign) in smallPlaces where !seen.contains(code) {
            seen.insert(code)
            countries.append(Country(code: code, name: name, continent: continent, subregion: subregion,
                                     centroid: (lat, lng), isSovereign: sovereign, hasShape: false))
        }

        return countries.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Vertex average of the largest outer ring — close enough to aim the camera.
    private static func centroid(of geometry: [String: Any]?) -> (lat: Double, lng: Double) {
        guard let geometry else { return (0, 0) }
        let polys: [[[[Double]]]]
        if geometry["type"] as? String == "Polygon", let c = geometry["coordinates"] as? [[[Double]]] {
            polys = [c]
        } else if let c = geometry["coordinates"] as? [[[[Double]]]] {
            polys = c
        } else {
            return (0, 0)
        }
        var best: [[Double]] = []
        var bestArea = -1.0
        for poly in polys {
            guard let ring = poly.first, ring.count > 2 else { continue }
            var area = 0.0
            for i in 0..<(ring.count - 1) {
                area += ring[i][0] * ring[i + 1][1] - ring[i + 1][0] * ring[i][1]
            }
            if abs(area) > bestArea {
                bestArea = abs(area)
                best = ring
            }
        }
        guard best.count > 1 else { return (0, 0) }
        let n = Double(best.count - 1) // last vertex repeats the first
        let sum = best.dropLast().reduce((lat: 0.0, lng: 0.0)) { ($0.lat + $1[1], $0.lng + $1[0]) }
        return (sum.lat / n, sum.lng / n)
    }
}
