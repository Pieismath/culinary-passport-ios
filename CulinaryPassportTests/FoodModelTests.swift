import XCTest
import UIKit
@testable import CulinaryPassport

final class FoodModelTests: XCTestCase {
    private let me = UUID()

    private func meal(_ code: String, _ date: String, restaurant: String = "", city: String? = nil,
                      photos: Int = 0) -> Meal {
        Meal(id: UUID(), userId: me, countryCode: code, title: "", city: city, date: date,
             notes: nil, photos: (0..<photos).map { "p\($0)" }, lat: nil, lng: nil,
             visibility: .friends, createdAt: Date(), kind: .meal, restaurantName: restaurant)
    }

    private func taste(_ code: String, first: String? = nil, meals: Int = 0) -> Taste {
        Taste(userId: me, countryCode: code, firstTasted: first, lastTasted: first, meals: meals,
              source: first == nil ? .manual : .meal, createdAt: Date())
    }

    // ── Countries ────────────────────────────────────────────────────────────

    func testSmallCountriesAreOnTheGlobe() {
        for code in ["SG", "MT", "MC", "VA", "MV", "BH", "HK", "PF"] {
            XCTAssertNotNil(CountryStore.byCode[code], "\(code) should be on the globe")
        }
        XCTAssertEqual(CountryStore.byCode["SG"]?.hasShape, false)
        XCTAssertEqual(CountryStore.byCode["HK"]?.isSovereign, false)
    }

