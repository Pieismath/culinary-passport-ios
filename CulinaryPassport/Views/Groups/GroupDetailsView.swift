import SwiftUI
import PhotosUI

/// Group photo, name, members, invite, leave/delete. Owners edit.
struct GroupDetailsView: View {
    let group: Group
    /// The group is gone for this user (left or deleted) — pop its screens.
    var onGone: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var customCode = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var confirmLeave = false
    @State private var confirmDelete = false

    private var current: Group { app.groups.first { $0.id == group.id } ?? group }
    private var isOwner: Bool { app.myId == current.createdBy }

    private var codeIsValid: Bool {
        let code = customCode.trimmed.lowercased()
        return (6...32).contains(code.count) && code.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        GroupAvatarView(group: current, size: 96)
                        if isOwner {
                            PhotosPicker(selection: $pickedItem, matching: .images) {
                                Text(busy ? "Uploading…" : "Change photo").font(.subheadline.weight(.medium))
                            }
                            .disabled(busy)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                if isOwner {
                    Section("Name") {
                        HStack {
                            TextField("Group name", text: $name)
                            if name.trimmed != current.name && !name.trimmed.isEmpty {
                                Button("Save") { Task { await saveName() } }
                                    .fontWeight(.semibold)
                            }
                        }
                        .listRowBackground(Color.card)
                    }
                }

                Section("Invite") {
                    HStack {
                        Text(current.inviteCode)
                            .font(.body.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = current.inviteCode
                            app.celebrate("Code copied")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy invite code")
                    }
                    .listRowBackground(Color.card)
                    ShareLink(item: AppLinks.groupInvite(current)) {
                        Label("Invite people", systemImage: "paperplane.fill")
                    }
                    .listRowBackground(Color.card)
                    if isOwner {
                        HStack {
                            TextField("Choose your own code", text: $customCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body.monospaced())
                            if !customCode.isEmpty {
                                Button("Save") { Task { await saveCode() } }
                                    .fontWeight(.semibold)
                                    .disabled(!codeIsValid)
                            }
                        }
                        .listRowBackground(Color.card)
                    }
                }

                Section("\(app.members(of: current.id).count) members") {
                    ForEach(app.members(of: current.id), id: \.self) { id in
                        NavigationLink {
                            ProfileView(userId: id)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(profile: app.profile(id), size: 36)
                                Text(id == app.myId ? "You" : (app.profile(id)?.name ?? "Traveller"))
                                Spacer()
                                if id == current.createdBy {
                                    Pill(text: "Owner")
                                }
                            }
                        }
                        .disabled(id == app.myId)
                        .listRowBackground(Color.card)
                    }
                }

                Section {
                    if isOwner {
                        Button("Delete group", role: .destructive) { confirmDelete = true }
                            .listRowBackground(Color.card)
                    } else {
                        Button("Leave group", role: .destructive) { confirmLeave = true }
                            .listRowBackground(Color.card)
                    }
                } footer: {
                    Text(isOwner
                         ? "Deleting removes the group and its chat for everyone. Everyone's memories stay in their passports."
                         : "You'll need the invite code to rejoin.")
                }
            }
            .paperListStyle()
            .navigationTitle("Group details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { name = current.name }
            .onChange(of: pickedItem) { Task { await uploadPhoto() } }
            .confirmationDialog("Leave \(current.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { Task { await leave() } }
            }
            .confirmationDialog("Delete \(current.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete group", role: .destructive) { Task { await deleteGroup() } }
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private func saveName() async {
        do {
            try await app.backend.updateGroup(id: current.id, GroupPatch(name: name.trimmed))
            await app.refreshGroups()
            app.celebrate("Renamed")
        } catch {
            app.show(error)
        }
    }

    private func saveCode() async {
        do {
            try await app.backend.updateGroup(id: current.id, GroupPatch(inviteCode: customCode.trimmed.lowercased()))
            customCode = ""
            await app.refreshGroups()
            app.celebrate("Invite code updated")
        } catch {
            let message = AppError.friendly(error)
            app.show(message.lowercased().contains("already exists") ? AppError("That code is taken — try another.") : error)
        }
    }

    private func uploadPhoto() async {
        guard let pickedItem else { return }
        busy = true
        defer {
            busy = false
            self.pickedItem = nil
        }
        do {
            guard let data = try await pickedItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = ImageTools.squareJPEG(image, side: 512) else {
                throw AppError("Couldn't read that photo.")
            }
            let path = try await app.backend.uploadGroupCover(groupId: current.id, jpeg)
            try await app.backend.updateGroup(id: current.id, GroupPatch(coverPhoto: path))
            await app.refreshGroups()
        } catch {
            app.show(error)
        }
    }

    private func leave() async {
        do {
            try await app.leaveGroup(current.id)
            dismiss()
            onGone()
        } catch {
            app.show(error)
        }
    }

    private func deleteGroup() async {
        do {
            try await app.deleteGroup(current.id)
            dismiss()
            onGone()
        } catch {
            app.show(error)
        }
    }
}
