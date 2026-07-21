import SwiftUI
import PhotosUI
import UIKit

/// iMessage-style group details: photo, name, members, invite code, leave.
/// Owners can change the photo and name and hand-pick the invite code.
struct GroupDetailsView: View {
    @Binding var group: Group
    let members: [UUID]
    let profiles: [UUID: Profile]
    /// Called after the current user leaves — the presenter pops the group.
    var onLeft: () -> Void
    var onChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var myId: UUID?
    @State private var name: String = ""
    @State private var customCode: String = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var status: String?
    @State private var confirmLeave = false

    private var isOwner: Bool { myId == group.createdBy }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            GroupAvatarView(group: group, size: 96)
                            if isOwner {
                                PhotosPicker(selection: $pickedItem, matching: .images) {
                                    Text(busy ? "Uploading…" : "Change photo")
                                        .font(.footnote)
                                }
                                .disabled(busy)
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                if isOwner {
                    Section("Name") {
                        HStack {
                            TextField("Group name", text: $name)
                            if name != group.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                                Button("Save") { Task { await saveName() } }
                            }
                        }
                    }
                }

                Section("Members") {
                    ForEach(members, id: \.self) { id in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(uiColor: UIColor(hex: profiles[id]?.color ?? "") ?? .systemGray))
                                .frame(width: 10, height: 10)
                            Text(profiles[id]?.name ?? "Someone")
                            if id == group.createdBy {
                                Text("owner")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(.systemGray5), in: Capsule())
                                    .foregroundStyle(Color(.secondaryLabel))
                            }
                            Spacer()
                            if id == myId {
                                Text("you").font(.caption).foregroundStyle(Color(.secondaryLabel))
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text(group.inviteCode)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = group.inviteCode
                            status = "Code copied"
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        ShareLink(item: "Join \"\(group.name)\" on Culinary Passport — invite code: \(group.inviteCode)") {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    if isOwner {
                        HStack {
                            TextField("Pick your own code", text: $customCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body.monospaced())
                            if !customCode.isEmpty {
                                Button("Save") { Task { await saveCode() } }
                                    .disabled(!codeIsValid)
                            }
                        }
                    }
                } header: {
                    Text("Invite code")
                } footer: {
                    if isOwner {
                        Text("4–16 letters and numbers. Anyone with the code can join.")
                    } else {
                        Text("Anyone with the code can join.")
                    }
                }

                if !isOwner {
                    Section {
                        Button("Leave group", role: .destructive) { confirmLeave = true }
                    }
                }

                if let status {
                    Text(status).font(.caption).foregroundStyle(Color(.secondaryLabel))
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Group details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task {
                myId = try? await SupabaseService.shared.client.auth.session.user.id
                name = group.name
            }
            .onChange(of: pickedItem) { Task { await uploadPhoto() } }
            .confirmationDialog("Leave \(group.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { Task { await leave() } }
            } message: {
                Text("You'll need an invite code to rejoin.")
            }
        }
    }

    private var codeIsValid: Bool {
        let code = customCode.trimmingCharacters(in: .whitespaces)
        return code.count >= 4 && code.count <= 16
            && code.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private func saveName() async {
        do {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            try await SupabaseService.shared.updateGroup(id: group.id, .init(name: trimmed))
            group.name = trimmed
            status = "Name updated"
            await onChanged()
        } catch { status = error.localizedDescription }
    }

    private func saveCode() async {
        do {
            let code = customCode.trimmingCharacters(in: .whitespaces).lowercased()
            try await SupabaseService.shared.updateGroup(id: group.id, .init(inviteCode: code))
            group.inviteCode = code
            customCode = ""
            status = "Invite code updated"
            await onChanged()
        } catch {
            // Unique constraint → someone else already has this code.
            status = error.localizedDescription.contains("duplicate")
                ? "That code is taken — try another." : error.localizedDescription
        }
    }

    private func uploadPhoto() async {
        guard let pickedItem else { return }
        busy = true
        defer { busy = false; self.pickedItem = nil }
        do {
            guard let data = try await pickedItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = ImageTools.squareJPEG(image, side: 512) else {
                status = "Couldn't read that photo"
                return
            }
            let path = try await SupabaseService.shared.uploadGroupCover(groupId: group.id, jpeg)
            try await SupabaseService.shared.updateGroup(id: group.id, .init(coverPhoto: path))
            group.coverPhoto = path
            status = "Photo updated"
            await onChanged()
        } catch { status = error.localizedDescription }
    }

    private func leave() async {
        do {
            try await SupabaseService.shared.leaveGroup(groupId: group.id)
            dismiss()
            onLeft()
        } catch { status = error.localizedDescription }
    }
}
