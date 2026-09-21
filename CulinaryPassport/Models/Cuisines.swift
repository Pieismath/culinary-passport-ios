import Foundation

/// A country's food, by the name people actually order it by. The Tasted half
/// of the passport stamps a country's cuisine, so the stamp for "GE" reads
/// GEORGIAN, not GEORGIA.
enum Cuisine {
    /// "Georgian" for GE. Countries without an entry fall back to their name
    /// ("Tuvalu"), which reads fine on a stamp.
    static func name(for code: String) -> String {
        names[code] ?? CountryStore.byCode[code]?.name ?? code
    }

    /// Every place you can taste: sovereign countries, plus territories with
    /// a food of their own. Antarctica and the like are travel-only.
    static let codes: [String] = CountryStore.all
        .filter { $0.isSovereign || names[$0.code] != nil }
        .map(\.code)
        .sorted { name(for: $0) < name(for: $1) }

    /// "an Ethiopian", "a Georgian", "a Ukrainian", "an Uzbek".
    static func withArticle(_ code: String) -> String {
        let name = name(for: code)
        let vowelSound = name.first.map { "AEIO".contains($0) } == true || name.hasPrefix("Uzb")
        return "\(vowelSound ? "an" : "a") \(name)"
    }

    /// What the dinner dice can land on: popular cuisines nobody at the table
    /// has tasted — or, once they've tried them all, ones you haven't — or
    /// anything, for the truly well-fed.
    static func dinnerPool(tastedByTable table: Set<String>, tastedByMe mine: Set<String>) -> [String] {
        let fresh = dicePool.filter { !table.contains($0) }
        if !fresh.isEmpty { return fresh }
        let mineFresh = dicePool.filter { !mine.contains($0) }
        return mineFresh.isEmpty ? dicePool : mineFresh
    }

    static func isCuisine(_ code: String) -> Bool { codeSet.contains(code) }
    private static let codeSet = Set(codes)

    /// Does this cuisine answer a search? "pho" finds Vietnamese, "arepa"
    /// finds Venezuelan and Colombian, "georg" finds Georgian.
    static func matches(_ code: String, _ query: String) -> Bool {
        let q = query.trimmed.lowercased()
        guard !q.isEmpty else { return true }
        if name(for: code).lowercased().contains(q) { return true }
        if CountryStore.byCode[code]?.matches(q) == true { return true }
        return (dishes[code] ?? []).contains { $0.contains(q) }
    }

