import Foundation

struct APIListing: Codable, Identifiable, Hashable {
    let id: Int64?
    let title: String
    let description: String
    let imageUrl: String?
    let address: String
    let latitude: Double?
    let longitude: Double?
    let price: Double
    let userId: String
    let userName: String?
    let isCompleted: Bool?
    let createdAt: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: APIListing, rhs: APIListing) -> Bool {
        lhs.id == rhs.id
    }
}

struct APIConversation: Codable, Identifiable {
    let id: Int64
    let listingId: Int64
    let buyerId: String
    let sellerId: String
    let createdAt: String?
    let updatedAt: String?
}

struct APIConversationSummary: Codable, Identifiable {
    let id: Int64
    let listingId: Int64
    let listingTitle: String
    let listingImageUrl: String?
    let lastMessage: String?
    let updatedAt: String?
    let buyerId: String
    let sellerId: String
    let unreadCount: Int?
    let lastReadAt: String?
}

struct APIMessage: Codable, Identifiable {
    let id: Int64
    let conversationId: Int64
    let senderId: String
    let body: String
    let createdAt: String?
}

struct APIUser: Codable {
    let userId: String
    let name: String?
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let messageNotificationsEnabled: Bool?
    let listingNotificationsEnabled: Bool?
    let listingNotificationRadiusKm: Double?
}

struct APIReview: Codable {
    let id: Int64?
    let listingId: Int64
    let reviewerId: String
    let revieweeId: String
    let rating: Int
    let comment: String?
    let createdAt: String?
}

private struct UpsertUserRequest: Codable {
    let userId: String
    let name: String?
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let messageNotificationsEnabled: Bool?
    let listingNotificationsEnabled: Bool?
    let listingNotificationRadiusKm: Double?
}

private struct CreateConversationRequest: Codable {
    let listingId: Int64
    let buyerId: String
}

private struct CreateMessageRequest: Codable {
    let conversationId: Int64
    let senderId: String
    let body: String
}

private struct MarkConversationReadRequest: Codable {
    let userId: String
}

private struct CreateReviewRequest: Codable {
    let listingId: Int64
    let reviewerId: String
    let revieweeId: String
    let rating: Int
    let comment: String?
}

private struct RegisterDeviceRequest: Codable {
    let userId: String
    let token: String
    let platform: String
}

struct APIResponse<T: Codable>: Codable {
    let success: Bool
    let data: T?
    let message: String?
}

class APIService {
    static let shared = APIService()

