import SwiftUI

/// Compact relative time: "now", "5m", "3h", "2d", "12 Apr".
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
        default:
            let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            return sameYear
                ? date.formatted(.dateTime.day().month(.abbreviated))
                : date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }
}

// ── Emoji ───────────────────────────────────────────────────────────────────

/// Pick any emoji to react with. A curated grid beats the system keyboard:
/// one tap, stays in the sheet, and reactions cluster on a few hundred glyphs.
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    static let quick = ["❤️", "🤤", "🔥", "🙌"]

    private static let sections: [(title: String, emoji: [String])] = [
        ("Reactions", ["❤️", "🤤", "😍", "🔥", "🙌", "👏", "😂", "🥹", "😮", "🤩", "💯", "✨", "🎉", "👀", "🙋", "👍"]),
        ("Food", ["🍜", "🍣", "🍕", "🌮", "🥟", "🍛", "🥘", "🍝", "🥙", "🍢", "🍤", "🥗", "🫓", "🌯", "🍔", "🍟",
                  "🥐", "🧀", "🥩", "🍗", "🍚", "🍲", "🫕", "🥞", "🧁", "🍰", "🍦", "🍩", "🌶️", "🧄", "🥑", "🍋"]),
        ("Drinks", ["☕️", "🍵", "🧋", "🍷", "🍹", "🍺", "🍶", "🥂", "🧃", "🥤"]),
        ("Feelings", ["🥵", "🥶", "🤯", "😭", "😅", "😴", "🫠", "🥳", "🤝", "💪", "🫡", "😎"]),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: section.title)
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(section.emoji, id: \.self) { emoji in
                                    Button {
                                        onPick(emoji)
                                        dismiss()
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 28))
                                            .frame(maxWidth: .infinity, minHeight: 42)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("React with \(emoji)")
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .paperBackground()
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Tallied reactions + a heart shortcut + "add any emoji".
struct ReactionBar: View {
    let tallies: [ReactionTally]
    let onToggle: (String, Bool) -> Void
    var compact = false

    @State private var picking = false

    private var hearted: Bool { tallies.contains { $0.emoji == "❤️" && $0.mine } }

    var body: some View {
        HStack(spacing: 6) {
            if !tallies.contains(where: { $0.emoji == "❤️" }) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onToggle("❤️", true)
                } label: {
                    Image(systemName: "heart")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(minWidth: 36, minHeight: 30)
                        .background(Color.sunken, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.inkSecondary)
                .accessibilityLabel("Like")
            }
            ForEach(tallies.prefix(compact ? 3 : 8)) { tally in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onToggle(tally.emoji, !tally.mine)
                } label: {
                    HStack(spacing: 4) {
                        Text(tally.emoji)
                        Text("\(tally.count)")
                            .monospacedDigit()
                            .foregroundStyle(tally.mine ? Color.brand : Color.inkSecondary)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(tally.mine ? Color.brandSoft : Color.sunken, in: Capsule())
                    .overlay {
                        if tally.mine { Capsule().strokeBorder(Color.brand.opacity(0.5), lineWidth: 1) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tally.emoji) \(tally.count)\(tally.mine ? ", including you" : "")")
            }
            Button { picking = true } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 15, weight: .medium))
                    .frame(minWidth: 36, minHeight: 30)
                    .background(Color.sunken, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.inkSecondary)
            .accessibilityLabel("Add a reaction")
        }
        .sheet(isPresented: $picking) {
            EmojiPickerSheet { emoji in onToggle(emoji, true) }
        }
    }
}

/// Comments under a meal: read, add, delete your own, report others'.
struct CommentsSection: View {
    let meal: Meal

    @Environment(AppModel.self) private var app
    @State private var comments: [Comment] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var canModerate: Bool { meal.userId == app.myId }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(comments.isEmpty ? "Comments" : "Comments · \(comments.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)

            if loaded && comments.isEmpty {
                Text("No comments yet. Say something nice.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkTertiary)
            }

            ForEach(comments.filter { !app.blocked.contains($0.authorId) }) { comment in
                HStack(alignment: .top, spacing: 10) {
                    AvatarView(profile: app.profile(comment.authorId), size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(app.profile(comment.authorId)?.name ?? "Someone")
                                .font(.subheadline.weight(.semibold))
                            Text(RelativeTime.short(comment.createdAt))
                                .font(.caption)
                                .foregroundStyle(Color.inkTertiary)
                        }
                        Text(comment.text)
                            .font(.subheadline)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    if comment.authorId == app.myId || canModerate {
                        Button(role: .destructive) {
                            Task { await delete(comment) }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    if comment.authorId != app.myId {
                        Button(role: .destructive) {
                            Task { await app.report("comment", id: comment.id, reason: "inappropriate") }
                        } label: { Label("Report", systemImage: "flag") }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add a comment…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.sunken, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(draft.trimmed.isEmpty ? Color.inkTertiary : Color.brand)
                }
                .disabled(draft.trimmed.isEmpty || sending)
                .accessibilityLabel("Send comment")
            }
        }
        .task(id: meal.id) { await load() }
    }

    private func load() async {
        let fetched = (try? await app.backend.comments(mealId: meal.id)) ?? []
        _ = await app.profiles(for: fetched.map(\.authorId))
        comments = fetched
        loaded = true
    }

    private func send() async {
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            try await app.backend.addComment(mealId: meal.id, text: text)
            draft = ""
            app.backend.logEvent("comment_added", props: nil)
            await load()
        } catch {
            app.show(error)
        }
    }

    private func delete(_ comment: Comment) async {
        let before = comments
        comments.removeAll { $0.id == comment.id }
        do {
            try await app.backend.deleteComment(id: comment.id)
        } catch {
            comments = before
            app.show(error)
        }
    }
}

/// Report with a short reason — used for meals, profiles and messages.
struct ReportSheet: View {
    let title: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = "Inappropriate"
    @State private var details = ""

    private let reasons = ["Inappropriate", "Spam", "Harassment", "Someone else's photo", "Something else"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Why are you reporting this?") {
                    Picker("Reason", selection: $reason) {
                        ForEach(reasons, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    TextField("Anything we should know? (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("Reports are private. We review them and remove content that breaks the community rules.")
                }
            }
            .paperListStyle()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Report") {
                        onSubmit(details.trimmed.isEmpty ? reason : "\(reason): \(details.trimmed)")
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
