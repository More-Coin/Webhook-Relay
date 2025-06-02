import Foundation
import Vapor
import RediStack

// MARK: - Queue Monitor

/// Monitors message queue health and performance
actor QueueMonitor {
    private let redis: RedisClient
    private let messageQueue: PersistentMessageQueueProtocol
    private let dlqManager: DeadLetterQueueManager
    private let logger: Logger
    private let config: MonitorConfig
    
    // Alert thresholds
    private var alertHandlers: [AlertHandler] = []
    private var lastAlerts: [String: Date] = [:] // Track last alert time by type
    
    // Monitoring task
    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring = false
    
    struct MonitorConfig {
        let checkInterval: TimeInterval
        let queueDepthThreshold: Int
        let processingRateThreshold: Double // messages per minute
        let errorRateThreshold: Double // percentage
        let oldestMessageThreshold: TimeInterval // seconds
        let alertCooldown: TimeInterval
        
        static let `default` = MonitorConfig(
            checkInterval: 30.0, // 30 seconds
            queueDepthThreshold: 1000,
            processingRateThreshold: 10.0, // Less than 10 msgs/min is concerning
            errorRateThreshold: 5.0, // 5% error rate
            oldestMessageThreshold: 3600.0, // 1 hour
            alertCooldown: 300.0 // 5 minutes between same alerts
        )
    }
    
    struct AlertHandler {
        let type: AlertType
        let handler: (QueueAlert) async -> Void
    }
    
    enum AlertType: String {
        case queueDepth = "queue_depth"
        case processingRate = "processing_rate"
        case errorRate = "error_rate"
        case oldMessage = "old_message"
        case dlqSize = "dlq_size"
        case connectionLost = "connection_lost"
    }
    
    init(
        redis: RedisClient,
        messageQueue: PersistentMessageQueueProtocol,
        dlqManager: DeadLetterQueueManager,
        config: MonitorConfig = .default,
        logger: Logger
    ) {
        self.redis = redis
        self.messageQueue = messageQueue
        self.dlqManager = dlqManager
        self.config = config
        self.logger = logger
    }
    
    // MARK: - Monitoring Control
    
    func startMonitoring() {
        guard !isMonitoring else {
            logger.info("Queue monitoring already active")
            return
        }
        
        isMonitoring = true
        logger.info("Starting queue monitoring")
        
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.performHealthCheck()
                
                try? await Task.sleep(nanoseconds: UInt64(self?.config.checkInterval ?? 30.0) * 1_000_000_000)
            }
        }
    }
    
    func stopMonitoring() {
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
        logger.info("Stopped queue monitoring")
    }
    
    // MARK: - Health Check
    
    func performHealthCheck() async {
        do {
            let health = try await getQueueHealth()
            
            // Check various health metrics
            await checkQueueDepth(health)
            await checkProcessingRate(health)
            await checkErrorRate(health)
            await checkOldestMessage(health)
            await checkDLQSize(health)
            
            // Update Prometheus metrics
            updateMetrics(health)
            
        } catch {
            logger.error("Queue health check failed: \(error)")
            
            // Alert on connection failure
            await sendAlert(QueueAlert(
                type: .connectionLost,
                severity: .critical,
                message: "Failed to check queue health: \(error.localizedDescription)",
                metrics: [:],
                timestamp: Date()
            ))
        }
    }
    
    func getQueueHealth() async throws -> QueueHealthReport {
        // Get queue statistics
        let queueStats = try await messageQueue.getStatistics()
        let dlqStats = try await dlqManager.getStatistics()
        
        // Calculate processing rate (simplified - in production, track over time)
        let processingRate = calculateProcessingRate()
        
        // Get oldest message info
        let oldestMessageAge = try await getOldestMessageAge()
        
        return QueueHealthReport(
            timestamp: Date(),
            queueDepth: queueStats.total,
            pendingMessages: queueStats.pending,
            processingMessages: queueStats.processing,
            completedMessages: queueStats.completed,
            failedMessages: queueStats.failed,
            dlqSize: dlqStats.totalMessages,
            processingRate: processingRate,
            errorRate: queueStats.errorRate,
            oldestMessageAge: oldestMessageAge,
            isHealthy: isHealthy(queueStats: queueStats, dlqStats: dlqStats)
        )
    }
    
    // MARK: - Alert Checks
    
    private func checkQueueDepth(_ health: QueueHealthReport) async {
        if health.queueDepth > config.queueDepthThreshold {
            await sendAlert(QueueAlert(
                type: .queueDepth,
                severity: .warning,
                message: "Queue depth exceeded threshold",
                metrics: [
                    "current": String(health.queueDepth),
                    "threshold": String(config.queueDepthThreshold)
                ],
                timestamp: Date()
            ))
        }
    }
    
    private func checkProcessingRate(_ health: QueueHealthReport) async {
        if health.processingRate < config.processingRateThreshold && health.queueDepth > 0 {
            await sendAlert(QueueAlert(
                type: .processingRate,
                severity: .warning,
                message: "Processing rate below threshold",
                metrics: [
                    "current": String(format: "%.2f", health.processingRate),
                    "threshold": String(format: "%.2f", config.processingRateThreshold),
                    "unit": "messages/minute"
                ],
                timestamp: Date()
            ))
        }
    }
    
    private func checkErrorRate(_ health: QueueHealthReport) async {
        if health.errorRate > config.errorRateThreshold {
            await sendAlert(QueueAlert(
                type: .errorRate,
                severity: .critical,
                message: "Error rate exceeded threshold",
                metrics: [
                    "current": String(format: "%.2f%%", health.errorRate),
                    "threshold": String(format: "%.2f%%", config.errorRateThreshold)
                ],
                timestamp: Date()
            ))
        }
    }
    
    private func checkOldestMessage(_ health: QueueHealthReport) async {
        if let age = health.oldestMessageAge, age > config.oldestMessageThreshold {
            await sendAlert(QueueAlert(
                type: .oldMessage,
                severity: .warning,
                message: "Messages stuck in queue",
                metrics: [
                    "oldest_age_minutes": String(format: "%.1f", age / 60),
                    "threshold_minutes": String(format: "%.1f", config.oldestMessageThreshold / 60)
                ],
                timestamp: Date()
            ))
        }
    }
    
    private func checkDLQSize(_ health: QueueHealthReport) async {
        if health.dlqSize > 0 {
            let severity: AlertSeverity = health.dlqSize > 100 ? .critical : .warning
            await sendAlert(QueueAlert(
                type: .dlqSize,
                severity: severity,
                message: "Messages in dead letter queue",
                metrics: [
                    "count": String(health.dlqSize)
                ],
                timestamp: Date()
            ))
        }
    }
    
    // MARK: - Alert Management
    
    func onAlert(type: AlertType, handler: @escaping (QueueAlert) async -> Void) {
        alertHandlers.append(AlertHandler(type: type, handler: handler))
    }
    
    private func sendAlert(_ alert: QueueAlert) async {
        // Check cooldown
        let alertKey = "\(alert.type):\(alert.severity)"
        if let lastAlert = lastAlerts[alertKey],
           Date().timeIntervalSince(lastAlert) < config.alertCooldown {
            return // Skip alert due to cooldown
        }
        
        lastAlerts[alertKey] = Date()
        
        // Log alert
        switch alert.severity {
        case .info:
            logger.info("Queue alert: \(alert.message)", metadata: alert.metrics.toMetadata())
        case .warning:
            logger.warning("Queue alert: \(alert.message)", metadata: alert.metrics.toMetadata())
        case .critical:
            logger.critical("Queue alert: \(alert.message)", metadata: alert.metrics.toMetadata())
        }
        
        // Send to handlers
        let handlers = alertHandlers.filter { $0.type == alert.type }
        for handler in handlers {
            await handler.handler(alert)
        }
    }
    
    // MARK: - Metrics
    
    private func updateMetrics(_ health: QueueHealthReport) {
        // Update Prometheus metrics
        WebhookRelayMetrics.queueDepth.record(health.queueDepth)
        
        // Additional queue metrics
        QueueMetrics.pendingMessages.record(health.pendingMessages)
        QueueMetrics.processingMessages.record(health.processingMessages)
        QueueMetrics.dlqSize.record(health.dlqSize)
        QueueMetrics.processingRate.record(health.processingRate)
        QueueMetrics.errorRate.record(health.errorRate)
        
        if let age = health.oldestMessageAge {
            QueueMetrics.oldestMessageAge.record(age)
        }
    }
    
    // MARK: - Helper Methods
    
    private func calculateProcessingRate() -> Double {
        // Simplified calculation - in production, track over time window
        return 0.0
    }
    
    private func getOldestMessageAge() async throws -> TimeInterval? {
        // Would need to track message timestamps
        return nil
    }
    
    private func isHealthy(queueStats: MessageStatistics, dlqStats: DLQStatistics) -> Bool {
        return queueStats.total < config.queueDepthThreshold &&
               queueStats.errorRate < config.errorRateThreshold &&
               dlqStats.totalMessages == 0
    }
}

