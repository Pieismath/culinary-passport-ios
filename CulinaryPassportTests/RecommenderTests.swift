import XCTest
@testable import CulinaryPassport

final class RecommenderTests: XCTestCase {
    private func entry(_ code: String, rating: Int, notes: String = "", dish: String = "",
                       wouldReturn: Bool = true) -> Entry {
        Entry(
            id: UUID(), userId: UUID(), countryCode: code, restaurantName: "Test",
            city: "Sydney", dateTried: "2026-06-01", rating: rating, notes: notes,
            signatureDish: dish, photos: [], wouldReturn: wouldReturn,
            placeId: nil, lat: nil, lng: nil, visibility: .private, createdAt: Date()
        )
    }

    func testNeverSuggestsSomethingAlreadyTried() {
        let journal = [entry("TH", rating: 5), entry("JP", rating: 4), entry("IT", rating: 5)]
        let codes = Recommender.suggestions(entries: journal, limit: 20).map(\.country.code)
        XCTAssertFalse(codes.contains("TH"))
        XCTAssertFalse(codes.contains("JP"))
        XCTAssertFalse(codes.contains("IT"))
    }

    func testLovedSubregionPullsUpItsNeighbours() throws {
        // Loved two Southeast Asian cuisines → more of that neighbourhood.
        // Asks the bundled data for the subregion name rather than hardcoding
        // Natural Earth's spelling.
        let seAsia = try XCTUnwrap(CountryStore.byCode["TH"]?.subregion)
        let journal = [entry("TH", rating: 5), entry("VN", rating: 5)]
        let top = Recommender.suggestions(entries: journal, limit: 8)
        XCTAssertTrue(top.contains { $0.country.subregion == seAsia },
                      "expected a Southeast Asian suggestion, got \(top.map(\.country.name))")
    }

    func testFlavourWordsInNotesSteerSuggestions() {
        // One loved meal, with the note doing the talking.
        let journal = [entry("IT", rating: 5, notes: "unbelievable noodles, best I've had")]
        let suggestions = Recommender.suggestions(entries: journal, limit: 10)
        let noodleCuisines = ["JP", "VN", "CN", "TH", "KR", "MY"]
        XCTAssertTrue(suggestions.contains { noodleCuisines.contains($0.country.code) },
                      "notes mentioning noodles should surface noodle cuisines")
    }

    func testDislikedFoodDoesNotPullItsNeighbourhoodUp() throws {
        let seAsia = try XCTUnwrap(CountryStore.byCode["TH"]?.subregion)
        func neighbours(_ list: [Recommender.Suggestion]) -> Int {
            list.filter { $0.country.subregion == seAsia }.count
        }
        let loved = Recommender.suggestions(entries: [entry("TH", rating: 5)], limit: 8)
        let hated = Recommender.suggestions(entries: [entry("TH", rating: 1, wouldReturn: false)], limit: 8)
        XCTAssertGreaterThan(neighbours(loved), neighbours(hated),
                             "a cuisine you disliked shouldn't recommend more of the same region")
    }

    func testListIsNotDominatedByOneRegion() {
        let journal = [entry("TH", rating: 5), entry("VN", rating: 5), entry("MY", rating: 5)]
        let suggestions = Recommender.suggestions(entries: journal, limit: 6)
        let bySubregion = Dictionary(grouping: suggestions, by: \.country.subregion)
        XCTAssertTrue(bySubregion.values.allSatisfy { $0.count <= 2 },
                      "no more than two picks should come from the same subregion")
    }

    func testEmptyJournalStillProducesSomethingSensible() {
        let suggestions = Recommender.suggestions(entries: [], limit: 5)
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { !$0.reason.isEmpty })
    }

    func testDeterministic() {
        let journal = [entry("TH", rating: 5, notes: "spicy and fresh"), entry("FR", rating: 4)]
        let a = Recommender.suggestions(entries: journal, limit: 6).map(\.country.code)
        let b = Recommender.suggestions(entries: journal, limit: 6).map(\.country.code)
        XCTAssertEqual(a, b)
    }
}
