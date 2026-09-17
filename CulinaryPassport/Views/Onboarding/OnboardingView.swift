import SwiftUI

/// First run, three short steps: who you are, where you've been (the photo
/// scan does the heavy lifting), and who you travel with. Skippable
/// throughout — a welcome, not a toll gate.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, passport, friends
    }

    @Environment(AppModel.self) private var app
    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var homeCountry: String?
    @State private var color = GroupPalette.fallbacks[1]
    @State private var pickingHome = false
    @State private var showImport = false
    @State private var showChecklist = false
    @State private var showPeople = false
    @State private var joinCode = ""
    @State private var joining = false
    @State private var loaded = false
    /// Stamps and trips before a scan/checklist opened — the home country is
    /// stamped on Continue, so "any stamps" can't mean "they built a passport".
    @State private var stampBaseline = 0
    @State private var tripBaseline = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.brand : Color.sunken)
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .accessibilityHidden(true)

            ZStack {
                switch step {
                case .welcome: welcome.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case .passport: passport.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case .friends: friends.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: step)
        }
        .paperBackground()
        .sheet(isPresented: $pickingHome) {
            CountryPickerSheet(title: "Where's home?", selected: homeCountry) { homeCountry = $0 }
        }
        .sheet(isPresented: $showImport) {
            NavigationStack {
                PhotoImportView(onDone: {
                    showImport = false
                    if app.stamps.count > stampBaseline || app.tripPlans.count > tripBaseline {
                        step = .friends
                    }
                })
            }
        }
        .sheet(isPresented: $showChecklist) {
            NavigationStack {
                CountryChecklistView(onDone: {
                    showChecklist = false
                    if app.stamps.count > stampBaseline { step = .friends }
                })
            }
        }
        .sheet(isPresented: $showPeople) { PeopleSearchView() }
        .onAppear(perform: prefill)
    }

    // ── 1. Welcome ───────────────────────────────────────────────────────────

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("BrandMark")
                    .resizable()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.top, 30)
                VStack(spacing: 8) {
                    Text("Welcome to Stampd")
                        .font(.displayLarge)
                        .foregroundStyle(Color.ink)
                    Text("Your passport for everywhere you've been — and everywhere you're going.")
                        .font(.body)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 0) {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                        .font(.headline)
                        .padding(14)
                    Divider().padding(.leading, 14)
                    Button { pickingHome = true } label: {
                        HStack {
                            Image(systemName: "house").foregroundStyle(Color.inkSecondary)
                            Text("Home").foregroundStyle(Color.ink)
                            Spacer()
                            Text(homeCountry.flatMap { CountryStore.byCode[$0] }.map { "\($0.flag) \($0.name)" } ?? "Choose country")
                                .foregroundStyle(homeCountry == nil ? Color.brand : Color.inkSecondary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                    .strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Your color on the globe")
                    HStack(spacing: 10) {
                        ForEach(GroupPalette.fallbacks, id: \.self) { swatch in
                            Button {
                                color = swatch
                                UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                Circle()
                                    .fill(Color(hex: swatch))
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if swatch == color {
                                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Color \(swatch)")
                            .accessibilityAddTraits(swatch == color ? .isSelected : [])
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Continue") {
                    Task { await saveIdentity() }
                    step = .passport
                }
                .buttonStyle(.primary)
                .disabled(name.trimmed.isEmpty)
                .padding(.top, 8)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // ── 2. Build the passport ────────────────────────────────────────────────

    private var passport: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Where have you been?")
                        .font(.displayLarge)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                    Text("Your camera roll already knows. It has the trips, the cities and the dates — the passport can just read them.")
                        .font(.body)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 36)

                optionCard(icon: "sparkle.magnifyingglass",
                           title: "Read my photos",
                           detail: "Finds your trips — countries, cities and dates — in seconds. It happens on your phone, and nothing is uploaded.",
                           badge: "Fastest") {
                    stampBaseline = app.stamps.count
                    tripBaseline = app.tripPlans.count
                    showImport = true
                }
                optionCard(icon: "checklist",
                           title: "Pick countries",
                           detail: "Tap the places you've been, continent by continent.",
                           badge: nil) {
                    stampBaseline = app.stamps.count
                    tripBaseline = app.tripPlans.count
                    showChecklist = true
                }

                if !app.stamps.isEmpty {
                    Text(app.tripPlans.isEmpty
                         ? "\(app.stats.countries.counted("country", "countries")) stamped so far"
                         : "\(app.stats.countries.counted("country", "countries")) · \(app.tripPlans.count.counted("trip")) so far")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brand)
                    Button("Continue") { step = .friends }
                        .buttonStyle(.primary)
                } else {
                    Button("Skip for now") { step = .friends }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
    }

    private func optionCard(icon: String, title: String, detail: String, badge: String?,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 56, height: 56)
                    .background(Color.brandSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline).foregroundStyle(Color.ink)
                        if let badge {
                            Pill(text: badge, tint: .brand, background: .brandSoft)
                        }
                    }
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.inkTertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    // ── 3. Friends ───────────────────────────────────────────────────────────

    private var friends: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Travel with friends")
                        .font(.displayLarge)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                    Text("See where your friends have been, ask them for tips, and plan the next trip on a shared globe.")
                        .font(.body)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 36)

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Got an invite code?")
                    HStack(spacing: 10) {
                        TextField("e.g. europe2027", text: $joinCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .padding(12)
                            .background(Color.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button(joining ? "…" : "Join") { Task { await join() } }
                            .buttonStyle(.capsuleProminent)
                            .disabled(joinCode.trimmed.isEmpty || joining)
                    }
                }
                .card()

                Button { showPeople = true } label: {
                    Label("Find friends on Stampd", systemImage: "person.badge.plus")
                }
                .buttonStyle(.secondary)

                ShareLink(item: AppLinks.inviteText(from: app.me)) {
                    Label("Invite friends", systemImage: "paperplane")
                }
                .buttonStyle(.secondary)

                Button("Start exploring") { finish() }
                    .buttonStyle(.primary)
                    .padding(.top, 10)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        if let me = app.me {
            name = me.name
            homeCountry = me.homeCountry
            if !me.color.isEmpty { color = me.color.lowercased() }
        }
        if homeCountry == nil, let region = Locale.current.region?.identifier, CountryStore.byCode[region] != nil {
            homeCountry = region
        }
    }

    private func saveIdentity() async {
        do {
            try await app.updateProfile(ProfilePatch(name: name.trimmed, color: color, homeCountry: homeCountry))
            if let home = homeCountry, !app.visitedCodes.contains(home) {
                // Home counts: you've been there.
                try? await app.addStamps([StampInput(countryCode: home, firstVisited: nil, lastVisited: nil, source: .manual)])
            }
        } catch {
            app.show(error)
        }
    }

    private func join() async {
        joining = true
        defer { joining = false }
        do {
            try await app.joinGroup(code: joinCode.trimmed)
            joinCode = ""
            app.celebrate("You're in! Find it under Groups.")
        } catch {
            app.show(error)
        }
    }

    private func finish() {
        if let id = app.myId { Onboarding.markDone(for: id) }
        app.backend.logEvent("onboarding_done", props: ["stamps": String(app.stamps.count)])
        app.needsOnboarding = false
    }
}
