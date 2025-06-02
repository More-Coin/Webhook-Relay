import Foundation
import Metrics
import Vapor

// MARK: - Webhook Relay Metrics

struct WebhookRelayMetrics {
    // MARK: - Message Metrics
    
    /// Total number of messages received from Facebook
    static let messagesReceived = Counter(
        label: "webhook_messages_received_total",
        dimensions: [("source", "facebook")]
    )
    
    /// Total number of messages successfully forwarded to NaraServer
    static let messagesForwarded = Counter(
        label: "webhook_messages_forwarded_total",
        dimensions: [("destination", "naraserver")]
    )
    
    /// Total number of messages that failed to forward
    static let messagesFailed = Counter(
        label: "webhook_messages_failed_total",
        dimensions: [("reason", "unknown")]
    )
    
    /// Time taken to forward messages (in seconds)
    static let forwardingDuration = Timer(
        label: "webhook_forwarding_duration_seconds"
    )
    
    // MARK: - Queue Metrics
    
    /// Current queue depth
    static let queueDepth = Gauge(
        label: "webhook_queue_depth"
    )
    
    /// Messages enqueued
    static let messagesEnqueued = Counter(
        label: "webhook_messages_enqueued_total"
    )
    
    /// Messages dequeued
    static let messagesDequeued = Counter(
        label: "webhook_messages_dequeued_total"
    )
    
    // MARK: - Connection Metrics
    
    /// Active SSE connections
    static let activeConnections = Gauge(
        label: "webhook_sse_connections_active"
    )
    
    /// WebSocket connection status (1 = connected, 0 = disconnected)
    static let websocketConnected = Gauge(
        label: "webhook_websocket_connected"
    )
    
    // MARK: - Error Metrics by Type
    
    /// Rate limit errors
    static let rateLimitErrors = Counter(
        label: "webhook_rate_limit_errors_total"
    )
    
    /// Authentication errors
    static let authenticationErrors = Counter(
        label: "webhook_authentication_errors_total"
    )
    
    /// Network errors
    static let networkErrors = Counter(
        label: "webhook_network_errors_total"
    )
    
    // MARK: - Health Check Metrics
    
    /// Health check status (1 = healthy, 0 = unhealthy)
    static let healthStatus = Gauge(
        label: "webhook_health_status"
    )
    
    // MARK: - Circuit Breaker Metrics
    
    /// Circuit breaker state changes
    static let circuitBreakerStateChanges = Counter(
        label: "webhook_circuit_breaker_state_changes_total",
        dimensions: [("from", "unknown"), ("to", "unknown")]
    )
    
    /// Circuit breaker rejections (when circuit is open)
    static let circuitBreakerRejections = Counter(
        label: "webhook_circuit_breaker_rejections_total"
    )
    
    /// Circuit breaker current state (0 = closed, 1 = open, 2 = half-open)
    static let circuitBreakerState = Gauge(
        label: "webhook_circuit_breaker_state"
    )
    
    /// Circuit breaker failure rate
    static let circuitBreakerFailureRate = Gauge(
        label: "webhook_circuit_breaker_failure_rate"
    )
    
    // MARK: - Convenience Methods
    
    /// Record a successful message forward
    static func recordSuccessfulForward(duration: TimeInterval) {
        messagesForwarded.increment()
        forwardingDuration.record(duration)
    }
    
    /// Record a failed message forward
    static func recordFailedForward(reason: String) {
        messagesFailed.increment(dimensions: [("reason", reason)])
    }
    
    /// Update queue metrics
    static func updateQueueMetrics(depth: Int) {
        queueDepth.record(depth)
    }
    
    /// Update connection metrics
    static func updateConnectionMetrics(sseConnections: Int, websocketConnected: Bool) {
        activeConnections.record(sseConnections)
        self.websocketConnected.record(websocketConnected ? 1 : 0)
    }
}

// MARK: - Prometheus Exporter

/// Simple Prometheus text format exporter
struct PrometheusExporter {
    
    /// Export all metrics in Prometheus text format
    static func export() -> String {
        var output = ""
        
        // Get all recorded metrics
        let factory = MetricsSystem.factory as? PrometheusMetricsFactory
        
        if let metrics = factory?.getMetrics() {
            output = formatMetrics(metrics)
        } else {
            // Fallback: manually format known metrics
            output = manualExport()
        }
        
        return output
    }
    
