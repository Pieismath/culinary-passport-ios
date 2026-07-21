import SwiftUI

/// Pick any emoji to react with (Slack-style), not a fixed set of four.
/// A curated grid beats the system keyboard here: it's one tap, it stays
/// inside the sheet, and reactions skew to the same few hundred glyphs.
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    private static let sections: [(title: String, emoji: [String])] = [
        ("Reactions", ["👍","❤️","😂","🔥","🙌","👏","😍","🤤","😋","😮","🥹","💯","✨","🎉","👀","🫶"]),
        ("Food", ["🍜","🍕","🌮","🍣","🍛","🍲","🥘","🍝","🥟","🍤","🍗","🥩","🌯","🥙","🍔","🍟",
                  "🥗","🍱","🍚","🍢","🧆","🫕","🥐","🥖","🧀","🥞","🧇","🍰","🍮","🍧","🍨","🍩"]),
        ("Drinks & spice", ["☕️","🍵","🍺","🍻","🍷","🥂","🍸","🧉","🌶️","🧄","🧅","🫚","🍋","🥑","🍯","🧂"]),
        ("Feelings", ["🥵","🥶","🤯","😭","🤩","😅","🙃","😴","🤢","🫠","😤","🥳","🤝","💪","🙏","🫡"]),
        ("Travel", ["✈️","🌍","🌏","🗺️","📍","🧳","🚗","🏝️","⛰️","🏙️","🌃","🎏","⭐️","🏆","🥇","💎"]),
    ]

    private var filtered: [(title: String, emoji: [String])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.sections }
        // Match on the section name — emoji have no searchable text here.
        let hits = Self.sections.filter { $0.title.lowercased().contains(q) }
        return hits.isEmpty ? Self.sections : hits
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(filtered, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(0.6)
                                .foregroundStyle(Color(.tertiaryLabel))
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(section.emoji, id: \.self) { emoji in
                                    Button {
                                        onPick(emoji)
                                        dismiss()
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 28))
                                            .frame(maxWidth: .infinity, minHeight: 40)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Reactions, food, feelings…")
            .navigationTitle("Add a reaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
