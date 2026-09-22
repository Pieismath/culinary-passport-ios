import Foundation

/// How much of the world you've eaten, derived from tastes + meals. Pure and
/// cheap — computed on demand, never stored.
struct FoodStats: Equatable {
    struct Progress: Equatable {
        var tasted: Int
        var total: Int
        var fraction: Double { total == 0 ? 0 : min(1, Double(tasted) / Double(total)) }
    }

    /// Cuisines tasted — the headline number.
    var cuisines = 0
    var meals = 0
    /// Different restaurants you've logged a meal at.
    var restaurants = 0
    var cities = 0
    /// Continents with at least one cuisine tasted (of six; Antarctica has
    /// no kitchen).
    var continents = 0
    var continentProgress: [Continent: Progress] = [:]
    /// The cuisine you log most, and how often.
    var favorite: String?
    var favoriteMeals = 0

    init() {}

    init(tastes: [Taste], meals: [Meal]) {
        let codes = Set(tastes.map(\.countryCode)).filter(Cuisine.isCuisine)
        cuisines = codes.count
        self.meals = meals.count
        restaurants = Set(meals.compactMap { meal -> String? in
            let name = meal.restaurantName.trimmed.lowercased()
            return name.isEmpty ? nil : "\(name)|\((meal.city ?? "").lowercased())"
        }).count
        cities = Set(meals.compactMap { meal -> String? in
            let city = (meal.city ?? "").trimmed.lowercased()
            return city.isEmpty ? nil : city
        }).count
        continentProgress = Self.continentProgress(codes)
        continents = continentProgress.values.filter { $0.tasted > 0 }.count
        if let top = Dictionary(grouping: meals, by: \.countryCode)
            .max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) {
            favorite = top.key
            favoriteMeals = top.value.count
        }
    }

    /// Continent by continent, for any set of cuisines (yours, a table's).
    static func continentProgress(_ codes: Set<String>) -> [Continent: Progress] {
        var result: [Continent: Progress] = [:]
        for continent in continents {
            let all = cuisinesByContinent[continent] ?? []
            result[continent] = Progress(tasted: all.filter(codes.contains).count, total: all.count)
        }
        return result
    }

    private static let cuisinesByContinent: [Continent: [String]] = Dictionary(
        grouping: Cuisine.codes, by: { CountryStore.byCode[$0]?.continent ?? .antarctica })

    /// "12%" of every cuisine there is, for any set of cuisines.
    static func percentText(_ count: Int) -> String {
        guard !Cuisine.codes.isEmpty else { return "0%" }
        let pct = Double(count) / Double(Cuisine.codes.count) * 100
        if pct > 0 && pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }

    /// The six continents with food, in the order they sit around the plate.
    static let continents: [Continent] = [.europe, .asia, .oceania, .africa, .southAmerica, .northAmerica]

    /// Of every cuisine there is to taste.
    var worldFraction: Double {
        guard !Cuisine.codes.isEmpty else { return 0 }
        return min(1, Double(cuisines) / Double(Cuisine.codes.count))
    }

    var worldPercentText: String { Self.percentText(cuisines) }

    /// Cuisines whose first meal was in `year` — the "new cuisines this year"
    /// goal. A cuisine ticked without a meal has no date, so it doesn't count.
    static func newCuisines(in year: Int, tastes: [Taste]) -> [Taste] {
        let prefix = String(year)
        return tastes.filter { $0.firstTasted?.hasPrefix(prefix) == true }
            .sorted { ($0.firstTasted ?? "") < ($1.firstTasted ?? "") }
    }
}

extension Continent {
    /// Short enough to set around a plate's rim.
    var shortName: String {
        switch self {
        case .africa: "Africa"
        case .antarctica: "Antarctica"
        case .asia: "Asia"
        case .europe: "Europe"
        case .northAmerica: "N. America"
        case .oceania: "Oceania"
        case .southAmerica: "S. America"
        }
    }
}
