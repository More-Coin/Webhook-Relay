import XCTest
@testable import FacebookWebhookRelay
import Vapor
import RediStack

final class PersistentMessageQueueTests: XCTestCase {
    var app: Application!
    var redis: RedisClient!
    var queue: PersistentMessageQueue!
    
    override func setUp() async throws {
        app = Application(.testing)
        
        // Configure test Redis
        let redisConfig = RedisClient.Configuration(
            hostname: "localhost",
            port: 6379,
            password: nil,
            database: 15 // Use test database
        )
        
        redis = RedisClient(
            configuration: redisConfig,
            eventLoopGroup: app.eventLoopGroup
        )
        
        // Clear test database
        _ = try? await redis.flushdb()
        
        // Create queue
        let config = MessageQueueConfig(
            maxSize: 100,
            ttl: 3600,
            streamKey: "test-webhook-messages",
            consumerGroup: "test-processors",
            consumerName: "test-consumer"
        )
        
        queue = PersistentMessageQueue(
            redis: redis,
            config: config,
            logger: app.logger
        )
    }
    
    override func tearDown() async throws {
        _ = try? await redis.flushdb()
        try await redis.close()
        app.shutdown()
    }
    
    // MARK: - Basic Queue Tests
    
    func testEnqueueAndDequeue() async throws {
        let messageData = "Test message".data(using: .utf8)!
        
        // Enqueue
        try await queue.enqueue(messageData)
        
        // Dequeue
        let dequeued = try await queue.dequeue()
        XCTAssertNotNil(dequeued)
        XCTAssertEqual(dequeued, messageData)
    }
    
    func testPersistedMessageEnqueueDequeue() async throws {
        let payload = "Test webhook payload".data(using: .utf8)!
        let message = PersistedMessage(
            payload: payload,
            messageType: "webhook",
            maxRetries: 3,
            metadata: ["source": "test"]
        )
        
        // Enqueue
        let streamId = try await queue.enqueuePersisted(message)
        XCTAssertFalse(streamId.isEmpty)
        
        // Dequeue
        let dequeued = try await queue.dequeueWithMetadata()
        XCTAssertNotNil(dequeued)
        XCTAssertEqual(dequeued?.payload, payload)
        XCTAssertEqual(dequeued?.messageType, "webhook")
        XCTAssertEqual(dequeued?.metadata["source"], "test")
    }
    
    func testQueueSize() async throws {
        let size1 = try await queue.size()
        XCTAssertEqual(size1, 0)
        
        // Add messages
        for i in 0..<5 {
            let data = "Message \(i)".data(using: .utf8)!
            try await queue.enqueue(data)
        }
        
        let size2 = try await queue.size()
        XCTAssertEqual(size2, 5)
    }
    
    func testQueueCapacity() async throws {
        // Fill queue to capacity
        let smallQueue = PersistentMessageQueue(
            redis: redis,
            config: MessageQueueConfig(maxSize: 3),
            logger: app.logger
        )
        
        for i in 0..<3 {
            let data = "Message \(i)".data(using: .utf8)!
            try await smallQueue.enqueue(data)
        }
        
        // Next enqueue should fail
        do {
            let data = "Overflow".data(using: .utf8)!
            try await smallQueue.enqueue(data)
            XCTFail("Should throw queue full error")
        } catch MessageQueueError.queueFull {
            // Expected
        }
    }
    
    // MARK: - Message Status Tests
    
    func testMessageStatusTransitions() async throws {
        let message = PersistedMessage(
            payload: "Test".data(using: .utf8)!,
            maxRetries: 3
        )
        
        // Enqueue and mark as processing
        _ = try await queue.enqueuePersisted(message)
        let dequeued = try await queue.dequeueWithMetadata()
        
        XCTAssertNotNil(dequeued)
        XCTAssertEqual(dequeued?.status, .pending)
        
        // Mark as processing
        try await queue.markAsProcessing(dequeued!.id)
        
        // Mark as completed
        try await queue.markAsCompleted(dequeued!.id)
    }
    
    func testMessageFailureAndRetry() async throws {
        let message = PersistedMessage(
            payload: "Test".data(using: .utf8)!,
            maxRetries: 2
        )
        
        _ = try await queue.enqueuePersisted(message)
        let dequeued = try await queue.dequeueWithMetadata()!
        
        // Fail the message
        try await queue.markAsFailed(dequeued.id, error: "Test error")
        
        // Message should be scheduled for retry
        // In real test, we'd wait and check retry
    }
    
    // MARK: - Dead Letter Queue Tests
    
    func testDeadLetterQueueAfterMaxRetries() async throws {
        let message = PersistedMessage(
            payload: "Test".data(using: .utf8)!,
            maxRetries: 1
        )
        
        _ = try await queue.enqueuePersisted(message)
        let dequeued = try await queue.dequeueWithMetadata()!
        
        // Fail once (max retries)
        try await queue.markAsFailed(dequeued.id, error: "Test error")
        
        // Check DLQ
        let dlqMessages = try await queue.getDeadLetterMessages(limit: 10)
        XCTAssertEqual(dlqMessages.count, 1)
        XCTAssertEqual(dlqMessages.first?.id, dequeued.id)
    }
    
