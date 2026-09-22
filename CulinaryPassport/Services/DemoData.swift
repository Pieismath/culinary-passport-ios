import Foundation

/// The demo cast: you (Alex), three friends, a follower and a public
/// stranger — with meals, cuisines tasted, three tables and some dinner
/// talk. Dates are relative to today so "2h ago" stays true.
enum DemoData {
    static let me = DemoBackend.meId
    static let maya = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000002")!
    static let sam = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000003")!
    static let priya = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000004")!
    static let leo = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000005")!
    static let hana = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000006")!

    static let dinnerClub = UUID(uuidString: "0D3E0000-0000-4000-8000-0000000000A1")!
    static let family = UUID(uuidString: "0D3E0000-0000-4000-8000-0000000000A2")!
    static let lunch = UUID(uuidString: "0D3E0000-0000-4000-8000-0000000000A3")!

    static var followDates: [UUID: Date] = [:]

    private static func ago(days: Double = 0, hours: Double = 0) -> Date {
        Date().addingTimeInterval(-(days * 86400 + hours * 3600))
    }

    static func seed(into db: DemoBackend) {
        let joined = ago(days: 420)
        db.seedProfile(Profile(id: me, name: "Alex Rivera", color: "#2fbf8a", homeCity: "San Francisco",
                               homeCountry: "US", username: "alex.rivera",
                               bio: "Working through the world one dinner at a time.", avatarUrl: nil,
                               isPublic: true, createdAt: joined, yearlyGoal: 12))
        db.seedProfile(Profile(id: maya, name: "Maya Chen", color: "#e8883a", homeCity: "Oakland",
                               homeCountry: "US", username: "mayachen", bio: "Will cross town for a good dumpling.",
                               avatarUrl: nil, isPublic: true, createdAt: joined, yearlyGoal: nil))
        db.seedProfile(Profile(id: sam, name: "Sam Okafor", color: "#3b82e0", homeCity: "San Francisco",
                               homeCountry: "GB", username: "sam.eats", bio: "Street food over tablecloths.",
                               avatarUrl: nil, isPublic: true, createdAt: joined, yearlyGoal: 10))
        db.seedProfile(Profile(id: priya, name: "Priya Nair", color: "#d86fb4", homeCity: "Bengaluru",
                               homeCountry: "IN", username: "priya", bio: nil,
                               avatarUrl: nil, isPublic: false, createdAt: joined, yearlyGoal: nil))
        db.seedProfile(Profile(id: leo, name: "Leo Martins", color: "#8b6fd8", homeCity: "São Paulo",
                               homeCountry: "BR", username: "leo.m", bio: "Churrasco purist, arepa convert.",
                               avatarUrl: nil, isPublic: true, createdAt: joined, yearlyGoal: nil))
        db.seedProfile(Profile(id: hana, name: "Hana Sato", color: "#2fa8bf", homeCity: "San Francisco",
                               homeCountry: "JP", username: "hana.sato", bio: "Noodles, every country's version.",
                               avatarUrl: nil, isPublic: true, createdAt: joined, yearlyGoal: nil))
        // Friends = mutual follows (or a shared table).
        for (a, b) in [(me, maya), (maya, me), (me, sam), (sam, me), (me, priya), (priya, me),
                       (leo, me), (me, hana), (maya, sam), (sam, maya)] {
            db.seedFollow(a, b)
        }
        followDates = [maya: ago(days: 200), sam: ago(days: 150), priya: ago(days: 90), leo: ago(days: 2)]

        // ── Meals ────────────────────────────────────────────────────────────
        // (user, restaurant, dish, cuisine, city, photo, note, lat, lng, days ago, visibility)
        let meals: [(UUID, String, String, String, String, String?, String?, Double, Double, Double, Visibility)] = [
            (me, "Supra", "Khachapuri", "GE", "San Francisco", "demo/khachapuri-1",
             "Cheese boat, butter, egg. Stirred it all together like they said. No regrets.", 37.76, -122.42, 3, .friends),
            (me, "Ramen Kiyo", "Tonkotsu ramen", "JP", "San Francisco", "demo/ramen-1", nil, 37.78, -122.41, 9, .public),
            (me, "Taqueria La Paloma", "Al pastor tacos", "MX", "San Francisco", "demo/tacos-1",
             "Pineapple on the spit. Four tacos was one too many. Five next time.", 37.75, -122.42, 12, .public),
            (me, "Pho Hoa Lan", "Pho tai", "VN", "Oakland", "demo/pho-1", nil, 37.80, -122.27, 17, .friends),
            (me, "Chalaca", "Ceviche mixto", "PE", "San Francisco", "demo/ceviche-1", nil, 37.79, -122.40, 24, .friends),
            (me, "Seoul Garden", "Dolsot bibimbap", "KR", "San Francisco", "demo/bibimbap-1", nil, 37.78, -122.43, 31, .friends),
            (me, "Dosa Mandir", "Masala dosa", "IN", "Berkeley", "demo/dosa-1", nil, 37.87, -122.27, 38, .friends),
            (me, "Osteria Vela", "Cacio e pepe", "IT", "San Francisco", "demo/pasta-1", nil, 37.80, -122.41, 45, .public),
            (me, "Ramen Kiyo", "Spicy miso ramen", "JP", "San Francisco", "demo/ramen-2", nil, 37.78, -122.41, 52, .friends),
            (me, "Isan Street", "Khao soi", "TH", "Oakland", "demo/khaosoi-1", nil, 37.81, -122.26, 60, .friends),
            (me, "Lalibela Kitchen", "Doro wat", "ET", "Oakland", "demo/injera-1",
             "Ate with our hands, which is the right way to do it.", 37.83, -122.26, 75, .friends),
            (me, "Golden Dragon", "Xiao long bao", "CN", "San Francisco", "demo/dumplings-1", nil, 37.79, -122.41, 90, .friends),
            (me, "Istanbul Grill", "Iskender kebab", "TR", "San Francisco", "demo/kebab-1", nil, 37.77, -122.42, 130, .friends),
            (maya, "Bissap Baobab", "Thieboudienne", "SN", "San Francisco", "demo/thieb-1",
             "Rice, fish, a tomato sauce I'd drink by the glass. First Senegalese!", 37.759, -122.419, 0.3, .friends),
            (sam, "Helmand Palace", "Mantu", "AF", "San Francisco", "demo/mantu-1", nil, 37.799, -122.422, 1.6, .friends),
            (hana, "Samarkand Grill", "Wedding plov", "UZ", "San Francisco", "demo/plov-1",
             "Carrots, lamb, the rice all shiny. A whole wedding in a bowl.", 37.769, -122.447, 3.2, .public),
            (leo, "Arepa Lab", "Reina pepiada", "VE", "São Paulo", "demo/arepa-1", nil, -23.56, -46.65, 6, .public),
            (priya, "Gaúcho Grill", "Picanha", "BR", "Bengaluru", "demo/churrasco-1", nil, 12.97, 77.59, 8, .friends),
            (maya, "Lalibela Kitchen", "Injera platter", "ET", "Oakland", "demo/injera-2",
             "Told Alex it was good. Alex was right to listen.", 37.83, -122.26, 11, .friends),
            (sam, "Suya Spot", "Beef suya", "NG", "Oakland", "demo/suya-1", nil, 37.812, -122.268, 14, .friends),
            (hana, "Pho Hoa Lan", "Pho ga", "VN", "Oakland", "demo/pho-2", nil, 37.80, -122.27, 20, .public),
        ]
        var mealIds: [String: UUID] = [:]
        for (user, restaurant, dish, code, city, photo, note, lat, lng, daysAgo, visibility) in meals {
            let created = ago(days: daysAgo)
            let id = UUID()
            mealIds[dish] = id
            db.seedMeal(Meal(id: id, userId: user, countryCode: code, title: "", city: city,
                             date: DayFormat.string(from: created), notes: note,
                             photos: photo.map { [$0] } ?? [], lat: lat, lng: lng,
                             visibility: visibility, createdAt: created, kind: .meal,
                             restaurantName: restaurant, dish: dish))
        }
        // Cuisines ticked on the checklist, no meals logged for them.
        for code in ["FR", "US", "GR", "ES", "LB", "DE", "GB"] {
            db.seedTaste(Taste(userId: me, countryCode: code, firstTasted: nil, lastTasted: nil,
                               meals: 0, source: .manual, createdAt: ago(days: 400)))
        }
        for (user, codes) in [(maya, ["JP", "MX", "IT", "CN", "KR", "FR", "TH", "VN", "US"]),
                              (sam, ["IN", "GB", "JP", "JM", "FR", "IT", "TR", "US", "CN"]),
                              (hana, ["JP", "KR", "TW", "FR", "IT", "CN", "TH"]),
                              (priya, ["IN", "TH", "LK", "SG", "CN", "IT", "MX"]),
                              (leo, ["BR", "PT", "PE", "AR", "IT", "US", "MX", "JP"])] {
            for code in codes {
                db.seedTaste(Taste(userId: user, countryCode: code, firstTasted: nil, lastTasted: nil,
                                   meals: 0, source: .manual, createdAt: ago(days: 300)))
            }
        }

        // ── Reactions + comments ─────────────────────────────────────────────
        func react(_ user: UUID, _ dish: String, _ emoji: String, hours: Double) {
            guard let id = mealIds[dish] else { return }
            db.seedReaction(Reaction(entryId: id, userId: user, emoji: emoji, createdAt: ago(hours: hours)))
        }
        react(maya, "Khachapuri", "😍", hours: 1)
        react(sam, "Khachapuri", "🔥", hours: 4)
        react(priya, "Al pastor tacos", "🤤", hours: 70)
        react(sam, "Doro wat", "❤️", hours: 30)
        react(me, "Thieboudienne", "😍", hours: 2)
        react(sam, "Thieboudienne", "🤤", hours: 2.5)
        react(me, "Wedding plov", "🔥", hours: 20)
        func comment(_ user: UUID, _ dish: String, _ text: String, hours: Double) {
            guard let id = mealIds[dish] else { return }
            db.seedComment(Comment(id: UUID(), entryId: id, authorId: user, text: text, createdAt: ago(hours: hours)))
        }
        comment(maya, "Khachapuri", "Is this the place on Valencia?? Taking me there", hours: 1.5)
        comment(sam, "Khachapuri", "The egg stir is the whole point", hours: 3)
        comment(me, "Thieboudienne", "Adding it to the list", hours: 2)
        comment(maya, "Thieboudienne", "Get the bissap juice too", hours: 1.8)

        // ── Tables ───────────────────────────────────────────────────────────
        let club = Group(id: dinnerClub, name: "Friday Dinner Club", coverPhoto: nil,
                         inviteCode: "fridaydinner", createdBy: me, createdAt: ago(days: 60))
        db.seedGroup(club, members: [me, maya, sam])
        let rivera = Group(id: family, name: "Rivera family", coverPhoto: nil,
                           inviteCode: "riverafam", createdBy: priya, createdAt: ago(days: 180))
        db.seedGroup(rivera, members: [priya, me, leo])
        let office = Group(id: lunch, name: "Office lunch", coverPhoto: nil,
                           inviteCode: "officelunch", createdBy: hana, createdAt: ago(days: 30))
        db.seedGroup(office, members: [hana, me, sam])

        // ── Restaurants to try ───────────────────────────────────────────────
        func save(_ cuisine: String, _ title: String, _ city: String, _ lat: Double, _ lng: Double,
                  note: String = "", from dish: String? = nil, daysAgo: Double) {
            db.seedSavedPlace(SavedPlace(id: UUID(), userId: me, countryCode: "US", title: title, city: city,
                                         lat: lat, lng: lng, note: note,
                                         sourceEntryId: dish.flatMap { mealIds[$0] },
                                         done: false, createdAt: ago(days: daysAgo), cuisineCode: cuisine))
        }
        save("MM", "Burma Superstar", "San Francisco", 37.783, -122.463,
             note: "Friday's spin. Get the tea leaf salad.", daysAgo: 2)
        save("AF", "Helmand Palace", "San Francisco", 37.799, -122.422,
             note: "Sam's mantu", from: "Mantu", daysAgo: 1.5)
        save("UZ", "Samarkand Grill", "San Francisco", 37.769, -122.447,
             note: "Hana's plov place", from: "Wedding plov", daysAgo: 3)

        // ── Dinner talk ──────────────────────────────────────────────────────
        func post(_ group: Group, _ author: UUID, _ text: String, meal: String? = nil,
                  pick: DinnerPick? = nil, hours: Double) -> UUID {
            let id = UUID()
            db.seedPost(GroupPost(id: id, groupId: group.id, authorId: author,
                                  entryId: meal.flatMap { mealIds[$0] },
                                  text: text.isEmpty ? (pick?.fallbackText ?? "") : text,
                                  photos: [], createdAt: ago(hours: hours), pick: pick))
            return id
        }
        _ = post(club, maya, "Where are we eating Friday? Something none of us has had 🍽️", hours: 50)
        let spin = post(club, me, "", pick: DinnerPick(cuisineCode: "MM"), hours: 49.5)
        let burma = post(club, me, "Burma Superstar on Clement? Tea leaf salad is supposed to be the move",
                         pick: DinnerPick(cuisineCode: "MM", placeName: "Burma Superstar",
                                          placeAddress: "309 Clement St, San Francisco",
                                          placeLat: 37.783, placeLng: -122.463), hours: 49)
        _ = post(club, sam, "Never had Burmese. I'm in", hours: 48)
        _ = post(club, maya, "Tried Senegalese last night — backup for next Friday?", meal: "Thieboudienne", hours: 6)
        db.seedPostReaction(PostReaction(postId: spin, userId: sam, emoji: "🔥"))
        db.seedPostReaction(PostReaction(postId: burma, userId: maya, emoji: GroupPost.imIn))
        db.seedPostReaction(PostReaction(postId: burma, userId: sam, emoji: GroupPost.imIn))
        db.seedPostComment(PostComment(id: UUID(), postId: burma, authorId: maya, parentId: nil,
                                       text: "Booking for 7", createdAt: ago(hours: 47)))
        _ = post(rivera, priya, "Sunday lunch — somewhere new for once?", hours: 58)
        _ = post(rivera, leo, "", pick: DinnerPick(cuisineCode: "PE"), hours: 40)
        _ = post(rivera, leo, "Only if there's ceviche", hours: 39.5)
        _ = post(office, hana, "An Uzbek place opened on 4th. Plov Thursday?", meal: "Wedding plov", hours: 3)
    }
}
