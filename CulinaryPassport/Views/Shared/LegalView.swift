import SwiftUI

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
        Stampd is a food passport: a place to keep the cuisines you've eaten \
        and the meals you've had, to spin for what to eat next, and to share \
        all of it with the people you choose. By creating an account you agree \
        to these terms and the community rules below.
        """)
        section("Your content", """
        Photos, meals, messages and reactions you post belong to you. You give \
        us permission to store them and show them to the people your \
        visibility settings allow — that's the whole license. Delete a meal \
        and it's gone; delete your account (Me → Settings → Delete account) \
        and everything goes with it, including your photos.
        """)
        section("Community rules", """
        Don't post content that is illegal, hateful, harassing, sexually \
        explicit, or that belongs to someone else. Don't post photos of people \
        who haven't agreed to it. Don't impersonate anyone. Don't spam, and \
        don't use Stampd to promote a restaurant you're paid by.

        Every meal, profile, comment and table message can be reported from \
        inside the app, and you can block anyone — blocked people disappear \
        from your feeds and search. We review reports and remove content or \
        accounts that break these rules.
        """)
        section("Tables", """
        Table owners can rename a table, set its photo and invite code, and \
        delete it. Deleting a table removes its chat for everyone; members' \
        meals stay in their own passports.
        """)
        section("Restaurants", """
        Restaurant names, addresses and distances come from Apple Maps. We \
        don't rate or rank restaurants, and we can't vouch for opening hours, \
        menus or allergens — check with the restaurant.
        """)
        section("No warranty", """
        The app is provided as-is while it grows. We do our best to keep your \
        data safe and the service up, but can't promise either, and we're not \
        liable for losses from using the app.
        """)
    }

    @ViewBuilder private var privacy: some View {
        section("What we store", """
        Your account (email, name, username, photo, colour, home country), \
        the cuisines you've tasted and when, the meals you log (photos, \
        restaurant, dish, city, date, words, and the restaurant's location), \
        restaurants you save, your follows, tables and blocks, messages and \
        reactions, and a small set of usage events (like "meal added") used \
        only to see whether features work.
        """)
        section("Your location", """
        When you spin or log a meal, your phone's location is used to find \
        restaurants near you. It's asked for then, used on your phone, and \
        never stored. A restaurant suggested at a table carries the \
        restaurant's address — never yours.
        """)
        section("Your photos", """
        A meal photo's location is read on your phone to guess the restaurant \
        you ate at; only the restaurant is saved. Photos you add are \
        re-encoded before upload, which strips their embedded GPS and camera \
        data.
        """)
        section("Who can see what", """
        Every meal has a visibility: Friends (people you follow each other \
        with, and your tables), Public, or Only me. Photos live in a private \
        bucket and follow the same rule. Your cuisines are visible to friends \
        and your tables, and to everyone if your profile is public. Private \
        profiles don't appear in search.
        """)
        section("What we don't do", """
        We don't sell your data and we don't show ads. We only share \
        information with the infrastructure that runs the app: Supabase \
        (database, storage, sign-in), Apple Maps (restaurant search), and \
        Apple or Google if you sign in with them.
        """)
        section("Your controls", """
        Edit or delete any meal, remove any stamp, change visibility per meal, \
        make your profile private, block people, leave tables, and delete \
        your account — immediately and permanently — from Settings.
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