// MARK: - Supporting Types

struct QueueHealthReport: Content {
    let timestamp: Date
    let queueDepth: Int
    let pendingMessages: Int
    let processingMessages: Int
    let completedMessages: Int
    let failedMessages: Int
    let dlqSize: Int
    let processingRate: Double // messages per minute
    let errorRate: Double // percentage
    let oldestMessageAge: TimeInterval? // seconds
    let isHealthy: Bool
}

enum AlertSeverity: String, Codable {
    case info
    case warning
    case critical
}

struct QueueAlert: Content {
    let type: QueueMonitor.AlertType
    let severity: AlertSeverity
    let message: String
    let metrics: [String: String]
    let timestamp: Date
}

// MARK: - Additional Metrics

struct QueueMetrics {
    static let pendingMessages = Gauge(
        label: "webhook_queue_pending_messages"
    )
    
    static let processingMessages = Gauge(
        label: "webhook_queue_processing_messages"
    )
    
    static let dlqSize = Gauge(
        label: "webhook_dlq_size"
    )
    
    static let processingRate = Gauge(
        label: "webhook_queue_processing_rate_per_minute"
    )
    
    static let errorRate = Gauge(
        label: "webhook_queue_error_rate_percent"
    )
    
    static let oldestMessageAge = Gauge(
        label: "webhook_queue_oldest_message_age_seconds"
    )
}

