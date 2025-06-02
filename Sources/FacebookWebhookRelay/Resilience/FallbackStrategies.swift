import Foundation
import Vapor

// MARK: - Fallback Strategy Protocol

protocol FallbackStrategy {
    associatedtype Input
    associatedtype Output
    
    func execute(_ input: Input) async throws -> Output
}

// MARK: - Message Queue Fallback

/// Fallback strategy that queues messages when circuit is open
struct MessageQueueFallback: FallbackStrategy {
    typealias Input = FacebookWebhookEvent
    typealias Output = Void
    
    let messageQueue: MessageQueue
    let logger: Logger
    
    func execute(_ webhookEvent: FacebookWebhookEvent) async throws {
        logger.warning("Circuit breaker open - queueing webhook for later delivery")
        
        // Encode the webhook event
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(webhookEvent)
        
        // Queue the message
        try await messageQueue.enqueue(data)
        
        logger.info("Webhook queued successfully", metadata: [
            "queueSize": "\(try await messageQueue.size())"
        ])
        
        // Track metric
        WebhookRelayMetrics.messagesEnqueued.increment()
    }
}

// MARK: - Response Cache

/// Simple in-memory cache for responses
actor ResponseCache {
    private var cache: [String: CachedResponse] = [:]
    private let maxSize: Int
    private let ttl: TimeInterval
    
    struct CachedResponse {
        let data: Any
        let timestamp: Date
        
        func isValid(ttl: TimeInterval) -> Bool {
            return Date().timeIntervalSince(timestamp) < ttl
        }
    }
    
    init(maxSize: Int = 100, ttl: TimeInterval = 300) { // 5 minutes default
        self.maxSize = maxSize
        self.ttl = ttl
    }
    
    func get(_ key: String) -> Any? {
        guard let cached = cache[key], cached.isValid(ttl: ttl) else {
            cache.removeValue(forKey: key)
            return nil
        }
        return cached.data
    }
    
    func set(_ key: String, value: Any) {
        // Clean up expired entries if at capacity
        if cache.count >= maxSize {
            cleanupExpired()
        }
        
        cache[key] = CachedResponse(data: value, timestamp: Date())
    }
    
    private func cleanupExpired() {
        let now = Date()
        cache = cache.filter { _, value in
            value.isValid(ttl: ttl)
        }
    }
}

// MARK: - Cached Response Fallback

/// Fallback strategy that returns cached responses when circuit is open
struct CachedResponseFallback: FallbackStrategy {
    typealias Input = String // Cache key
    typealias Output = SenderInfo
    
    let cache: ResponseCache
    let logger: Logger
    
    func execute(_ senderId: String) async throws -> SenderInfo {
        if let cached = await cache.get(senderId) as? SenderInfo {
            logger.info("Circuit breaker open - returning cached sender info", metadata: [
                "senderId": senderId
            ])
            return cached
        }
        
        // Return default if no cache
        logger.warning("Circuit breaker open - no cached data, returning default", metadata: [
            "senderId": senderId
        ])
        return SenderInfo(firstName: "Unknown", lastName: "User")
    }
    
    /// Store a successful response in cache
    func cacheResponse(_ senderId: String, response: SenderInfo) async {
        await cache.set(senderId, value: response)
    }
}

// MARK: - Health Check Fallback

/// Returns degraded health status when circuit is open
struct HealthCheckFallback: FallbackStrategy {
    typealias Input = Void
    typealias Output = HealthStatus
    
    let logger: Logger
    
    func execute(_ input: Void) async throws -> HealthStatus {
        logger.warning("Circuit breaker open - returning degraded health status")
        
        return HealthStatus(
            status: "degraded",
            timestamp: Date().iso8601,
            connections: 0,
            serverConnected: false,
            circuitBreakerState: "open"
        )
    }
}

// MARK: - Notification Service

/// Service to handle notifications when circuit state changes
actor CircuitBreakerNotificationService {
    private let logger: Logger
    private var lastNotificationTime: Date?
    private let notificationCooldown: TimeInterval = 300 // 5 minutes
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    func notifyCircuitOpen(reason: String) async {
        guard shouldNotify() else { return }
        
        logger.critical("⚠️ CIRCUIT BREAKER OPENED", metadata: [
            "reason": reason,
            "timestamp": "\(Date().iso8601)"
        ])
        
        lastNotificationTime = Date()
        
        // Here you could add:
        // - Send email alerts
        // - Post to Slack/Discord
        // - Trigger PagerDuty
        // - Update status page
    }
    
    func notifyCircuitClosed() async {
        logger.info("✅ CIRCUIT BREAKER CLOSED - Service recovered", metadata: [
            "timestamp": "\(Date().iso8601)"
        ])
    }
    
    private func shouldNotify() -> Bool {
        guard let lastTime = lastNotificationTime else { return true }
        return Date().timeIntervalSince(lastTime) > notificationCooldown
    }
}

// MARK: - Application Extensions

extension Application {
    struct ResponseCacheKey: StorageKey {
        typealias Value = ResponseCache
    }
    
    var responseCache: ResponseCache {
        get {
            if let existing = storage[ResponseCacheKey.self] {
                return existing
            }
            let cache = ResponseCache()
            storage[ResponseCacheKey.self] = cache
            return cache
        }
        set {
            storage[ResponseCacheKey.self] = newValue
        }
    }
    
    struct NotificationServiceKey: StorageKey {
        typealias Value = CircuitBreakerNotificationService
    }
    
    var circuitBreakerNotifications: CircuitBreakerNotificationService {
        get {
            if let existing = storage[NotificationServiceKey.self] {
                return existing
            }
            let service = CircuitBreakerNotificationService(logger: logger)
            storage[NotificationServiceKey.self] = service
            return service
        }
        set {
            storage[NotificationServiceKey.self] = newValue
        }
    }
}