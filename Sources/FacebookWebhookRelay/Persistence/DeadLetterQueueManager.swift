import Foundation
import Vapor
import RediStack

// MARK: - Dead Letter Queue Manager

/// Manages failed messages that have exceeded retry limits
actor DeadLetterQueueManager {
    private let redis: RedisClient
    private let messageQueue: PersistentMessageQueueProtocol
    private let logger: Logger
    private let config: DLQConfig
    
    // Alert handlers
    private var alertHandlers: [(PersistedMessage) async -> Void] = []
    
    struct DLQConfig {
        let alertThreshold: Int
        let retentionDays: Int
        let cleanupInterval: TimeInterval
        
        static let `default` = DLQConfig(
            alertThreshold: 10,
            retentionDays: 7,
            cleanupInterval: 3600 // 1 hour
        )
    }
    
    init(
        redis: RedisClient,
        messageQueue: PersistentMessageQueueProtocol,
        config: DLQConfig = .default,
        logger: Logger
    ) {
        self.redis = redis
        self.messageQueue = messageQueue
        self.config = config
        self.logger = logger
    }
    
    // MARK: - DLQ Operations
    
    func addToDeadLetter(_ message: PersistedMessage, reason: String) async throws {
        let dlqKey = getDeadLetterStreamKey()
        
        // Update message with DLQ status
        var dlqMessage = message.withStatus(.deadLetter)
        dlqMessage.error = reason
        
        // Add to DLQ stream
        let fields = dlqMessage.toRedisFields()
        let streamId = try await redis.xadd(
            to: RedisKey(dlqKey),
            fields: fields.mapValues { RESPValue(bulk: $0) },
            id: "*"
        )
        
        logger.warning("Message added to dead letter queue", metadata: [
            "messageId": message.id,
            "streamId": String(streamId),
            "reason": reason,
            "retryCount": "\(message.retryCount)"
        ])
        
        // Track metric
        WebhookRelayMetrics.messagesFailed.increment(dimensions: [
            ("reason", reason.replacingOccurrences(of: " ", with: "_").lowercased())
        ])
        
        // Check if we need to alert
        await checkAlertThreshold()
        
        // Trigger alert handlers
        for handler in alertHandlers {
            await handler(dlqMessage)
        }
    }
    
    func getMessages(
        limit: Int = 100,
        status: MessageStatus? = nil,
        fromDate: Date? = nil,
        toDate: Date? = nil
    ) async throws -> [PersistedMessage] {
        let dlqKey = getDeadLetterStreamKey()
        
        // Get messages from stream
        let messages = try await redis.xrange(
            from: RedisKey(dlqKey),
            lowerBound: fromDate?.timeIntervalSince1970.description ?? "-",
            upperBound: toDate?.timeIntervalSince1970.description ?? "+",
            count: limit
        )
        
        let persistedMessages = try messages.compactMap { message -> PersistedMessage? in
            let fields = message.fields.compactMapValues { respValue -> String? in
                if case .bulkString(let data) = respValue {
                    return String(data: data, encoding: .utf8)
                }
                return nil
            }
            
            let persistedMessage = try PersistedMessage.fromRedisFields(fields)
            
            // Filter by status if provided
            if let status = status, persistedMessage.status != status {
                return nil
            }
            
            return persistedMessage
        }
        
        return persistedMessages
    }
    
    func replayMessage(_ messageId: String) async throws {
        let dlqKey = getDeadLetterStreamKey()
        
        // Find the message
        let messages = try await getMessages(limit: 1000)
        guard let message = messages.first(where: { $0.id == messageId }) else {
            throw ValidationError(reason: "Message not found in dead letter queue")
        }
        
        // Create fresh message for replay
        let replayMessage = PersistedMessage(
            payload: message.payload,
            messageType: message.messageType,
            maxRetries: message.maxRetries,
            metadata: message.metadata
        )
        
        // Re-enqueue
        _ = try await messageQueue.enqueuePersisted(replayMessage)
        
        // Remove from DLQ
        if let streamId = message.streamId {
            _ = try await redis.xdel(
                from: RedisKey(dlqKey),
                messageIds: [streamId]
            )
        }
        
        logger.info("Message replayed from DLQ", metadata: [
            "messageId": messageId,
            "originalRetryCount": "\(message.retryCount)"
        ])
        
        // Track metric
        WebhookRelayMetrics.messagesEnqueued.increment(dimensions: [("type", "dlq_replay")])
    }
    
    func replayAll(filter: MessageFilter? = nil) async throws -> Int {
        let messages = try await getMessages(limit: filter?.limit ?? 1000)
        var replayedCount = 0
        
        for message in messages {
            // Apply filter
            if let status = filter?.status, message.status != status {
                continue
            }
            if let messageType = filter?.messageType, message.messageType != messageType {
                continue
            }
            
            do {
                try await replayMessage(message.id)
                replayedCount += 1
            } catch {
                logger.error("Failed to replay message from DLQ", metadata: [
                    "messageId": message.id,
                    "error": "\(error)"
                ])
            }
        }
        
        logger.info("Replayed messages from DLQ", metadata: [
            "count": "\(replayedCount)"
        ])
        
        return replayedCount
    }
    
    func purgeMessage(_ messageId: String) async throws {
        let dlqKey = getDeadLetterStreamKey()
        
        // Find and remove the message
        let messages = try await redis.xrange(
            from: RedisKey(dlqKey),
            lowerBound: "-",
            upperBound: "+"
        )
        
        for message in messages {
            let fields = message.fields.compactMapValues { respValue -> String? in
                if case .bulkString(let data) = respValue {
                    return String(data: data, encoding: .utf8)
                }
                return nil
            }
            
            if fields["id"] == messageId {
                _ = try await redis.xdel(
                    from: RedisKey(dlqKey),
                    messageIds: [String(message.id)]
                )
                
                logger.info("Purged message from DLQ", metadata: ["messageId": messageId])
                return
            }
        }
        
        throw ValidationError(reason: "Message not found in dead letter queue")
    }
    
    // MARK: - Monitoring & Alerting
    
    func getStatistics() async throws -> DLQStatistics {
        let dlqKey = getDeadLetterStreamKey()
        
        // Get stream info
        let info = try await redis.xinfo(.stream(RedisKey(dlqKey)))
        var length = 0
        
        if case .array(let infoArray) = info {
            for i in stride(from: 0, to: infoArray.count - 1, by: 2) {
                if case .bulkString(let key) = infoArray[i],
                   key == "length",
                   case .integer(let len) = infoArray[i + 1] {
                    length = Int(len)
                }
            }
        }
        
        // Get messages for detailed stats
        let messages = try await getMessages(limit: 1000)
        
        // Group by error type
        var errorCounts: [String: Int] = [:]
        for message in messages {
            let error = message.error ?? "unknown"
            errorCounts[error, default: 0] += 1
        }
        
        // Find oldest message
        let oldestMessage = messages.min(by: { $0.createdAt < $1.createdAt })
        
        return DLQStatistics(
            totalMessages: length,
            oldestMessageDate: oldestMessage?.createdAt,
            errorBreakdown: errorCounts,
            averageRetryCount: messages.isEmpty ? 0 : 
                Double(messages.reduce(0) { $0 + $1.retryCount }) / Double(messages.count)
        )
    }
    
    func onMessage(_ handler: @escaping (PersistedMessage) async -> Void) {
        alertHandlers.append(handler)
    }
    
    private func checkAlertThreshold() async {
        do {
            let stats = try await getStatistics()
            
            if stats.totalMessages >= config.alertThreshold {
                logger.critical("Dead letter queue threshold exceeded", metadata: [
                    "threshold": "\(config.alertThreshold)",
                    "currentSize": "\(stats.totalMessages)"
                ])
                
                // Here you could trigger additional alerts:
                // - Send email
                // - Post to Slack
                // - Create PagerDuty incident
            }
        } catch {
            logger.error("Failed to check DLQ alert threshold: \(error)")
        }
    }
    
    // MARK: - Cleanup
    
    func cleanupOldMessages() async throws {
        let dlqKey = getDeadLetterStreamKey()
        let cutoffDate = Date().addingTimeInterval(-Double(config.retentionDays * 86400))
        
        // Get old messages
        let messages = try await redis.xrange(
            from: RedisKey(dlqKey),
            lowerBound: "-",
            upperBound: String(cutoffDate.timeIntervalSince1970)
        )
        
        guard !messages.isEmpty else {
            logger.info("No old messages to clean up in DLQ")
            return
        }
        
        // Remove old messages
        let messageIds = messages.map { String($0.id) }
        for chunk in messageIds.chunked(into: 100) {
            _ = try await redis.xdel(
                from: RedisKey(dlqKey),
                messageIds: chunk
            )
        }
        
        logger.info("Cleaned up old messages from DLQ", metadata: [
            "count": "\(messages.count)",
            "cutoffDate": cutoffDate.iso8601
        ])
    }
    
    // MARK: - Helper Methods
    
    private func getDeadLetterStreamKey() -> String {
        return "webhook-messages:dlq"
    }
}

