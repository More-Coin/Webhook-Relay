import Foundation
import Vapor
import RediStack

// MARK: - Message Retry Scheduler

/// Handles scheduling and processing of message retries
actor MessageRetryScheduler {
    private let redis: RedisClient
    private let messageQueue: PersistentMessageQueueProtocol
    private let logger: Logger
    private let config: RetrySchedulerConfig
    
    private var isRunning = false
    private var schedulerTask: Task<Void, Never>?
    
    struct RetrySchedulerConfig {
        let checkInterval: TimeInterval
        let batchSize: Int
        let maxConcurrentRetries: Int
        
        static let `default` = RetrySchedulerConfig(
            checkInterval: 5.0, // Check every 5 seconds
            batchSize: 10,
            maxConcurrentRetries: 5
        )
    }
    
    init(
        redis: RedisClient,
        messageQueue: PersistentMessageQueueProtocol,
        config: RetrySchedulerConfig = .default,
        logger: Logger
    ) {
        self.redis = redis
        self.messageQueue = messageQueue
        self.config = config
        self.logger = logger
    }
    
    // MARK: - Scheduler Control
    
    func start() {
        guard !isRunning else {
            logger.info("Retry scheduler already running")
            return
        }
        
        isRunning = true
        logger.info("Starting message retry scheduler")
        
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.processRetries()
                
                // Sleep for check interval
                try? await Task.sleep(nanoseconds: UInt64(self?.config.checkInterval ?? 5.0) * 1_000_000_000)
            }
        }
    }
    
    func stop() {
        isRunning = false
        schedulerTask?.cancel()
        schedulerTask = nil
        logger.info("Stopped message retry scheduler")
    }
    
    // MARK: - Retry Processing
    
    private func processRetries() async {
        do {
            let retryKey = getRetryScheduleKey()
            let now = Date().timeIntervalSince1970
            
            // Get messages ready for retry
            let readyMessages = try await redis.zrangebyscore(
                from: RedisKey(retryKey),
                lowerBound: .inclusive(0),
                upperBound: .inclusive(now),
                limit: (0, config.batchSize),
                includeScores: true
            )
            
            guard !readyMessages.isEmpty else { return }
            
            logger.info("Found \(readyMessages.count / 2) messages ready for retry")
            
            // Process retries with concurrency control
            await withTaskGroup(of: Void.self) { group in
                var activeRetries = 0
                
                // Process pairs (value, score)
                for i in stride(from: 0, to: readyMessages.count, by: 2) {
                    guard i + 1 < readyMessages.count else { continue }
                    
                    let messageValue = readyMessages[i]
                    let scoreValue = readyMessages[i + 1]
                    
                    guard case .bulkString(let idData) = messageValue,
                          let messageId = String(data: idData, encoding: .utf8),
                          case .double(let score) = scoreValue else {
                        continue
                    }
                    
                    // Wait if we've hit concurrency limit
                    while activeRetries >= config.maxConcurrentRetries {
                        await group.next()
                        activeRetries -= 1
                    }
                    
                    activeRetries += 1
                    group.addTask { [weak self] in
                        await self?.retryMessage(messageId: messageId, scheduledTime: score)
                    }
                }
            }
        } catch {
            logger.error("Error processing retries: \(error)")
        }
    }
    
    private func retryMessage(messageId: String, scheduledTime: Double) async {
        do {
            logger.info("Retrying message", metadata: [
                "messageId": messageId,
                "scheduledTime": "\(Date(timeIntervalSince1970: scheduledTime).iso8601)"
            ])
            
            let retryKey = getRetryScheduleKey()
            let messageKey = "\(retryKey):\(messageId)"
            
            // Get the full message
            let fields = try await redis.hgetall(from: RedisKey(messageKey))
            
            let stringFields = fields.compactMapValues { value -> String? in
                if case .bulkString(let data) = value {
                    return String(data: data, encoding: .utf8)
                }
                return nil
            }
            
            guard !stringFields.isEmpty else {
                logger.warning("Retry message not found", metadata: ["messageId": messageId])
                // Remove from schedule
                _ = try await redis.zrem(messageId, from: RedisKey(retryKey))
                return
            }
            
            let message = try PersistedMessage.fromRedisFields(stringFields)
            
            // Re-enqueue the message
            let updatedMessage = message.withStatus(.pending)
            _ = try await messageQueue.enqueuePersisted(updatedMessage)
            
            // Clean up retry data
            _ = try await redis.zrem(messageId, from: RedisKey(retryKey))
            _ = try await redis.del(RedisKey(messageKey))
            
            logger.info("Message successfully re-enqueued for retry", metadata: [
                "messageId": messageId,
                "retryCount": "\(message.retryCount)"
            ])
            
            // Track metric
            WebhookRelayMetrics.messagesEnqueued.increment(dimensions: [("type", "retry")])
            
        } catch {
            logger.error("Failed to retry message", metadata: [
                "messageId": messageId,
                "error": "\(error)"
            ])
        }
    }
    
    // MARK: - Retry Management
    
    func scheduleRetry(_ message: PersistedMessage) async throws {
        guard let nextRetryAt = message.nextRetryAt else {
            throw ValidationError(reason: "Message has no retry time")
        }
        
        let retryKey = getRetryScheduleKey()
        let score = nextRetryAt.timeIntervalSince1970
        
        // Add to sorted set
        _ = try await redis.zadd(
            to: RedisKey(retryKey),
            items: [(score, RESPValue(bulk: message.id))]
        )
        
        // Store full message
        let messageKey = "\(retryKey):\(message.id)"
        let fields = message.toRedisFields()
        
        for (field, value) in fields {
            _ = try await redis.hset(
                field,
                to: value,
                in: RedisKey(messageKey)
            )
        }
        
        // Set expiration (24 hours)
        _ = try await redis.expire(
            RedisKey(messageKey),
            after: .seconds(86400)
        )
        
        logger.info("Message scheduled for retry", metadata: [
            "messageId": message.id,
            "retryAt": nextRetryAt.iso8601,
            "retryCount": "\(message.retryCount)"
        ])
    }
    
    func cancelRetry(_ messageId: String) async throws {
        let retryKey = getRetryScheduleKey()
        let messageKey = "\(retryKey):\(messageId)"
        
        // Remove from schedule and delete message data
        _ = try await redis.zrem(messageId, from: RedisKey(retryKey))
        _ = try await redis.del(RedisKey(messageKey))
        
        logger.info("Cancelled retry for message", metadata: ["messageId": messageId])
    }
    
    func getPendingRetries() async throws -> [(messageId: String, retryAt: Date)] {
        let retryKey = getRetryScheduleKey()
        
        let pending = try await redis.zrange(
            from: RedisKey(retryKey),
            lowerBound: 0,
            upperBound: -1,
            includeScores: true
        )
        
        var results: [(messageId: String, retryAt: Date)] = []
        
        // Process pairs
        for i in stride(from: 0, to: pending.count, by: 2) {
            guard i + 1 < pending.count else { continue }
            
            if case .bulkString(let idData) = pending[i],
               let messageId = String(data: idData, encoding: .utf8),
               case .double(let score) = pending[i + 1] {
                let retryAt = Date(timeIntervalSince1970: score)
                results.append((messageId: messageId, retryAt: retryAt))
            }
        }
        
        return results
    }
    
    // MARK: - Helper Methods
    
    private func getRetryScheduleKey() -> String {
        // Use the same key pattern as the message queue
        return "webhook-messages:retry:schedule"
    }
}

