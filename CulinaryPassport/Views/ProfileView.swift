import SwiftUI
import PhotosUI

/// MVP step 4-5: solo profile + the avatar pipeline entry point.
/// Selfie → Vision face-crop → generate-avatar edge function → cached PNG.
struct ProfileView: View {
    @State private var avatarURL: URL?
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var status: String?
    @State private var equipped = EquippedStore.load()
    @State private var profile: Profile?
    @State private var showEdit = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Composited with equipped accessories (ROADMAP item 17).
                ComposedAvatarView(url: avatarURL, equipped: equipped, size: 180)
                    .id(equipped)

                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label(busy ? "Generating…" : "New selfie → new avatar", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

                if let profile {
                    VStack(spacing: 2) {
                        Text(profile.name).font(.title3).bold()
                        if let username = profile.username, !username.isEmpty {
                            Text("@\(username)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Label(profile.isPublic == true ? "Public profile" : "Private profile",
                              systemImage: profile.isPublic == true ? "globe" : "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    AvatarCustomizeView(avatarURL: avatarURL)
                } label: {
                    Label("Customize avatar", systemImage: "wand.and.stars")
                }
                .disabled(avatarURL == nil)

                Button { showEdit = true } label: {
                    Label("Edit profile", systemImage: "pencil")
                }

                NavigationLink {
                    WrappedView()
                } label: {
                    Label("Year in review", systemImage: "sparkles")
                }

                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                Button("Sign out") {
                    Task { try? await SupabaseService.shared.client.auth.signOut() }
                }
                .font(.caption)
            }
            .padding()
            .navigationTitle("Profile")
            .task { await loadAvatar() }
            .onAppear { equipped = EquippedStore.load() } // reflect customizer changes on return
            .onChange(of: pickedItem) {
                Task { await generate() }
            }
            .sheet(isPresented: $showEdit) {
                if let profile {
                    ProfileEditSheet(profile: profile) { await loadAvatar() }
                }
            }
        }
    }

    private func loadAvatar() async {
        guard let me = try? await SupabaseService.shared.myProfile() else { return }
        profile = me
        if let urlString = me.avatarUrl { avatarURL = URL(string: urlString) }
    }

    private func generate() async {
        guard let pickedItem else { return }
        busy = true
        defer { busy = false; self.pickedItem = nil }
        do {
            guard let data = try await pickedItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                status = "Couldn't read that photo"
                return
            }
            status = "Generating your avatar — takes ~20s…"
            let result = try await AvatarService.generateAvatar(from: image)
            avatarURL = URL(string: "\(result.url)?v=\(Int(Date().timeIntervalSince1970))")
            status = "Done (\(result.provider))"
        } catch {
            status = error.localizedDescription // includes the 3/day limit message from the server
        }
    }
}

/// Edit name / username / bio and toggle profile visibility (v1.1 item 7).
struct ProfileEditSheet: View {
    let profile: Profile
    var onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var username: String
    @State private var bio: String
    @State private var isPublic: Bool
    @State private var saving = false
    @State private var error: String?

    init(profile: Profile, onSave: @escaping () async -> Void) {
        self.profile = profile
        self.onSave = onSave
        _name = State(initialValue: profile.name)
        _username = State(initialValue: profile.username ?? "")
        _bio = State(initialValue: profile.bio ?? "")
        _isPublic = State(initialValue: profile.isPublic ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                    TextField("Username", text: $username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                Section("Bio") {
                    TextField("A line about your taste", text: $bio, axis: .vertical)
                }
                Section {
                    Toggle("Public profile", isOn: $isPublic)
                } footer: {
                    Text("Public profiles can be found in People search and followed.")
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(name.isEmpty || saving)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        do {
            try await SupabaseService.shared.updateMyProfile(
                name: name,
                username: trimmedUser.isEmpty ? nil : trimmedUser,
                bio: bio.trimmingCharacters(in: .whitespaces).isEmpty ? nil : bio,
                isPublic: isPublic
            )
            await onSave()
            dismiss()
        } catch {
            self.error = error.localizedDescription // e.g. username-taken from the DB
        }
    }
}
