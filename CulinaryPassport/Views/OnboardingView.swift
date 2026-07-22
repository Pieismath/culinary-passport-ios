import SwiftUI

/// First-run: three screens between signup and an empty globe. Pick your
/// color, log the first meal (the stamp moment does the selling), find your
/// people. Skippable at every step — it's a welcome, not a toll gate.
struct OnboardingView: View {
    var onDone: () -> Void

    @State private var page = 0
    @State private var name = ""
    @State private var color = GroupPalette.fallbacks[0]
    @State private var showQuickLog = false
    @State private var loggedFirst = false
    @State private var inviteCode = ""
    @State private var joinStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                identityPage.tag(0)
                firstMealPage.tag(1)
                peoplePage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(page == 2 ? "Start eating the world" : "Skip for now") {
                if page < 2 { withAnimation { page += 1 } } else { finish() }
            }
            .font(.footnote)
            .foregroundStyle(Color(.secondaryLabel))
            .padding(.bottom, 14)
        }
        .background(Color(red: 0.972, green: 0.960, blue: 0.930).ignoresSafeArea())
        .sheet(isPresented: $showQuickLog) {
            QuickLogView {
                loggedFirst = true
                withAnimation { page = 2 }
            }
        }
        .task {
            if let me = try? await SupabaseService.shared.myProfile() {
                name = me.name
                color = me.color.lowercased()
            }
        }
    }

    // ── 1: who are you on the globe ──────────────────────────────────────────

    private var identityPage: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("🌍").font(.system(size: 64))
            Text("Welcome to your\nCulinary Passport")
                .font(.system(.title, design: .serif).weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Every cuisine you eat colors in a country.\nThis color is you, on every globe.")
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)

            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38)), count: 4), spacing: 12) {
                ForEach(GroupPalette.fallbacks, id: \.self) { swatch in
                    Button {
                        color = swatch
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Circle()
                            .fill(Color(uiColor: UIColor(hex: swatch) ?? .gray))
                            .frame(width: 38, height: 38)
                            .overlay {
                                if swatch == color {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Next") {
                Task { await saveIdentity() }
                withAnimation { page = 1 }
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .padding(30)
    }

    private func saveIdentity() async {
        guard let me = try? await SupabaseService.shared.myProfile() else { return }
        try? await SupabaseService.shared.updateMyProfile(
            name: name.trimmingCharacters(in: .whitespaces),
            username: me.username, bio: me.bio,
            isPublic: me.isPublic ?? true, color: color
        )
    }

    // ── 2: the first stamp ───────────────────────────────────────────────────

    private var firstMealPage: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("🍜").font(.system(size: 64))
            Text("Log your first meal")
                .font(.system(.title, design: .serif).weight(.semibold))
            Text("Think of the last place you ate out.\nThat's your first stamp.")
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)

            Button(loggedFirst ? "Logged ✓" : "Log it — takes 15 seconds") {
                showQuickLog = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(loggedFirst)
            Spacer()
        }
        .padding(30)
    }

    // ── 3: the people ────────────────────────────────────────────────────────

    private var peoplePage: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("💜").font(.system(size: 64))
            Text("Eat the world together")
                .font(.system(.title, design: .serif).weight(.semibold))
            Text("Groups share one globe — a couple, a family,\nthe group chat that can never pick a restaurant.")
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)

            HStack {
                TextField("Have an invite code?", text: $inviteCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                Button("Join") {
                    Task {
                        do {
                            _ = try await SupabaseService.shared.joinGroup(
                                inviteCode: inviteCode.trimmingCharacters(in: .whitespaces))
                            joinStatus = "In! Find it on the Groups tab."
                        } catch { joinStatus = "That code didn't match a group." }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(inviteCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let joinStatus {
                Text(joinStatus).font(.caption).foregroundStyle(Color(.secondaryLabel))
            }

            Button("Done") { finish() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(30)
    }

    private func finish() {
        SupabaseService.shared.logEvent("onboarding_done",
                                        props: ["logged_first": String(loggedFirst)])
        onDone()
    }
}
