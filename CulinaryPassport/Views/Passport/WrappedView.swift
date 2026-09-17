import SwiftUI

/// Your year in travel: where you went, what was new, how far, and a card
/// worth posting.
struct WrappedView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var shareImage: UIImage?
    @State private var viewing: Memory?

    private var years: [Int] { YearInReview.availableYears(stamps: app.stamps, memories: app.memories) }
    private var review: YearInReview { YearInReview(year: year, stamps: app.stamps, memories: app.memories) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if years.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(years, id: \.self) { option in
                                Button { withAnimation(.snappy) { year = option } } label: {
                                    Text(String(option))
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(option == year ? Color.onBrand : Color.ink)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 34)
                                        .background(option == year ? Color.brand : Color.card, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                let r = review
                if r.isEmpty {
                    EmptyStateView(systemImage: "calendar", title: "Nothing in \(String(year)) yet",
                                   message: "Add memories from this year's trips and your review fills itself in.")
                        .padding(.top, 60)
                } else {
                    hero(r)
                    HStack(spacing: 12) {
                        tile("\(r.newCountries.count)", "new countr\(r.newCountries.count == 1 ? "y" : "ies")", tint: .stampRed)
                        tile("\(r.continents)", "continent\(r.continents == 1 ? "" : "s")", tint: .brand)
                    }
                    if r.distanceKm >= 1 {
                        distanceCard(r)
                    }
                    HStack(spacing: 12) {
                        tile("\(r.trips.count)", "trip\(r.trips.count == 1 ? "" : "s")", tint: .bucket)
                        tile("\(r.cities)", "cit\(r.cities == 1 ? "y" : "ies")", tint: Color(hex: "#2e5c8a"))
                    }
                    if !r.newCountries.isEmpty {
                        newStampsCard(r)
                    }
                    if let top = r.topCountry, let country = CountryStore.byCode[top.code] {
                        VStack(spacing: 6) {
                            Eyebrow(text: "Where you kept going back")
                            Text("\(country.flag) \(country.name)").font(.display)
                            Text("\(top.memories) memor\(top.memories == 1 ? "y" : "ies")")
                                .font(.subheadline)
                                .foregroundStyle(Color.inkSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .card()
                    }
                    if !r.trips.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("The trips")
                            ForEach(r.trips.reversed()) { trip in
                                TripCard(trip: trip)
                            }
                        }
                    }
                }
            }
            .padding(Metrics.gutter)
            .padding(.bottom, 24)
        }
        .paperBackground()
        .navigationTitle("Your \(String(year)) in travel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            if let shareImage, !review.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: Image(uiImage: shareImage),
                              preview: SharePreview("My \(String(year)) in travel", image: Image(uiImage: shareImage))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: year) { renderShareCard() }
        .onAppear {
            if let latest = years.first, review.isEmpty { year = latest }
        }
    }

    private func hero(_ r: YearInReview) -> some View {
        VStack(spacing: 10) {
            Eyebrow(text: "In \(String(year)) you visited", color: .brand)
            Text("\(r.countries.count)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)
                .contentTransition(.numericText())
            Text(r.countries.count == 1 ? "country" : "countries")
                .font(.displaySmall)
                .foregroundStyle(Color.ink)
            Text(r.countries.map(Country.flag(for:)).joined(separator: " "))
                .font(.title2)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .card()
    }

    private func tile(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func distanceCard(_ r: YearInReview) -> some View {
        let km = Int(r.distanceKm.rounded())
        let laps = r.distanceKm / 40_075
        return VStack(spacing: 6) {
            Eyebrow(text: "Distance between your memories")
            Text("\(km.formatted()) km")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)
            Text(laps >= 0.1
                 ? "That's \(String(format: "%.1f", laps))× around the Earth."
                 : "Across \(r.countries.count) countr\(r.countries.count == 1 ? "y" : "ies") and \(r.trips.count) trip\(r.trips.count == 1 ? "" : "s").")
                .font(.subheadline)
                .foregroundStyle(Color.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func newStampsCard(_ r: YearInReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("New stamps", subtitle: "First visits in \(String(year))")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 10) {
                ForEach(r.newCountries, id: \.self) { code in
                    StampBadge(code: code, subtitle: String(year), size: 96)
                }
            }
        }
        .card()
    }

    @MainActor
    private func renderShareCard() {
        let r = review
        guard !r.isEmpty else { shareImage = nil; return }
        let card = ShareCard {
            VStack(spacing: 12) {
                Text("MY \(String(year)) IN TRAVEL")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.33))
                Text("\(r.countries.count)")
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                Text(r.countries.count == 1 ? "country" : "countries")
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                Text(r.countries.prefix(12).map(Country.flag(for:)).joined(separator: " "))
                    .font(.system(size: 26))
                    .multilineTextAlignment(.center)
                HStack(spacing: 22) {
                    stat("\(r.newCountries.count)", "new")
                    stat("\(r.trips.count)", "trips")
                    stat("\(Int(r.distanceKm.rounded()).formatted())", "km")
                }
                .padding(.top, 6)
            }
            .foregroundStyle(Color(red: 0.12, green: 0.1, blue: 0.08))
        }
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        shareImage = renderer.uiImage
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.33))
        }
    }
}

