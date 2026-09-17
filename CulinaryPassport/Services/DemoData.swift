import Foundation

/// The demo cast: you (Alex), three friends, a follower and a public
/// stranger — with passports, memories, two groups and some chatter.
/// Dates are relative to today so "2h ago" and "On this day" stay true.
enum DemoData {
    static let me = DemoBackend.meId
    static let maya = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000002")!
    static let sam = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000003")!
    static let priya = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000004")!
    static let leo = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000005")!
    static let hana = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000006")!

    static var followDates: [UUID: Date] = [:]

    private static func ago(days: Double = 0, hours: Double = 0) -> Date {
        Date().addingTimeInterval(-(days * 86400 + hours * 3600))
    }

    /// yyyy-MM-dd for `years` ago today (the "On this day" memory).
    private static func sameDay(yearsAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .year, value: -yearsAgo, to: Date()) ?? Date()
        return DayFormat.string(from: date)
    }

    static func seed(into db: DemoBackend) {
        let joined = ago(days: 420)
        db.seedProfile(Profile(id: me, name: "Alex Rivera", color: "#2fbf8a", homeCity: "San Francisco",
                               homeCountry: "US", username: "alex.rivera",
                               bio: "Collecting stamps, sunsets and train windows.", avatarUrl: nil,
                               isPublic: true, createdAt: joined, yearlyGoal: 5))
        db.seedProfile(Profile(id: maya, name: "Maya Chen", color: "#e8883a", homeCity: "Vancouver",
                               homeCountry: "CA", username: "mayachen", bio: "Lakes, mountains, repeat.",
                               avatarUrl: nil, isPublic: true, createdAt: joined, yearlyGoal: nil))
        db.seedProfile(Profile(id: sam, name: "Sam Okafor", color: "#3b82e0", homeCity: "London",
                               homeCountry: "GB", username: "samtravels", bio: "One carry-on, 41 countries.",
                               avatarUrl: nil, isPublic: true, createdAt: joined, yearlyGoal: 8))
        db.seedProfile(Profile(id: priya, name: "Priya Nair", color: "#d86fb4", homeCity: "Bengaluru",
                               homeCountry: "IN", username: "priya", bio: nil,
                               avatarUrl: nil, isPublic: false, createdAt: joined, yearlyGoal: nil))
        db.seedProfile(Profile(id: leo, name: "Leo Martins", color: "#8b6fd8", homeCity: "São Paulo",
                               homeCountry: "BR", username: "leo.m", bio: "Waterfalls > beaches.",
                               avatarUrl: nil, isPublic: true, createdAt: joined, yearlyGoal: nil))
        db.seedProfile(Profile(id: hana, name: "Hana Sato", color: "#2fa8bf", homeCity: "Osaka",
                               homeCountry: "JP", username: "hana.sato", bio: "Slow travel, film cameras.",
                               avatarUrl: nil, isPublic: true, createdAt: joined, yearlyGoal: nil))

        // Friends = mutual follows (or a shared group).
        for (a, b) in [(me, maya), (maya, me), (me, sam), (sam, me), (me, priya), (priya, me),
                       (leo, me), (me, hana), (maya, sam), (sam, maya)] {
            db.seedFollow(a, b)
        }
        followDates = [maya: ago(days: 200), sam: ago(days: 150), priya: ago(days: 90), leo: ago(days: 2)]

        // ── Alex's passport ──────────────────────────────────────────────────
        let manual: [(String, String?, String?, Stamp.Source)] = [
            ("US", "1998-06-01", "2026-08-22", .manual), ("CA", "2018-07-04", "2018-07-11", .photos),
            ("MX", "2019-03-15", "2019-03-22", .photos), ("FR", "2021-09-10", "2021-09-18", .photos),
            ("VA", "2021-09-20", "2021-09-20", .manual), ("ES", "2023-06-02", "2023-06-09", .photos),
            ("GB", "2023-05-28", "2023-06-01", .photos),
        ]
        for (code, first, last, source) in manual {
            db.seedStamp(Stamp(userId: me, countryCode: code, firstVisited: first, lastVisited: last,
                               source: source, createdAt: ago(days: 300)))
        }

        let mine: [(String, String, String, String, [String], String?, Double, Double, Visibility, Double)] = [
            ("Big Sur", "Big Sur", "US", "2026-08-22", ["demo/bigsur-1"], "Highway 1 with the windows down. Fog rolled in right on cue.", 36.27, -121.81, .friends, 26),
            ("Oia sunset", "Santorini", "GR", "2025-07-02", ["demo/santorini-1", "demo/santorini-2"], "Everyone claps when the sun goes down. We clapped.", 36.46, 25.38, .public, 440),
            ("Trastevere", "Rome", "IT", "2025-05-03", ["demo/rome-1"], "Cacio e pepe, then a very long walk.", 41.89, 12.47, .friends, 500),
            ("Skógafoss", "Skógar", "IS", "2025-02-18", ["demo/iceland-1", "demo/reykjavik-1"], "Soaked, frozen, grinning. Northern lights two nights later.", 63.53, -19.51, .public, 580),
            ("Machu Picchu", "Cusco", "PE", sameDay(yearsAgo: 2), ["demo/machupicchu-1", "demo/machupicchu-2"], "Four days on the Inca Trail for this view. Worth every step.", -13.16, -72.54, .public, 730),
            ("Victoria Peak", "Hong Kong", "HK", "2024-04-19", ["demo/hongkong-1"], nil, 22.27, 114.15, .friends, 880),
            ("Gyeongbokgung", "Seoul", "KR", "2024-04-16", ["demo/seoul-1"], "Rented hanbok. Zero regrets.", 37.58, 126.98, .friends, 882),
            ("Fushimi Inari", "Kyoto", "JP", "2024-04-12", ["demo/kyoto-1", "demo/kyoto-2"], "Went at 6am and had the gates almost to ourselves.", 34.97, 135.77, .public, 886),
            ("Shibuya Crossing", "Tokyo", "JP", "2024-04-09", ["demo/tokyo-1"], nil, 35.66, 139.70, .friends, 889),
            ("Jemaa el-Fnaa", "Marrakech", "MA", "2023-06-20", ["demo/marrakech-1"], "Orange juice stalls as far as you can see.", 31.63, -7.99, .friends, 1190),
            ("Belém", "Lisbon", "PT", "2023-06-14", ["demo/lisbon-1"], "Pastéis still warm. Tram 28 at golden hour.", 38.70, -9.21, .public, 1195),
            ("Gardens by the Bay", "Singapore", "SG", "2022-11-08", ["demo/singapore-1"], nil, 1.28, 103.86, .friends, 1410),
            ("Hạ Long Bay", "Hạ Long", "VN", "2022-11-03", ["demo/halong-1", "demo/halong-2"], "Slept on a junk boat. Kayaked through a cave.", 20.91, 107.18, .public, 1414),
            ("Grand Palace", "Bangkok", "TH", "2022-10-28", ["demo/bangkok-1"], nil, 13.75, 100.49, .friends, 1420),
            ("Milford Sound", "Fiordland", "NZ", "2020-01-15", ["demo/milford-1"], "Rain made a hundred waterfalls.", -44.64, 167.90, .friends, 2440),
            ("Opera House", "Sydney", "AU", "2020-01-05", ["demo/sydney-1"], nil, -33.86, 151.21, .public, 2450),
        ]
        var memoryIds: [String: UUID] = [:]
        for (title, city, code, date, photos, notes, lat, lng, visibility, createdDaysAgo) in mine {
            let id = UUID()
            memoryIds[title] = id
            db.seedMemory(Memory(id: id, userId: me, countryCode: code, title: title, city: city, date: date,
                                 notes: notes, photos: photos, lat: lat, lng: lng, visibility: visibility,
                                 createdAt: ago(days: createdDaysAgo)))
        }
        db.seedBucket(["NO", "AR", "ZA", "EG", "NP", "CU", "TZ", "PF"])

        // ── Friends' passports + recent memories ─────────────────────────────
        func stamps(_ user: UUID, _ codes: [String], firstYear: Int) {
            for (i, code) in codes.enumerated() {
                let year = firstYear + i % 8
                db.seedStamp(Stamp(userId: user, countryCode: code, firstVisited: "\(year)-05-01",
                                   lastVisited: "\(year)-05-09", source: .photos, createdAt: ago(days: 400)))
            }
        }
        stamps(maya, ["CA", "US", "MX", "FR", "IT", "JP", "IS", "CR", "PE"], firstYear: 2015)
        stamps(sam, ["GB", "FR", "ES", "PT", "MA", "US", "JP", "TH", "ZA", "KE", "IE", "NL", "DE"], firstYear: 2012)
        stamps(priya, ["IN", "AE", "SG", "TH", "LK", "GB", "MV"], firstYear: 2016)
        stamps(leo, ["BR", "PT", "CL", "US", "UY"], firstYear: 2017)
        stamps(hana, ["JP", "KR", "TW", "FR", "IT", "CH"], firstYear: 2018)

        let theirs: [(UUID, String, String, String, Int, [String], String?, Double, Double, Visibility, Double)] = [
            (sam, "Petra", "Wadi Musa", "JO", 0, ["demo/petra-1", "demo/petra-2"], "Walked the Siq at dawn. Country #42!", 30.33, 35.44, .friends, 0.1),
            (hana, "Hallstatt", "Hallstatt", "AT", 0, ["demo/hallstatt-1"], "Postcard town, real people.", 47.56, 13.65, .public, 1.2),
            (priya, "Hội An lanterns", "Hội An", "VN", 0, ["demo/hoian-1"], "Full moon festival — the whole river glowed.", 15.88, 108.33, .friends, 2.4),
            (maya, "Lake Louise", "Banff", "CA", 0, ["demo/lakelouise-1", "demo/lakelouise-2"], "That color is real, I promise.", 51.42, -116.18, .friends, 5),
            (hana, "Cappadocia", "Göreme", "TR", 0, ["demo/cappadocia-1"], "4:30am alarm for balloons. Worth it.", 38.64, 34.83, .public, 9),
            (maya, "Sagrada Família", "Barcelona", "ES", 0, ["demo/barcelona-1"], nil, 41.40, 2.17, .friends, 16),
            (leo, "Iguazu Falls", "Puerto Iguazú", "AR", 0, ["demo/iguazu-1"], "Garganta del Diablo is LOUD.", -25.69, -54.44, .public, 21),
            (sam, "Edinburgh Castle", "Edinburgh", "GB", 0, ["demo/edinburgh-1"], nil, 55.95, -3.20, .friends, 38),
            (maya, "Bora Bora", "Bora Bora", "PF", 0, ["demo/borabora-1"], "Overwater bungalow for our anniversary.", -16.50, -151.74, .friends, 95),
            (sam, "Table Mountain", "Cape Town", "ZA", 0, ["demo/capetown-1"], nil, -33.96, 18.40, .friends, 120),
            (priya, "Taj Mahal", "Agra", "IN", 0, ["demo/agra-1"], nil, 27.18, 78.04, .friends, 190),
        ]
        var friendMemory: [String: UUID] = [:]
        for (user, title, city, code, _, photos, notes, lat, lng, visibility, createdDaysAgo) in theirs {
            let id = UUID()
            friendMemory[title] = id
            let created = ago(days: createdDaysAgo)
            db.seedMemory(Memory(id: id, userId: user, countryCode: code, title: title, city: city,
                                 date: DayFormat.string(from: created.addingTimeInterval(-86400)),
                                 notes: notes, photos: photos, lat: lat, lng: lng, visibility: visibility,
                                 createdAt: created))
        }
        // Sam's Petra stamp is brand new (the "stamped a new country" moment).
        db.seedStamp(Stamp(userId: sam, countryCode: "JO", firstVisited: DayFormat.string(from: ago(days: 1)),
                           lastVisited: DayFormat.string(from: ago(days: 1)), source: .memory, createdAt: ago(hours: 3)))
        db.seedStamp(Stamp(userId: priya, countryCode: "VN", firstVisited: DayFormat.string(from: ago(days: 3)),
                           lastVisited: DayFormat.string(from: ago(days: 3)), source: .memory, createdAt: ago(days: 2.4)))

        // ── Reactions + comments ─────────────────────────────────────────────
        func react(_ user: UUID, _ memory: String?, _ emoji: String, hours: Double) {
            guard let memory, let id = memoryIds[memory] ?? friendMemory[memory] else { return }
            db.seedReaction(Reaction(entryId: id, userId: user, emoji: emoji, createdAt: ago(hours: hours)))
        }
        react(maya, "Machu Picchu", "😍", hours: 1)
        react(sam, "Machu Picchu", "🔥", hours: 4)
        react(priya, "Fushimi Inari", "😍", hours: 70)
        react(sam, "Oia sunset", "❤️", hours: 30)
        react(maya, "Oia sunset", "❤️", hours: 29)
        react(me, "Petra", "🔥", hours: 2)
        react(maya, "Petra", "😍", hours: 2.5)
        react(me, "Lake Louise", "❤️", hours: 100)
        react(priya, "Lake Louise", "🥹", hours: 90)

        func comment(_ user: UUID, _ memory: String, _ text: String, hours: Double) {
            guard let id = memoryIds[memory] ?? friendMemory[memory] else { return }
            db.seedComment(Comment(id: UUID(), entryId: id, authorId: user, text: text, createdAt: ago(hours: hours)))
        }
        comment(sam, "Oia sunset", "Adding this to the list", hours: 5)
        comment(maya, "Oia sunset", "The colors!!", hours: 28)
        comment(maya, "Machu Picchu", "Did you do the full four days?? Legend", hours: 1.5)
        comment(me, "Petra", "Congrats on 42 🎉", hours: 2)
        comment(sam, "Petra", "Cheers! Wadi Rum next", hours: 1.8)

        // ── Groups ───────────────────────────────────────────────────────────
        let europe = Group(id: UUID(uuidString: "0D3E0000-0000-4000-8000-0000000000A1")!, name: "Europe 2027",
                           coverPhoto: nil, inviteCode: "europe2027", createdBy: me, createdAt: ago(days: 60))
        db.seedGroup(europe, members: [me, maya, sam])
        let hikers = Group(id: UUID(uuidString: "0D3E0000-0000-4000-8000-0000000000A2")!, name: "Rivera family",
                           coverPhoto: nil, inviteCode: "riverafam", createdBy: priya, createdAt: ago(days: 180))
        db.seedGroup(hikers, members: [priya, me, leo])

        // ── Trips you're planning (and one that already happened) ────────────
        func day(inDays: Int) -> String {
            DayFormat.string(from: Date().addingTimeInterval(Double(inDays) * 86400))
        }
        let europeTrip = TripPlan(id: UUID(uuidString: "0D3E0000-0000-4000-8000-0000000000B1")!, userId: me,
                                  name: "Alps by rail", countryCodes: ["FR", "IT", "CH"],
                                  startsOn: day(inDays: 201), endsOn: day(inDays: 216), groupId: europe.id,
                                  notes: "Trains between everything. No flights.", createdAt: ago(days: 40))
        let patagonia = TripPlan(id: UUID(uuidString: "0D3E0000-0000-4000-8000-0000000000B2")!, userId: me,
                                 name: "Patagonia, one day", countryCodes: ["AR", "CL"],
                                 startsOn: nil, endsOn: nil, groupId: nil,
                                 notes: "The W trek, end of season.", createdAt: ago(days: 120))
        // The Japan/Korea/Hong Kong run in the stamp book was planned first —
        // its memories turn it into a chapter.
        let blossom = TripPlan(id: UUID(uuidString: "0D3E0000-0000-4000-8000-0000000000B3")!, userId: me,
                               name: "Cherry blossom loop", countryCodes: ["JP", "KR", "HK"],
                               startsOn: "2024-04-08", endsOn: "2024-04-20", groupId: nil,
                               notes: "", createdAt: ago(days: 920))
        for plan in [europeTrip, patagonia, blossom] { db.seedTripPlan(plan) }

        func save(_ trip: TripPlan?, _ code: String, _ title: String, _ city: String,
                  _ lat: Double?, _ lng: Double?, note: String = "", from memory: String? = nil,
                  done: Bool = false, daysAgo: Double) {
            db.seedSavedPlace(SavedPlace(id: UUID(), userId: me, tripId: trip?.id, countryCode: code,
                                         title: title, city: city, lat: lat, lng: lng, note: note,
                                         sourceEntryId: memory.flatMap { friendMemory[$0] },
                                         done: done, createdAt: ago(days: daysAgo)))
        }
        save(europeTrip, "IT", "Cinque Terre", "Monterosso", 44.15, 9.65,
             note: "Walk the coast path early, before the ferries.", daysAgo: 30)
        save(europeTrip, "FR", "Aiguille du Midi", "Chamonix", 45.88, 6.89,
             note: "First cable car, clear mornings only.", daysAgo: 22)
        save(europeTrip, "CH", "Lauterbrunnen valley", "Lauterbrunnen", 46.59, 7.91, daysAgo: 12)
        save(patagonia, "CL", "Torres del Paine", "Puerto Natales", -50.94, -73.41, daysAgo: 110)
        save(patagonia, "AR", "Perito Moreno", "El Calafate", -50.47, -73.05, daysAgo: 108)
        save(nil, "AT", "Hallstatt", "Hallstatt", 47.56, 13.65,
             note: "Hana says go on a weekday.", from: "Hallstatt", daysAgo: 1.1)
        save(nil, "JO", "Petra", "Wadi Musa", 30.33, 35.44, from: "Petra", daysAgo: 0.1)
        save(nil, "ES", "Sagrada Família", "Barcelona", 41.40, 2.17,
             note: "Book the towers.", from: "Sagrada Família", daysAgo: 15)

        func post(_ group: Group, _ author: UUID, _ text: String, memory: String? = nil, hours: Double) -> UUID {
            let id = UUID()
            db.seedPost(GroupPost(id: id, groupId: group.id, authorId: author,
                                  entryId: memory.flatMap { memoryIds[$0] ?? friendMemory[$0] },
                                  text: text, photos: [], createdAt: ago(hours: hours)))
            return id
        }
        _ = post(europe, maya, "Okay — Portugal or Greece first?", hours: 50)
        let greece = post(europe, me, "Greece. Santorini in early July is unreal.", memory: "Oia sunset", hours: 49)
        _ = post(europe, sam, "Only if we do Lisbon on the way back", hours: 48)
        let dates = post(europe, maya, "Flights look cheapest 12–26 June 👀", hours: 6)
        db.seedPostReaction(PostReaction(postId: greece, userId: maya, emoji: "🔥"))
        db.seedPostReaction(PostReaction(postId: greece, userId: sam, emoji: "👍"))
        db.seedPostReaction(PostReaction(postId: dates, userId: me, emoji: "🙌"))
        db.seedPostComment(PostComment(id: UUID(), postId: dates, authorId: sam, parentId: nil,
                                       text: "Booking leave tomorrow", createdAt: ago(hours: 5)))

        _ = post(hikers, priya, "Hội An was magical. Next family trip: Vietnam?", memory: "Hội An lanterns", hours: 58)
        _ = post(hikers, leo, "Only if there's a waterfall", hours: 40)
    }
}