// MARK: - Application Extension

extension Application {
    struct RetrySchedulerKey: StorageKey {
        typealias Value = MessageRetryScheduler
    }
    
    var messageRetryScheduler: MessageRetryScheduler? {
        get {
            storage[RetrySchedulerKey.self]
        }
        set {
            storage[RetrySchedulerKey.self] = newValue
        }
    }
    
    /// Set up message retry scheduler
    func setupMessageRetryScheduler() {
        guard let redis = self.redis else {
            logger.warning("Cannot setup retry scheduler - Redis not configured")
            return
        }
        
        guard let messageQueue = self.messageQueue as? PersistentMessageQueueProtocol else {
            logger.warning("Cannot setup retry scheduler - PersistentMessageQueue not configured")
            return
        }
        
        let scheduler = MessageRetryScheduler(
            redis: redis,
            messageQueue: messageQueue,
            logger: logger
        )
        
        self.messageRetryScheduler = scheduler
        
        // Start the scheduler
        Task {
            await scheduler.start()
        }
        
        // Ensure clean shutdown
        self.lifecycle.use(
            LifecycleHandler(
                shutdownAsync: { app in
                    app.logger.info("Stopping message retry scheduler")
                    await app.messageRetryScheduler?.stop()
                }
            )
        )
        
        logger.info("Message retry scheduler configured and started")
    }
}