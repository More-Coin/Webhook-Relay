import Foundation
import RediStack
import Vapor
import NIOCore

// MARK: - Enhanced Message Queue Protocol

protocol PersistentMessageQueueProtocol: MessageQueue {
    func enqueuePersisted(_ message: PersistedMessage) async throws -> String
    func dequeueWithMetadata() async throws -> PersistedMessage?
    func markAsProcessing(_ messageId: String) async throws
    func markAsCompleted(_ messageId: String) async throws
    func markAsFailed(_ messageId: String, error: String) async throws
    func getDeadLetterMessages(limit: Int) async throws -> [PersistedMessage]
    func replayMessage(_ messageId: String) async throws
    func getStatistics() async throws -> MessageStatistics
}

// MARK: - Enhanced Persistent Message Queue

actor PersistentMessageQueue: PersistentMessageQueueProtocol {
    private let redis: RedisClient
    private let config: MessageQueueConfig
    private let logger: Logger
    private let retryPolicy: RetryPolicy
    
    // Stream keys
    private let mainStreamKey: String
    private let processingStreamKey: String
    private let deadLetterStreamKey: String
    private let retryScheduleKey: String
    
    // Consumer group configuration
    private let consumerGroup: String
    private let consumerName: String
    
    private var isInitialized = false
    
    init(
        redis: RedisClient,
        config: MessageQueueConfig = MessageQueueConfig(),
        retryPolicy: RetryPolicy = .default,
        logger: Logger
    ) {
        self.redis = redis
        self.config = config
        self.retryPolicy = retryPolicy
        self.logger = logger
        
        // Set up stream keys
        self.mainStreamKey = config.streamKey
        self.processingStreamKey = "\(config.streamKey):processing"
        self.deadLetterStreamKey = "\(config.streamKey):dlq"
        self.retryScheduleKey = "\(config.streamKey):retry:schedule"
        
        self.consumerGroup = config.consumerGroup
        self.consumerName = config.consumerName
    }
    
    // MARK: - Initialization
    
    private func ensureInitialized() async throws {
        guard !isInitialized else { return }
        
        do {
            // Create consumer groups for all streams
            let streams = [mainStreamKey, processingStreamKey, deadLetterStreamKey]
            
            for stream in streams {
                _ = try? await redis.xgroup(
                    .create(
                        stream: RedisKey(stream),
                        groupName: consumerGroup,
                        id: "$",
                        makeStream: true
                    )
                )
            }
            
            isInitialized = true
            logger.info("Persistent message queue initialized", metadata: [
                "mainStream": mainStreamKey,
                "consumerGroup": consumerGroup
            ])
        } catch {
            logger.error("Failed to initialize persistent message queue: \(error)")
            throw error
        }
    }
    
    // MARK: - Basic MessageQueue Protocol Implementation
    
    func enqueue(_ message: Data) async throws {
        let persisted = PersistedMessage(
            payload: message,
            maxRetries: retryPolicy.maxRetries
        )
        _ = try await enqueuePersisted(persisted)
    }
    
    func dequeue() async throws -> Data? {
        guard let message = try await dequeueWithMetadata() else {
            return nil
        }
        return message.payload
    }
    
    func acknowledge(_ messageId: String) async throws {
        try await markAsCompleted(messageId)
    }
    
    func size() async throws -> Int {
        try await ensureInitialized()
        
        do {
            let info = try await redis.xinfo(.stream(RedisKey(mainStreamKey)))
            
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
            logger.error("Failed to get queue size: \(error)")
            throw MessageQueueError.sizeCheckFailed(error)
        }
    }
    
    // MARK: - Enhanced Operations
    
    func enqueuePersisted(_ message: PersistedMessage) async throws -> String {
        try await ensureInitialized()
        
        // Check queue capacity
        let currentSize = try await size()
        if currentSize >= config.maxSize {
            logger.warning("Message queue at capacity (\(currentSize)/\(config.maxSize))")
            throw MessageQueueError.queueFull
        }
        
        let fields = message.toRedisFields()
        
        do {
            let streamId = try await redis.xadd(
                to: RedisKey(mainStreamKey),
                fields: fields.mapValues { RESPValue(bulk: $0) },
                id: "*"
            )
            
            logger.info("Enqueued persistent message", metadata: [
                "messageId": message.id,
                "streamId": String(streamId),
                "messageType": message.messageType
            ])
            
            // Track metric
            WebhookRelayMetrics.messagesEnqueued.increment()
            
            return String(streamId)
        } catch {
            logger.error("Failed to enqueue message: \(error)")
            throw MessageQueueError.enqueueFailed(error)
        }
    }
    
    func dequeueWithMetadata() async throws -> PersistedMessage? {
        try await ensureInitialized()
        
        // First, check for messages ready for retry
        if let retryMessage = try await getNextRetryMessage() {
            return retryMessage
        }
        
        // Then get new messages
        do {
            let messages = try await redis.xreadgroup(
                group: consumerGroup,
                consumer: consumerName,
                from: [RedisKey(mainStreamKey): ">"],
                count: 1,
                blockTimeout: .seconds(1)
            )
            
            guard let streamMessages = messages[RedisKey(mainStreamKey)],
                  let message = streamMessages.first else {
                return nil
            }
            
            // Parse message fields
            let fields = message.fields.compactMapValues { respValue -> String? in
                if case .bulkString(let data) = respValue {
                    return String(data: data, encoding: .utf8)
                }
                return nil
            }
            
            var persistedMessage = try PersistedMessage.fromRedisFields(fields)
            persistedMessage = persistedMessage.withStreamId(String(message.id))
            
            // Move to processing stream
            try await moveToProcessing(persistedMessage)
            
            logger.debug("Dequeued message", metadata: [
                "messageId": persistedMessage.id,
                "streamId": String(message.id)
            ])
            
            // Track metric
            WebhookRelayMetrics.messagesDequeued.increment()
            
            return persistedMessage
        } catch {
            logger.error("Failed to dequeue message: \(error)")
            throw MessageQueueError.dequeueFailed(error)
        }
    }
    
    func markAsProcessing(_ messageId: String) async throws {
        try await ensureInitialized()
        
        // Update status in processing stream
        logger.debug("Marking message as processing: \(messageId)")
    }
    
    func markAsCompleted(_ messageId: String) async throws {
        try await ensureInitialized()
        
        do {
            // Acknowledge the message in consumer group
            if let streamId = await getStreamId(for: messageId) {
                _ = try await redis.xack(
                    stream: RedisKey(mainStreamKey),
                    group: consumerGroup,
                    messageIds: [streamId]
                )
                
                // Remove from processing stream
                _ = try await redis.xdel(
                    from: RedisKey(processingStreamKey),
                    messageIds: [streamId]
                )
            }
            
            logger.info("Message completed successfully: \(messageId)")
        } catch {
            logger.error("Failed to mark message as completed: \(error)")
            throw error
        }
    }
    
    func markAsFailed(_ messageId: String, error: String) async throws {
        try await ensureInitialized()
        
        // Get the message from processing stream
        guard let message = await getProcessingMessage(messageId) else {
            logger.warning("Failed message not found in processing: \(messageId)")
            return
        }
        
        let failedMessage = message.withRetry(error: error)
        
        if failedMessage.canRetry {
            // Schedule for retry
            try await scheduleRetry(failedMessage)
            logger.info("Message scheduled for retry", metadata: [
                "messageId": messageId,
                "retryCount": "\(failedMessage.retryCount)",
                "nextRetryAt": failedMessage.nextRetryAt?.iso8601 ?? "unknown"
            ])
        } else {
            // Move to dead letter queue
            try await moveToDeadLetter(failedMessage)
            logger.warning("Message moved to dead letter queue", metadata: [
                "messageId": messageId,
                "retryCount": "\(failedMessage.retryCount)",
                "error": error
            ])
            
            // Track DLQ metric
            WebhookRelayMetrics.messagesFailed.increment(dimensions: [("reason", "max_retries")])
        }
    }
    
    // MARK: - Dead Letter Queue Operations
    
    func getDeadLetterMessages(limit: Int = 100) async throws -> [PersistedMessage] {
        try await ensureInitialized()
        
        let messages = try await redis.xrange(
            from: RedisKey(deadLetterStreamKey),
            lowerBound: "-",
            upperBound: "+",
            count: limit
        )
        
        return try messages.compactMap { message in
            let fields = message.fields.compactMapValues { respValue -> String? in
                if case .bulkString(let data) = respValue {
                    return String(data: data, encoding: .utf8)
                }
                return nil
            }
            
            return try PersistedMessage.fromRedisFields(fields)
        }
    }
    
    func replayMessage(_ messageId: String) async throws {
        try await ensureInitialized()
        
        // Find message in DLQ
        let dlqMessages = try await getDeadLetterMessages(limit: 1000)
        guard let message = dlqMessages.first(where: { $0.id == messageId }) else {
            throw MessageQueueError.dequeueFailed(
                ValidationError(reason: "Message not found in dead letter queue")
            )
        }
        
        // Reset retry count and re-enqueue
        var replayMessage = message
        replayMessage = PersistedMessage(
            payload: message.payload,
            messageType: message.messageType,
            maxRetries: message.maxRetries,
            metadata: message.metadata
        )
        
        _ = try await enqueuePersisted(replayMessage)
        
        // Remove from DLQ
        if let streamId = message.streamId {
            _ = try await redis.xdel(
                from: RedisKey(deadLetterStreamKey),
                messageIds: [streamId]
            )
        }
        
        logger.info("Message replayed from DLQ", metadata: [
            "messageId": messageId
        ])
    }
    
    // MARK: - Statistics
    
    func getStatistics() async throws -> MessageStatistics {
        try await ensureInitialized()
        
        // Get counts from all streams
        let mainSize = try await getStreamSize(mainStreamKey)
        let processingSize = try await getStreamSize(processingStreamKey)
        let dlqSize = try await getStreamSize(deadLetterStreamKey)
        
        // Get pending messages info
        let pendingInfo = try await redis.xpending(
            stream: RedisKey(mainStreamKey),
            group: consumerGroup
        )
        
        let pendingCount: Int
        if case .array(let array) = pendingInfo,
           array.count >= 1,
           case .integer(let count) = array[0] {
            pendingCount = Int(count)
        } else {
            pendingCount = 0
        }
        
        // Calculate rates (simplified for now)
        let processingRate = 0.0 // Would need time-series data
        let errorRate = dlqSize > 0 ? Double(dlqSize) / Double(mainSize + processingSize + dlqSize) : 0.0
        
        return MessageStatistics(
            total: mainSize + processingSize + dlqSize,
            pending: pendingCount,
            processing: processingSize,
            completed: 0, // Would need separate tracking
            failed: 0, // Would need separate tracking
            deadLetter: dlqSize,
            oldestMessage: nil, // Would need to query
            processingRate: processingRate,
            errorRate: errorRate * 100
        )
    }
    
    // MARK: - Private Helper Methods
    
    private func moveToProcessing(_ message: PersistedMessage) async throws {
        let fields = message.withStatus(.processing).toRedisFields()
        
        _ = try await redis.xadd(
            to: RedisKey(processingStreamKey),
            fields: fields.mapValues { RESPValue(bulk: $0) },
            id: message.streamId ?? "*"
        )
    }
    
    private func moveToDeadLetter(_ message: PersistedMessage) async throws {
        let fields = message.withStatus(.deadLetter).toRedisFields()
        
        _ = try await redis.xadd(
            to: RedisKey(deadLetterStreamKey),
            fields: fields.mapValues { RESPValue(bulk: $0) },
            id: "*"
        )
        
        // Remove from processing
        if let streamId = message.streamId {
            _ = try await redis.xdel(
                from: RedisKey(processingStreamKey),
                messageIds: [streamId]
            )
        }
    }
    
    private func scheduleRetry(_ message: PersistedMessage) async throws {
        guard let nextRetryAt = message.nextRetryAt else { return }
        
        let score = nextRetryAt.timeIntervalSince1970
        let member = message.id
        
        _ = try await redis.zadd(
            to: RedisKey(retryScheduleKey),
            items: [(score, RESPValue(bulk: member))]
        )
        
        // Store the full message for retrieval
        let messageKey = "\(retryScheduleKey):\(message.id)"
        let fields = message.toRedisFields()
        
        for (field, value) in fields {
            _ = try await redis.hset(
                field,
                to: value,
                in: RedisKey(messageKey)
            )
        }
        
        // Set expiration
        _ = try await redis.expire(
            RedisKey(messageKey),
            after: .seconds(Int64(config.ttl))
        )
    }
    
    private func getNextRetryMessage() async throws -> PersistedMessage? {
        let now = Date().timeIntervalSince1970
        
        // Get messages ready for retry
        let readyMessages = try await redis.zrangebyscore(
            from: RedisKey(retryScheduleKey),
            lowerBound: .inclusive(0),
            upperBound: .inclusive(now),
            limit: (0, 1)
        )
        
        guard let messageId = readyMessages.first,
              case .bulkString(let idData) = messageId,
              let id = String(data: idData, encoding: .utf8) else {
            return nil
        }
        
        // Get the full message
        let messageKey = "\(retryScheduleKey):\(id)"
        let fields = try await redis.hgetall(from: RedisKey(messageKey))
        
        let stringFields = fields.compactMapValues { value -> String? in
            if case .bulkString(let data) = value {
                return String(data: data, encoding: .utf8)
            }
            return nil
        }
        
        let message = try PersistedMessage.fromRedisFields(stringFields)
        
        // Remove from retry schedule
        _ = try await redis.zrem(id, from: RedisKey(retryScheduleKey))
        _ = try await redis.del(RedisKey(messageKey))
        
        // Re-enqueue for processing
        let updatedMessage = message.withStatus(.pending)
        _ = try await enqueuePersisted(updatedMessage)
        
        return updatedMessage
    }
    
    private func getStreamId(for messageId: String) async -> String? {
        // This would need to track message ID to stream ID mapping
        // For now, simplified implementation
        return nil
    }
    
    private func getProcessingMessage(_ messageId: String) async -> PersistedMessage? {
        // Get message from processing stream by ID
        // Simplified implementation
        return nil
    }
    
    private func getStreamSize(_ streamKey: String) async throws -> Int {
        let info = try await redis.xinfo(.stream(RedisKey(streamKey)))
        
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
    }
}