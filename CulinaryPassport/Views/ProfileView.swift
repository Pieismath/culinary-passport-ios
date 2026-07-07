import SwiftUI
import PhotosUI

/// MVP step 4-5: solo profile + the avatar pipeline entry point.
/// Selfie → Vision face-crop → generate-avatar edge function → cached PNG.
struct ProfileView: View {
    @State private var avatarURL: URL?
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                AsyncImage(url: avatarURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "person.crop.circle.dashed")
                        .font(.system(size: 90))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 180, height: 180)

                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label(busy ? "Generating…" : "New selfie → new avatar", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

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
            .onChange(of: pickedItem) {
                Task { await generate() }
            }
        }
    }

    private func loadAvatar() async {
        guard let session = try? await SupabaseService.shared.client.auth.session else { return }
        let profiles: [Profile]? = try? await SupabaseService.shared.client
            .from("profiles").select().eq("id", value: session.user.id).execute().value
        if let urlString = profiles?.first?.avatarUrl { avatarURL = URL(string: urlString) }
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