/// Terms + community rules + privacy, in plain language.
struct LegalView: View {
    enum Page: String, CaseIterable, Identifiable {
        case terms = "Terms & community"
        case privacy = "Privacy"
        var id: String { rawValue }
    }

    @State private var page: Page = .terms

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch page {
                case .terms: terms
                case .privacy: privacy
                }
            }
            .padding(Metrics.gutter)
        }
        .paperBackground()
        .navigationTitle("Terms & privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var terms: some View {
        section("The deal", """
        Stampd is a travel passport: a place to keep the countries you've \
        visited and the memories from them, and to share them with the people \
        you choose. By creating an account you agree to these terms and the \
        community rules below.
        """)
        section("Your content", """
        Photos, memories, messages and reactions you post belong to you. You \
        give us permission to store them and show them to the people your \
        visibility settings allow — that's the whole license. Delete a memory \
        and it's gone; delete your account (Passport → Settings → Delete \
        account) and everything goes with it, including your photos.
        """)
        section("Community rules", """
        Don't post content that is illegal, hateful, harassing, sexually \
        explicit, or that belongs to someone else. Don't post photos of people \
        who haven't agreed to it. Don't impersonate anyone. Don't spam.

        Every memory, profile, comment and group message can be reported from \
        inside the app, and you can block anyone — blocked people disappear \
        from your feeds and search. We review reports and remove content or \
        accounts that break these rules.
        """)
        section("Groups", """
        Group owners can rename a group, set its photo and invite code, and \
        delete it. Deleting a group removes its chat for everyone; members' \
        memories stay in their own passports.
        """)
        section("Travel safely", """
        Think before sharing where you are while you're still there. Memories \
        default to Friends, and you can make any memory Only me.
        """)
        section("No warranty", """
        The app is provided as-is while it grows. We do our best to keep your \
        data safe and the service up, but can't promise either, and we're not \
        liable for losses from using the app.
        """)
    }

    @ViewBuilder private var privacy: some View {
        section("What we store", """
        Your account (email, name, username, photo, color, home country), the \
        countries you've stamped and when, the memories you post (photos, \
        place, city, date, words, and the place's coordinates — rounded to \
        about a kilometre when they come from a photo), your follows, \
        groups and blocks, messages and reactions, and a small set of usage \
        events (like "memory added") used only to see whether features work.
        """)
        section("Your photo library stays on your phone", """
        "Find countries in my photos" reads photo locations on your device to \
        work out which countries you've been to. Nothing is uploaded — only \
        the countries you choose to stamp (and their dates) are saved. Photos \
        you add to a memory are re-encoded before upload, which strips their \
        embedded GPS and camera data.
        """)
        section("Who can see what", """
        Every memory has a visibility: Friends (people you follow each other \
        with, and your groups), Public, or Only me. Photos live in a private \
        bucket and follow the same rule. Your stamps are visible to friends, \
        and to everyone if your profile is public. Private profiles don't \
        appear in search.
        """)
        section("What we don't do", """
        We don't sell your data and we don't show ads. We only share \
        information with the infrastructure that runs the app: Supabase \
        (database, storage, sign-in), Apple Maps (place search), and Apple or \
        Google if you sign in with them.
        """)
        section("Your controls", """
        Edit or delete any memory, remove any stamp, change visibility per \
        memory, make your profile private, block people, leave groups, and \
        delete your account — immediately and permanently — from Settings.
        """)
        section("Contact", """
        Questions or takedown requests: technical@theprojectfactory.com.
        """)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.displayXSmall).foregroundStyle(Color.ink)
            Text(body).font(.subheadline).foregroundStyle(Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}
