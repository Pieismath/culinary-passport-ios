import SwiftUI

/// v1.2 groundwork: list your groups, create one, join via invite code.
/// Feed / shared map / solidarity-consensus toggles land after MVP.
struct GroupsView: View {
    @State private var groups: [Group] = []
    @State private var newName = ""
    @State private var inviteCode = ""
    @State private var status: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(groups) { group in
                        NavigationLink(value: group) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).font(.headline)
                                Text("invite code: \(group.inviteCode)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } header: {
                    Text("Your groups")
                } footer: {
                    if groups.isEmpty { Text("Couple, family, roommates, work friends — a user can be in unlimited groups.") }
                }

                Section("Create") {
                    HStack {
                        TextField("Group name", text: $newName)
                        Button("Create") { Task { await create() } }
                            .disabled(newName.isEmpty)
                    }
                }

                Section("Join") {
                    HStack {
                        TextField("Invite code", text: $inviteCode)
                            .autocapitalization(.none)
                        Button("Join") { Task { await join() } }
                            .disabled(inviteCode.isEmpty)
                    }
                }

                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("Groups")
            .navigationDestination(for: Group.self) { GroupFeedView(group: $0) }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        do { groups = try await SupabaseService.shared.myGroups() }
        catch { status = error.localizedDescription }
    }

    private func create() async {
        do {
            _ = try await SupabaseService.shared.createGroup(name: newName)
            newName = ""
            await reload()
        } catch { status = error.localizedDescription }
    }

    private func join() async {
        do {
            _ = try await SupabaseService.shared.joinGroup(inviteCode: inviteCode)
            inviteCode = ""
            await reload()
        } catch { status = error.localizedDescription }
    }
}
