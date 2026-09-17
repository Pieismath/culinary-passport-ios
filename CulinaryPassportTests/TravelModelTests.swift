import XCTest
import UIKit
@testable import CulinaryPassport

final class TravelModelTests: XCTestCase {
    private let me = UUID()

    private func memory(_ code: String, _ date: String, city: String? = nil, photos: Int = 0,
                        lat: Double? = nil, lng: Double? = nil, title: String = "") -> Memory {
        Memory(id: UUID(), userId: me, countryCode: code, title: title, city: city, date: date,
               notes: nil, photos: (0..<photos).map { "p\($0)" }, lat: lat, lng: lng,
               visibility: .friends, createdAt: Date())
    }

    private func stamp(_ code: String, _ first: String?, _ last: String? = nil,
                       source: Stamp.Source = .manual) -> Stamp {
        Stamp(userId: me, countryCode: code, firstVisited: first, lastVisited: last ?? first,
              source: source, createdAt: Date())
    }

    // ── Countries ────────────────────────────────────────────────────────────

    func testSmallCountriesAreStampable() {
        for code in ["SG", "MT", "MC", "VA", "MV", "BH", "HK", "PF"] {
            XCTAssertNotNil(CountryStore.byCode[code], "\(code) should be stampable")
        }
        XCTAssertEqual(CountryStore.byCode["SG"]?.hasShape, false)
        XCTAssertEqual(CountryStore.byCode["HK"]?.isSovereign, false)
    }

    func testCountryCountAndContinents() {
        // 193 UN members + Vatican City + Palestine + Taiwan + Kosovo.
        XCTAssertEqual(CountryStore.sovereignCount, 197)
        // Antarctica is a destination now, and "Seven seas" is not a continent.
        XCTAssertEqual(CountryStore.byCode["AQ"]?.continent, .antarctica)
        XCTAssertEqual(CountryStore.byCode["TF"]?.continent, .antarctica)
        XCTAssertEqual(Set(CountryStore.all.map(\.continent)).count, 7)
    }

    func testCodesAreUniqueAndFlagsRender() {
        XCTAssertEqual(CountryStore.all.count, Set(CountryStore.all.map(\.code)).count)
        XCTAssertEqual(Country.flag(for: "JP"), "🇯🇵")
    }

    func testSearchMatchesAliases() {
        XCTAssertTrue(CountryStore.byCode["US"]!.matches("usa"))
        XCTAssertTrue(CountryStore.byCode["GB"]!.matches("England"))
        XCTAssertTrue(CountryStore.byCode["CZ"]!.matches("czech republic"))
        XCTAssertFalse(CountryStore.byCode["FR"]!.matches("Japan"))
    }

    // ── Photo locations → places ─────────────────────────────────────────────

    func testSmallPlacesWinInsideLargerPolygons() {
        XCTAssertEqual(PlaceLocator.country(lat: 41.9029, lng: 12.4534), "VA") // St Peter's
        XCTAssertEqual(PlaceLocator.country(lat: 41.8902, lng: 12.4922), "IT") // Colosseum
        XCTAssertEqual(PlaceLocator.country(lat: 22.2855, lng: 114.1577), "HK") // Central
        XCTAssertEqual(PlaceLocator.country(lat: 1.2834, lng: 103.8607), "SG") // Marina Bay
        XCTAssertEqual(PlaceLocator.country(lat: 35.8989, lng: 14.5146), "MT") // Valletta
    }