    func testCountryCountAndContinents() {
        // 193 UN members + Vatican City + Palestine + Taiwan + Kosovo.
        XCTAssertEqual(CountryStore.sovereignCount, 197)
        // "Seven seas" is not a continent.
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

    // ── Where a restaurant is (a saved one is filed by its own country) ──────

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

    func testEveryPlaceTheLocatorCanReturnIsOnTheGlobe() {
        for code in Set(PlaceLocator.outlines.map(\.code) + PlaceLocator.islands.map(\.code)) {
            XCTAssertNotNil(CountryStore.byCode[code], "\(code) resolves from a location but isn't on the globe")
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
        // A beach café a few km off the coarse coastline still counts…
        XCTAssertNotNil(CountryGeometry.nearestCountry(atLat: 39.0, lng: -9.52, withinKm: 12))
        // …but globe taps never snap (the geometry tests keep that honest).
        XCTAssertNil(CountryGeometry.nearestCountry(atLat: 39.0, lng: -11.5, withinKm: 12))
    }

    // ── How much of the world ────────────────────────────────────────────────

    func testStatsCountCuisinesContinentsAndRestaurants() {
        let meals = [meal("JP", "2026-01-02", restaurant: "Ramen Kiyo", city: "San Francisco"),
                     meal("JP", "2026-02-02", restaurant: "Ramen Kiyo", city: "San Francisco"),
                     meal("ET", "2026-03-02", restaurant: "Lalibela", city: "Oakland"),
                     meal("PE", "2026-03-09", city: "San Francisco")]
        let stats = FoodStats(tastes: [taste("JP", first: "2026-01-02", meals: 2), taste("ET", first: "2026-03-02", meals: 1),
                                       taste("PE", first: "2026-03-09", meals: 1), taste("FR"),
                                       taste("AQ")],
                              meals: meals)
        XCTAssertEqual(stats.cuisines, 4, "Antarctica has no kitchen, so it can't count")
        XCTAssertEqual(stats.meals, 4)
        XCTAssertEqual(stats.restaurants, 2, "the same restaurant twice is one; a meal with none is none")
        XCTAssertEqual(stats.cities, 2)
        XCTAssertEqual(stats.continents, 4) // Asia, Africa, South America, Europe
        XCTAssertEqual(stats.favorite, "JP")
        XCTAssertEqual(stats.favoriteMeals, 2)
        XCTAssertEqual(stats.continentProgress[.africa]?.tasted, 1)
        XCTAssertEqual(stats.continentProgress[.antarctica], nil, "the plate's rim has six continents")
        let africa = Cuisine.codes.filter { CountryStore.byCode[$0]?.continent == .africa }.count
        XCTAssertEqual(stats.continentProgress[.africa]?.total, africa)
    }

    func testContinentsGoRoundThePlateOnce() {
        XCTAssertEqual(FoodStats.continents.count, 6)
        XCTAssertEqual(Set(FoodStats.continents).count, 6)
        XCTAssertFalse(FoodStats.continents.contains(.antarctica))
        // Every cuisine sits on one of them.
        let onTheRim = FoodStats.continentProgress(Set(Cuisine.codes)).values.reduce(0) { $0 + $1.total }
        XCTAssertEqual(onTheRim, Cuisine.codes.count)
    }

    func testWorldPercentText() {
        XCTAssertEqual(FoodStats.percentText(0), "0%")
        XCTAssertEqual(FoodStats.percentText(1), "<1%")
        XCTAssertEqual(FoodStats.percentText(Cuisine.codes.count), "100%")
        var stats = FoodStats()
        stats.cuisines = Cuisine.codes.count / 2
        XCTAssertEqual(stats.worldPercentText, "\(Int((Double(Cuisine.codes.count / 2) / Double(Cuisine.codes.count) * 100).rounded()))%")
    }

    func testNewCuisinesThisYearCountFirstMealsOnly() {
        let tastes = [taste("JP", first: "2025-11-01"), taste("ET", first: "2026-03-02"),
                      taste("PE", first: "2026-01-09"), taste("FR")]
        XCTAssertEqual(FoodStats.newCuisines(in: 2026, tastes: tastes).map(\.countryCode), ["PE", "ET"],
                       "oldest first; a cuisine ticked without a meal has no date to count")
    }

    // ── The passport ─────────────────────────────────────────────────────────

    func testMachineReadableStripReadsLikeAPassport() throws {
        let id = try XCTUnwrap(UUID(uuidString: "0D3E0000-0000-4000-8000-000000000001"))
        let profile = Profile(id: id, name: "Alex Rivera", color: "#2fbf8a", homeCity: "San Francisco",
                              homeCountry: "US", username: "alex.rivera", bio: nil, avatarUrl: nil,
                              isPublic: true, createdAt: Date(), yearlyGoal: nil)
        var stats = FoodStats()
        stats.cuisines = 20
        stats.continents = 5
        stats.meals = 13
        let lines = MachineReadableStrip.lines(profile: profile, stats: stats)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.count == 40 }, "both lines are filled to the same width")
        XCTAssertTrue(lines[0].hasPrefix("PCUSRIVERA<<ALEX"), lines[0])
        XCTAssertTrue(lines[1].contains("US0205<0013"), lines[1])
        // The number is derived from the account, so it never changes.
        XCTAssertEqual(MachineReadableStrip.lines(profile: profile, stats: stats), lines)

        // One-word names and no home kitchen still produce a valid strip.
        let sparse = Profile(id: id, name: "Prince", color: "#2fbf8a", homeCity: nil, homeCountry: nil,
                             username: nil, bio: nil, avatarUrl: nil, isPublic: false,
                             createdAt: Date(), yearlyGoal: nil)
        let bare = MachineReadableStrip.lines(profile: sparse, stats: FoodStats())
        XCTAssertTrue(bare[0].hasPrefix("PCXXPRINCE<<"), bare[0])
        XCTAssertTrue(bare.allSatisfy { $0.count == 40 })
        XCTAssertTrue(MachineReadableStrip.lines(profile: nil, stats: FoodStats())[0].hasPrefix("PCXXHUNGRY"))
    }

    // ── Food ─────────────────────────────────────────────────────────────────

