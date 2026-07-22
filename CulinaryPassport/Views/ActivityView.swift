import SwiftUI

/// "Someone noticed you" — new followers, reactions and comments on your
/// meals, newest first. The surface push notifications will deep-link into
/// once the paid developer account lands.
struct ActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ActivityItem] = []
    @State private var loaded = false
    @State private var viewing: Entry?

    /// Everything newer than this was unseen when the sheet opened.
    static var lastSeen: Date {
        get { UserDefaults.standard.object(forKey: "activityLastSeen") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "activityLastSeen") }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    Button {
                        if case let .reacted(_, entry) = item.kind { viewing = entry }
                        if case let .commented(_, entry) = item.kind { viewing = entry }
                    } label: {
                        row(item).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .overlay {
                if loaded && items.isEmpty {
                    ContentUnavailableView(
                        "Nothing yet",
                        systemImage: "bell",
                        description: Text("Follows, reactions and comments on your meals land here.")
                    )
                } else if !loaded {
                    ProgressView()
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $viewing) { entry in
                EntryDetailView(entry: entry)
                    .presentationDetents([.medium, .large])
            }
            .task {
                items = (try? await SupabaseService.shared.activity()) ?? []
                loaded = true
                Self.lastSeen = Date()
            }
        }
    }

    private func row(_ item: ActivityItem) -> some View {
        HStack(spacing: 12) {
            ProfilePhotoView(url: item.actor.avatarUrl.flatMap(URL.init), size: 38)
            VStack(alignment: .leading, spacing: 2) {
                switch item.kind {
                case .followedYou:
                    Text("\(Text(item.actor.name).bold()) started following you")
                case let .reacted(emoji, entry):
                    Text("\(Text(item.actor.name).bold()) reacted \(emoji) to \(entry.restaurantName)")
                case let .commented(text, entry):
                    Text("\(Text(item.actor.name).bold()) on \(entry.restaurantName): \(text)")
                        .lineLimit(2)
                }
                Text(item.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .font(.subheadline)
            Spacer(minLength: 0)
            if item.date > Self.lastSeen {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 3)
    }
}