    /// Each pair is metres-to-kilometres apart across a border a circle around
    /// the small place could never see.
    func testBorderTownsStayInTheirOwnCountry() {
        let pairs: [(String, Double, Double, String)] = [
            ("Lok Ma Chau", 22.5146, 114.0659, "HK"), ("Futian checkpoint", 22.5250, 114.0666, "CN"),
            ("Shenzhen CBD", 22.5400, 114.0570, "CN"), ("Tsim Sha Tsui", 22.2950, 114.1720, "HK"),
            ("Woodlands", 1.4450, 103.7690, "SG"), ("Johor Bahru", 1.4655, 103.7578, "MY"),
            ("Legoland Malaysia", 1.4285, 103.6292, "MY"), ("Tuas", 1.3200, 103.6400, "SG"),
            ("Senado Square", 22.1935, 113.5398, "MO"), ("Zhuhai Gongbei", 22.2240, 113.5480, "CN"),
            ("Gibraltar town", 36.1408, -5.3536, "GI"), ("La Línea", 36.1650, -5.3480, "ES"),
            ("Monte Carlo", 43.7395, 7.4280, "MC"), ("Beausoleil", 43.7450, 7.4240, "FR"),
            ("Vaduz", 47.1410, 9.5215, "LI"), ("Buchs", 47.1680, 9.4780, "CH"),
            ("Feldkirch", 47.2380, 9.5980, "AT"),
            ("San Marino", 43.9360, 12.4460, "SM"), ("Rimini", 44.0600, 12.5700, "IT"),
            ("Andorra la Vella", 42.5063, 1.5218, "AD"), ("La Seu d'Urgell", 42.3580, 1.4560, "ES"),
            ("Piazza Navona", 41.8992, 12.4731, "IT"),
            ("Philipsburg", 18.0260, -63.0450, "SX"), ("Marigot", 18.0680, -63.0830, "MF"),
        ]
        for (name, lat, lng, expected) in pairs {
            XCTAssertEqual(PlaceLocator.country(lat: lat, lng: lng), expected, name)
        }
    }

    func testIslandGroupsFarFromTheirCapitalStillResolve() {
        let places: [(String, Double, Double, String)] = [
            ("Vava'u", -18.6500, -173.9800, "TO"), ("Chuuk", 7.4500, 151.8500, "FM"),
            ("Yap", 9.5100, 138.1300, "FM"), ("Kiritimati", 1.8700, -157.4000, "KI"),
            ("Tarawa", 1.3300, 172.9800, "KI"), ("Nuku Hiva", -8.9000, -140.1000, "PF"),
            ("Bora Bora", -16.5000, -151.7500, "PF"), ("Rodrigues", -19.7000, 63.4200, "MU"),
            ("Cayman Brac", 19.7200, -79.8000, "KY"), ("Carriacou", 12.4800, -61.4500, "GD"),
            ("Mayotte", -12.7800, 45.2300, "YT"), ("Grande Comore", -11.7000, 43.2500, "KM"),
            ("Saba", 17.6300, -63.2400, "BQ"), ("Tortola", 18.4300, -64.6200, "VG"),
            ("St John", 18.3300, -64.7400, "VI"), ("Addu Atoll", -0.6300, 73.1500, "MV"),
        ]
        for (name, lat, lng, expected) in places {
            XCTAssertEqual(PlaceLocator.country(lat: lat, lng: lng), expected, name)
        }
    }

    func testEveryPlaceTheLocatorCanReturnIsStampable() {
        for code in Set(PlaceLocator.outlines.map(\.code) + PlaceLocator.islands.map(\.code)) {
            XCTAssertNotNil(CountryStore.byCode[code], "\(code) resolves from photos but isn't in the passport")
        }
    }

    func testInlandPhotosResolveToTheirCountry() {
        XCTAssertEqual(PlaceLocator.country(lat: 48.8584, lng: 2.2945), "FR")  // Eiffel Tower
        XCTAssertEqual(PlaceLocator.country(lat: 35.0116, lng: 135.7681), "JP") // Kyoto
        XCTAssertEqual(PlaceLocator.country(lat: -13.1631, lng: -72.5450), "PE") // Machu Picchu
    }

    func testOpenOceanStaysUnresolved() {
        XCTAssertNil(PlaceLocator.country(lat: 0, lng: -30))   // mid-Atlantic
        XCTAssertNil(PlaceLocator.country(lat: -40, lng: -120)) // South Pacific
    }

    func testCoastalSnapStaysTight() {
        // A beach photo a few km off the coarse coastline still counts…
        XCTAssertNotNil(CountryGeometry.nearestCountry(atLat: 39.0, lng: -9.52, withinKm: 12))
        // …but globe taps never snap (the geometry tests keep that honest).
        XCTAssertNil(CountryGeometry.nearestCountry(atLat: 39.0, lng: -11.5, withinKm: 12))
    }