    private let baseURL: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "http://localhost:8080" : trimmed
    }()

    private init() {}

    /// Creates a listing with optional image - all in one request
    func createListing(
        title: String,
        description: String,
        address: String,
        latitude: Double?,
        longitude: Double?,
        price: Double,
        userId: String,
        userName: String?,
        imageData: Data?
    ) async throws -> APIListing {
        let url = URL(string: "\(baseURL)/api/listings")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Add form fields
        let fields: [(String, String)] = [
            ("title", title),
            ("description", description),
            ("address", address),
            ("latitude", latitude.map { String($0) } ?? ""),
            ("longitude", longitude.map { String($0) } ?? ""),
            ("price", String(price)),
            ("userId", userId),
            ("userName", userName ?? "")
        ]

        for (name, value) in fields where !value.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        // Add image if present
        if let imageData {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"image\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(imageData)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 else {
            throw APIError.requestFailed
        }

        let apiResponse = try JSONDecoder().decode(APIResponse<APIListing>.self, from: data)

        guard let listing = apiResponse.data else {
            throw APIError.invalidResponse
        }

        return listing
    }

    func getListings() async throws -> [APIListing] {
        let url = URL(string: "\(baseURL)/api/listings")!

        let (data, _) = try await URLSession.shared.data(from: url)
        let apiResponse = try JSONDecoder().decode(APIResponse<[APIListing]>.self, from: data)

        return apiResponse.data ?? []
    }

    func getListings(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) async throws -> [APIListing] {
        var components = URLComponents(string: "\(baseURL)/api/listings")!
        components.queryItems = [
            URLQueryItem(name: "minLat", value: String(minLat)),
            URLQueryItem(name: "maxLat", value: String(maxLat)),
            URLQueryItem(name: "minLon", value: String(minLon)),
            URLQueryItem(name: "maxLon", value: String(maxLon))
        ]

        let url = components.url!
        let (data, _) = try await URLSession.shared.data(from: url)
        let apiResponse = try JSONDecoder().decode(APIResponse<[APIListing]>.self, from: data)

        return apiResponse.data ?? []
    }

    func getListings(userId: String) async throws -> [APIListing] {
        let url = URL(string: "\(baseURL)/api/listings/user/\(userId)")!

        let (data, _) = try await URLSession.shared.data(from: url)
        let apiResponse = try JSONDecoder().decode(APIResponse<[APIListing]>.self, from: data)

        return apiResponse.data ?? []
    }

    func updateListing(
        listingId: Int64,
        title: String,
        description: String,
        address: String,
        latitude: Double?,
        longitude: Double?,
        price: Double,
        userId: String,
        imageData: Data?
    ) async throws -> APIListing {
        let url = URL(string: "\(baseURL)/api/listings/\(listingId)")!

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let fields: [(String, String)] = [
            ("title", title),
            ("description", description),
            ("address", address),
            ("latitude", latitude.map { String($0) } ?? ""),
            ("longitude", longitude.map { String($0) } ?? ""),
            ("price", String(price)),
            ("userId", userId)
        ]

        for (name, value) in fields where !value.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        if let imageData {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"image\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(imageData)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed
        }

        let apiResponse = try JSONDecoder().decode(APIResponse<APIListing>.self, from: data)
        guard let listing = apiResponse.data else {
            throw APIError.invalidResponse
        }

        return listing
    }

    func deleteListing(id: Int64) async throws {
        let url = URL(string: "\(baseURL)/api/listings/\(id)")!

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed
        }
    }

    func getListing(id: Int64) async throws -> APIListing {
        let url = URL(string: "\(baseURL)/api/listings/\(id)")!

        let (data, _) = try await URLSession.shared.data(from: url)
        let apiResponse = try JSONDecoder().decode(APIResponse<APIListing>.self, from: data)

        guard let listing = apiResponse.data else {
            throw APIError.invalidResponse
        }

        return listing
    }

    @discardableResult
    func upsertUser(
        userId: String,
        name: String?,
        address: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        messageNotificationsEnabled: Bool? = nil,
        listingNotificationsEnabled: Bool? = nil,
        listingNotificationRadiusKm: Double? = nil
    ) async throws -> APIUser {
        let url = URL(string: "\(baseURL)/api/users")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = UpsertUserRequest(
            userId: userId,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            messageNotificationsEnabled: messageNotificationsEnabled,
            listingNotificationsEnabled: listingNotificationsEnabled,
            listingNotificationRadiusKm: listingNotificationRadiusKm
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed
        }

        let apiResponse = try JSONDecoder().decode(APIResponse<APIUser>.self, from: data)

        guard let user = apiResponse.data else {
            throw APIError.invalidResponse
        }

        return user
    }

    func getUser(userId: String) async throws -> APIUser {
        let url = URL(string: "\(baseURL)/api/users/\(userId)")!

        let (data, _) = try await URLSession.shared.data(from: url)
        let apiResponse = try JSONDecoder().decode(APIResponse<APIUser>.self, from: data)

        guard let user = apiResponse.data else {
            throw APIError.invalidResponse
        }

        return user
    }

    func createReview(
        listingId: Int64,
        reviewerId: String,
        revieweeId: String,
        rating: Int,
        comment: String?
    ) async throws -> APIReview {
        let url = URL(string: "\(baseURL)/api/reviews")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CreateReviewRequest(
                listingId: listingId,
                reviewerId: reviewerId,
                revieweeId: revieweeId,
                rating: rating,
                comment: comment
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed
        }

        let apiResponse = try JSONDecoder().decode(APIResponse<APIReview>.self, from: data)

        guard let review = apiResponse.data else {
            throw APIError.invalidResponse
        }

        return review
    }

    func getReviewsByReviewer(userId: String) async throws -> [APIReview] {
        var components = URLComponents(string: "\(baseURL)/api/reviews")!
        components.queryItems = [
            URLQueryItem(name: "reviewerId", value: userId)
        ]

        let url = components.url!
        let (data, _) = try await URLSession.shared.data(from: url)
        let apiResponse = try JSONDecoder().decode(APIResponse<[APIReview]>.self, from: data)

        return apiResponse.data ?? []
    }

    func getReviewsByReviewee(userId: String) async throws -> [APIReview] {
        var components = URLComponents(string: "\(baseURL)/api/reviews")!
        components.queryItems = [
            URLQueryItem(name: "revieweeId", value: userId)
        ]

        let url = components.url!
        let (data, _) = try await URLSession.shared.data(from: url)
        let apiResponse = try JSONDecoder().decode(APIResponse<[APIReview]>.self, from: data)

        return apiResponse.data ?? []
    }

    func createConversation(listingId: Int64, buyerId: String) async throws -> APIConversation {
        let url = URL(string: "\(baseURL)/api/conversations")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreateConversationRequest(listingId: listingId, buyerId: buyerId))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed
        }

        let apiResponse = try JSONDecoder().decode(APIResponse<APIConversation>.self, from: data)
        guard let conversation = apiResponse.data else {
            throw APIError.invalidResponse
        }

        return conversation
    }

    func getConversations(userId: String) async throws -> [APIConversationSummary] {
        var components = URLComponents(string: "\(baseURL)/api/conversations")!
        components.queryItems = [URLQueryItem(name: "userId", value: userId)]

        let url = components.url!
        let (data, _) = try await URLSession.shared.data(from: url)
        let apiResponse = try JSONDecoder().decode(APIResponse<[APIConversationSummary]>.self, from: data)

        return apiResponse.data ?? []
    }

    func getMessages(conversationId: Int64) async throws -> [APIMessage] {
        var components = URLComponents(string: "\(baseURL)/api/messages")!
        components.queryItems = [URLQueryItem(name: "conversationId", value: String(conversationId))]

        let url = components.url!
        let (data, _) = try await URLSession.shared.data(from: url)
        let apiResponse = try JSONDecoder().decode(APIResponse<[APIMessage]>.self, from: data)

        return apiResponse.data ?? []
    }

    func sendMessage(conversationId: Int64, senderId: String, body: String) async throws -> APIMessage {
        let url = URL(string: "\(baseURL)/api/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CreateMessageRequest(conversationId: conversationId, senderId: senderId, body: body)
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed
        }

        let apiResponse = try JSONDecoder().decode(APIResponse<APIMessage>.self, from: data)
        guard let message = apiResponse.data else {
            throw APIError.invalidResponse
        }

        return message
    }

    func registerDeviceToken(userId: String, token: String) async throws {
        let url = URL(string: "\(baseURL)/api/device-tokens")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RegisterDeviceRequest(userId: userId, token: token, platform: "apns")
        )

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed
        }
    }

    func markConversationRead(conversationId: Int64, userId: String) async throws {
        let url = URL(string: "\(baseURL)/api/conversations/\(conversationId)/read")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            MarkConversationReadRequest(userId: userId)
        )

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed
        }
    }

    func webSocketURL(conversationId: Int64, userId: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/conversations/\(conversationId)"
        components.queryItems = [URLQueryItem(name: "userId", value: userId)]
        return components.url
    }
}

enum APIError: Error {
    case requestFailed
    case invalidResponse
}
