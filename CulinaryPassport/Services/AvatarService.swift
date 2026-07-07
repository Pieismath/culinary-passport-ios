import Foundation
import UIKit
import Vision

/// Selfie → stylized avatar, via the `generate-avatar` Supabase Edge Function.
/// The style prompt lives server-side (locked constant) — the client only ships pixels.
enum AvatarService {
    struct Response: Decodable {
        let url: String
        let provider: String
    }

    /// Crop to the face (better model input), then upload. Returns the avatar URL.
    /// Server enforces the 3/day rate limit — surface its 429 message verbatim.
    static func generateAvatar(from selfie: UIImage) async throws -> Response {
        let cropped = (try? await faceCrop(selfie)) ?? selfie
        guard let jpeg = cropped.jpegData(compressionQuality: 0.85) else {
            throw AvatarError.badImage
        }

        var body = Data()
        let boundary = "cp-\(UUID().uuidString)"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"selfie\"; filename=\"selfie.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let session = try await SupabaseService.shared.client.auth.session
        var req = URLRequest(url: Config.supabaseURL.appending(path: "functions/v1/generate-avatar"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 120 // generation takes a while

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AvatarError.server(message ?? "Avatar generation failed")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// Vision-framework face crop with generous headroom (hair matters for likeness).
    private static func faceCrop(_ image: UIImage) async throws -> UIImage {
        guard let cg = image.cgImage else { throw AvatarError.badImage }
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: cg).perform([request])
        guard let face = request.results?.first else { return image }

        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // Vision is normalized + bottom-left origin; pad 80% around the face box.
        let box = face.boundingBox
        let pad: CGFloat = 0.8
        let rect = CGRect(
            x: max(0, (box.minX - box.width * pad) * w),
            y: max(0, (1 - box.maxY - box.height * pad) * h),
            width: min(w, box.width * (1 + 2 * pad) * w),
            height: min(h, box.height * (1 + 2 * pad) * h)
        )
        guard let croppedCG = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: croppedCG, scale: image.scale, orientation: image.imageOrientation)
    }

    enum AvatarError: LocalizedError {
        case badImage
        case server(String)

        var errorDescription: String? {
            switch self {
            case .badImage: "Couldn't read that photo — try another one"
            case .server(let message): message
            }
        }
    }
}