    // ── Stats ────────────────────────────────────────────────────────────────

    func testStatsSeparateCountriesFromTerritories() {
        let stats = TravelStats(stamps: [stamp("JP", "2024-04-01"), stamp("HK", "2024-04-19"),
                                         stamp("FR", nil), stamp("AQ", "2020-01-01")],
                                memories: [memory("JP", "2024-04-12", city: "Kyoto", photos: 2),
                                           memory("JP", "2024-04-09", city: "Tokyo", photos: 1),
                                           memory("JP", "2024-04-10", city: "kyoto")])
        XCTAssertEqual(stats.countries, 2)       // JP, FR
        XCTAssertEqual(stats.territories, 2)     // HK, AQ
        XCTAssertEqual(stats.continents, 3)      // Asia, Europe, Antarctica
        XCTAssertEqual(stats.cities, 2)          // Kyoto (case-insensitive), Tokyo
        XCTAssertEqual(stats.photos, 3)
        XCTAssertEqual(stats.continentProgress[.asia]?.visited, 2)
    }

    func testWorldPercentText() {
        var stats = TravelStats()
        XCTAssertEqual(stats.worldPercentText, "0%")
        stats.countries = 1
        XCTAssertEqual(stats.worldPercentText, "<1%")
        stats.countries = 2
        XCTAssertEqual(stats.worldPercentText, "1%")
        stats.countries = 20
        XCTAssertEqual(stats.worldPercentText, "10%")
    }

    func testNewCountriesThisYearUseFirstVisit() {
        let stamps = [stamp("JP", "2019-04-01", "2026-03-01"), stamp("PT", "2026-06-02"), stamp("FR", nil)]
        XCTAssertEqual(TravelStats.newCountries(in: 2026, stamps: stamps).map(\.countryCode), ["PT"])
    }

    func testStampYearsText() {
        XCTAssertEqual(stamp("JP", "2019-04-01", "2024-10-11").yearsText, "2019 – 2024")
        XCTAssertEqual(stamp("JP", "2024-04-01", "2024-10-11").yearsText, "2024")
        XCTAssertNil(stamp("JP", nil).yearsText)
    }

    // ── Trips ────────────────────────────────────────────────────────────────

    func testTripsSplitOnGaps() {
        let trips = TripBuilder.trips(from: [
            memory("JP", "2024-04-09"), memory("JP", "2024-04-12"), memory("KR", "2024-04-16"),
            memory("HK", "2024-04-19"),
            memory("PT", "2023-06-14"), memory("MA", "2023-06-20"),   // 6 days: same trip
            memory("ES", "2023-05-01"),                                // 6 weeks earlier: its own trip
        ])
        XCTAssertEqual(trips.count, 3)
        XCTAssertEqual(trips[0].countryCodes, ["JP", "KR", "HK"]) // newest trip first
        XCTAssertEqual(trips[0].days, 11)
        XCTAssertEqual(trips[1].countryCodes, ["PT", "MA"])
        XCTAssertEqual(trips[2].countryCodes, ["ES"])
        XCTAssertEqual(trips[0].title, "Japan, South Korea +1")
    }

    func testJourneyDistanceUsesCoordinatesThenCentroids() {
        let km = Geo.journeyKm([
            memory("GB", "2024-01-01", lat: 51.5074, lng: -0.1278),  // London
            memory("FR", "2024-01-02", lat: 48.8566, lng: 2.3522),   // Paris
        ])
        XCTAssertEqual(km, 344, accuracy: 5)
        XCTAssertEqual(Geo.journeyKm([memory("JP", "2024-01-01")]), 0)
    }

    func testYearInReview() {
        let review = YearInReview(
            year: 2024,
            stamps: [stamp("JP", "2019-04-01", "2024-04-12"), stamp("KR", "2024-04-16"),
                     stamp("DE", "2023-01-01", "2024-12-01", source: .photos)],
            memories: [memory("JP", "2024-04-12", city: "Kyoto", photos: 2),
                       memory("KR", "2024-04-16", city: "Seoul", photos: 1)]
        )
        XCTAssertEqual(Set(review.countries), ["JP", "KR", "DE"]) // DE from photo-import dates
        XCTAssertEqual(review.newCountries, ["KR"])
        XCTAssertEqual(review.memories, 2)
        XCTAssertEqual(review.photos, 3)
        XCTAssertEqual(review.trips.count, 1)
    }

