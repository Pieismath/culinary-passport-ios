import SwiftUI

/// One logged meal, in full: photos, rating, dish, notes — reached by tapping
/// an entry anywhere (globe panel, timeline, photo map). Your own entries get
/// Edit and Delete; someone else's (group globe) are read-only.
struct EntryDetailView: View {
    let entry: Entry
    /// Shown as "logged by …" when the viewer isn't the author (group views).
    var author: Profile? = nil
    /// Called after an edit or delete lands so the presenter can reload.
    var onChanged: (() async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var myId: UUID?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var deleting = false

    private var country: Country? { CountryStore.byCode[entry.countryCode] }
    private var isMine: Bool { myId == entry.userId }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    Text(String(repeating: "★", count: entry.rating))
                        .font(.title3)
                        .foregroundStyle(.orange)

                    if let dish = entry.signatureDish, !dish.isEmpty {
                        Label(dish, systemImage: "fork.knife")
                    }

                    ForEach(entry.photos, id: \.self) { path in
                        SignedPhotoImage(path: path) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color(.secondarySystemBackground)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    if let notes = entry.notes, !notes.isEmpty {
                        Text(notes)
                    }

                    footerBadges
                }
                .padding()
            }
            .navigationTitle(entry.restaurantName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if isMine {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { editing = true }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isMine {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label(deleting ? "Deleting…" : "Delete this meal", systemImage: "trash")
                            .font(.subheadline)
                    }
                    .disabled(deleting)
                    .padding(.bottom, 6)
                }
            }
            .task { myId = try? await SupabaseService.shared.client.auth.session.user.id }
            .sheet(isPresented: $editing) {
                EntrySheet(mode: .edit(entry)) {
                    await onChanged?()
                    dismiss() // the entry shown here is now stale
                }
            }
            .confirmationDialog("Delete this meal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("\(entry.restaurantName) and its photos will be removed.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(country?.flagEmoji ?? "🌍").font(.largeTitle)
            VStack(alignment: .leading, spacing: 2) {
                Text(country?.cuisineName ?? entry.countryCode).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
            Spacer()
        }
    }

    private var subtitle: String {
        var parts = [Self.pretty(entry.dateTried)]
        if let city = entry.city, !city.isEmpty { parts.append(city) }
        if let author, !isMine { parts.append("logged by \(author.name)") }
        return parts.joined(separator: " · ")
    }

    private var footerBadges: some View {
        HStack(spacing: 8) {
            if let visibility = entry.visibility {
                Label(visibilityText(visibility), systemImage: visibilityIcon(visibility))
            }
            if entry.wouldReturn {
                Label("Would return", systemImage: "arrow.uturn.left.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(Color(.secondaryLabel))
    }

    private func visibilityText(_ v: Entry.Visibility) -> String {
        switch v {
        case .public: "Public"
        case .groups: "My groups"
        case .private: "Only me"
        }
    }

    private func visibilityIcon(_ v: Entry.Visibility) -> String {
        switch v {
        case .public: "globe"
        case .groups: "person.3"
        case .private: "lock"
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await SupabaseService.shared.deleteEntry(entry)
            await onChanged?()
            dismiss()
        } catch {
            // leave the sheet up; the button re-enables for a retry
        }
    }

    private static let parse: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func pretty(_ raw: String) -> String {
        guard let date = parse.date(from: raw) else { return raw }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