// MARK: - Dictionary Extension

extension Dictionary where Key == String, Value == String {
    func toMetadata() -> Logger.Metadata {
        return self.reduce(into: [:]) { result, pair in
            result[pair.key] = .string(pair.value)
        }
    }
}

// MARK: - Application Extension

extension Application {
    struct QueueMonitorKey: StorageKey {
        typealias Value = QueueMonitor
    }
    
    var queueMonitor: QueueMonitor? {
        get {
            storage[QueueMonitorKey.self]
        }
        set {
            storage[QueueMonitorKey.self] = newValue
        }
    }
    
    /// Set up queue monitoring and alerting
    func setupQueueMonitoring() {
        guard let redis = self.redis else {
            logger.warning("Cannot setup queue monitoring - Redis not configured")
            return
        }
        
        guard let messageQueue = self.messageQueue as? PersistentMessageQueueProtocol else {
            logger.warning("Cannot setup queue monitoring - PersistentMessageQueue not configured")
            return
        }
        
        guard let dlqManager = self.deadLetterQueueManager else {
            logger.warning("Cannot setup queue monitoring - DLQ manager not configured")
            return
        }
        
        let monitor = QueueMonitor(
            redis: redis,
            messageQueue: messageQueue,
            dlqManager: dlqManager,
            logger: logger
        )
        
        self.queueMonitor = monitor
        
        // Set up alert handlers
        Task {
            // Critical alerts
            await monitor.onAlert(type: .errorRate) { alert in
                self.logger.critical("🚨 High error rate detected", metadata: alert.metrics.toMetadata())
                // Send to PagerDuty, Slack, etc.
            }
            
            await monitor.onAlert(type: .connectionLost) { alert in
                self.logger.critical("🚨 Queue connection lost", metadata: alert.metrics.toMetadata())
            }
            
            // Warning alerts
            await monitor.onAlert(type: .queueDepth) { alert in
                self.logger.warning("⚠️ Queue depth high", metadata: alert.metrics.toMetadata())
            }
            
            await monitor.onAlert(type: .dlqSize) { alert in
                self.logger.warning("⚠️ Messages in DLQ", metadata: alert.metrics.toMetadata())
            }
            
            // Start monitoring
            await monitor.startMonitoring()
        }
        
        // Ensure clean shutdown
        self.lifecycle.use(
            LifecycleHandler(
                shutdownAsync: { app in
                    app.logger.info("Stopping queue monitor")
                    await app.queueMonitor?.stopMonitoring()
                }
            )
        )
        
        logger.info("Queue monitoring configured and started")
    }
}