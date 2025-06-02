import Foundation
import Vapor

// MARK: - SSE Message Types

/// Base protocol for all SSE messages
protocol SSEMessageProtocol: Codable {
    var type: String { get }
    var timestamp: String { get }
    var version: String { get }
}

/// Versioning for SSE messages
struct SSEMessageVersion {
    static let current = "2.0"
    static let legacy = "1.0"
}

// MARK: - Specific SSE Message Types

/// Customer update SSE message
struct CustomerUpdateSSE: SSEMessageProtocol {
    let type = "customer_update"
    let version: String
    let timestamp: String
    let action: String // created, updated, deleted
    let customerId: String
    let customerData: CustomerData?
    
    struct CustomerData: Codable {
        let id: UUID?
        let customerId: String
        let customerName: String
        let conversationId: String
        let phoneNumber: String?
        let address: String?
        let lastContactedAt: Date?
    }
    
    init(action: String, customerId: String, customerData: CustomerData?, timestamp: Date = Date(), version: String = SSEMessageVersion.current) {
        self.version = version
        self.timestamp = timestamp.iso8601
        self.action = action
        self.customerId = customerId
        self.customerData = customerData
    }
}

/// Order update SSE message
struct OrderUpdateSSE: SSEMessageProtocol {
    let type = "order_update"
    let version: String
    let timestamp: String
    let action: String
    let orderId: String
    let orderData: OrderData?
    
    struct OrderData: Codable {
        let id: UUID?
        let orderMessageId: String
        let date: Date
        let customerId: String
        let customerName: String
        let totalAmount: Double
        let isCancelled: Bool
        let items: [OrderItem]?
    }
    
    struct OrderItem: Codable {
        let name: String
        let quantity: Int
        let price: Double
    }
    
    init(action: String, orderId: String, orderData: OrderData?, timestamp: Date = Date(), version: String = SSEMessageVersion.current) {
        self.version = version
        self.timestamp = timestamp.iso8601
        self.action = action
        self.orderId = orderId
        self.orderData = orderData
    }
}

/// Inventory update SSE message
struct InventoryUpdateSSE: SSEMessageProtocol {
    let type = "inventory_update"
    let version: String
    let timestamp: String
    let action: String
    let itemId: String
    let inventoryData: InventoryData?
    
    struct InventoryData: Codable {
        let id: UUID?
        let itemName: String
        let quantity: Int
        let transactionType: String
        let date: Date
        let currentStock: Int?
    }
    
    init(action: String, itemId: String, inventoryData: InventoryData?, timestamp: Date = Date(), version: String = SSEMessageVersion.current) {
        self.version = version
        self.timestamp = timestamp.iso8601
        self.action = action
        self.itemId = itemId
        self.inventoryData = inventoryData
    }
}

/// New message SSE (from Facebook)
struct MessageSSE: SSEMessageProtocol {
    let type = "new_message"
    let version: String
    let timestamp: String
    let message: AppMessage
    
    init(message: AppMessage, timestamp: Date = Date(), version: String = SSEMessageVersion.current) {
        self.version = version
        self.timestamp = timestamp.iso8601
        self.message = message
    }
}

/// Postback SSE (from Facebook)
struct PostbackSSE: SSEMessageProtocol {
    let type = "postback"
    let version: String
    let timestamp: String
    let senderId: String
    let payload: String
    let title: String?
    
    init(senderId: String, payload: String, title: String? = nil, timestamp: Date = Date(), version: String = SSEMessageVersion.current) {
        self.version = version
        self.timestamp = timestamp.iso8601
        self.senderId = senderId
        self.payload = payload
        self.title = title
    }
}

/// Bulk update SSE message
struct BulkUpdateSSE: SSEMessageProtocol {
    let type = "bulk_update"
    let version: String
    let timestamp: String
    let changeCount: Int
    let changes: [BulkChange]
    
    struct BulkChange: Codable {
        let entityType: String
        let entityId: String
        let action: String
        let data: AnyCodable?
    }
    
    init(changes: [BulkChange], timestamp: Date = Date(), version: String = SSEMessageVersion.current) {
        self.version = version
        self.timestamp = timestamp.iso8601
        self.changeCount = changes.count
        self.changes = changes
    }
}

/// Error SSE message
struct ErrorSSE: SSEMessageProtocol {
    let type = "error"
    let version: String
    let timestamp: String
    let errorCode: String
    let errorMessage: String
    let details: [String: AnyCodable]?
    
