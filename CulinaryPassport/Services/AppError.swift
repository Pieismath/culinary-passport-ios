import Foundation

/// A failure with a sentence a person can act on. Anything that reaches the
/// screen goes through `AppError.friendly(_:)` so raw transport and decoding
/// errors ("The data couldn't be read because it isn't in the correct
/// format.") never do.
struct AppError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }

    static func friendly(_ error: Error) -> String {
        if let app = error as? AppError { return app.message }
        if error is CancellationError { return "Cancelled." }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "You're offline. We'll catch up when you're back."
            case NSURLErrorTimedOut:
                return "That took too long. Try again in a moment."
            default:
                return "Couldn't reach Stampd. Try again in a moment."
            }
        }
        let text = error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("duplicate key") && lower.contains("username") {
            return "That username is taken."
        }
        if lower.contains("duplicate key") { return "That already exists." }
        if lower.contains("invalid login credentials") { return "Email or password is wrong." }
        if lower.contains("email not confirmed") { return "Confirm your email first — check your inbox." }
        if lower.contains("too many invite attempts") { return "Too many wrong codes. Try again in an hour." }
        if lower.contains("row-level security") { return "You don't have permission to do that." }
        if error is DecodingError { return "Something came back in an unexpected shape. Try again." }
        return text
    }
}
