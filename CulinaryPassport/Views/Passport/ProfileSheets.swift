import SwiftUI

/// Name, @username, bio, home, color, public/private.
struct ProfileEditSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var homeCountry: String?
    @State private var homeCity = ""
    @State private var color = GroupPalette.fallbacks[1]
    @State private var isPublic = true
    @State private var saving = false
    @State private var error: String?
    @State private var pickingHome = false
    @State private var loaded = false

    private var normalizedUsername: String { Handles.normalizedUsername(username) }

    private var usernameProblem: String? { Handles.problem(with: username) }

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    HStack(spacing: 2) {
                        Text("@").foregroundStyle(Color.inkTertiary)
                        TextField("username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                    }
                    TextField("A line about how you eat", text: $bio, axis: .vertical)
                        .lineLimit(1...4)
                }
                .listRowBackground(Color.card)

                Section("Home kitchen") {
                    Button { pickingHome = true } label: {
                        HStack {
                            Text("Country").foregroundStyle(Color.ink)
                            Spacer()
                            Text(homeCountry.flatMap { CountryStore.byCode[$0] }.map { "\($0.flag) \($0.name)" } ?? "Choose")
                                .foregroundStyle(Color.inkSecondary)
                        }
                    }
                    TextField("City", text: $homeCity)
                        .textContentType(.addressCity)
                }
                .listRowBackground(Color.card)

                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(GroupPalette.fallbacks, id: \.self) { swatch in
                            Button { color = swatch } label: {
                                Circle()
                                    .fill(Color(hex: swatch))
                                    .frame(height: 30)
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
                    .padding(.vertical, 4)
                } header: {
                    Text("Your color")
                } footer: {
                    Text("Your cuisines wear this on every globe. At a table, if someone already has it, yours shifts to the next free colour there.")
                }
                .listRowBackground(Color.card)

                Section {
                    Toggle("Public profile", isOn: $isPublic).tint(Color.brand)
                } footer: {
                    Text(isPublic
                         ? "Anyone can find you, follow you and see your cuisines. Meals still follow their own visibility."
                         : "Only friends (people you follow each other with) and your tables can see your cuisines. You won't appear in search.")
                }
                .listRowBackground(Color.card)

                if let message = usernameProblem ?? error {
                    Section { Text(message).foregroundStyle(Color.danger).font(.footnote) }
                        .listRowBackground(Color.clear)
                }
            }
            .paperListStyle()
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(name.trimmed.isEmpty || usernameProblem != nil || saving)
                }
            }
            .sheet(isPresented: $pickingHome) {
                CountryPickerSheet(title: "Home country", selected: homeCountry) { homeCountry = $0 }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded, let me = app.me else { return }
        loaded = true
        name = me.name
        username = me.username ?? ""
        bio = me.bio ?? ""
        homeCountry = me.homeCountry
        homeCity = me.homeCity ?? ""
        color = me.color.lowercased()
        isPublic = me.isPublic ?? true
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await app.updateProfile(ProfilePatch(
                name: name.trimmed,
                username: normalizedUsername.isEmpty ? nil : normalizedUsername,
                bio: bio.trimmed,
                isPublic: isPublic,
                color: color,
                homeCountry: homeCountry,
                homeCity: homeCity.trimmed
            ))
            dismiss()
        } catch {
            self.error = AppError.friendly(error)
        }
    }
}

/// "How many new cuisines this year?"
struct GoalEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""

    private let presets = [4, 12, 26, 52]

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text("New cuisines in \(String(Calendar.current.component(.year, from: Date())))")
                        .font(.displaySmall)
                    Text("Counts cuisines whose first meal you log this year. Twelve is one a month; fifty-two is one a week.")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                }
                .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    ForEach(presets, id: \.self) { preset in
                        Button { Task { await set(preset) } } label: {
                            Text("\(preset)")
                                .font(.number(.title2))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .foregroundStyle(app.me?.yearlyGoal == preset ? Color.onBrand : Color.ink)
                                .background(app.me?.yearlyGoal == preset ? Color.brand : Color.card,
                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("Custom", text: $custom)
                        .keyboardType(.numberPad)
                        .padding(12)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
                        .frame(width: 120)
                    Button("Set") {
                        if let value = Int(custom), (1...300).contains(value) { Task { await set(value) } }
                    }
                    .buttonStyle(.capsuleProminent)
                    .disabled(Int(custom).map { !(1...300).contains($0) } ?? true)
                }

                if app.me?.yearlyGoal != nil {
                    Button("Remove goal", role: .destructive) { Task { await set(nil) } }
                        .font(.subheadline)
                }
                Spacer()
            }
            .padding(24)
            .paperBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func set(_ goal: Int?) async {
        do {
            try await app.updateProfile(ProfilePatch(yearlyGoal: .some(goal)))
            dismiss()
        } catch {
            app.show(error)
        }
    }
}

/// Account, privacy, legal — and the irreversible stuff, last.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var defaultVisibility = SettingsStore.defaultVisibility
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var showEdit = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    Button { showEdit = true } label: {
                        HStack(spacing: 12) {
                            AvatarView(profile: app.me, size: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.me?.name ?? "").foregroundStyle(Color.ink)
                                Text(app.me?.handle ?? "Add a username").font(.caption).foregroundStyle(Color.inkSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.inkTertiary)
                        }
                    }
                }
                .listRowBackground(Color.card)

                Section {
                    Picker("New meals are", selection: $defaultVisibility) {
                        ForEach(Visibility.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                    }
                    .onChange(of: defaultVisibility) { _, value in SettingsStore.defaultVisibility = value }
                } header: {
                    Text("Meals")
                } footer: {
                    Text(defaultVisibility.explanation)
                }
                .listRowBackground(Color.card)

                Section("About") {
                    NavigationLink("Terms & privacy") { LegalView() }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
                .listRowBackground(Color.card)

                Section {
                    Button("Sign out") { confirmSignOut = true }
                        .foregroundStyle(Color.ink)
                    Button(deleting ? "Deleting…" : "Delete account", role: .destructive) { confirmDelete = true }
                        .disabled(deleting)
                } footer: {
                    Text("Deleting your account permanently removes your passport, meals, photos, and any tables you own.")
                }
                .listRowBackground(Color.card)
            }
            .paperListStyle()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showEdit) { ProfileEditSheet() }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        dismiss()
                        await app.signOut()
                    }
                }
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { Task { await deleteAccount() } }
            } message: {
                Text("This is permanent. Your stamps, meals, photos and the tables you own are deleted, and it can't be undone.")
            }
            .overlay { if deleting { SavingOverlay(text: "Deleting your account…") } }
        }
    }

    private func deleteAccount() async {
        deleting = true
        defer { deleting = false }
        do {
            try await app.deleteAccount()
        } catch {
            // Previously swallowed: the button just stopped spinning.
            app.show(error)
        }
    }
}