    init(errorCode: String, errorMessage: String, details: [String: AnyCodable]? = nil, timestamp: Date = Date(), version: String = SSEMessageVersion.current) {
        self.version = version
        self.timestamp = timestamp.iso8601
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.details = details
    }
}

/// System status SSE message
struct SystemStatusSSE: SSEMessageProtocol {
    let type = "system_status"
    let version: String
    let timestamp: String
    let status: String
    let message: String?
    
    init(status: String, message: String? = nil, timestamp: Date = Date(), version: String = SSEMessageVersion.current) {
        self.version = version
        self.timestamp = timestamp.iso8601
        self.status = status
        self.message = message
    }
}

// MARK: - SSE Message Wrapper

/// Wrapper enum to handle different SSE message types
enum SSEMessage: Codable {
    case customerUpdate(CustomerUpdateSSE)
    case orderUpdate(OrderUpdateSSE)
    case inventoryUpdate(InventoryUpdateSSE)
    case newMessage(MessageSSE)
    case postback(PostbackSSE)
    case bulkUpdate(BulkUpdateSSE)
    case error(ErrorSSE)
    case systemStatus(SystemStatusSSE)
    
    // Legacy format support
    case legacy(AppMessageData)
    
    // Custom encoding to ensure proper type discrimination
    enum CodingKeys: String, CodingKey {
        case type
        case data
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .customerUpdate(let message):
            try container.encode("customer_update", forKey: .type)
            try container.encode(message, forKey: .data)
        case .orderUpdate(let message):
            try container.encode("order_update", forKey: .type)
            try container.encode(message, forKey: .data)
        case .inventoryUpdate(let message):
            try container.encode("inventory_update", forKey: .type)
            try container.encode(message, forKey: .data)
        case .newMessage(let message):
            try container.encode("new_message", forKey: .type)
            try container.encode(message, forKey: .data)
        case .postback(let message):
            try container.encode("postback", forKey: .type)
            try container.encode(message, forKey: .data)
        case .bulkUpdate(let message):
            try container.encode("bulk_update", forKey: .type)
            try container.encode(message, forKey: .data)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .data)
        case .systemStatus(let message):
            try container.encode("system_status", forKey: .type)
            try container.encode(message, forKey: .data)
        case .legacy(let message):
            // For legacy format, encode directly without wrapper
            try message.encode(to: encoder)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "customer_update":
            let data = try container.decode(CustomerUpdateSSE.self, forKey: .data)
            self = .customerUpdate(data)
        case "order_update":
            let data = try container.decode(OrderUpdateSSE.self, forKey: .data)
            self = .orderUpdate(data)
        case "inventory_update":
            let data = try container.decode(InventoryUpdateSSE.self, forKey: .data)
            self = .inventoryUpdate(data)
        case "new_message":
            let data = try container.decode(MessageSSE.self, forKey: .data)
            self = .newMessage(data)
        case "postback":
            let data = try container.decode(PostbackSSE.self, forKey: .data)
            self = .postback(data)
        case "bulk_update":
            let data = try container.decode(BulkUpdateSSE.self, forKey: .data)
            self = .bulkUpdate(data)
        case "error":
            let data = try container.decode(ErrorSSE.self, forKey: .data)
            self = .error(data)
        case "system_status":
            let data = try container.decode(SystemStatusSSE.self, forKey: .data)
            self = .systemStatus(data)
        default:
            // Try legacy format
            let legacyData = try AppMessageData(from: decoder)
            self = .legacy(legacyData)
        }
    }
}

// MARK: - Helper Extensions

extension SSEMessage {
    /// Convert to legacy AppMessageData format for backward compatibility
    func toLegacyFormat() -> AppMessageData? {
        switch self {
        case .legacy(let data):
            return data
        case .newMessage(let message):
            return AppMessageData(type: "new_message", appMessage: message.message)
        case .postback(let postback):
            return AppMessageData(
                type: "postback",
                postbackSenderId: postback.senderId,
                payload: postback.payload,
                timestamp: ISO8601DateFormatter().date(from: postback.timestamp) ?? Date()
            )
        default:
            // Other types don't have direct legacy equivalents
            return nil
        }
    }
    
    /// Check if this is a legacy format message
    var isLegacy: Bool {
        if case .legacy = self {
            return true
        }
        return false
    }
}