    /// The cuisine a restaurant's name gives away — "Pho Saigon", "Taqueria
    /// El Farolito", "Tbilisi Café". Nil when the name says nothing.
    static func suggest(from text: String) -> String? {
        let words = " " + text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter ? $0 : " " }
            .reduce(into: "") { $0.append($1) } + " "
        var best: (code: String, length: Int)?
        for (code, cues) in clues {
            for cue in cues where words.contains(" \(cue) ") {
                // Longest cue wins: "korean bbq" over "bbq".
                if best == nil || cue.count > best!.length { best = (code, cue.count) }
            }
        }
        return best?.code
    }

    /// Cuisines a city of any size is likely to serve — what the dinner dice
    /// rolls from, so it never lands on something you can't find tonight.
    static let dicePool: [String] = [
        "AF", "AR", "BR", "CN", "CO", "CU", "DE", "DO", "EG", "ER", "ES", "ET", "FR", "GB", "GE",
        "GR", "HT", "HU", "ID", "IE", "IL", "IN", "IR", "IT", "JM", "JP", "KR", "LB", "LK", "MA",
        "MM", "MX", "MY", "NG", "NP", "PE", "PH", "PK", "PL", "PR", "PT", "RU", "SN", "SO", "SV",
        "SY", "TH", "TR", "TW", "UA", "US", "UZ", "VE", "VN", "YE",
    ]

    // ── Names ────────────────────────────────────────────────────────────────

    private static let names: [String: String] = [
        "AF": "Afghan", "AL": "Albanian", "DZ": "Algerian", "AD": "Andorran", "AO": "Angolan",
        "AG": "Antiguan", "AR": "Argentine", "AM": "Armenian", "AU": "Australian", "AT": "Austrian",
        "AZ": "Azerbaijani", "BS": "Bahamian", "BH": "Bahraini", "BD": "Bangladeshi", "BB": "Bajan",
        "BY": "Belarusian", "BE": "Belgian", "BZ": "Belizean", "BJ": "Beninese", "BT": "Bhutanese",
        "BO": "Bolivian", "BA": "Bosnian", "BW": "Botswanan", "BR": "Brazilian", "BN": "Bruneian",
        "BG": "Bulgarian", "BF": "Burkinabé", "BI": "Burundian", "KH": "Cambodian", "CM": "Cameroonian",
        "CA": "Canadian", "CV": "Cape Verdean", "CF": "Central African", "TD": "Chadian", "CL": "Chilean",
        "CN": "Chinese", "CO": "Colombian", "KM": "Comorian", "CG": "Congolese", "CD": "Congolese (DRC)",
        "CR": "Costa Rican", "CI": "Ivorian", "HR": "Croatian", "CU": "Cuban", "CY": "Cypriot",
        "CZ": "Czech", "DK": "Danish", "DJ": "Djiboutian", "DM": "Dominica", "DO": "Dominican",
        "EC": "Ecuadorian", "EG": "Egyptian", "SV": "Salvadoran", "GQ": "Equatoguinean", "ER": "Eritrean",
        "EE": "Estonian", "SZ": "Swazi", "ET": "Ethiopian", "FJ": "Fijian", "FI": "Finnish",
        "FR": "French", "GA": "Gabonese", "GM": "Gambian", "GE": "Georgian", "DE": "German",
        "GH": "Ghanaian", "GR": "Greek", "GD": "Grenadian", "GT": "Guatemalan", "GN": "Guinean",
        "GW": "Bissau-Guinean", "GY": "Guyanese", "HT": "Haitian", "HN": "Honduran", "HU": "Hungarian",
        "IS": "Icelandic", "IN": "Indian", "ID": "Indonesian", "IR": "Persian", "IQ": "Iraqi",
        "IE": "Irish", "IL": "Israeli", "IT": "Italian", "JM": "Jamaican", "JP": "Japanese",
        "JO": "Jordanian", "KZ": "Kazakh", "KE": "Kenyan", "KI": "I-Kiribati", "XK": "Kosovar",
        "KW": "Kuwaiti", "KG": "Kyrgyz", "LA": "Lao", "LV": "Latvian", "LB": "Lebanese",
        "LS": "Basotho", "LR": "Liberian", "LY": "Libyan", "LI": "Liechtenstein", "LT": "Lithuanian",
        "LU": "Luxembourgish", "MG": "Malagasy", "MW": "Malawian", "MY": "Malaysian", "MV": "Maldivian",
        "ML": "Malian", "MT": "Maltese", "MH": "Marshallese", "MR": "Mauritanian", "MU": "Mauritian",
        "MX": "Mexican", "FM": "Micronesian", "MD": "Moldovan", "MC": "Monégasque", "MN": "Mongolian",
        "ME": "Montenegrin", "MA": "Moroccan", "MZ": "Mozambican", "MM": "Burmese", "NA": "Namibian",
        "NR": "Nauruan", "NP": "Nepali", "NL": "Dutch", "NZ": "New Zealand", "NI": "Nicaraguan",
        "NE": "Nigerien", "NG": "Nigerian", "KP": "North Korean", "MK": "Macedonian", "NO": "Norwegian",
        "OM": "Omani", "PK": "Pakistani", "PW": "Palauan", "PS": "Palestinian", "PA": "Panamanian",
        "PG": "Papua New Guinean", "PY": "Paraguayan", "PE": "Peruvian", "PH": "Filipino", "PL": "Polish",
        "PT": "Portuguese", "QA": "Qatari", "RO": "Romanian", "RU": "Russian", "RW": "Rwandan",
        "KN": "Kittitian", "LC": "Saint Lucian", "VC": "Vincentian", "WS": "Samoan", "SM": "Sammarinese",
        "ST": "São Toméan", "SA": "Saudi", "SN": "Senegalese", "RS": "Serbian", "SC": "Seychellois",
        "SL": "Sierra Leonean", "SG": "Singaporean", "SK": "Slovak", "SI": "Slovenian",
        "SB": "Solomon Islands", "SO": "Somali", "ZA": "South African", "KR": "Korean",
        "SS": "South Sudanese", "ES": "Spanish", "LK": "Sri Lankan", "SD": "Sudanese", "SR": "Surinamese",
        "SE": "Swedish", "CH": "Swiss", "SY": "Syrian", "TW": "Taiwanese", "TJ": "Tajik",
        "TZ": "Tanzanian", "TH": "Thai", "TL": "Timorese", "TG": "Togolese", "TO": "Tongan",
        "TT": "Trinidadian", "TN": "Tunisian", "TR": "Turkish", "TM": "Turkmen", "TV": "Tuvaluan",
        "UG": "Ugandan", "UA": "Ukrainian", "AE": "Emirati", "GB": "British", "US": "American",
        "UY": "Uruguayan", "UZ": "Uzbek", "VU": "Ni-Vanuatu", "VE": "Venezuelan", "VN": "Vietnamese",
        "YE": "Yemeni", "ZM": "Zambian", "ZW": "Zimbabwean",
        // Territories with a food of their own
        "HK": "Hong Kong", "MO": "Macanese", "PR": "Puerto Rican", "GU": "Chamorro",
        "PF": "Tahitian", "GL": "Greenlandic", "CW": "Curaçaoan", "AW": "Aruban", "RE": "Réunionese",
        "MQ": "Martinican", "GP": "Guadeloupean", "BM": "Bermudian", "KY": "Caymanian", "FO": "Faroese",
    ]

    // ── Dishes (search) and clues (restaurant names) ─────────────────────────

    /// What people search for when they mean a cuisine.
    private static let dishes: [String: [String]] = [
        "JP": ["sushi", "ramen", "udon", "soba", "izakaya", "yakitori", "tempura", "omakase", "katsu", "onigiri", "matcha"],
        "CN": ["dim sum", "dumpling", "sichuan", "szechuan", "cantonese", "hunan", "peking duck", "hot pot", "xiao long bao", "bao", "chow mein"],
        "KR": ["korean bbq", "bibimbap", "kimchi", "tteokbokki", "bulgogi", "soju", "fried chicken"],
        "VN": ["pho", "banh mi", "bun cha", "bun bo"],
        "TH": ["pad thai", "tom yum", "som tam", "green curry", "khao soi"],
        "IN": ["curry", "biryani", "dosa", "tandoori", "tikka", "masala", "chaat", "thali", "naan"],
        "MX": ["tacos", "taco", "burrito", "mole", "tamales", "pozole", "quesadilla", "elote", "mezcal"],
        "IT": ["pizza", "pasta", "risotto", "gelato", "tiramisu", "carbonara", "focaccia"],
        "FR": ["croissant", "crepe", "steak frites", "bouillabaisse", "coq au vin", "macaron"],
        "ES": ["tapas", "paella", "churros", "jamon", "pintxos", "tortilla"],
        "GR": ["gyro", "souvlaki", "moussaka", "spanakopita", "tzatziki"],
        "TR": ["kebab", "doner", "baklava", "pide", "lahmacun", "kofte"],
        "LB": ["shawarma", "falafel", "hummus", "manakish", "tabbouleh", "mezze"],
        "ET": ["injera", "doro wat", "tibs", "kitfo"],
        "ER": ["injera", "zigni"],
        "PE": ["ceviche", "lomo saltado", "pollo a la brasa", "causa", "pisco"],
        "GE": ["khachapuri", "khinkali", "churchkhela", "badrijani"],
        "MA": ["tagine", "couscous", "pastilla", "harira"],
        "PH": ["adobo", "sisig", "lumpia", "pancit", "halo halo", "lechon"],
        "MY": ["nasi lemak", "laksa", "roti canai", "satay", "char kway teow"],
        "SG": ["hainanese chicken rice", "chili crab", "laksa", "kaya toast"],
        "ID": ["nasi goreng", "rendang", "satay", "gado gado", "mie goreng"],
        "BR": ["churrasco", "feijoada", "pao de queijo", "acai", "coxinha", "picanha"],
        "AR": ["asado", "empanadas", "chimichurri", "milanesa", "dulce de leche"],
        "CO": ["arepa", "bandeja paisa", "empanadas"],
        "VE": ["arepa", "cachapa", "pabellon"],
        "SV": ["pupusa", "pupusas"],
        "CU": ["cubano", "ropa vieja", "cuban sandwich"],
        "JM": ["jerk chicken", "jerk", "patty", "ackee"],
        "HT": ["griot", "pikliz", "diri djon djon"],
        "NP": ["momo", "dal bhat"],
        "PK": ["nihari", "karahi", "biryani", "haleem"],
        "AF": ["kabuli pulao", "mantu", "bolani"],
        "IR": ["kebab koobideh", "tahdig", "ghormeh sabzi", "fesenjan"],
        "IL": ["shakshuka", "sabich", "falafel", "hummus"],
        "UZ": ["plov", "samsa", "lagman"],
        "MM": ["mohinga", "tea leaf salad", "khao suey"],
        "TW": ["bubble tea", "beef noodle soup", "xiaolongbao", "gua bao"],
        "HK": ["dim sum", "egg tart", "pineapple bun", "roast goose"],
        "LK": ["hoppers", "kottu", "string hoppers"],
        "NG": ["jollof", "suya", "egusi", "puff puff"],
        "SN": ["thieboudienne", "yassa", "mafe"],
        "SO": ["suqaar", "canjeero", "bariis"],
        "YE": ["mandi", "saltah", "fahsa"],
        "EG": ["koshari", "ful medames", "molokhia", "taameya"],
        "SY": ["shawarma", "kibbeh", "fattoush"],
        "RU": ["pelmeni", "blini", "borscht", "stroganoff"],
        "UA": ["varenyky", "borscht", "holubtsi"],
        "PL": ["pierogi", "kielbasa", "zurek", "bigos"],
        "HU": ["goulash", "langos", "paprikash", "chimney cake"],
        "DE": ["bratwurst", "schnitzel", "pretzel", "currywurst", "spaetzle"],
        "PT": ["pasteis de nata", "bacalhau", "francesinha", "piri piri"],
        "GB": ["fish and chips", "sunday roast", "pie", "full english"],
        "IE": ["irish stew", "soda bread", "boxty"],
        "US": ["burger", "bbq", "barbecue", "hot dog", "cheesesteak", "fried chicken", "mac and cheese"],
        "PR": ["mofongo", "pernil", "alcapurria"],
        "DO": ["mangu", "sancocho", "chicharron"],
        "CA": ["poutine", "butter tart", "nanaimo bar"],
        "AU": ["meat pie", "lamington", "pavlova", "flat white"],
        "BE": ["waffle", "frites", "moules frites"],
        "CH": ["fondue", "raclette", "rosti"],
        "SE": ["meatballs", "kanelbulle", "smorgasbord"],
        "AT": ["schnitzel", "apfelstrudel", "sachertorte"],
    ]

    /// Words in a restaurant's name that give its cuisine away.
    private static let clues: [String: [String]] = [
        "JP": ["sushi", "ramen", "izakaya", "udon", "soba", "yakitori", "tempura", "omakase", "japanese", "katsu", "robata", "teppanyaki", "donburi"],
        "CN": ["dim sum", "dumpling", "dumplings", "szechuan", "sichuan", "cantonese", "hunan", "chinese", "hot pot", "noodle house", "shanghai", "peking", "canton"],
        "KR": ["korean", "korean bbq", "bibimbap", "kimchi", "seoul", "pocha", "tofu house", "bulgogi"],
        "VN": ["pho", "banh mi", "vietnamese", "saigon", "hanoi"],
        "TH": ["thai", "bangkok", "siam", "isan", "khao"],
        "IN": ["indian", "curry", "tandoor", "tandoori", "masala", "biryani", "dosa", "chaat", "punjab", "punjabi", "bombay", "mumbai", "delhi", "madras", "tikka", "mahal"],
        "MX": ["taqueria", "tacos", "taco", "mexican", "cantina", "burrito", "tortilleria", "mezcaleria"],
        "IT": ["pizzeria", "pizza", "trattoria", "osteria", "ristorante", "italian", "pasta", "enoteca", "gelateria", "napoli", "roma"],
        "FR": ["bistro", "bistrot", "brasserie", "french", "boulangerie", "creperie", "patisserie", "chez"],
        "ES": ["tapas", "spanish", "paella", "taberna", "bodega"],
        "GR": ["greek", "taverna", "souvlaki", "gyro", "gyros", "athens", "mykonos"],
        "TR": ["turkish", "kebab", "doner", "istanbul", "anatolia", "ottoman"],
        "LB": ["lebanese", "beirut", "manoushe", "zaatar"],
        "ET": ["ethiopian", "addis", "abyssinia", "injera"],
        "ER": ["eritrean", "asmara"],
        "PE": ["peruvian", "ceviche", "cevicheria", "lima", "inca", "pollo a la brasa"],
        "GE": ["georgian", "tbilisi", "khachapuri", "supra", "khinkali"],
        "MA": ["moroccan", "marrakech", "tagine", "casablanca", "fez"],
        "PH": ["filipino", "manila", "adobo", "sisig", "lechon"],
        "MY": ["malaysian", "penang", "kuala lumpur", "laksa"],
        "SG": ["singaporean", "hawker"],
        "ID": ["indonesian", "bali", "jakarta", "warung"],
        "BR": ["brazilian", "churrascaria", "brasil"],
        "AR": ["argentine", "argentinian", "parrilla", "buenos aires", "empanadas"],
        "CO": ["colombian", "bogota", "medellin"],
        "VE": ["venezuelan", "arepa", "arepas", "caracas"],
        "SV": ["salvadoran", "pupuseria", "pupusas"],
        "CU": ["cuban", "havana", "habana"],
        "JM": ["jamaican", "jerk", "kingston"],
        "HT": ["haitian", "port au prince"],
        "NP": ["nepali", "nepalese", "himalayan", "momo", "everest", "kathmandu"],
        "PK": ["pakistani", "karachi", "lahore"],
        "AF": ["afghan", "kabul"],
        "IR": ["persian", "iranian", "tehran", "shiraz"],
        "IL": ["israeli", "tel aviv", "shuk"],
        "UZ": ["uzbek", "samarkand", "tashkent"],
        "MM": ["burmese", "myanmar", "yangon", "mandalay"],
        "TW": ["taiwanese", "taipei", "boba"],
        "HK": ["hong kong", "cha chaan teng"],
        "LK": ["sri lankan", "ceylon", "colombo"],
        "NG": ["nigerian", "lagos", "suya", "naija"],
        "SN": ["senegalese", "dakar"],
        "SO": ["somali", "mogadishu"],
        "YE": ["yemeni", "sanaa", "mandi"],
        "EG": ["egyptian", "cairo", "koshari"],
        "SY": ["syrian", "damascus", "aleppo"],
        "RU": ["russian", "moscow", "pelmeni"],
        "UA": ["ukrainian", "kyiv", "odessa"],
        "PL": ["polish", "pierogi", "krakow", "warsaw"],
        "HU": ["hungarian", "budapest", "goulash"],
        "DE": ["german", "biergarten", "bierhaus", "brauhaus", "bavarian", "schnitzel"],
        "PT": ["portuguese", "lisbon", "porto", "nata", "piri piri"],
        "GB": ["british", "chippy", "fish and chips", "pub"],
        "IE": ["irish"],
        "US": ["diner", "american", "bbq", "barbecue", "smokehouse", "burger", "burgers"],
        "PR": ["puerto rican", "boricua", "mofongo"],
        "DO": ["dominican"],
        "CA": ["canadian", "poutine"],
        "BE": ["belgian", "frites"],
        "CH": ["swiss", "fondue"],
        "SE": ["swedish", "scandinavian"],
        "AT": ["austrian", "vienna", "wien"],
        "AU": ["australian", "aussie"],
    ]
}
