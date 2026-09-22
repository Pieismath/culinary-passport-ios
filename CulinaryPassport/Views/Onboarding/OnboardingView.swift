import SwiftUI

/// First run, three short steps: who you are, what you've already eaten (tap
/// the plates), and who you eat with. Skippable throughout — a welcome, not
/// a toll gate.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, tasted, tables
    }

    @Environment(AppModel.self) private var app
    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var homeCountry: String?
    @State private var color = GroupPalette.fallbacks[1]
    @State private var pickingHome = false
    @State private var picked: Set<String> = []
    @State private var savingTastes = false
    @State private var showPeople = false
    @State private var joinCode = ""
    @State private var joining = false
    @State private var loaded = false

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
                case .tasted: tasted.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                case .tables: tables.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: step)
        }
        .paperBackground()
        .sheet(isPresented: $pickingHome) {
            CountryPickerSheet(title: "Where's home?", selected: homeCountry) { homeCountry = $0 }
        }
        .sheet(isPresented: $showPeople) { PeopleSearchView() }
        .onAppear(perform: prefill)
    }

    // ── 1. Welcome ───────────────────────────────────────────────────────────

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Plate(rim: 0.16, band: Color.brand.opacity(0.3)) {
                        Image(systemName: "globe.europe.africa.fill")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(Color.brand.opacity(0.85))
                    }
                    .frame(width: 150, height: 150)
                    Image(systemName: "fork.knife")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.onBrand)
                        .frame(width: 42, height: 42)
                        .background(Color.brand, in: Circle())
                        .offset(x: 58, y: 52)
                }
                .padding(.top, 26)
                VStack(spacing: 8) {
                    Text("How much of the world have you eaten?")
                        .font(.displayLarge)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                    Text("Every cuisine you try gets a stamp and fills in your globe. Spin it when you can't decide — it lands on something you've never had.")
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
                            Text("Home kitchen").foregroundStyle(Color.ink)
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
                    Eyebrow(text: "Your colour on the globe")
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
                            .accessibilityLabel("Colour \(swatch)")
                            .accessibilityAddTraits(swatch == color ? .isSelected : [])
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Continue") {
                    Task { await saveIdentity() }
                    // Your home cuisine is a fair guess for your first stamp.
                    if let homeCountry, Cuisine.isCuisine(homeCountry) { picked.insert(homeCountry) }
                    step = .tasted
                }
                .buttonStyle(.primary)
                .disabled(name.trimmed.isEmpty)
                .padding(.top, 8)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // ── 2. What you've eaten ─────────────────────────────────────────────────

    private var tasted: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What have you already eaten?")
                        .font(.displayLarge)
                        .foregroundStyle(Color.ink)
                    Text("Tap every cuisine you've tried. It takes a minute, and you can add more any time.")
                        .font(.body)
                        .foregroundStyle(Color.inkSecondary)
                }
                .padding(.top, 26)
                CuisineChecklistView(picked: $picked)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(savingTastes ? "Saving…" : (picked.isEmpty ? "Skip for now" : "That's \(picked.count.counted("cuisine")) — continue")) {
                    Task { await saveTastes() }
                }
                .buttonStyle(.primary)
                .disabled(savingTastes)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // ── 3. Tables ────────────────────────────────────────────────────────────

    private var tables: some View {
        ScrollView {
            VStack(spacing: 20) {
                RoundTable(seats: [TableSeat(id: "me", profile: app.me)] + (1..<4).map { TableSeat.empty($0) },
                           cloth: Color(hex: color), seatSize: 34) {
                    Image(systemName: "globe.europe.africa.fill")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.brand)
                }
                .frame(width: 200, height: 200)
                .padding(.top, 26)
                VStack(spacing: 8) {
                    Text("Pull up a chair")
                        .font(.displayLarge)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                    Text("Set a table for the people you eat with. The spin lands on something none of you has had, and you talk it over right there.")
                        .font(.body)
                        .foregroundStyle(Color.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Got an invite code?")
                    HStack(spacing: 10) {
                        TextField("e.g. fridaydinner", text: $joinCode)
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

                Button("Start spinning") { finish() }
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
        } catch {
            app.show(error)
        }
    }

    private func saveTastes() async {
        let fresh = Array(picked.subtracting(app.tastedCodes))
        guard !fresh.isEmpty else {
            step = .tables
            return
        }
        savingTastes = true
        defer { savingTastes = false }
        do {
            try await app.addTastes(fresh)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            step = .tables
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
            app.celebrate("You're in! Find it under Tables.")
        } catch {
            app.show(error)
        }
    }

    private func finish() {
        if let id = app.myId { Onboarding.markDone(for: id) }
        app.backend.logEvent("onboarding_done", props: ["cuisines": String(app.tastes.count)])
        app.needsOnboarding = false
    }
}
