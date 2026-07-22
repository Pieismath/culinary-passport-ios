import SwiftUI

/// Terms + community guidelines + privacy, in-app (App Store guideline 1.2
/// requires published terms for apps with user-generated content). Plain
/// readable prose, not legalese theatre.
struct LegalView: View {
    enum Page: String, CaseIterable, Identifiable {
        case terms = "Terms & community"
        case privacy = "Privacy"
        var id: String { rawValue }
    }

    var page: Page = .terms
    @State private var selection: Page = .terms

    init(page: Page = .terms) {
        self.page = page
        _selection = State(initialValue: page)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Page", selection: $selection) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch selection {
                case .terms: terms
                case .privacy: privacy
                }
            }
            .padding()
        }
        .navigationTitle("Terms & privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var terms: some View {
        section("The deal", """
        Culinary Passport is a place to log the world's cuisines as you eat \
        them and share that journey with people you choose. By creating an \
        account you agree to these terms and to the community rules below.
        """)
        section("Your content", """
        Meals, photos, notes, messages and reactions you post belong to you. \
        You give us permission to store and display them to the people your \
        visibility settings allow — that's the whole license. Delete a meal \
        and it's gone; delete your account (Profile → Delete account) and \
        everything goes with it, including your photos.
        """)
        section("Community rules", """
        This is an app about dinner. Don't post content that is illegal, \
        hateful, harassing, sexually explicit, or that belongs to someone \
        else. Don't impersonate people. Don't spam.

        Every meal, profile and message can be reported from inside the app, \
        and you can block any user from their profile — blocked people \
        disappear from your feeds and search. We review reports and remove \
        content or accounts that break these rules, at our discretion.
        """)
        section("Groups", """
        Group owners can rename a group, set its photo and invite code, and \
        delete the group. Deleting a group removes its chat for everyone; \
        members' logged meals stay in their own journals.
        """)
        section("No warranty", """
        The app is provided as-is while it grows. We do our best to keep \
        your data safe and the service up, but we can't promise either, and \
        we're not liable for losses that come from using the app.
        """)
    }

    @ViewBuilder private var privacy: some View {
        section("What we store", """
        Your account (email, name, username, photo, your chosen color), the \
        meals you log (restaurant, cuisine, date, rating, notes, photos), \
        your social graph (follows, groups, blocks), messages and reactions, \
        and a small set of anonymous-style usage events (like "meal logged") \
        used only to understand whether features work.
        """)
        section("Who can see what", """
        Every meal has a visibility you control: Public, My groups, or Only \
        me. Meal photos live in a private bucket and are served through \
        expiring signed links that follow the same rule. Private profiles \
        can't be found in search.
        """)
        section("What we don't do", """
        We don't sell your data, we don't show ads, and we don't share your \
        information with third parties except the infrastructure that runs \
        the app (Supabase for database/storage/auth, Google Places for \
        restaurant search — your queries are proxied so your identity isn't \
        attached, and Apple/Google if you sign in with them).
        """)
        section("Your controls", """
        Edit or delete any meal. Change visibility per meal. Block users. \
        Leave groups. Export nothing yet (ask us). Delete your account from \
        Profile → Delete account — it's immediate and permanent.
        """)
        section("Contact", """
        Questions or takedown requests: technical@theprojectfactory.com.
        """)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(body).font(.subheadline).foregroundStyle(Color(.secondaryLabel))
        }
        .padding(.top, 6)
    }
}
