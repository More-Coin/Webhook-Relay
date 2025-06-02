import Foundation
import Vapor

// MARK: - Circuit Breaker Types

enum CircuitBreakerState {
    case closed
    case open(until: Date)
    case halfOpen
}

enum CircuitBreakerError: Error, LocalizedError {
    case circuitOpen
    case halfOpenLimitReached
    
    var errorDescription: String? {
        switch self {
        case .circuitOpen:
            return "Circuit breaker is open - service unavailable"
        case .halfOpenLimitReached:
            return "Circuit breaker is half-open and has reached its request limit"
        }
    }
}

// MARK: - Circuit Breaker Configuration

struct CircuitBreakerConfig {
    let failureThreshold: Int
    let resetTimeout: TimeInterval
    let halfOpenMaxAttempts: Int
    let slidingWindowSize: TimeInterval
    let minimumRequests: Int
    
    init(
        failureThreshold: Int = 5,
        resetTimeout: TimeInterval = 60,
        halfOpenMaxAttempts: Int = 3,
        slidingWindowSize: TimeInterval = 60,
        minimumRequests: Int = 10
    ) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
        self.halfOpenMaxAttempts = halfOpenMaxAttempts
        self.slidingWindowSize = slidingWindowSize
        self.minimumRequests = minimumRequests
    }
}

// MARK: - Circuit Breaker Actor

actor CircuitBreaker {
    private var state: CircuitBreakerState = .closed
    private let config: CircuitBreakerConfig
    private let logger: Logger
    
    // Failure tracking
    private var failures: [Date] = []
    private var halfOpenAttempts = 0
    
    // Metrics
    private var stateChanges: [(from: CircuitBreakerState, to: CircuitBreakerState, at: Date)] = []
    private var lastStateChange: Date = Date()
    
    // State change notifications
    typealias StateChangeHandler = (CircuitBreakerState, CircuitBreakerState) -> Void
    private var stateChangeHandlers: [StateChangeHandler] = []
    
    init(config: CircuitBreakerConfig = CircuitBreakerConfig(), logger: Logger) {
        self.config = config
        self.logger = logger
        logger.info("Circuit breaker initialized", metadata: [
            "failureThreshold": "\(config.failureThreshold)",
            "resetTimeout": "\(config.resetTimeout)",
            "halfOpenMaxAttempts": "\(config.halfOpenMaxAttempts)"
        ])
    }
    
    // MARK: - Public Interface
    
    func execute<T>(_ operation: () async throws -> T) async throws -> T {
        let currentState = state
        
        switch currentState {
        case .open(let until):
            if Date() > until {
                // Transition to half-open
                await transitionToHalfOpen()
                return try await executeInHalfOpen(operation)
            } else {
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
    
    func getMetrics() -> CircuitBreakerMetrics {
        let failureRate = calculateFailureRate()
        return CircuitBreakerMetrics(
            state: describeState(state),
            failureCount: failures.count,
            failureRate: failureRate,
            lastStateChange: lastStateChange,
            stateChangeCount: stateChanges.count
        )
    }
    
    func onStateChange(_ handler: @escaping StateChangeHandler) {
        stateChangeHandlers.append(handler)
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
            throw CircuitBreakerError.halfOpenLimitReached
        }
        
        halfOpenAttempts += 1
        
        do {
            let result = try await operation()
            await transitionToClosed()
            return result
        } catch {
            await transitionToOpen()
            throw error
        }
    }
    
    // MARK: - State Transitions
    
    private func transitionToOpen() {
        let previousState = state
        let reopenTime = Date().addingTimeInterval(config.resetTimeout)
        state = .open(until: reopenTime)
        halfOpenAttempts = 0
        
        logger.warning("Circuit breaker opened", metadata: [
            "reopenAt": "\(reopenTime)",
            "failureCount": "\(failures.count)"
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
        failures.removeAll()
        halfOpenAttempts = 0
        
        logger.info("Circuit breaker closed - service recovered")
        
        recordStateChange(from: previousState, to: state)
        notifyStateChange(from: previousState, to: state)
    }
    
    // MARK: - Failure Tracking
    
    private func recordSuccess() {
        // Remove old failures outside the sliding window
        cleanupOldFailures()
    }
    
    private func recordFailure() {
        let now = Date()
        failures.append(now)
        cleanupOldFailures()
        
        // Check if we should open the circuit
        if shouldOpenCircuit() {
            transitionToOpen()
        }
    }
    
    private func cleanupOldFailures() {
        let cutoff = Date().addingTimeInterval(-config.slidingWindowSize)
        failures.removeAll { $0 < cutoff }
    }
    
    private func shouldOpenCircuit() -> Bool {
        guard state == .closed else { return false }
        
        // Need minimum requests before opening
        guard failures.count >= config.minimumRequests else { return false }
        
        let failureRate = calculateFailureRate()
        return failures.count >= config.failureThreshold || failureRate > 0.5
    }
    
    private func calculateFailureRate() -> Double {
        guard !failures.isEmpty else { return 0.0 }
        
        let windowStart = Date().addingTimeInterval(-config.slidingWindowSize)
        let recentFailures = failures.filter { $0 >= windowStart }.count
        
        // This is a simplified calculation - in production you'd track total requests too
        return Double(recentFailures) / Double(max(recentFailures, config.minimumRequests))
    }
    
    // MARK: - Metrics and Notifications
    
    private func recordStateChange(from oldState: CircuitBreakerState, to newState: CircuitBreakerState) {
        stateChanges.append((from: oldState, to: newState, at: Date()))
        lastStateChange = Date()
        
        // Keep only recent state changes (last 100)
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
            return "open (until \(until))"
        case .halfOpen:
            return "half-open"
        }
    }
}

// MARK: - Metrics

struct CircuitBreakerMetrics: Content {
    let state: String
    let failureCount: Int
    let failureRate: Double
    let lastStateChange: Date
    let stateChangeCount: Int
}

// MARK: - Application Extension

extension Application {
    struct CircuitBreakerKey: StorageKey {
        typealias Value = EnhancedCircuitBreaker
    }
    
    var circuitBreaker: EnhancedCircuitBreaker? {
        get {
            storage[CircuitBreakerKey.self]
        }
        set {
            storage[CircuitBreakerKey.self] = newValue
        }
    }
}