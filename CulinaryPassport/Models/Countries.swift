import Foundation

/// One selectable cuisine/country — parsed from the bundled Natural Earth 110m
/// GeoJSON (same file the web app ships; geometry is kept for the globe build).
struct Country: Identifiable, Hashable {
    let code: String       // ISO_A2
    let name: String
    let continent: String
    let subregion: String
    let centroid: (lat: Double, lng: Double)
    let rare: Bool

    var id: String { code }
    var flagEmoji: String {
        code.unicodeScalars.reduce(into: "") { result, scalar in
            if let flag = UnicodeScalar(127397 + scalar.value) { result.unicodeScalars.append(flag) }
        }
    }
    /// "Georgian restaurant" beats "Georgia restaurant" in search queries.
    var cuisineName: String { Self.demonyms[code] ?? name }

    static func == (lhs: Country, rhs: Country) -> Bool { lhs.code == rhs.code }
    func hash(into hasher: inout Hasher) { hasher.combine(code) }

    // Mirrors web src/config.ts DEMONYMS
    static let demonyms: [String: String] = [
        "AF": "Afghan", "AL": "Albanian", "AR": "Argentinian", "AM": "Armenian", "AU": "Australian",
        "AT": "Austrian", "BD": "Bangladeshi", "BE": "Belgian", "BO": "Bolivian", "BA": "Bosnian",
        "BR": "Brazilian", "BG": "Bulgarian", "KH": "Cambodian", "CA": "Canadian", "CL": "Chilean",
        "CN": "Chinese", "CO": "Colombian", "HR": "Croatian", "CU": "Cuban", "CY": "Cypriot",
        "CZ": "Czech", "DK": "Danish", "DO": "Dominican", "EC": "Ecuadorian", "EG": "Egyptian",
        "ET": "Ethiopian", "FJ": "Fijian", "FI": "Finnish", "FR": "French", "GE": "Georgian",
        "DE": "German", "GH": "Ghanaian", "GR": "Greek", "GT": "Guatemalan", "HT": "Haitian",
        "HN": "Honduran", "HU": "Hungarian", "IS": "Icelandic", "IN": "Indian", "ID": "Indonesian",
        "IR": "Persian", "IQ": "Iraqi", "IE": "Irish", "IL": "Israeli", "IT": "Italian",
        "JM": "Jamaican", "JP": "Japanese", "JO": "Jordanian", "KZ": "Kazakh", "KE": "Kenyan",
        "KR": "Korean", "KP": "North Korean", "LA": "Laotian", "LB": "Lebanese", "LY": "Libyan",
        "MG": "Malagasy", "MY": "Malaysian", "ML": "Malian", "MX": "Mexican", "MN": "Mongolian",
        "MA": "Moroccan", "MM": "Burmese", "NP": "Nepalese", "NL": "Dutch", "NZ": "New Zealand",
        "NG": "Nigerian", "NO": "Norwegian", "PK": "Pakistani", "PA": "Panamanian", "PY": "Paraguayan",
        "PE": "Peruvian", "PH": "Filipino", "PL": "Polish", "PT": "Portuguese", "RO": "Romanian",
        "RU": "Russian", "SA": "Saudi Arabian", "SN": "Senegalese", "RS": "Serbian", "SG": "Singaporean",
        "SK": "Slovak", "SI": "Slovenian", "SO": "Somali", "ZA": "South African", "ES": "Spanish",
        "LK": "Sri Lankan", "SD": "Sudanese", "SE": "Swedish", "CH": "Swiss", "SY": "Syrian",
        "TW": "Taiwanese", "TZ": "Tanzanian", "TH": "Thai", "TN": "Tunisian", "TR": "Turkish",
        "UA": "Ukrainian", "GB": "British", "US": "American", "UY": "Uruguayan", "UZ": "Uzbek",
        "VE": "Venezuelan", "VN": "Vietnamese", "YE": "Yemeni", "ZM": "Zambian", "ZW": "Zimbabwean",
    ]

    // Mirrors web src/config.ts RARE_CODES
    static let rareCodes: Set<String> = [
        "BT", "KM", "KI", "NR", "TV", "PW", "MH", "FM", "SS", "TD", "CF", "ER",
        "DJ", "GW", "GQ", "ST", "TL", "BN", "MV", "SM", "AD", "LI", "MC", "VU",
        "SB", "TO", "WS", "TM", "GA", "LS", "SZ", "BI", "NE", "MR",
    ]
}

enum CountryStore {
    /// All selectable countries, name-sorted. Loaded once from the bundle.
    static let all: [Country] = load()
    static let byCode: [String: Country] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    // Natural Earth quirk: ISO_A2 = -99 for these in the 110m dataset (web geo.ts ISO_FIX)
    private static let isoFix = ["France": "FR", "Norway": "NO", "Kosovo": "XK"]

    private static func load() -> [Country] {
        guard let url = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]]
        else {
            assertionFailure("countries.geojson missing from bundle")
            return []
        }

        var countries: [Country] = []
        for feature in features {
            guard let props = feature["properties"] as? [String: Any] else { continue }
            var code = props["ISO_A2"] as? String ?? ""
            if code.count != 2 || code == "-9" {
                code = isoFix[props["ADMIN"] as? String ?? ""] ?? ""
            }
            guard code.count == 2, code.allSatisfy({ $0.isUppercase }), code != "AQ" else { continue }
            countries.append(Country(
                code: code,
                name: props["NAME"] as? String ?? props["ADMIN"] as? String ?? "Unknown",
                continent: props["CONTINENT"] as? String ?? "",
                subregion: props["SUBREGION"] as? String ?? "",
                centroid: centroid(of: feature["geometry"] as? [String: Any]),
                rare: Country.rareCodes.contains(code)
            ))
        }
        return countries.sorted { $0.name < $1.name }
    }

    /// Vertex average of the largest outer ring — matches the web's analyzeGeometry.
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
