import Foundation
import RediStack
import Vapor
import NIOCore

// MARK: - MessageQueue Protocol

protocol MessageQueue {
    func enqueue(_ message: Data) async throws
    func dequeue() async throws -> Data?
    func acknowledge(_ messageId: String) async throws
    func size() async throws -> Int
}

// MARK: - Message Queue Configuration

struct MessageQueueConfig {
    let maxSize: Int
    let ttl: TimeInterval
    let streamKey: String
    let consumerGroup: String
    let consumerName: String
    
    init(
        maxSize: Int = 10000,
        ttl: TimeInterval = 3600,
        streamKey: String = "webhook-messages",
        consumerGroup: String = "webhook-processors",
        consumerName: String = "relay-consumer"
    ) {
        self.maxSize = maxSize
        self.ttl = ttl
        self.streamKey = streamKey
        self.consumerGroup = consumerGroup
        self.consumerName = consumerName
    }
}

// MARK: - Redis Message Queue Implementation

actor RedisMessageQueue: MessageQueue {
    private let redis: RedisClient
    private let config: MessageQueueConfig
    private let logger: Logger
    private var isInitialized = false
    
    init(redis: RedisClient, config: MessageQueueConfig = MessageQueueConfig(), logger: Logger) {
        self.redis = redis
        self.config = config
        self.logger = logger
    }
    
    // MARK: - Initialization
    
    private func ensureInitialized() async throws {
        guard !isInitialized else { return }
        
        do {
            // Create consumer group if it doesn't exist
            // This will fail if the group already exists, which is fine
            _ = try? await redis.xgroup(
                .create(
                    stream: RedisKey(config.streamKey),
                    groupName: config.consumerGroup,
                    id: "$",
                    makeStream: true
                )
            )
            
            isInitialized = true
            logger.info("Redis message queue initialized - stream: \\(config.streamKey), group: \\(config.consumerGroup)")
        } catch {
            logger.error("Failed to initialize Redis message queue: \\(error)")
            throw error
        }
    }
    
    // MARK: - Queue Operations
    
    func enqueue(_ message: Data) async throws {
        try await ensureInitialized()
        
        // Check queue size before adding
        let currentSize = try await size()
        if currentSize >= config.maxSize {
            logger.warning("Message queue is at capacity (\\(currentSize)/\\(config.maxSize)), rejecting message")
            throw MessageQueueError.queueFull
        }
        
        let messageId = UUID().uuidString
        let timestamp = Date().timeIntervalSince1970
        
        let fields: [String: RESPValue] = [
            "id": .init(bulk: messageId),
            "data": .init(bulk: message),
            "timestamp": .init(bulk: String(timestamp)),
            "ttl": .init(bulk: String(Int(timestamp + config.ttl)))
        ]
        
        do {
            let streamId = try await redis.xadd(
                to: RedisKey(config.streamKey),
                fields: fields,
                id: "*" // Auto-generate ID
            )
            
            logger.debug("Enqueued message \\(messageId) with stream ID: \\(streamId)")
        } catch {
            logger.error("Failed to enqueue message: \\(error)")
            throw MessageQueueError.enqueueFailed(error)
        }
    }
    
    func dequeue() async throws -> Data? {
        try await ensureInitialized()
        
        do {
            let messages = try await redis.xreadgroup(
                group: config.consumerGroup,
                consumer: config.consumerName,
                from: [RedisKey(config.streamKey): ">"],
                count: 1,
                blockTimeout: .seconds(1)
            )
            
            guard let streamMessages = messages[RedisKey(config.streamKey)],
                  let message = streamMessages.first else {
                return nil
            }
            
            // Extract message data
            if let dataValue = message.fields["data"],
               case .bulkString(let data) = dataValue {
                
                logger.debug("Dequeued message with ID: \\(message.id)")
                return data
            } else {
                logger.warning("Dequeued message with invalid data format: \\(message.id)")
                // Acknowledge invalid message to remove it from queue
                try await acknowledge(String(message.id))
                return nil
            }
            
        } catch {
            logger.error("Failed to dequeue message: \\(error)")
            throw MessageQueueError.dequeueFailed(error)
        }
    }
    
    func acknowledge(_ messageId: String) async throws {
        try await ensureInitialized()
        
        do {
            let acknowledgedCount = try await redis.xack(
                stream: RedisKey(config.streamKey),
                group: config.consumerGroup,
                messageIds: [messageId]
            )
            
            if acknowledgedCount > 0 {
                logger.debug("Acknowledged message: \\(messageId)")
            } else {
                logger.warning("Failed to acknowledge message (already processed?): \\(messageId)")
            }
        } catch {
            logger.error("Failed to acknowledge message \\(messageId): \\(error)")
            throw MessageQueueError.acknowledgeFailed(error)
        }
    }
    
    func size() async throws -> Int {
        try await ensureInitialized()
        
        do {
            let info = try await redis.xinfo(.stream(RedisKey(config.streamKey)))
            
            // Parse stream info to get length
            if case .array(let infoArray) = info {
                for i in stride(from: 0, to: infoArray.count - 1, by: 2) {
                    if case .bulkString(let key) = infoArray[i],
                       key == "length",
                       case .integer(let length) = infoArray[i + 1] {
                        return Int(length)
                    }
                }
            }
            
            return 0
        } catch {
            logger.error("Failed to get queue size: \\(error)")
            throw MessageQueueError.sizeCheckFailed(error)
        }
    }
    
    // MARK: - Health Check
    
    func healthCheck() async throws -> QueueHealth {
        let queueSize = try await size()
        let isHealthy = queueSize < config.maxSize
        
        return QueueHealth(
            size: queueSize,
            maxSize: config.maxSize,
            isHealthy: isHealthy,
            utilizationPercent: Double(queueSize) / Double(config.maxSize) * 100
        )
    }
    
    // MARK: - Cleanup
    
    func cleanup() async throws {
        try await ensureInitialized()
        
        let now = Date().timeIntervalSince1970
        
        // Clean up expired messages
        // Note: This is a simple implementation. In production, you might want
        // a more sophisticated cleanup process
        logger.info("Starting queue cleanup for expired messages")
        
        // This would require iterating through messages and checking TTL
        // For now, we rely on Redis's built-in expiration
    }
}

