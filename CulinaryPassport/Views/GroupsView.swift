import SwiftUI

/// Your groups. The list is the whole screen — creating and joining live
/// behind the "+" in the corner, as sheets you can always back out of.
/// (They used to be inline text fields, which trapped the keyboard on a
/// screen you were only passing through.)
struct GroupsView: View {
    @State private var groups: [Group] = []
    @State private var membersByGroup: [UUID: [UUID]] = [:]
    @State private var profiles: [UUID: Profile] = [:]
    @State private var sheet: Sheet?
    @State private var status: String?

    enum Sheet: String, Identifiable {
        case create, join
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    NavigationLink(value: group) {
                        GroupRow(
                            group: group,
                            members: (membersByGroup[group.id] ?? []).compactMap { profiles[$0] }
                        )
                    }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.red)
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView {
                        Label("No groups yet", systemImage: "person.3")
                    } description: {
                        Text("A group is a shared globe — a couple, a family, roommates, work friends. You can be in as many as you like.")
                    } actions: {
                        Button("Create a group") { sheet = .create }
                            .buttonStyle(.borderedProminent)
                        Button("Join with a code") { sheet = .join }
                    }
                }
            }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { sheet = .create } label: {
                            Label("Create a group", systemImage: "plus.circle")
                        }
                        Button { sheet = .join } label: {
                            Label("Join with a code", systemImage: "envelope.open")
                        }
                    } label: {
                        BrandedIcon(name: "action-add", size: 24)
                    }
                    .accessibilityLabel("Create or join a group")
                }
            }
            .navigationDestination(for: Group.self) { GroupGlobeView(group: $0) }
            .sheet(item: $sheet) { which in
                switch which {
                case .create:
                    NameEntrySheet(
                        title: "Create a group",
                        field: "Group name",
                        placeholder: "Sunday dinners",
                        actionLabel: "Create",
                        autocapitalize: true
                    ) { name in
                        _ = try await SupabaseService.shared.createGroup(name: name)
                        await reload()
                    }
                case .join:
                    NameEntrySheet(
                        title: "Join a group",
                        field: "Invite code",
                        placeholder: "e.g. fangfamily",
                        actionLabel: "Join",
                        autocapitalize: false,
                        footer: "Ask a member for the group's invite code — they'll find it under the group's details."
                    ) { code in
                        _ = try await SupabaseService.shared.joinGroup(inviteCode: code)
                        await reload()
                    }
                }
            }
            .task {
                for await state in SupabaseService.shared.client.auth.authStateChanges
                where state.session != nil {
                    await reload()
                }
            }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        do {
            groups = try await SupabaseService.shared.myGroups()
            let memberships = try await SupabaseService.shared.groupMembers(groupIds: groups.map(\.id))
            membersByGroup = Dictionary(grouping: memberships, by: \.groupId)
                .mapValues { $0.map(\.userId) }
            let ids = Array(Set(memberships.map(\.userId)))
            let people = try await SupabaseService.shared.profiles(ids: ids)
            profiles = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct GroupRow: View {
    let group: Group
    let members: [Profile]

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatarView(group: group, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(.headline)
                HStack(spacing: 6) {
                    // A few faces, then the count — reads at a glance.
                    HStack(spacing: -6) {
                        ForEach(members.prefix(3)) { person in
                            ProfilePhotoView(url: person.avatarUrl.flatMap(URL.init), size: 20)
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                        }
                    }
                    Text("\(members.count) member\(members.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One text field, a Cancel and a confirm button — always escapable, so the
/// keyboard can never strand you.
private struct NameEntrySheet: View {
    let title: String
    let field: String
    let placeholder: String
    let actionLabel: String
    var autocapitalize: Bool = true
    var footer: String? = nil
    let action: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(placeholder, text: $text)
                        .focused($focused)
                        .textInputAutocapitalization(autocapitalize ? .words : .never)
                        .autocorrectionDisabled(!autocapitalize)
                        .submitLabel(.done)
                        .onSubmit { Task { await run() } }
                } header: {
                    Text(field)
                } footer: {
                    if let footer { Text(footer) }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "…" : actionLabel) { Task { await run() } }
                        .disabled(trimmed.isEmpty || busy)
                }
                // Belt and braces: a way down from the keyboard itself.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func run() async {
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await action(trimmed)
            dismiss()
        } catch let failure {
            // e.g. "invalid invite code" from the join RPC
            error = failure.localizedDescription
        }
    }
}
