import Foundation

/// Point → place on the globe, tuned for real locations (where a restaurant
/// is) rather than globe taps.
///
/// The bundled Natural Earth 110m polygons don't include the small places
/// people stamp (Singapore, Hong Kong, Vatican City…), and several of them sit
/// inside or beside a much bigger neighbour. So, in order:
///
///  1. **Outlines** for the small places that share a land border. A radius
///     around Hong Kong's centre reaches Shenzhen, and around Singapore's
///     reaches Johor Bahru; these lines don't.
///  2. **Circles** for island places, one per island group — a single circle
///     big enough to cover all of Kiribati would swallow 3,000 km of ocean and
///     still miss Kiritimati.
///  3. **Country polygons**, then a short coastal snap: the 110m coastline is
///     coarse, so a beach photo can land a few kilometres "offshore".
///
/// Outlines and circles are hand-built and accurate to a few hundred metres —
/// enough to put a photo in the right country, not to survey a border.
enum PlaceLocator {
    static func country(lat: Double, lng: Double, coastalSnapKm: Double = 12) -> String? {
        for outline in outlines where outline.contains(lat: lat, lng: lng) {
            return outline.code
        }
        var best: (code: String, fit: Double)?
        for island in islands {
            // Cheap bounding check before the trig.
            guard abs(island.lat - lat) < island.km / 100 + 0.5 else { continue }
            let fit = Geo.distanceKm(lat, lng, island.lat, island.lng) / island.km
            if fit <= 1, best == nil || fit < best!.fit { best = (island.code, fit) }
        }
        if let best { return best.code }
        if let code = CountryGeometry.country(atLat: lat, lng: lng) { return code }
        return CountryGeometry.nearestCountry(atLat: lat, lng: lng, withinKm: coastalSnapKm)
    }

    // ── Outlines: small places with a land border ────────────────────────────

    struct Outline {
        let code: String
        let ring: Ring
        let minLng: Double, maxLng: Double, minLat: Double, maxLat: Double

        init(_ code: String, _ points: [(Double, Double)]) {
            self.code = code
            ring = points.map { SIMD2<Double>($0.0, $0.1) }
            minLng = ring.map(\.x).min() ?? 0
            maxLng = ring.map(\.x).max() ?? 0
            minLat = ring.map(\.y).min() ?? 0
            maxLat = ring.map(\.y).max() ?? 0
        }

        func contains(lat: Double, lng: Double) -> Bool {
            guard lng >= minLng, lng <= maxLng, lat >= minLat, lat <= maxLat else { return false }
            return CountryGeometry.contains(ring, lng: lng, lat: lat)
        }
    }

