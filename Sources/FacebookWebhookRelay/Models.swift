//
//  Models.swift
//  FacebookWebhookRelay
//
//  Created by Stephen Barrett on 22/5/2568 BE.
//

import Vapor

// --- Facebook Webhook Structures ---
struct FacebookWebhookEvent: Content {
    let object: String
    let entry: [FacebookEntry]
}

struct FacebookEntry: Content {
    let id: String
    let time: Int
    let messaging: [FacebookMessagingEvent]?
}

struct FacebookMessagingEvent: Content {
    let sender: FacebookUser
    let recipient: FacebookUser
    let timestamp: Int
    let message: FacebookMessageContent?
    let postback: FacebookPostback?
}

struct FacebookUser: Content {
    let id: String
}

struct FacebookMessageContent: Content {
    let mid: String
    let text: String?
    // Add other fields like attachments if needed
}

struct FacebookPostback: Content {
    let mid: String? // Sometimes present
    let payload: String
    let title: String? // Sometimes present
}

// --- Structures for SSE and your app ---
struct AppMessageData: Content {
    let type: String // e.g., "new_message", "postback"
    let message: AppMessage?
    let postbackPayload: String?
    let senderId: String? // This will be derived from message or provided for postback
    let timestamp: String

    // Initializer for events that include an AppMessage (like new_message)
    init(type: String, appMessage: AppMessage, timestamp: Date = Date()) {
        self.type = type
        self.message = appMessage
        self.postbackPayload = nil
        self.senderId = appMessage.senderId // Get senderId from the AppMessage
        self.timestamp = timestamp.iso8601
    }

    // Initializer for postback events
    init(type: String = "postback", postbackSenderId: String, payload: String, timestamp: Date = Date()) {
        self.type = type
        self.message = nil
        self.postbackPayload = payload
        self.senderId = postbackSenderId // Use the provided senderId for postbacks
        self.timestamp = timestamp.iso8601
    }
}

struct AppMessage: Content {
    let id: String
    let senderId: String
    let senderName: String
    let text: String
    let timestamp: String
    let isFromCustomer: Bool
    let conversationId: String
    let customerName: String
    let customerId: String
}

struct SenderInfo: Content {
    let firstName: String?
    let lastName: String?
    var name: String {
        "\(firstName ?? "") \(lastName ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
    }
    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

struct HealthStatus: Content {
    let status: String
    let timestamp: String
    let connections: Int
    let serverConnected: Bool
}

// Helper for Date to ISO8601 String
extension Date {
    var iso8601: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}

// --- Server Communication Models ---
struct ServerMessage: Codable {
    let type: String // "orderChange", "customerChange", etc.
    let entityId: String
    let action: String
    let timestamp: String
    let data: [String: AnyCodable]? // Dynamic data structure
}

// Helper struct for handling dynamic JSON
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable cannot decode value")
        }
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "AnyCodable cannot encode value"))
        }
    }
}

// --- Facebook Send Message Structures ---
struct FacebookSendMessageRequest: Content {
    let recipient: FacebookRecipient
    let message: FacebookMessageToSend
    let messagingType: String? // "RESPONSE", "UPDATE", "MESSAGE_TAG"
    let tag: String? // For message tags
}

struct FacebookRecipient: Content {
    let id: String // PSID of the recipient
}

struct FacebookMessageToSend: Content {
    let text: String?
    let attachment: FacebookAttachment? // For sending images, etc.
}

struct FacebookAttachment: Content {
    let type: String // "image", "video", "file", "template"
    let payload: FacebookAttachmentPayload
}

struct FacebookAttachmentPayload: Content {
    let url: String? // For media attachments
    let templateType: String? // For template attachments
    // Add more fields as needed
}

// --- Flattened Message Request Structure (for your app/server) ---
struct FlattenedMessageRequest: Content {
    let recipientPSID: String
    let text: String
    let conversationId: String?
    let messagingType: String? // "RESPONSE", "UPDATE", "MESSAGE_TAG"
    let tag: String? // For message tags
    
    // Convert to Facebook API format
    func toFacebookRequest() -> FacebookSendMessageRequest {
        return FacebookSendMessageRequest(
            recipient: FacebookRecipient(id: recipientPSID),
            message: FacebookMessageToSend(text: text, attachment: nil),
            messagingType: messagingType,
            tag: tag
        )
    }
}