// MARK: - Supporting Types

struct DLQStatistics: Content {
    let totalMessages: Int
    let oldestMessageDate: Date?
    let errorBreakdown: [String: Int]
    let averageRetryCount: Double
}

// MARK: - Array Extension for Chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Application Extension

extension Application {
    struct DLQManagerKey: StorageKey {
        typealias Value = DeadLetterQueueManager
    }
    
    var deadLetterQueueManager: DeadLetterQueueManager? {
        get {
            storage[DLQManagerKey.self]
        }
        set {
            storage[DLQManagerKey.self] = newValue
        }
    }
    
    /// Set up dead letter queue manager
    func setupDeadLetterQueueManager() {
        guard let redis = self.redis else {
            logger.warning("Cannot setup DLQ manager - Redis not configured")
            return
        }
        
        guard let messageQueue = self.messageQueue as? PersistentMessageQueueProtocol else {
            logger.warning("Cannot setup DLQ manager - PersistentMessageQueue not configured")
            return
        }
        
        let dlqManager = DeadLetterQueueManager(
            redis: redis,
            messageQueue: messageQueue,
            logger: logger
        )
        
        self.deadLetterQueueManager = dlqManager
        
        // Set up alert handler
        Task {
            await dlqManager.onMessage { [weak self] message in
                self?.logger.warning("New message in DLQ", metadata: [
                    "messageId": message.id,
                    "error": message.error ?? "unknown",
                    "retryCount": "\(message.retryCount)"
                ])
                
                // Additional alerting could go here
            }
        }
        
        // Set up periodic cleanup
        let cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(dlqManager.config.cleanupInterval) * 1_000_000_000)
                
                do {
                    try await self?.deadLetterQueueManager?.cleanupOldMessages()
                } catch {
                    self?.logger.error("DLQ cleanup failed: \(error)")
                }
            }
        }
        
        // Ensure clean shutdown
        self.lifecycle.use(
            LifecycleHandler(
                shutdownAsync: { app in
                    app.logger.info("Stopping DLQ cleanup task")
                    cleanupTask.cancel()
                }
            )
        )
        
        logger.info("Dead letter queue manager configured")
    }
}