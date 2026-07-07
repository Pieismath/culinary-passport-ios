import Foundation

// Mirrors the Supabase schema: web repo supabase/schema.sql + social-schema.sql.
// Snake-case mapping is handled by the shared JSONDecoder in SupabaseService.

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var color: String
    var homeCity: String
    var username: String?
    var bio: String?
    var avatarUrl: String?
    var isPublic: Bool?
}

struct Entry: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var countryCode: String
    var restaurantName: String
    var city: String?
    var dateTried: String // yyyy-mm-dd
    var rating: Int
    var notes: String?
    var signatureDish: String?
    var photos: [String]
    var wouldReturn: Bool
    var placeId: String?
    var lat: Double?
    var lng: Double?
    var visibility: Visibility?
    let createdAt: Date

    enum Visibility: String, Codable { case `public`, groups, `private` }
}

/// Insert payload — id / created_at come from Postgres defaults.
struct NewEntry: Codable {
    let userId: UUID
    var countryCode: String
    var restaurantName: String
    var city: String
    var dateTried: String
    var rating: Int
    var notes: String
    var signatureDish: String
    var wouldReturn: Bool
    var placeId: String?
    var lat: Double?
    var lng: Double?
}

struct Group: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var coverPhoto: String?
    var inviteCode: String
    let createdBy: UUID
    let createdAt: Date
}

struct GroupMember: Codable, Hashable {
    let groupId: UUID
    let userId: UUID
    var role: Role
    let joinedAt: Date

    enum Role: String, Codable { case owner, member }
}

struct GroupPost: Codable, Identifiable, Hashable {
    let id: UUID
    let groupId: UUID
    let authorId: UUID
    var entryId: UUID?
    var text: String
    var photos: [String]
    let createdAt: Date
}

struct PostComment: Codable, Identifiable, Hashable {
    let id: UUID
    let postId: UUID
    let authorId: UUID
    var parentId: UUID?
    var text: String
    let createdAt: Date
}

struct Follow: Codable, Hashable {
    let followerId: UUID
    let followeeId: UUID
    let createdAt: Date
}
