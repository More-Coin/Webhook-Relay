import Foundation

// MARK: - Sliding Window Counter

/// A thread-safe sliding window counter for tracking request outcomes over time
actor SlidingWindowCounter {
    private let windowSize: TimeInterval
    private let bucketSize: TimeInterval
    private var buckets: [TimeBucket] = []
    
    struct TimeBucket {
        let startTime: Date
        var successCount: Int = 0
        var failureCount: Int = 0
        
        var totalCount: Int {
            successCount + failureCount
        }
        
        var failureRate: Double {
            guard totalCount > 0 else { return 0.0 }
            return Double(failureCount) / Double(totalCount)
        }
    }
    
    init(windowSize: TimeInterval = 60, bucketSize: TimeInterval = 1) {
        self.windowSize = windowSize
        self.bucketSize = bucketSize
    }
    
    // MARK: - Recording Methods
    
    func recordSuccess() {
        let now = Date()
        cleanupOldBuckets(now: now)
        
        let bucket = ensureCurrentBucket(now: now)
        bucket.successCount += 1
    }
    
    func recordFailure() {
        let now = Date()
        cleanupOldBuckets(now: now)
        
        let bucket = ensureCurrentBucket(now: now)
        bucket.failureCount += 1
    }
    
    // MARK: - Query Methods
    
    func getMetrics() -> WindowMetrics {
        let now = Date()
        cleanupOldBuckets(now: now)
        
        let totalSuccess = buckets.reduce(0) { $0 + $1.successCount }
        let totalFailure = buckets.reduce(0) { $0 + $1.failureCount }
        let totalRequests = totalSuccess + totalFailure
        
        let failureRate = totalRequests > 0 ? Double(totalFailure) / Double(totalRequests) : 0.0
        
        return WindowMetrics(
            successCount: totalSuccess,
            failureCount: totalFailure,
            totalCount: totalRequests,
            failureRate: failureRate,
            windowSize: windowSize,
            bucketCount: buckets.count
        )
    }
    
    func getFailureCount() -> Int {
        cleanupOldBuckets(now: Date())
        return buckets.reduce(0) { $0 + $1.failureCount }
    }
    
    func getFailureRate() -> Double {
        let metrics = getMetrics()
        return metrics.failureRate
    }
    
    func getTotalCount() -> Int {
        cleanupOldBuckets(now: Date())
        return buckets.reduce(0) { $0 + $1.totalCount }
    }
    
    // MARK: - Private Methods
    
    private func ensureCurrentBucket(now: Date) -> TimeBucket {
        let bucketStart = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / bucketSize) * bucketSize)
        
        if let lastBucket = buckets.last, lastBucket.startTime == bucketStart {
            return lastBucket
        } else {
            let newBucket = TimeBucket(startTime: bucketStart)
            buckets.append(newBucket)
            return buckets[buckets.count - 1]
        }
    }
    
    private func cleanupOldBuckets(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSize)
        buckets.removeAll { $0.startTime < cutoff }
    }
    
    // MARK: - Reset
    
    func reset() {
        buckets.removeAll()
    }
}

// MARK: - Metrics

struct WindowMetrics {
    let successCount: Int
    let failureCount: Int
    let totalCount: Int
    let failureRate: Double
    let windowSize: TimeInterval
    let bucketCount: Int
}

// MARK: - Enhanced Circuit Breaker with Sliding Window

extension CircuitBreaker {
    /// Creates a circuit breaker with enhanced sliding window tracking
    static func withSlidingWindow(
        config: CircuitBreakerConfig = CircuitBreakerConfig(),
        logger: Logger
    ) -> EnhancedCircuitBreaker {
        return EnhancedCircuitBreaker(config: config, logger: logger)
    }
}