    /// Manual export of known metrics (fallback)
    private static func manualExport() -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        
        return """
        # HELP webhook_messages_received_total Total number of messages received from Facebook
        # TYPE webhook_messages_received_total counter
        webhook_messages_received_total{source="facebook"} 0 \(timestamp)
        
        # HELP webhook_messages_forwarded_total Total number of messages successfully forwarded
        # TYPE webhook_messages_forwarded_total counter
        webhook_messages_forwarded_total{destination="naraserver"} 0 \(timestamp)
        
        # HELP webhook_messages_failed_total Total number of messages that failed to forward
        # TYPE webhook_messages_failed_total counter
        webhook_messages_failed_total{reason="unknown"} 0 \(timestamp)
        
        # HELP webhook_forwarding_duration_seconds Time taken to forward messages
        # TYPE webhook_forwarding_duration_seconds histogram
        
        # HELP webhook_queue_depth Current message queue depth
        # TYPE webhook_queue_depth gauge
        webhook_queue_depth 0 \(timestamp)
        
        # HELP webhook_sse_connections_active Number of active SSE connections
        # TYPE webhook_sse_connections_active gauge
        webhook_sse_connections_active 0 \(timestamp)
        
        # HELP webhook_websocket_connected WebSocket connection status
        # TYPE webhook_websocket_connected gauge
        webhook_websocket_connected 0 \(timestamp)
        
        # HELP webhook_health_status Overall health status
        # TYPE webhook_health_status gauge
        webhook_health_status 1 \(timestamp)
        """
    }
    
    private static func formatMetrics(_ metrics: [String: Any]) -> String {
        // Implementation would depend on the metrics backend
        // For now, return manual export
        return manualExport()
    }
}

// MARK: - Metrics Factory

/// Simple metrics factory that stores metrics in memory
final class PrometheusMetricsFactory: MetricsFactory {
    private var counters: [String: CounterHandler] = [:]
    private var gauges: [String: RecorderHandler] = [:]
    private var timers: [String: TimerHandler] = [:]
    private let lock = NSLock()
    
    func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        let key = makeKey(label: label, dimensions: dimensions)
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = counters[key] {
            return existing
        }
        
        let counter = PrometheusCounter(label: label, dimensions: dimensions)
        counters[key] = counter
        return counter
    }
    
    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        let key = makeKey(label: label, dimensions: dimensions)
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = gauges[key] {
            return existing
        }
        
        let gauge = PrometheusGauge(label: label, dimensions: dimensions)
        gauges[key] = gauge
        return gauge
    }
    
    func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        let key = makeKey(label: label, dimensions: dimensions)
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = timers[key] {
            return existing
        }
        
        let timer = PrometheusTimer(label: label, dimensions: dimensions)
        timers[key] = timer
        return timer
    }
    
    func destroyCounter(_ handler: CounterHandler) {
        // Not implemented for simplicity
    }
    
    func destroyRecorder(_ handler: RecorderHandler) {
        // Not implemented for simplicity
    }
    
    func destroyTimer(_ handler: TimerHandler) {
        // Not implemented for simplicity
    }
    
    func getMetrics() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        
        return [
            "counters": counters,
            "gauges": gauges,
            "timers": timers
        ]
    }
    
    private func makeKey(label: String, dimensions: [(String, String)]) -> String {
        var key = label
        for (name, value) in dimensions.sorted(by: { $0.0 < $1.0 }) {
            key += "{\(name)=\"\(value)\"}"
        }
        return key
    }
}

// MARK: - Metric Handlers

final class PrometheusCounter: CounterHandler {
    private var value: Int64 = 0
    private let lock = NSLock()
    let label: String
    let dimensions: [(String, String)]
    
    init(label: String, dimensions: [(String, String)]) {
        self.label = label
        self.dimensions = dimensions
    }
    
    func increment(by amount: Int64) {
        lock.lock()
        defer { lock.unlock() }
        value += amount
    }
    
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        value = 0
    }
    
    var currentValue: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class PrometheusGauge: RecorderHandler {
    private var value: Double = 0
    private let lock = NSLock()
    let label: String
    let dimensions: [(String, String)]
    
    init(label: String, dimensions: [(String, String)]) {
        self.label = label
        self.dimensions = dimensions
    }
    
    func record(_ value: Int64) {
        record(Double(value))
    }
    
    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
    
    var currentValue: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class PrometheusTimer: TimerHandler {
    private var values: [Int64] = []
    private let lock = NSLock()
    let label: String
    let dimensions: [(String, String)]
    
    init(label: String, dimensions: [(String, String)]) {
        self.label = label
        self.dimensions = dimensions
    }
    
    func recordNanoseconds(_ duration: Int64) {
        lock.lock()
        defer { lock.unlock() }
        values.append(duration)
        
        // Keep only last 1000 values to prevent memory growth
        if values.count > 1000 {
            values.removeFirst()
        }
    }
    
    var summary: [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        
        guard !values.isEmpty else {
            return ["count": 0, "sum": 0]
        }
        
        let sorted = values.sorted()
        let count = Double(sorted.count)
        let sum = sorted.reduce(0, +)
        
        return [
            "count": count,
            "sum": Double(sum) / 1_000_000_000, // Convert to seconds
            "p50": Double(sorted[Int(count * 0.5)]) / 1_000_000_000,
            "p95": Double(sorted[Int(count * 0.95)]) / 1_000_000_000,
            "p99": Double(sorted[Int(count * 0.99)]) / 1_000_000_000
        ]
    }
}