import Foundation
import Vapor

// MARK: - Message Status

enum MessageStatus: String, Codable {
    case pending = "pending"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"
    case deadLetter = "dead_letter"
    
    var canRetry: Bool {
        switch self {
        case .failed, .processing:
            return true
        case .pending, .completed, .deadLetter:
            return false
        }
    }
}

// MARK: - Persisted Message

struct PersistedMessage: Codable {
    let id: String
    let streamId: String?
    let payload: Data
    let messageType: String
    let retryCount: Int
    let maxRetries: Int
    let createdAt: Date
    let updatedAt: Date
    let nextRetryAt: Date?
    let status: MessageStatus
    let error: String?
    let metadata: [String: String]
    
    // Computed properties
    var canRetry: Bool {
        return status.canRetry && retryCount < maxRetries
    }
    
    var isExpired: Bool {
        // Messages expire after 24 hours
        return Date().timeIntervalSince(createdAt) > 86400
    }
    
    // Initialize new message
    init(
        payload: Data,
        messageType: String = "webhook",
        maxRetries: Int = 5,
        metadata: [String: String] = [:]
    ) {
        self.id = UUID().uuidString
        self.streamId = nil
        self.payload = payload
        self.messageType = messageType
        self.retryCount = 0
        self.maxRetries = maxRetries
        self.createdAt = Date()
        self.updatedAt = Date()
        self.nextRetryAt = nil
        self.status = .pending
        self.error = nil
        self.metadata = metadata
    }
    
    // Create copy with updated fields
    func withRetry(error: String) -> PersistedMessage {
        var updated = self
        updated.retryCount += 1
        updated.updatedAt = Date()
        updated.status = retryCount + 1 >= maxRetries ? .deadLetter : .failed
        updated.error = error
        updated.nextRetryAt = calculateNextRetryTime()
        return updated
    }
    
    func withStatus(_ status: MessageStatus) -> PersistedMessage {
        var updated = self
        updated.status = status
        updated.updatedAt = Date()
        return updated
    }
    
    func withStreamId(_ streamId: String) -> PersistedMessage {
        var updated = self
        updated.streamId = streamId
        return updated
    }
    
    // Calculate exponential backoff
    private func calculateNextRetryTime() -> Date {
        let baseDelay: TimeInterval = 1.0 // 1 second
        let maxDelay: TimeInterval = 300.0 // 5 minutes
        
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s...
        let delay = min(baseDelay * pow(2.0, Double(retryCount)), maxDelay)
        
        // Add jitter (±20%)
        let jitter = delay * Double.random(in: -0.2...0.2)
        let totalDelay = delay + jitter
        
        return Date().addingTimeInterval(totalDelay)
    }
}

// MARK: - Message Batch

struct MessageBatch {
    let messages: [PersistedMessage]
    let cursor: String?
    let hasMore: Bool
    
    var count: Int {
        return messages.count
    }
}

// MARK: - Message Filter

struct MessageFilter {
    let status: MessageStatus?
    let messageType: String?
    let fromDate: Date?
    let toDate: Date?
    let limit: Int
    
    init(
        status: MessageStatus? = nil,
        messageType: String? = nil,
        fromDate: Date? = nil,
        toDate: Date? = nil,
        limit: Int = 100
    ) {
        self.status = status
        self.messageType = messageType
        self.fromDate = fromDate
        self.toDate = toDate
        self.limit = min(limit, 1000) // Cap at 1000
    }
}

// MARK: - Retry Policy

struct RetryPolicy {
    let maxRetries: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let jitterFactor: Double
    
    static let `default` = RetryPolicy(
        maxRetries: 5,
        baseDelay: 1.0,
        maxDelay: 300.0,
        jitterFactor: 0.2
    )
    
    static let aggressive = RetryPolicy(
        maxRetries: 10,
        baseDelay: 0.5,
        maxDelay: 60.0,
        jitterFactor: 0.3
    )
    
    static let conservative = RetryPolicy(
        maxRetries: 3,
        baseDelay: 5.0,
        maxDelay: 600.0,
        jitterFactor: 0.1
    )
}

// MARK: - Message Statistics

struct MessageStatistics: Content {
    let total: Int
    let pending: Int
    let processing: Int
    let completed: Int
    let failed: Int
    let deadLetter: Int
    let oldestMessage: Date?
    let processingRate: Double // messages per minute
    let errorRate: Double // percentage
}

// MARK: - Redis Field Helpers

extension PersistedMessage {
    // Convert to Redis fields for storage
    func toRedisFields() -> [String: String] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        var fields: [String: String] = [
            "id": id,
            "payload": payload.base64EncodedString(),
            "messageType": messageType,
            "retryCount": String(retryCount),
            "maxRetries": String(maxRetries),
            "createdAt": createdAt.iso8601,
            "updatedAt": updatedAt.iso8601,
            "status": status.rawValue
        ]
        
        if let streamId = streamId {
            fields["streamId"] = streamId
        }
        
        if let nextRetryAt = nextRetryAt {
            fields["nextRetryAt"] = nextRetryAt.iso8601
        }
        
        if let error = error {
            fields["error"] = error
        }
        
        // Encode metadata as JSON
        if !metadata.isEmpty,
           let metadataData = try? encoder.encode(metadata),
           let metadataString = String(data: metadataData, encoding: .utf8) {
            fields["metadata"] = metadataString
        }
        
        return fields
    }
    
    // Create from Redis fields
    static func fromRedisFields(_ fields: [String: String]) throws -> PersistedMessage {
        guard let id = fields["id"],
              let payloadString = fields["payload"],
              let payload = Data(base64Encoded: payloadString),
              let messageType = fields["messageType"],
              let retryCountString = fields["retryCount"],
              let retryCount = Int(retryCountString),
              let maxRetriesString = fields["maxRetries"],
              let maxRetries = Int(maxRetriesString),
              let createdAtString = fields["createdAt"],
              let updatedAtString = fields["updatedAt"],
              let statusString = fields["status"],
              let status = MessageStatus(rawValue: statusString) else {
            throw MessageQueueError.dequeueFailed(
                ValidationError(reason: "Invalid message fields")
            )
        }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let createdAt = formatter.date(from: createdAtString),
              let updatedAt = formatter.date(from: updatedAtString) else {
            throw MessageQueueError.dequeueFailed(
                ValidationError(reason: "Invalid date format")
            )
        }
        
        let nextRetryAt = fields["nextRetryAt"].flatMap { formatter.date(from: $0) }
        
        // Decode metadata
        let decoder = JSONDecoder()
        let metadata: [String: String] = fields["metadata"].flatMap { metadataString in
            guard let data = metadataString.data(using: .utf8),
                  let decoded = try? decoder.decode([String: String].self, from: data) else {
                return nil
            }
            return decoded
        } ?? [:]
        
        return PersistedMessage(
            id: id,
            streamId: fields["streamId"],
            payload: payload,
            messageType: messageType,
            retryCount: retryCount,
            maxRetries: maxRetries,
            createdAt: createdAt,
            updatedAt: updatedAt,
            nextRetryAt: nextRetryAt,
            status: status,
            error: fields["error"],
            metadata: metadata
        )
    }
}

// MARK: - Validation Error

struct ValidationError: Error {
    let reason: String
}