actor EnhancedCircuitBreaker {
    private var state: CircuitBreakerState = .closed
    private let config: CircuitBreakerConfig
    private let logger: Logger
    private let slidingWindow: SlidingWindowCounter
    
    // Half-open state tracking
    private var halfOpenAttempts = 0
    private var consecutiveSuccesses = 0
    
    // Metrics
    private var stateChanges: [(from: CircuitBreakerState, to: CircuitBreakerState, at: Date)] = []
    private var lastStateChange: Date = Date()
    
    // State change notifications
    typealias StateChangeHandler = (CircuitBreakerState, CircuitBreakerState) -> Void
    private var stateChangeHandlers: [StateChangeHandler] = []
    
    init(config: CircuitBreakerConfig = CircuitBreakerConfig(), logger: Logger) {
        self.config = config
        self.logger = logger
        self.slidingWindow = SlidingWindowCounter(
            windowSize: config.slidingWindowSize,
            bucketSize: max(1, config.slidingWindowSize / 60) // Create 60 buckets
        )
        
        logger.info("Enhanced circuit breaker initialized", metadata: [
            "failureThreshold": "\(config.failureThreshold)",
            "resetTimeout": "\(config.resetTimeout)",
            "slidingWindowSize": "\(config.slidingWindowSize)"
        ])
    }
    
    // MARK: - Public Interface
    
    func execute<T>(_ operation: () async throws -> T) async throws -> T {
        let currentState = state
        
        switch currentState {
        case .open(let until):
            if Date() > until {
                await transitionToHalfOpen()
                return try await executeInHalfOpen(operation)
            } else {
                await slidingWindow.recordFailure() // Count circuit open as failure
                throw CircuitBreakerError.circuitOpen
            }
            
        case .halfOpen:
            return try await executeInHalfOpen(operation)
            
        case .closed:
            return try await executeInClosed(operation)
        }
    }
    
    func getCurrentState() -> CircuitBreakerState {
        return state
    }
    
    func getMetrics() async -> EnhancedCircuitBreakerMetrics {
        let windowMetrics = await slidingWindow.getMetrics()
        
        return EnhancedCircuitBreakerMetrics(
            state: describeState(state),
            windowMetrics: windowMetrics,
            lastStateChange: lastStateChange,
            stateChangeCount: stateChanges.count,
            consecutiveSuccesses: consecutiveSuccesses
        )
    }
    
    func onStateChange(_ handler: @escaping StateChangeHandler) {
        stateChangeHandlers.append(handler)
    }
    
    func reset() async {
        state = .closed
        halfOpenAttempts = 0
        consecutiveSuccesses = 0
        await slidingWindow.reset()
        logger.info("Circuit breaker manually reset")
    }
    
    // MARK: - State Execution Methods
    
    private func executeInClosed<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            let result = try await operation()
            await recordSuccess()
            return result
        } catch {
            await recordFailure()
            throw error
        }
    }
    
    private func executeInHalfOpen<T>(_ operation: () async throws -> T) async throws -> T {
        guard halfOpenAttempts < config.halfOpenMaxAttempts else {
            await slidingWindow.recordFailure()
            throw CircuitBreakerError.halfOpenLimitReached
        }
        
        halfOpenAttempts += 1
        
        do {
            let result = try await operation()
            await recordHalfOpenSuccess()
            return result
        } catch {
            await recordHalfOpenFailure()
            throw error
        }
    }
    
    // MARK: - State Transitions
    
    private func transitionToOpen() {
        let previousState = state
        let reopenTime = Date().addingTimeInterval(config.resetTimeout)
        state = .open(until: reopenTime)
        halfOpenAttempts = 0
        consecutiveSuccesses = 0
        
        let metrics = Task { await slidingWindow.getMetrics() }
        
        logger.warning("Circuit breaker opened", metadata: [
            "reopenAt": "\(reopenTime)",
            "failureCount": "\(metrics)",
            "failureRate": "\(metrics)"
        ])
        
        recordStateChange(from: previousState, to: state)
        notifyStateChange(from: previousState, to: state)
    }
    
    private func transitionToHalfOpen() {
        let previousState = state
        state = .halfOpen
        halfOpenAttempts = 0
        
        logger.info("Circuit breaker transitioned to half-open")
        
        recordStateChange(from: previousState, to: state)
        notifyStateChange(from: previousState, to: state)
    }
    
    private func transitionToClosed() {
        let previousState = state
        state = .closed
        halfOpenAttempts = 0
        consecutiveSuccesses = 0
        
        logger.info("Circuit breaker closed - service recovered")
        
        recordStateChange(from: previousState, to: state)
        notifyStateChange(from: previousState, to: state)
    }
    
    // MARK: - Success/Failure Recording
    
    private func recordSuccess() async {
        await slidingWindow.recordSuccess()
        consecutiveSuccesses += 1
    }
    
    private func recordFailure() async {
        await slidingWindow.recordFailure()
        consecutiveSuccesses = 0
        
        if await shouldOpenCircuit() {
            transitionToOpen()
        }
    }
    
    private func recordHalfOpenSuccess() async {
        await slidingWindow.recordSuccess()
        consecutiveSuccesses += 1
        
        // Require multiple consecutive successes to close
        if consecutiveSuccesses >= 3 {
            transitionToClosed()
        }
    }
    
    private func recordHalfOpenFailure() async {
        await slidingWindow.recordFailure()
        consecutiveSuccesses = 0
        transitionToOpen()
    }
    
    private func shouldOpenCircuit() async -> Bool {
        guard state == .closed else { return false }
        
        let metrics = await slidingWindow.getMetrics()
        
        // Need minimum requests before evaluating
        guard metrics.totalCount >= config.minimumRequests else { return false }
        
        // Open if we exceed failure threshold OR failure rate is too high
        return metrics.failureCount >= config.failureThreshold || metrics.failureRate > 0.5
    }
    
    // MARK: - Helpers
    
    private func recordStateChange(from oldState: CircuitBreakerState, to newState: CircuitBreakerState) {
        stateChanges.append((from: oldState, to: newState, at: Date()))
        lastStateChange = Date()
        
        // Keep only recent state changes
        if stateChanges.count > 100 {
            stateChanges.removeFirst(stateChanges.count - 100)
        }
    }
    
    private func notifyStateChange(from oldState: CircuitBreakerState, to newState: CircuitBreakerState) {
        for handler in stateChangeHandlers {
            handler(oldState, newState)
        }
    }
    
    private func describeState(_ state: CircuitBreakerState) -> String {
        switch state {
        case .closed:
            return "closed"
        case .open(let until):
            let remaining = until.timeIntervalSince(Date())
            return "open (reopens in \(Int(max(0, remaining)))s)"
        case .halfOpen:
            return "half-open (\(halfOpenAttempts)/\(config.halfOpenMaxAttempts) attempts)"
        }
    }
}

// MARK: - Enhanced Metrics

struct EnhancedCircuitBreakerMetrics: Content {
    let state: String
    let windowMetrics: WindowMetrics
    let lastStateChange: Date
    let stateChangeCount: Int
    let consecutiveSuccesses: Int
}