    func testCuisinesAreNamedTheWayPeopleOrderThem() {
        XCTAssertEqual(Cuisine.name(for: "GE"), "Georgian")
        XCTAssertEqual(Cuisine.name(for: "KR"), "Korean")
        XCTAssertEqual(Cuisine.name(for: "IR"), "Persian")
        XCTAssertEqual(Cuisine.name(for: "HK"), "Hong Kong")
        XCTAssertEqual(Cuisine.withArticle("ET"), "an Ethiopian")
        XCTAssertEqual(Cuisine.withArticle("GE"), "a Georgian")
        XCTAssertEqual(Cuisine.withArticle("UA"), "a Ukrainian")
        XCTAssertEqual(Cuisine.withArticle("UZ"), "an Uzbek")
        XCTAssertFalse(Cuisine.isCuisine("AQ"), "Antarctica has no kitchen")
        XCTAssertTrue(Cuisine.isCuisine("PR"), "territories with a food of their own count")
        XCTAssertGreaterThan(Cuisine.codes.count, 197)
    }

    func testRestaurantNamesGiveTheirCuisineAway() {
        XCTAssertEqual(Cuisine.suggest(from: "Pho Saigon"), "VN")
        XCTAssertEqual(Cuisine.suggest(from: "Taqueria El Farolito"), "MX")
        XCTAssertEqual(Cuisine.suggest(from: "Tbilisi Café"), "GE")
        XCTAssertEqual(Cuisine.suggest(from: "Seoul Korean BBQ House"), "KR", "the longer cue beats plain bbq")
        XCTAssertEqual(Cuisine.suggest(from: "Joe's Diner"), "US")
        XCTAssertEqual(Cuisine.suggest(from: "Crêperie Saint-Germain"), "FR", "accents don't hide a cue")
        XCTAssertNil(Cuisine.suggest(from: "The Blue Door"))
    }

    func testSearchingADishFindsItsCuisine() {
        XCTAssertTrue(Cuisine.matches("VN", "pho"))
        XCTAssertTrue(Cuisine.matches("VE", "arepa"))
        XCTAssertTrue(Cuisine.matches("CO", "arepa"))
        XCTAssertTrue(Cuisine.matches("GE", "georg"))
        XCTAssertFalse(Cuisine.matches("JP", "pho"))
    }

    func testTheSpinLandsOnSomethingNobodyAtTheTableHasHad() {
        let pool = Cuisine.dinnerPool(tastedByTable: ["JP", "MX", "IT"], tastedByMe: ["JP"])
        XCTAssertFalse(pool.contains("JP") || pool.contains("MX") || pool.contains("IT"))
        XCTAssertTrue(pool.allSatisfy { Cuisine.dicePool.contains($0) })
        // The table has had everything popular: fall back to what I haven't.
        let everything = Set(Cuisine.dicePool)
        let mine = Cuisine.dinnerPool(tastedByTable: everything, tastedByMe: ["JP"])
        XCTAssertFalse(mine.contains("JP"))
        XCTAssertFalse(Cuisine.dinnerPool(tastedByTable: everything, tastedByMe: everything).isEmpty)
    }

    // ── Dinner picks at a table ──────────────────────────────────────────────

    func testAPickReadsWellWhereTheAppCantDrawIt() {
        XCTAssertEqual(DinnerPick(cuisineCode: "MM").fallbackText, "🎲 The globe says 🇲🇲 Burmese tonight")
        let restaurant = DinnerPick(cuisineCode: "MM", placeName: "Burma Superstar", placeAddress: "309 Clement St",
                                    placeLat: 37.78, placeLng: -122.46)
        XCTAssertEqual(restaurant.fallbackText, "🇲🇲 Burmese at Burma Superstar?")
        XCTAssertTrue(restaurant.hasPlace && restaurant.hasCoordinate)
        XCTAssertFalse(DinnerPick(cuisineCode: "MM", placeName: "  ").hasPlace)
    }