    /// (lng, lat), following the border as it runs on the ground.
    static let outlines: [Outline] = [
        // Hong Kong: the Sham Chun River and Deep Bay separate it from
        // Shenzhen — Futian sits barely 2 km north of the river.
        Outline("HK", [
            (113.825, 22.133), (113.825, 22.280), (113.850, 22.430),   // west, Pearl estuary
            (113.930, 22.475), (113.970, 22.495),                      // Deep Bay
            (114.015, 22.508), (114.066, 22.518), (114.090, 22.522),   // Sham Chun River
            (114.116, 22.530), (114.131, 22.541), (114.160, 22.562),   // Lo Wu, Man Kam To
            (114.190, 22.556), (114.223, 22.546),                      // Sha Tau Kok
            (114.250, 22.555), (114.330, 22.575), (114.400, 22.555),   // Mirs Bay
            (114.440, 22.550), (114.460, 22.500), (114.520, 22.400),
            (114.520, 22.133),
        ]),
        // Macau: the Border Gate to Zhuhai's Gongbei, and the Shizimen
        // channel between Coloane and Hengqin.
        Outline("MO", [
            (113.533, 22.217), (113.556, 22.217), (113.565, 22.195),   // Border Gate, Outer Harbour
            (113.600, 22.160), (113.600, 22.130), (113.580, 22.105),   // Taipa, airport, Coloane
            (113.545, 22.105), (113.540, 22.125), (113.544, 22.145),   // Hengqin channel
            (113.542, 22.165), (113.533, 22.185), (113.532, 22.205),   // Inner Harbour
        ]),
        // Singapore: the Johor Strait, about a kilometre wide at the Causeway.
        Outline("SG", [
            (103.600, 1.180), (103.590, 1.290), (103.625, 1.345),      // Tuas, Second Link
            (103.650, 1.400), (103.700, 1.435), (103.740, 1.455),      // Kranji
            (103.768, 1.456), (103.800, 1.472), (103.840, 1.470),      // Causeway, Sembawang
            (103.900, 1.440), (103.960, 1.425), (104.030, 1.430),      // Seletar, Pulau Ubin
            (104.060, 1.390), (104.080, 1.320), (104.100, 1.260),      // Tekong, east strait
            (103.950, 1.210), (103.760, 1.160),                        // southern islands
        ]),
        // Gibraltar: the frontier runs along the north side of the runway.
        Outline("GI", [
            (-5.372, 36.1552), (-5.338, 36.1552), (-5.330, 36.1300),
            (-5.340, 36.1040), (-5.360, 36.1100), (-5.372, 36.1300),
        ]),
        // Vatican City: the walls, plus St Peter's Square out to the line
        // between the colonnades.
        Outline("VA", [
            (12.4587, 41.9036), (12.4587, 41.9008), (12.4556, 41.9004),
            (12.4520, 41.8998), (12.4478, 41.9003), (12.4455, 41.9030),
            (12.4462, 41.9058), (12.4510, 41.9075), (12.4553, 41.9068),
            (12.4572, 41.9046),
        ]),
        // Monaco: a strip along the coast, with Beausoleil and Cap-d'Ail
        // (France) a few streets uphill.
        Outline("MC", [
            (7.4120, 43.7220), (7.4210, 43.7230), (7.4300, 43.7320),   // offshore
            (7.4420, 43.7430), (7.4440, 43.7530), (7.4380, 43.7500),   // Larvotto, Saint-Roman
            (7.4270, 43.7430), (7.4210, 43.7400), (7.4140, 43.7370),   // Beausoleil border
            (7.4090, 43.7320), (7.4080, 43.7270),                      // Cap-d'Ail border
        ]),
        Outline("SM", [
            (12.4900, 43.9924), (12.5163, 43.9800), (12.5100, 43.9500),  // Dogana
            (12.5050, 43.9200), (12.4900, 43.8950), (12.4600, 43.8935),  // Faetano
            (12.4200, 43.8980), (12.4032, 43.9200), (12.4100, 43.9550),  // Chiesanuova
            (12.4450, 43.9750), (12.4700, 43.9850),                      // Serravalle
        ]),
        // Liechtenstein: the Rhine to Switzerland, the ridge to Austria.
        Outline("LI", [
            (9.4800, 47.0550), (9.4940, 47.0980), (9.5020, 47.1375),   // Rhine: Balzers → Vaduz
            (9.4870, 47.1630), (9.4960, 47.2100), (9.5120, 47.2400),   // Schaan, Bendern, Ruggell
            (9.5320, 47.2705), (9.5550, 47.2500), (9.5700, 47.2180),   // Schellenberg, Schaanwald
            (9.6050, 47.1750), (9.6350, 47.1300), (9.6250, 47.0850),   // Malbun ridge
            (9.5900, 47.0520), (9.5300, 47.0484),
        ]),
        Outline("AD", [
            (1.4650, 42.4288), (1.5300, 42.4450), (1.5800, 42.4700),   // Spanish border
            (1.6600, 42.4950), (1.7300, 42.5000), (1.7866, 42.5300),   // Pas de la Casa
            (1.7800, 42.5500), (1.7400, 42.5800), (1.7200, 42.6150),   // French border
            (1.6000, 42.6558), (1.5000, 42.6450), (1.4300, 42.6100),
            (1.4135, 42.5500), (1.4350, 42.4800),
        ]),
        // Saint Martin is one island, two countries: Dutch south, French north.
        Outline("SX", [
            (-63.1270, 18.0500), (-63.1250, 18.0330), (-63.1150, 18.0230),  // Cupecoy, Maho
            (-63.0900, 18.0080), (-63.0500, 18.0120), (-63.0200, 18.0180),  // Simpson Bay, Philipsburg
            (-63.0060, 18.0430), (-63.0130, 18.0570), (-63.0400, 18.0620),  // Oyster Pond, border
            (-63.0700, 18.0600), (-63.1000, 18.0570), (-63.1270, 18.0560),
        ]),
        Outline("MF", [
            (-63.1450, 18.0480), (-63.1270, 18.0560), (-63.1000, 18.0570),  // Terres Basses, border
            (-63.0700, 18.0600), (-63.0400, 18.0620), (-63.0130, 18.0570),
            (-63.0150, 18.0700), (-63.0250, 18.1050), (-63.0600, 18.1200),  // Anse Marcel, Grand Case
            (-63.1000, 18.1150), (-63.1200, 18.0950), (-63.1450, 18.0700),  // Marigot
        ]),
    ]

    // ── Circles: one per island group ────────────────────────────────────────

    struct Island {
        let code: String, lat: Double, lng: Double, km: Double
    }

