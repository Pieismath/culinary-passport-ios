import Foundation

// Mirrors the Supabase schema: web repo supabase/schema.sql + social-schema.sql.
// Snake-case mapping is handled by the shared JSONDecoder in SupabaseService.

extension Profile {
    /// Stand-in used while assembling activity items before profiles resolve.
    static func placeholder(_ id: UUID) -> Profile {
        Profile(id: id, name: "", color: "#c98a2e", homeCity: "",
                username: nil, bio: nil, avatarUrl: nil, isPublic: nil,
                createdAt: nil, yearlyGoal: nil)
    }
}

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var color: String
    var homeCity: String
    var username: String?
    var bio: String?
    var avatarUrl: String?
    var isPublic: Bool?
    /// Signup date — "Member since March 2026" on the profile header.
    var createdAt: Date?
    /// Beli-style "how many cuisines this year?" target. Nil = not set.
    var yearlyGoal: Int?
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
    var photos: [String] = []
    var visibility: String = "groups"
}

/// Update payload for editing an existing entry (id / created_at are immutable).
struct EntryUpdate: Codable {
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
    var photos: [String] = []
    var visibility: String = "groups"
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

struct PostReaction: Codable, Hashable {
    let postId: UUID
    let userId: UUID
    let emoji: String
}

/// A discover-feed row: an entry paired with its (public) author.
struct FeedItem: Identifiable, Hashable {
    let entry: Entry
    let author: Profile
    var id: UUID { entry.id }
}

struct Follow: Codable, Hashable {
    let followerId: UUID
    let followeeId: UUID
    let createdAt: Date
}

// Insert payloads (ids / timestamps come from Postgres defaults)

struct NewGroupPost: Codable {
    let groupId: UUID
    let authorId: UUID
    var entryId: UUID?
    var text: String
    var photos: [String] = []
}

struct NewComment: Codable {
    let postId: UUID
    let authorId: UUID
    var parentId: UUID?
    var text: String
}

// ── Retention/social layer (2026-07-22 migration) ───────────────────────────

/// A restaurant on the user's Want to Try list.
struct SavedRestaurant: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var restaurantName: String
    var city: String?
    var countryCode: String
    var note: String?
    let createdAt: Date
}

/// An emoji reaction on a MEAL (entry_reactions).
struct EntryReaction: Codable, Hashable {
    let entryId: UUID
    let userId: UUID
    let emoji: String
    let createdAt: Date?
}

/// A comment on a MEAL (entry_comments).
struct EntryComment: Codable, Identifiable, Hashable {
    let id: UUID
    let entryId: UUID
    let authorId: UUID
    var text: String
    let createdAt: Date
}

/// One row in the Activity feed — assembled client-side from follows,
/// entry reactions, and entry comments aimed at the current user.
struct ActivityItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case followedYou
        case reacted(emoji: String, entry: Entry)
        case commented(text: String, entry: Entry)
    }

    let id: String
    let actor: Profile
    let kind: Kind
    let date: Date
}