    func testTablePostsDecodeWithAndWithoutAPick() throws {
        let old = #"""
        {"id":"8E0B8C35-2A68-4E2B-9D0A-6B7E53F2C9A1","group_id":"0D3E0000-0000-4000-8000-0000000000A1",
         "author_id":"0D3E0000-0000-4000-8000-000000000001","entry_id":null,"text":"Friday?",
         "photos":[],"created_at":"2026-09-18T19:04:11.123456+00:00"}
        """#
        let plain = try SupabaseBackend.decoder.decode(GroupPost.self, from: Data(old.utf8))
        XCTAssertNil(plain.pick, "rows from before picks existed still load")
        XCTAssertEqual(plain.text, "Friday?")

        let ticket = #"""
        {"id":"8E0B8C35-2A68-4E2B-9D0A-6B7E53F2C9A2","group_id":"0D3E0000-0000-4000-8000-0000000000A1",
         "author_id":"0D3E0000-0000-4000-8000-000000000001","entry_id":null,"text":"🇲🇲 Burmese at Burma Superstar?",
         "photos":[],"created_at":"2026-09-18T19:04:11.123456+00:00","cuisine_code":"MM",
         "place_name":"Burma Superstar","place_address":"309 Clement St","place_lat":37.78,"place_lng":-122.46}
        """#
        let pick = try XCTUnwrap(SupabaseBackend.decoder.decode(GroupPost.self, from: Data(ticket.utf8)).pick)
        XCTAssertEqual(pick.cuisineCode, "MM")
        XCTAssertEqual(pick.placeName, "Burma Superstar")
        XCTAssertEqual(try XCTUnwrap(pick.placeLng), -122.46, accuracy: 0.0001)
    }

    // ── Serialization + input hygiene ────────────────────────────────────────

    func testMealRowsDecodeFromTheCulinaryColumns() throws {
        let json = #"""
        {"id":"8E0B8C35-2A68-4E2B-9D0A-6B7E53F2C9A1","user_id":"0D3E0000-0000-4000-8000-000000000001",
         "kind":"meal","country_code":"GE","title":"","restaurant_name":"Supra","signature_dish":"Khachapuri",
         "city":"San Francisco","date_tried":"2026-09-18","notes":null,"photos":[],"lat":37.76,"lng":-122.42,
         "visibility":"groups","rating":5,"created_at":"2026-09-18T19:04:11.123456+00:00"}
        """#
        let meal = try SupabaseBackend.decoder.decode(Meal.self, from: Data(json.utf8))
        XCTAssertTrue(meal.isMeal)
        XCTAssertEqual(meal.visibility, .friends)
        XCTAssertEqual(meal.restaurantName, "Supra")
        XCTAssertEqual(meal.dish, "Khachapuri")
        XCTAssertEqual(meal.displayTitle, "Khachapuri")
        XCTAssertEqual(meal.feedLine, "🇬🇪 Georgian at Supra")

        let patch = MealPatch(countryCode: "GE", title: "", city: "", dateTried: "2026-09-18", notes: "",
                              photos: [], lat: nil, lng: nil, visibility: "private",
                              restaurantName: "Supra", signatureDish: "Khinkali")
        let encoded = try XCTUnwrap(String(data: SupabaseBackend.encoder.encode(patch), encoding: .utf8))
        XCTAssertTrue(encoded.contains("\"date_tried\""))
        XCTAssertTrue(encoded.contains("\"signature_dish\":\"Khinkali\""))
        XCTAssertTrue(encoded.contains("\"lat\":null"), "clearing the restaurant must null its coordinates")
    }

    func testUsernames() {
        XCTAssertEqual(Handles.normalizedUsername("  @Jason.F "), "jason.f")
        XCTAssertTrue(Handles.isValidUsername("alex.rivera"))
        XCTAssertFalse(Handles.isValidUsername("ab"))
        XCTAssertFalse(Handles.isValidUsername("_alex"))
        XCTAssertNotNil(Handles.problem(with: "jоhn")) // Cyrillic о look-alike
        XCTAssertNil(Handles.problem(with: "@jason_f"))
        XCTAssertNil(Handles.problem(with: ""))
    }

    func testSearchTermsCannotBreakTheFilter() {
        XCTAssertEqual(SupabaseBackend.sanitizedSearchTerm("smith, j (london)"), "smith j london")
        XCTAssertEqual(SupabaseBackend.sanitizedSearchTerm("@maya%*"), "maya")
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func signedInModel() async -> AppModel {
        let app = AppModel(demo: true)
        (app.backend as? DemoBackend)?.latency = .zero
        app.start()
        for _ in 0..<200 where app.loadState != .loaded || app.peopleTastes.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return app
    }

    func testDemoAccountLoads() async {
        let app = await signedInModel()
        XCTAssertEqual(app.loadState, .loaded)
        XCTAssertEqual(app.me?.name, "Alex Rivera")
        XCTAssertGreaterThan(app.stats.cuisines, 10)
        XCTAssertTrue(app.meals.allSatisfy(\.isMeal))
        XCTAssertEqual(app.groups.count, 3)
        XCTAssertFalse(app.peopleTastes.isEmpty, "table mates' tastes load for the spins")
        XCTAssertFalse(app.toTry.isEmpty)
    }

    func testFirstMealOfACuisineIsAFirstTaste() async throws {
        let app = await signedInModel()
        XCTAssertFalse(app.tastedCodes.contains("UZ"))
        let before = app.stats.cuisines

        var draft = MealDraft()
        draft.countryCode = "UZ"
        draft.restaurantName = "Plov Center"
        draft.dish = "Plov"
        let first = try await app.saveMeal(draft, editing: nil, newPhotos: [], shareTo: [])
        XCTAssertTrue(first.isFirstTaste, "a first taste plays the stamp moment")
        XCTAssertEqual(first.cuisineNumber, before + 1, "numbered among cuisines")
        await app.refreshTastes()
        XCTAssertTrue(app.tastedCodes.contains("UZ"))
        XCTAssertEqual(app.tastesByCode["UZ"]?.meals, 1)
        XCTAssertEqual(app.mealsByCountry["UZ"]?.count, 1)

        draft.dish = "Samsa"
        let second = try await app.saveMeal(draft, editing: nil, newPhotos: [], shareTo: [])
        XCTAssertFalse(second.isFirstTaste)

        // A cuisine with meals can't be un-tasted; deleting them all does it.
        do {
            try await app.removeTaste("UZ")
            XCTFail("meals keep the taste")
        } catch {}
        try await app.deleteMeal(first.meal)
        try await app.deleteMeal(second.meal)
        XCTAssertFalse(app.tastedCodes.contains("UZ"))
    }

    func testEditingAMealKeepsWhatItDoesntShow() async throws {
        let app = await signedInModel()
        let demo = try XCTUnwrap(app.backend as? DemoBackend)
        var draft = MealDraft()
        draft.countryCode = "NP"
        draft.title = "From the culinary app"
        draft.dish = "Momo"
        let saved = try await app.saveMeal(draft, editing: nil, newPhotos: [], shareTo: [])
        var edit = MealDraft(meal: saved.meal)
        edit.dish = "Jhol momo"
        let edited = try await app.saveMeal(edit, editing: saved.meal, newPhotos: [], shareTo: [])
        XCTAssertEqual(edited.meal.dish, "Jhol momo")
        XCTAssertEqual(edited.meal.title, "From the culinary app", "an edit must not wipe the old title")
        XCTAssertFalse(edited.isFirstTaste)
        let stored = try await demo.meal(id: saved.meal.id)
        XCTAssertEqual(stored?.title, "From the culinary app")
    }

    func testSaveWhoseResponseWasLostStillSucceedsOnce() async throws {
        let app = await signedInModel()
        let demo = try XCTUnwrap(app.backend as? DemoBackend)
        var draft = MealDraft()
        draft.countryCode = "IS"
        draft.dish = "Plokkfiskur"
        let jpeg = try XCTUnwrap(UIImage(systemName: "star")?.jpegData(compressionQuality: 0.5))
        let before = app.meals.count

        demo.nextWriteFault = .responseLost
        let result = try await app.saveMeal(draft, editing: nil, newPhotos: [jpeg], shareTo: [])
        XCTAssertEqual(app.meals.count, before + 1)
        // The photo the saved row points at was not cleaned up as a failure.
        let path = try XCTUnwrap(result.meal.photos.first)
        let stored = try await demo.photoData(path: path)
        XCTAssertEqual(stored, jpeg)
    }

    func testFailedSaveCleansUpItsUploadsAndRetriesWithTheSameId() async throws {
        let app = await signedInModel()
        let demo = try XCTUnwrap(app.backend as? DemoBackend)
        var draft = MealDraft()
        draft.countryCode = "IS"
        draft.dish = "Kjötsúpa"
        let jpeg = try XCTUnwrap(UIImage(systemName: "star")?.jpegData(compressionQuality: 0.5))
        let id = UUID()
        let before = app.meals.count

        demo.nextWriteFault = .beforeWrite
        do {
            _ = try await app.saveMeal(draft, editing: nil, newId: id, newPhotos: [jpeg], shareTo: [])
            XCTFail("the write never landed")
        } catch {
            XCTAssertEqual(app.meals.count, before)
        }
        let saved = try await app.saveMeal(draft, editing: nil, newId: id, newPhotos: [jpeg], shareTo: [])
        XCTAssertEqual(saved.meal.id, id)
        XCTAssertEqual(app.meals.filter { $0.id == id }.count, 1)
    }

    // ── Spinning ─────────────────────────────────────────────────────────────

    func testTheTableSpinSkipsWhatAnyoneThereHasHad() async throws {
        let app = await signedInModel()
        let table = DemoData.dinnerClub
        let eaters = app.eaters(at: table)
        XCTAssertEqual(Set(eaters), [DemoData.me, DemoData.maya, DemoData.sam])
        let between = app.tasted(by: eaters)
        XCTAssertTrue(between.isSuperset(of: app.tastedCodes), "your own tastes count at the table")
        XCTAssertTrue(between.contains("SN"), "Maya's first Senegalese counts for everyone")

        let pool = app.spinPool(for: table)
        XCTAssertFalse(pool.isEmpty)
        XCTAssertTrue(pool.allSatisfy { !between.contains($0) }, "the spin never lands on something one of you has had")

        // Everyone has had it, or only some of you.
        let all = app.tastedByEveryone(eaters)
        XCTAssertTrue(all.isSubset(of: between))
        XCTAssertTrue(all.contains("JP"), "Alex, Maya and Sam have all had Japanese")
        XCTAssertFalse(all.contains("SN"))

        // Just you: only your own tastes are ruled out.
        let solo = app.spinPool(for: nil)
        XCTAssertTrue(solo.allSatisfy { !app.tastedCodes.contains($0) })
        XCTAssertTrue(solo.contains("SN"), "Maya's had Senegalese; you haven't")
    }

    func testARestaurantPickGoesToTheTableAsATicket() async throws {
        let app = await signedInModel()
        let demo = try XCTUnwrap(app.backend as? DemoBackend)
        let table = DemoData.dinnerClub
        let pick = DinnerPick(cuisineCode: "MY", placeName: "Azalina's", placeAddress: "499 Ellis St, San Francisco",
                              placeLat: 37.785, placeLng: -122.414)
        try await app.postPick(pick, to: table)

        let posts = try await demo.posts(groupId: table, before: nil, limit: 5)
        let ticket = try XCTUnwrap(posts.first)
        XCTAssertEqual(ticket.pick, pick)
        XCTAssertEqual(ticket.text, pick.fallbackText, "older clients and pushes still read it")

        // "I'm in" is a reaction on the ticket.
        try await demo.setPostReaction(postId: ticket.id, emoji: GroupPost.imIn, on: true)
        let reactions = try await demo.postReactions(postIds: [ticket.id])
        XCTAssertEqual(reactions.map(\.emoji), [GroupPost.imIn])
    }

    // ── Restaurants to try + tastes ──────────────────────────────────────────

    func testTickingCuisinesOnTheChecklist() async throws {
        let app = await signedInModel()
        try await app.addTastes(["NP", "SN"])
        XCTAssertTrue(app.tastedCodes.isSuperset(of: ["NP", "SN"]))
        XCTAssertEqual(app.tastesByCode["NP"]?.source, .manual)
        XCTAssertEqual(app.tastesByCode["NP"]?.meals, 0)
        try await app.removeTaste("NP")
        XCTAssertFalse(app.tastedCodes.contains("NP"))
    }

    func testSavingAFriendsMealKeepsTheRestaurantWhereItIs() async throws {
        let app = await signedInModel()
        let demo = try XCTUnwrap(app.backend as? DemoBackend)
        let feed = try await demo.friendsFeed(before: nil, limit: 30)
        let meal = try XCTUnwrap(feed.first { $0.countryCode == "SN" })   // Maya's Senegalese
        XCTAssertNil(app.savedPlace(from: meal))

        await app.toggleSavedPlace(from: meal)
        let saved = try XCTUnwrap(app.savedPlace(from: meal))
        XCTAssertEqual(saved.title, "Bissap Baobab")
        XCTAssertEqual(saved.cuisineCode, "SN")
        XCTAssertEqual(saved.countryCode, "US", "the restaurant is in San Francisco, not Senegal")
        XCTAssertEqual(saved.note, "Try the thieboudienne")
        XCTAssertEqual(app.restaurantsByCuisine["SN"]?.map(\.id), [saved.id])

        await app.toggleSavedPlace(from: meal)
        XCTAssertNil(app.savedPlace(from: meal), "tapping again unsaves it")
        XCTAssertNil(app.restaurantsByCuisine["SN"])
    }

    func testEatingAtASavedRestaurantTicksItOff() async throws {
        let app = await signedInModel()
        let place = try XCTUnwrap(app.toTry.first { $0.cuisineCode == "MM" })
        try await app.updatePlace(place, done: true)
        XCTAssertFalse(app.toTry.contains { $0.id == place.id })
        XCTAssertNil(app.restaurantsByCuisine["MM"], "a ticked restaurant isn't still to try")
    }

    func testFriendsFeedIsMealsOnly() async throws {
        let app = await signedInModel()
        let feed = try await app.backend.friendsFeed(before: nil, limit: 50)
        XCTAssertFalse(feed.isEmpty)
        XCTAssertTrue(feed.allSatisfy(\.isMeal))
        XCTAssertFalse(feed.contains { $0.userId == app.myId })
    }

    func testDeepLinks() async {
        let app = await signedInModel()
        app.handle(url: URL(string: "culinarypassport://join/fridaydinner")!)
        XCTAssertEqual(app.route, .joinGroup("fridaydinner"))
        let id = UUID()
        app.handle(url: URL(string: "culinarypassport://meal/\(id.uuidString)")!)
        XCTAssertEqual(app.route, .meal(id))
        // Links from the travel build still open.
        app.handle(url: URL(string: "culinarypassport://memory/\(id.uuidString)")!)
        XCTAssertEqual(app.route, .meal(id))
        app.route = nil
        app.handle(url: URL(string: "https://example.com/join/x")!)
        XCTAssertNil(app.route)
    }
}