    func testReplayFromDLQ() async throws {
        // Add message to DLQ
        let message = PersistedMessage(
            payload: "Test".data(using: .utf8)!,
            maxRetries: 0 // Will go straight to DLQ on failure
        )
        
        _ = try await queue.enqueuePersisted(message)
        let dequeued = try await queue.dequeueWithMetadata()!
        try await queue.markAsFailed(dequeued.id, error: "Test error")
        
        // Replay from DLQ
        try await queue.replayMessage(dequeued.id)
        
        // Should be back in main queue
        let replayed = try await queue.dequeueWithMetadata()
        XCTAssertNotNil(replayed)
        XCTAssertEqual(replayed?.payload, message.payload)
    }
    
    // MARK: - Statistics Tests
    
    func testQueueStatistics() async throws {
        // Add various messages
        for i in 0..<5 {
            let message = PersistedMessage(
                payload: "Message \(i)".data(using: .utf8)!
            )
            _ = try await queue.enqueuePersisted(message)
        }
        
        let stats = try await queue.getStatistics()
        XCTAssertGreaterThanOrEqual(stats.total, 5)
        XCTAssertGreaterThanOrEqual(stats.pending, 0)
    }
}

// MARK: - Retry Scheduler Tests

final class MessageRetrySchedulerTests: XCTestCase {
    var app: Application!
    var redis: RedisClient!
    var queue: PersistentMessageQueue!
    var scheduler: MessageRetryScheduler!
    
    override func setUp() async throws {
        app = Application(.testing)
        
        let redisConfig = RedisClient.Configuration(
            hostname: "localhost",
            port: 6379,
            database: 15
        )
        
        redis = RedisClient(
            configuration: redisConfig,
            eventLoopGroup: app.eventLoopGroup
        )
        
        _ = try? await redis.flushdb()
        
        queue = PersistentMessageQueue(
            redis: redis,
            logger: app.logger
        )
        
        scheduler = MessageRetryScheduler(
            redis: redis,
            messageQueue: queue,
            config: .init(checkInterval: 0.1, batchSize: 10, maxConcurrentRetries: 5),
            logger: app.logger
        )
    }
    
    override func tearDown() async throws {
        await scheduler.stop()
        _ = try? await redis.flushdb()
        try await redis.close()
        app.shutdown()
    }
    
    func testScheduleRetry() async throws {
        let message = PersistedMessage(
            payload: "Test".data(using: .utf8)!
        ).withRetry(error: "Test error")
        
        try await scheduler.scheduleRetry(message)
        
        let pending = try await scheduler.getPendingRetries()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.messageId, message.id)
    }
    
    func testCancelRetry() async throws {
        let message = PersistedMessage(
            payload: "Test".data(using: .utf8)!
        ).withRetry(error: "Test error")
        
        try await scheduler.scheduleRetry(message)
        try await scheduler.cancelRetry(message.id)
        
        let pending = try await scheduler.getPendingRetries()
        XCTAssertEqual(pending.count, 0)
    }
}

// MARK: - Dead Letter Queue Manager Tests

final class DeadLetterQueueManagerTests: XCTestCase {
    var app: Application!
    var redis: RedisClient!
    var queue: PersistentMessageQueue!
    var dlqManager: DeadLetterQueueManager!
    
    override func setUp() async throws {
        app = Application(.testing)
        
        let redisConfig = RedisClient.Configuration(
            hostname: "localhost",
            port: 6379,
            database: 15
        )
        
        redis = RedisClient(
            configuration: redisConfig,
            eventLoopGroup: app.eventLoopGroup
        )
        
        _ = try? await redis.flushdb()
        
        queue = PersistentMessageQueue(
            redis: redis,
            logger: app.logger
        )
        
        dlqManager = DeadLetterQueueManager(
            redis: redis,
            messageQueue: queue,
            logger: app.logger
        )
    }
    
    override func tearDown() async throws {
        _ = try? await redis.flushdb()
        try await redis.close()
        app.shutdown()
    }
    
    func testAddToDeadLetter() async throws {
        let message = PersistedMessage(
            payload: "Failed message".data(using: .utf8)!
        )
        
        try await dlqManager.addToDeadLetter(message, reason: "Max retries exceeded")
        
        let messages = try await dlqManager.getMessages(limit: 10)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, message.id)
        XCTAssertEqual(messages.first?.error, "Max retries exceeded")
    }
    
    func testDLQStatistics() async throws {
        // Add multiple messages
        for i in 0..<3 {
            let message = PersistedMessage(
                payload: "Message \(i)".data(using: .utf8)!,
                retryCount: i
            )
            try await dlqManager.addToDeadLetter(message, reason: "Error \(i % 2)")
        }
        
        let stats = try await dlqManager.getStatistics()
        XCTAssertEqual(stats.totalMessages, 3)
        XCTAssertEqual(stats.errorBreakdown.count, 2) // Two different errors
        XCTAssertEqual(stats.averageRetryCount, 1.0, accuracy: 0.1)
    }
    
    func testReplayFromDLQ() async throws {
        let message = PersistedMessage(
            payload: "Test".data(using: .utf8)!
        )
        
        try await dlqManager.addToDeadLetter(message, reason: "Test")
        
        // Replay
        try await dlqManager.replayMessage(message.id)
        
        // Should be removed from DLQ
        let remaining = try await dlqManager.getMessages()
        XCTAssertEqual(remaining.count, 0)
    }
    
    func testPurgeMessage() async throws {
        let message = PersistedMessage(
            payload: "Test".data(using: .utf8)!
        )
        
        try await dlqManager.addToDeadLetter(message, reason: "Test")
        try await dlqManager.purgeMessage(message.id)
        
        let remaining = try await dlqManager.getMessages()
        XCTAssertEqual(remaining.count, 0)
    }
}