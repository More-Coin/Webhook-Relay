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
    let type: String // e.g., "new_message", "postback", "potential_order"
    let message: AppMessage?
    let postbackPayload: String?
    let senderId: String? // This will be derived from message or provided for postback
    let timestamp: String

    // Initializer for events that include an AppMessage (like new_message, potential_order)
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
}

// Helper for Date to ISO8601 String
extension Date {
    var iso8601: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}
