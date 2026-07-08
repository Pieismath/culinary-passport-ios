import Foundation
import Supabase

// MVP step 3 — restaurant autocomplete. The mobile client can't use the web's
// HTTP-referrer-locked Places key, so every call goes through the `places-proxy`
// edge function, which holds a server-restricted key. The Supabase functions
// client attaches the signed-in user's JWT automatically (the proxy requires it).
struct PlacesService {
    static let shared = PlacesService()

    /// Google returns camelCase already, so no key strategy — decode keys as-is.
    private let decoder = JSONDecoder()

    struct Suggestion: Identifiable, Hashable {
        let placeId: String
        let mainText: String       // "Chat Thai"
        let secondaryText: String  // "Campbell Street, Haymarket NSW, Australia"
        var id: String { placeId }
    }

    struct Details: Hashable {
        let name: String
        let address: String
        let city: String?
        let lat: Double?
        let lng: Double?
    }

    func autocomplete(_ input: String, near bias: (lat: Double, lng: Double)?) async throws -> [Suggestion] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        let req = AutocompleteRequest(
            input: trimmed,
            bias: bias.map { Bias(lat: $0.lat, lng: $0.lng) }
        )
        let resp: AutocompleteResponse = try await SupabaseService.shared.client.functions.invoke(
            "places-proxy", options: .init(body: req), decoder: decoder
        )
        return resp.suggestions.compactMap { s in
            guard let p = s.placePrediction else { return nil }
            return Suggestion(
                placeId: p.placeId,
                mainText: p.structuredFormat?.mainText?.text ?? p.text?.text ?? "",
                secondaryText: p.structuredFormat?.secondaryText?.text ?? ""
            )
        }
    }

    func details(placeId: String) async throws -> Details {
        let req = DetailsRequest(placeId: placeId)
        let resp: DetailsResponse = try await SupabaseService.shared.client.functions.invoke(
            "places-proxy", options: .init(body: req), decoder: decoder
        )
        // "locality" is the city; fall back to the next-broadest admin area.
        let city = resp.addressComponents?.first { $0.types.contains("locality") }?.longText
            ?? resp.addressComponents?.first { $0.types.contains("postal_town") }?.longText
            ?? resp.addressComponents?.first { $0.types.contains("administrative_area_level_2") }?.longText
        return Details(
            name: resp.displayName?.text ?? "",
            address: resp.formattedAddress ?? "",
            city: city,
            lat: resp.location?.latitude,
            lng: resp.location?.longitude
        )
    }

    // MARK: - Wire types (match the places-proxy request/response shapes)

    private struct Bias: Encodable { let lat: Double; let lng: Double }
    private struct AutocompleteRequest: Encodable {
        let kind = "autocomplete"
        let input: String
        let bias: Bias?
    }
    private struct DetailsRequest: Encodable {
        let kind = "details"
        let placeId: String
    }

    private struct AutocompleteResponse: Decodable {
        let suggestions: [SuggestionWire]
    }
    private struct SuggestionWire: Decodable {
        let placePrediction: PlacePrediction?
    }
    private struct PlacePrediction: Decodable {
        let placeId: String
        let text: TextWire?
        let structuredFormat: StructuredFormat?
    }
    private struct StructuredFormat: Decodable {
        let mainText: TextWire?
        let secondaryText: TextWire?
    }
    private struct TextWire: Decodable { let text: String }

    private struct DetailsResponse: Decodable {
        let formattedAddress: String?
        let location: LocationWire?
        let displayName: TextWire?
        let addressComponents: [AddressComponent]?
    }
    private struct LocationWire: Decodable { let latitude: Double; let longitude: Double }
    private struct AddressComponent: Decodable {
        let longText: String
        let types: [String]
    }
}