    static let islands: [Island] = [
        // Europe & the Atlantic
        Island(code: "AX", lat: 60.20, lng: 19.95, km: 45),
        Island(code: "AX", lat: 60.05, lng: 20.65, km: 25),   // Föglö, Kökar
        Island(code: "FO", lat: 62.01, lng: -6.85, km: 80),
        Island(code: "GG", lat: 49.45, lng: -2.58, km: 13),
        Island(code: "JE", lat: 49.21, lng: -2.13, km: 13),
        Island(code: "IM", lat: 54.24, lng: -4.55, km: 32),
        Island(code: "MT", lat: 35.92, lng: 14.42, km: 28),
        Island(code: "SJ", lat: 78.22, lng: 15.65, km: 300),
        Island(code: "SJ", lat: 74.50, lng: 19.00, km: 40),   // Bear Island
        Island(code: "CV", lat: 16.00, lng: -24.01, km: 260),
        Island(code: "BM", lat: 32.31, lng: -64.75, km: 28),
        Island(code: "PM", lat: 46.88, lng: -56.32, km: 30),
        // Caribbean
        Island(code: "AG", lat: 17.07, lng: -61.80, km: 25),
        Island(code: "AG", lat: 17.62, lng: -61.78, km: 16),  // Barbuda
        Island(code: "AI", lat: 18.22, lng: -63.05, km: 16),
        Island(code: "AW", lat: 12.52, lng: -69.97, km: 22),
        Island(code: "BB", lat: 13.19, lng: -59.54, km: 25),
        Island(code: "BL", lat: 17.90, lng: -62.83, km: 12),
        Island(code: "BQ", lat: 12.18, lng: -68.26, km: 30),  // Bonaire
        Island(code: "BQ", lat: 17.49, lng: -62.98, km: 10),  // Sint Eustatius
        Island(code: "BQ", lat: 17.63, lng: -63.24, km: 8),   // Saba
        Island(code: "CW", lat: 12.17, lng: -68.99, km: 36),
        Island(code: "DM", lat: 15.41, lng: -61.37, km: 25),
        Island(code: "GD", lat: 12.12, lng: -61.68, km: 25),
        Island(code: "GD", lat: 12.48, lng: -61.45, km: 14),  // Carriacou
        Island(code: "GP", lat: 16.25, lng: -61.58, km: 45),
        Island(code: "GP", lat: 15.87, lng: -61.58, km: 16),  // Les Saintes
        Island(code: "GP", lat: 15.93, lng: -61.27, km: 18),  // Marie-Galante
        Island(code: "KN", lat: 17.30, lng: -62.75, km: 22),
        Island(code: "KY", lat: 19.31, lng: -81.25, km: 40),
        Island(code: "KY", lat: 19.70, lng: -79.87, km: 30),  // Cayman Brac, Little Cayman
        Island(code: "LC", lat: 13.91, lng: -60.98, km: 25),
        Island(code: "MF", lat: 18.08, lng: -63.06, km: 10),
        Island(code: "MQ", lat: 14.64, lng: -61.02, km: 35),
        Island(code: "MS", lat: 16.74, lng: -62.19, km: 14),
        Island(code: "SX", lat: 18.03, lng: -63.06, km: 10),
        Island(code: "TC", lat: 21.78, lng: -72.25, km: 45),
        Island(code: "TC", lat: 21.50, lng: -71.20, km: 45),  // Grand Turk, Salt Cay
        Island(code: "VC", lat: 13.25, lng: -61.20, km: 22),
        Island(code: "VC", lat: 12.98, lng: -61.28, km: 16),  // Bequia, Mustique
        Island(code: "VC", lat: 12.65, lng: -61.40, km: 20),  // Union Island
        Island(code: "VG", lat: 18.43, lng: -64.62, km: 12),  // Tortola
        Island(code: "VG", lat: 18.48, lng: -64.40, km: 12),  // Virgin Gorda
        Island(code: "VG", lat: 18.73, lng: -64.33, km: 14),  // Anegada
        Island(code: "VG", lat: 18.44, lng: -64.75, km: 8),   // Jost Van Dyke
        Island(code: "VI", lat: 18.34, lng: -64.93, km: 14),  // St Thomas
        Island(code: "VI", lat: 18.33, lng: -64.74, km: 9),   // St John
        Island(code: "VI", lat: 17.73, lng: -64.78, km: 25),  // St Croix
        // Africa & the Indian Ocean
        Island(code: "KM", lat: -11.70, lng: 43.27, km: 40),
        Island(code: "KM", lat: -12.22, lng: 44.43, km: 30),  // Anjouan
        Island(code: "KM", lat: -12.30, lng: 43.73, km: 25),  // Mohéli
        Island(code: "YT", lat: -12.83, lng: 45.15, km: 35),
        Island(code: "MU", lat: -20.28, lng: 57.57, km: 40),
        Island(code: "MU", lat: -19.70, lng: 63.42, km: 25),  // Rodrigues
        Island(code: "RE", lat: -21.12, lng: 55.54, km: 45),
        Island(code: "SC", lat: -4.62, lng: 55.45, km: 60),
        Island(code: "SC", lat: -4.32, lng: 55.73, km: 30),   // Praslin, La Digue
        Island(code: "SC", lat: -9.42, lng: 46.40, km: 60),   // Aldabra
        Island(code: "ST", lat: 0.25, lng: 6.60, km: 60),
        Island(code: "ST", lat: 1.61, lng: 7.41, km: 40),     // Príncipe
        // Asia
        Island(code: "BH", lat: 26.05, lng: 50.55, km: 30),
        Island(code: "MV", lat: 4.20, lng: 73.40, km: 250),
        Island(code: "MV", lat: 6.70, lng: 73.05, km: 120),   // northern atolls
        Island(code: "MV", lat: 1.50, lng: 73.20, km: 200),
        Island(code: "MV", lat: -0.60, lng: 73.15, km: 80),   // Addu
        // The Pacific
        Island(code: "AS", lat: -14.30, lng: -170.70, km: 40),
        Island(code: "AS", lat: -14.22, lng: -169.50, km: 25),  // Manu'a
        Island(code: "CK", lat: -20.00, lng: -159.50, km: 400), // southern Cooks
        Island(code: "CK", lat: -10.00, lng: -161.00, km: 450), // northern Cooks
        Island(code: "CK", lat: -10.90, lng: -165.80, km: 120), // Pukapuka
        Island(code: "FM", lat: 6.90, lng: 158.20, km: 120),    // Pohnpei
        Island(code: "FM", lat: 7.40, lng: 151.80, km: 150),    // Chuuk
        Island(code: "FM", lat: 9.50, lng: 138.10, km: 120),    // Yap
        Island(code: "FM", lat: 5.32, lng: 163.00, km: 60),     // Kosrae
        Island(code: "GU", lat: 13.44, lng: 144.79, km: 32),
        Island(code: "KI", lat: 1.45, lng: 173.00, km: 550),    // Gilberts
        Island(code: "KI", lat: -3.00, lng: -171.70, km: 300),  // Phoenix
        Island(code: "KI", lat: 3.00, lng: -158.50, km: 350),   // Line, incl. Kiritimati
        Island(code: "MH", lat: 7.10, lng: 171.20, km: 150),    // Majuro
        Island(code: "MH", lat: 8.72, lng: 167.73, km: 200),    // Kwajalein
        Island(code: "MH", lat: 11.40, lng: 165.50, km: 200),   // Bikini
        Island(code: "MH", lat: 11.35, lng: 162.33, km: 100),   // Enewetak
        Island(code: "MP", lat: 15.18, lng: 145.75, km: 70),    // Saipan, Tinian
        Island(code: "MP", lat: 14.15, lng: 145.20, km: 25),    // Rota
        Island(code: "MP", lat: 16.35, lng: 145.80, km: 60),    // northern islands
        Island(code: "NR", lat: -0.52, lng: 166.93, km: 10),
        Island(code: "NU", lat: -19.05, lng: -169.87, km: 25),
        Island(code: "PF", lat: -17.60, lng: -149.60, km: 300), // Society
        Island(code: "PF", lat: -15.50, lng: -146.50, km: 400), // Tuamotu
        Island(code: "PF", lat: -9.00, lng: -139.50, km: 250),  // Marquesas
        Island(code: "PF", lat: -22.50, lng: -150.00, km: 350), // Austral
        Island(code: "PF", lat: -23.10, lng: -134.97, km: 120), // Gambier
        Island(code: "PW", lat: 7.45, lng: 134.52, km: 100),
        Island(code: "TO", lat: -21.18, lng: -175.20, km: 120), // Tongatapu
        Island(code: "TO", lat: -19.80, lng: -174.40, km: 90),  // Ha'apai
        Island(code: "TO", lat: -18.65, lng: -173.98, km: 80),  // Vava'u
        Island(code: "TV", lat: -8.52, lng: 179.20, km: 180),
        Island(code: "TV", lat: -6.30, lng: 176.30, km: 200),   // northern atolls
        Island(code: "WF", lat: -13.30, lng: -176.17, km: 30),
        Island(code: "WF", lat: -14.30, lng: -178.10, km: 30),  // Futuna
        Island(code: "WS", lat: -13.76, lng: -172.10, km: 90),
    ]
}

enum Geo {
    /// Great-circle distance in kilometres (haversine).
    static func distanceKm(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}