// MARK: - In-Memory Message Queue (Fallback)

actor InMemoryMessageQueue: MessageQueue {
    private var messages: [QueuedMessage] = []
    private var acknowledgedIds: Set<String> = []
    private let config: MessageQueueConfig
    private let logger: Logger
    
    init(config: MessageQueueConfig = MessageQueueConfig(), logger: Logger) {
        self.config = config
        self.logger = logger
        logger.info("Initialized in-memory message queue (fallback mode)")
    }
    
    func enqueue(_ message: Data) async throws {
        // Clean up expired messages first
        cleanupExpired()
        
        if messages.count >= config.maxSize {
            logger.warning("In-memory queue is at capacity (\\(messages.count)/\\(config.maxSize))")
            throw MessageQueueError.queueFull
        }
        
        let queuedMessage = QueuedMessage(
            id: UUID().uuidString,
            data: message,
            enqueuedAt: Date(),
            expiresAt: Date().addingTimeInterval(config.ttl)
        )
        
        messages.append(queuedMessage)
        logger.debug("Enqueued message \\(queuedMessage.id) (in-memory)")
    }
    
    func dequeue() async throws -> Data? {
        cleanupExpired()
        
        guard let message = messages.first(where: { !acknowledgedIds.contains($0.id) }) else {
            return nil
        }
        
        logger.debug("Dequeued message \\(message.id) (in-memory)")
        return message.data
    }
    
    func acknowledge(_ messageId: String) async throws {
        acknowledgedIds.insert(messageId)
        
        // Remove acknowledged messages
        messages.removeAll { acknowledgedIds.contains($0.id) }
        
        logger.debug("Acknowledged message \\(messageId) (in-memory)")
    }
    
    func size() async throws -> Int {
        cleanupExpired()
        return messages.count - acknowledgedIds.count
    }
    
    private func cleanupExpired() {
        let now = Date()
        let beforeCount = messages.count
        
        messages.removeAll { $0.expiresAt < now }
        
        if messages.count < beforeCount {
            logger.debug("Cleaned up \\(beforeCount - messages.count) expired messages")
        }
    }
}

// MARK: - Supporting Types

struct QueuedMessage {
    let id: String
    let data: Data
    let enqueuedAt: Date
    let expiresAt: Date
}

struct QueueHealth: Content {
    let size: Int
    let maxSize: Int
    let isHealthy: Bool
    let utilizationPercent: Double
}

// MARK: - Errors

enum MessageQueueError: Error, LocalizedError {
    case queueFull
    case enqueueFailed(Error)
    case dequeueFailed(Error)
    case acknowledgeFailed(Error)
    case sizeCheckFailed(Error)
    case redisConnectionFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .queueFull:
            return "Message queue is at capacity"
        case .enqueueFailed(let error):
            return "Failed to enqueue message: \\(error.localizedDescription)"
        case .dequeueFailed(let error):
            return "Failed to dequeue message: \\(error.localizedDescription)"
        case .acknowledgeFailed(let error):
            return "Failed to acknowledge message: \\(error.localizedDescription)"
        case .sizeCheckFailed(let error):
            return "Failed to check queue size: \\(error.localizedDescription)"
        case .redisConnectionFailed(let error):
            return "Redis connection failed: \\(error.localizedDescription)"
        }
    }
}

// MARK: - Application Extension

extension Application {
    struct MessageQueueKey: StorageKey {
        typealias Value = MessageQueue
    }
    
    var messageQueue: MessageQueue {
        get {
            guard let queue = storage[MessageQueueKey.self] else {
                fatalError("MessageQueue not configured. Configure with app.messageQueue = ...")
            }
            return queue
        }
        set {
            storage[MessageQueueKey.self] = newValue
        }
    }
}