    // ── Reminders ────────────────────────────────────────────────────────────

    func testOnThisDayPlansOneReminderPerDayPreferringPhotos() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 1; components.hour = 12
        let now = try XCTUnwrap(Calendar.current.date(from: components))
        let plan = MemoryReminders.upcoming(memories: [
            memory("PE", "2024-09-17", photos: 0, title: "Cusco"),
            memory("PE", "2023-09-17", photos: 2, title: "Machu Picchu"),
            memory("JP", "2026-09-17", photos: 1, title: "Too recent"), // this year: not an anniversary yet
            memory("IS", "2025-02-18", photos: 1, title: "Skógafoss"),
        ], now: now, limit: 10)
        XCTAssertEqual(plan.count, 2)
        guard plan.count == 2 else { return }
        XCTAssertTrue(plan[0].body.contains("Machu Picchu"))
        XCTAssertTrue(plan[0].body.hasPrefix("3 years ago"))
        // Next 18 Feb after 1 Sep 2026 is in 2027 → two years on.
        XCTAssertTrue(plan[1].body.hasPrefix("2 years ago"), plan[1].body)
    }

    // ── Input hygiene ────────────────────────────────────────────────────────

    func testUsernames() {
        XCTAssertEqual(Handles.normalizedUsername("  @Jason.F "), "jason.f")
        XCTAssertTrue(Handles.isValidUsername("alex.rivera"))
        XCTAssertFalse(Handles.isValidUsername("ab"))
        XCTAssertFalse(Handles.isValidUsername("_alex"))
        XCTAssertNotNil(Handles.problem(with: "jоhn")) // Cyrillic о look-alike
        XCTAssertNil(Handles.problem(with: "@jason_f"))
        XCTAssertNil(Handles.problem(with: ""))
    }

    func testPhotoCoordinatesAreCoarsened() {
        XCTAssertEqual(PlaceSearch.coarse(34.967123), 34.97, accuracy: 0.0001)
        XCTAssertEqual(PlaceSearch.coarse(-72.54489), -72.54, accuracy: 0.0001)
    }

    func testSearchTermsCannotBreakTheFilter() {
        XCTAssertEqual(SupabaseBackend.sanitizedSearchTerm("smith, j (london)"), "smith j london")
        XCTAssertEqual(SupabaseBackend.sanitizedSearchTerm("@maya%*"), "maya")
    }

    func testMemoryJSONUsesLegacyColumnNames() throws {
        let json = """
        {"id":"\(UUID().uuidString)","user_id":"\(UUID().uuidString)","country_code":"JP",
         "restaurant_name":"","title":"Fushimi Inari","city":"Kyoto","date_tried":"2024-04-12",
         "rating":null,"notes":"","photos":["a/b.jpg"],"lat":34.97,"lng":135.77,
         "visibility":"groups","kind":"memory","created_at":"2026-09-17T10:00:00.123456+00:00"}
        """
        let memory = try SupabaseBackend.decoder.decode(Memory.self, from: Data(json.utf8))
        XCTAssertEqual(memory.date, "2024-04-12")
        XCTAssertEqual(memory.visibility, .friends)
        XCTAssertEqual(memory.displayTitle, "Fushimi Inari")
        XCTAssertEqual(memory.placeLine, "Kyoto, Japan")

        let patch = MemoryPatch(countryCode: "JP", title: "", city: "", dateTried: "2024-04-12", notes: "",
                                photos: [], lat: nil, lng: nil, visibility: "private")
        let encoded = try XCTUnwrap(String(data: SupabaseBackend.encoder.encode(patch), encoding: .utf8))
        XCTAssertTrue(encoded.contains("\"date_tried\""))
        XCTAssertTrue(encoded.contains("\"lat\":null"), "clearing a place must null the coordinates")
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func signedInModel() async -> AppModel {
        let app = AppModel(demo: true)
        (app.backend as? DemoBackend)?.latency = .zero
        app.start()
        for _ in 0..<200 where app.loadState != .loaded {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return app
    }

    func testDemoAccountLoads() async {
        let app = await signedInModel()
        XCTAssertEqual(app.loadState, .loaded)
        XCTAssertEqual(app.me?.name, "Alex Rivera")
        XCTAssertGreaterThan(app.stats.countries, 10)
        XCTAssertFalse(app.groups.isEmpty)
    }

    func testFirstMemoryInACountryStampsIt() async throws {
        let app = await signedInModel()
        XCTAssertFalse(app.visitedCodes.contains("NO"))
        var draft = MemoryDraft()
        draft.countryCode = "NO"
        draft.title = "Preikestolen"
        let countriesBefore = app.stats.countries
        let result = try await app.saveMemory(draft, editing: nil, newPhotos: [], shareTo: [])
        XCTAssertTrue(result.isNewCountry)
        XCTAssertEqual(result.countryNumber, countriesBefore + 1, "numbered among countries, not territories")
        XCTAssertTrue(app.visitedCodes.contains("NO"))
        XCTAssertEqual(app.memoriesByCountry["NO"]?.count, 1)

        // A second memory there isn't a new stamp.
        draft.title = "Bergen"
        let again = try await app.saveMemory(draft, editing: nil, newPhotos: [], shareTo: [])
        XCTAssertFalse(again.isNewCountry)
    }

    func testStampWithMemoriesCannotBeRemoved() async {
        let app = await signedInModel()
        do {
            try await app.removeStamp("JP")
            XCTFail("Japan has memories; removing its stamp should be refused")
        } catch {
            XCTAssertTrue(app.visitedCodes.contains("JP"))
        }
    }

    func testDeletingTheOnlyMemoryDropsAMemoryOnlyStamp() async throws {
        let app = await signedInModel()
        var draft = MemoryDraft()
        draft.countryCode = "CL"
        draft.title = "Torres del Paine"
        let saved = try await app.saveMemory(draft, editing: nil, newPhotos: [], shareTo: [])
        XCTAssertTrue(app.visitedCodes.contains("CL"))
        try await app.deleteMemory(saved.memory)
        XCTAssertFalse(app.visitedCodes.contains("CL"))
    }

    func testBulkStampsMergeDates() async throws {
        let app = await signedInModel()
        try await app.addStamps([
            StampInput(countryCode: "DE", firstVisited: "2019-08-02", lastVisited: "2024-12-18", source: .photos),
            StampInput(countryCode: "JP", firstVisited: "2015-01-01", lastVisited: "2015-01-05", source: .photos),
        ])
        XCTAssertTrue(app.visitedCodes.contains("DE"))
        XCTAssertEqual(app.stampsByCode["JP"]?.firstVisited, "2015-01-01")
        XCTAssertEqual(app.stampsByCode["JP"]?.lastVisited, "2024-04-12")
    }

    func testStampDatesFollowMemoryEdits() async throws {
        let app = await signedInModel()
        try await app.addStamps([StampInput(countryCode: "NO", firstVisited: "2019-06-01",
                                            lastVisited: "2019-06-09", source: .photos)])
        var draft = MemoryDraft()
        draft.countryCode = "NO"
        draft.title = "Lofoten"
        draft.date = DayFormat.date(from: "2026-09-17")!
        let saved = try await app.saveMemory(draft, editing: nil, newPhotos: [], shareTo: [])
        await app.refreshStamps()
        XCTAssertEqual(app.stampsByCode["NO"]?.lastVisited, "2026-09-17")

        // Correcting the date narrows the range back — it no longer counts for 2026.
        var fix = MemoryDraft(memory: saved.memory)
        fix.date = DayFormat.date(from: "2019-06-05")!
        _ = try await app.saveMemory(fix, editing: saved.memory, newPhotos: [], shareTo: [])
        await app.refreshStamps()
        XCTAssertEqual(app.stampsByCode["NO"]?.firstVisited, "2019-06-01")
        XCTAssertEqual(app.stampsByCode["NO"]?.lastVisited, "2019-06-09")

        // Deleting it keeps the photo stamp with the dates the photos gave.
        let edited = try XCTUnwrap(app.memoriesByCountry["NO"]?.first)
        try await app.deleteMemory(edited)
        XCTAssertEqual(app.stampsByCode["NO"]?.source, .photos)
        XCTAssertEqual(app.stampsByCode["NO"]?.lastVisited, "2019-06-09")
    }

    func testSaveWhoseResponseWasLostStillSucceedsOnce() async throws {
        let app = await signedInModel()
        let demo = try XCTUnwrap(app.backend as? DemoBackend)
        var draft = MemoryDraft()
        draft.countryCode = "IS"
        draft.title = "Reynisfjara"
        let jpeg = try XCTUnwrap(UIImage(systemName: "star")?.jpegData(compressionQuality: 0.5))
        let before = app.memories.count

        demo.nextWriteFault = .responseLost
        let result = try await app.saveMemory(draft, editing: nil, newPhotos: [jpeg], shareTo: [])
        XCTAssertEqual(app.memories.count, before + 1)
        // The photo the saved row points at was not cleaned up as a failure.
        let path = try XCTUnwrap(result.memory.photos.first)
        let stored = try await demo.photoData(path: path)
        XCTAssertEqual(stored, jpeg)
    }

    func testFailedSaveCleansUpItsUploadsAndRetriesWithTheSameId() async throws {
        let app = await signedInModel()
        let demo = try XCTUnwrap(app.backend as? DemoBackend)
        var draft = MemoryDraft()
        draft.countryCode = "IS"
        draft.title = "Skógafoss"
        let jpeg = try XCTUnwrap(UIImage(systemName: "star")?.jpegData(compressionQuality: 0.5))
        let id = UUID()
        let before = app.memories.count

        demo.nextWriteFault = .beforeWrite
        do {
            _ = try await app.saveMemory(draft, editing: nil, newId: id, newPhotos: [jpeg], shareTo: [])
            XCTFail("the write never landed")
        } catch {
            XCTAssertEqual(app.memories.count, before)
        }
        let saved = try await app.saveMemory(draft, editing: nil, newId: id, newPhotos: [jpeg], shareTo: [])
        XCTAssertEqual(saved.memory.id, id)
        XCTAssertEqual(app.memories.filter { $0.id == id }.count, 1)
    }

    func testDaysAreReadInTheGivenTimeZone() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-04-12T23:30:00Z"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(DayFormat.string(from: instant, in: tokyo), "2024-04-13")
        XCTAssertEqual(DayFormat.string(from: instant, in: newYork), "2024-04-12")
        // Alternating zones must not leave the shared calendar in the wrong one.
        XCTAssertEqual(DayFormat.string(from: instant, in: tokyo), "2024-04-13")

        XCTAssertEqual(DayFormat.string(from: try XCTUnwrap(DayFormat.date(from: "2024-02-29"))), "2024-02-29")
        XCTAssertNil(DayFormat.date(from: "2023-02-29"))
        XCTAssertNil(DayFormat.date(from: "not a date"))
    }

    func testExifCaptureTimeKeepsItsLocalDay() throws {
        for id in ["America/Los_Angeles", "Asia/Tokyo", "Pacific/Kiritimati"] {
            let zone = try XCTUnwrap(TimeZone(identifier: id))
            let date = try XCTUnwrap(PhotoMetadata.exifDate("2024:04:12 08:03:55", in: zone))
            XCTAssertEqual(DayFormat.string(from: date, in: zone), "2024-04-12", id)
        }
        XCTAssertNil(PhotoMetadata.exifDate("0000:00:00 00:00:00"))
        XCTAssertNil(PhotoMetadata.exifDate("garbage"))
    }

    func testDeepLinks() async {
        let app = await signedInModel()
        app.handle(url: URL(string: "culinarypassport://join/europe2027")!)
        XCTAssertEqual(app.route, .joinGroup("europe2027"))
        let id = UUID()
        app.handle(url: URL(string: "culinarypassport://memory/\(id.uuidString)")!)
        XCTAssertEqual(app.route, .memory(id))
        app.route = nil
        app.handle(url: URL(string: "https://example.com/join/x")!)
        XCTAssertNil(app.route)
    }
}
