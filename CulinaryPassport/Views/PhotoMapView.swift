import SwiftUI
import MapKit

/// v1.1 item 10 — meals pinned on a map at their resolved coordinates. Entries
/// logged via Places carry lat/lng; a photo (if any) rides on the pin.
struct PhotoMapView: View {
    let entries: [Entry]
    @State private var selected: Entry?

    private var located: [Entry] {
        entries.filter { $0.lat != nil && $0.lng != nil }
    }

    var body: some View {
        if located.isEmpty {
            ContentUnavailableView(
                "No mapped meals yet",
                systemImage: "mappin.slash",
                description: Text("Log a meal with a restaurant from search to place it on the map.")
            )
        } else {
            // .automatic frames all annotations — critical here because a
            // long-distance couple's meals span opposite sides of the globe, where
            // a naive lat/lng bounding-box center lands in the wrong ocean.
            Map(initialPosition: .automatic) {
                ForEach(located) { entry in
                    Annotation(
                        entry.restaurantName,
                        coordinate: CLLocationCoordinate2D(latitude: entry.lat!, longitude: entry.lng!)
                    ) {
                        PinView(entry: entry)
                            .onTapGesture { selected = entry }
                    }
                }
            }
            .sheet(item: $selected) { entry in
                MealDetailCard(entry: entry)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct PinView: View {
    let entry: Entry
    private var country: Country? { CountryStore.byCode[entry.countryCode] }

    var body: some View {
        ZStack {
            Circle().fill(.background).frame(width: 40, height: 40)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .shadow(radius: 2)
            if let first = entry.photos.first {
                SignedPhotoImage(path: first) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(country?.flagEmoji ?? "🍽️")
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())
            } else {
                Text(country?.flagEmoji ?? "🍽️").font(.title3)
            }
        }
    }
}

private struct MealDetailCard: View {
    let entry: Entry
    private var country: Country? { CountryStore.byCode[entry.countryCode] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(country?.flagEmoji ?? "🌍") \(entry.restaurantName)")
                    .font(.title2).bold()
                Text("\(country?.cuisineName ?? entry.countryCode) · \(entry.dateTried)\(entry.city.map { " · \($0)" } ?? "")")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(String(repeating: "★", count: entry.rating)).foregroundStyle(.orange)

                if let dish = entry.signatureDish, !dish.isEmpty {
                    Label(dish, systemImage: "fork.knife")
                }
                ForEach(entry.photos, id: \.self) { path in
                    SignedPhotoImage(path: path) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(.secondarySystemBackground)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if let notes = entry.notes, !notes.isEmpty {
                    Text(notes).font(.body)
                }
            }
            .padding()
        }
    }
}
