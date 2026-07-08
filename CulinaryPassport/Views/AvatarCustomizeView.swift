import SwiftUI

/// ROADMAP item 17 — equip unlockable accessories onto the base avatar. Unlocks
/// are earned by logging meals; equipped items composite in live (device-local).
struct AvatarCustomizeView: View {
    let avatarURL: URL?

    @State private var equipped = EquippedStore.load()
    @State private var progress = AvatarProgress.empty
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ComposedAvatarView(url: avatarURL, equipped: equipped, size: 220)
                    .padding(.top, 8)

                ForEach(AccessorySlot.allCases, id: \.self) { slot in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(slot.title)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(AvatarCatalog.inSlot(slot)) { accessory in
                                AccessoryTile(
                                    accessory: accessory,
                                    unlocked: accessory.unlocked(progress),
                                    equipped: equipped[slot] == accessory.id,
                                    onTap: { toggle(accessory) }
                                )
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Customize")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadProgress() }
        .onChange(of: equipped) { _, new in EquippedStore.save(new) }
        .overlay {
            if !loaded { ProgressView() }
        }
    }

    private func toggle(_ accessory: AvatarAccessory) {
        guard accessory.unlocked(progress) else { return }
        if equipped[accessory.slot] == accessory.id {
            equipped[accessory.slot] = nil        // tap again to remove
        } else {
            equipped[accessory.slot] = accessory.id
        }
    }

    private func loadProgress() async {
        defer { loaded = true }
        if let entries = try? await SupabaseService.shared.myEntries() {
            progress = .from(entries: entries)
        }
    }
}

private struct AccessoryTile: View {
    let accessory: AvatarAccessory
    let unlocked: Bool
    let equipped: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(equipped ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground))
                    swatch
                        .opacity(unlocked ? 1 : 0.25)
                    if !unlocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .offset(y: 22)
                    }
                    if equipped {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .offset(x: 26, y: -26)
                    }
                }
                .frame(width: 72, height: 72)
                .overlay {
                    Circle().strokeBorder(equipped ? Color.accentColor : .clear, lineWidth: 2)
                }

                Text(accessory.name)
                    .font(.caption2)
                    .lineLimit(1)
                Text(unlocked ? " " : accessory.unlockHint)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
    }

    @ViewBuilder private var swatch: some View {
        if let glyph = accessory.glyph {
            Text(glyph).font(.system(size: 34))
        } else if let ring = accessory.ringColor {
            Circle().strokeBorder(Color(ring), lineWidth: 5).frame(width: 44, height: 44)
        }
    }
}
