import XCTest
@testable import FacebookWebhookRelay
import Vapor

final class CircuitBreakerTests: XCTestCase {
    var logger: Logger!
    
    override func setUp() {
        super.setUp()
        logger = Logger(label: "test.circuit-breaker")
    }
    
    // MARK: - Basic Circuit Breaker Tests
    
    func testCircuitBreakerStartsClosed() async throws {
        let breaker = CircuitBreaker(logger: logger)
        let state = await breaker.getCurrentState()
        
        switch state {
        case .closed:
            XCTAssertTrue(true, "Circuit breaker should start in closed state")
        default:
            XCTFail("Circuit breaker should start in closed state, but was \(state)")
        }
    }
    
    func testSuccessfulOperationInClosedState() async throws {
        let breaker = CircuitBreaker(logger: logger)
        
        let result = try await breaker.execute {
            return "success"
        }
        
        XCTAssertEqual(result, "success")
    }
    
    func testCircuitOpensAfterFailureThreshold() async throws {
        let config = CircuitBreakerConfig(
            failureThreshold: 3,
            resetTimeout: 60,
            minimumRequests: 1
        )
        let breaker = CircuitBreaker(config: config, logger: logger)
        
        // Cause failures
        for i in 0..<3 {
            do {
                _ = try await breaker.execute {
                    throw TestError.simulatedFailure
                }
                XCTFail("Operation should have failed")
            } catch {
                // Expected
                logger.info("Failure \(i + 1) recorded")
            }
        }
        
        // Circuit should now be open
        let state = await breaker.getCurrentState()
        switch state {
        case .open:
            XCTAssertTrue(true, "Circuit should be open after threshold failures")
        default:
            XCTFail("Circuit should be open, but was \(state)")
        }
        
        // Next call should fail immediately with circuit open error
        do {
            _ = try await breaker.execute {
                return "should not execute"
            }
            XCTFail("Should throw circuit open error")
        } catch CircuitBreakerError.circuitOpen {
            XCTAssertTrue(true, "Correctly threw circuit open error")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testHalfOpenStateAfterTimeout() async throws {
        let config = CircuitBreakerConfig(
            failureThreshold: 1,
            resetTimeout: 0.1, // 100ms for testing
            halfOpenMaxAttempts: 1,
            minimumRequests: 1
        )
        let breaker = CircuitBreaker(config: config, logger: logger)
        
        // Open the circuit
        do {
            _ = try await breaker.execute {
                throw TestError.simulatedFailure
            }
        } catch {
            // Expected
        }
        
        // Wait for reset timeout
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Should be half-open now, next call should be allowed
        let result = try await breaker.execute {
            return "recovered"
        }
        
        XCTAssertEqual(result, "recovered")
        
        // Circuit should be closed again
        let state = await breaker.getCurrentState()
        switch state {
        case .closed:
            XCTAssertTrue(true, "Circuit should be closed after successful half-open test")
        default:
            XCTFail("Circuit should be closed, but was \(state)")
        }
    }
    
    // MARK: - Enhanced Circuit Breaker Tests
    
    func testEnhancedCircuitBreakerWithSlidingWindow() async throws {
        let config = CircuitBreakerConfig(
            failureThreshold: 5,
            resetTimeout: 60,
            slidingWindowSize: 10, // 10 second window
            minimumRequests: 10
        )
        let breaker = EnhancedCircuitBreaker(config: config, logger: logger)
        
        // Record some successes
        for _ in 0..<5 {
            _ = try await breaker.execute {
                return "success"
            }
        }
        
        // Record failures but not enough to open
        for _ in 0..<4 {
            do {
                _ = try await breaker.execute {
                    throw TestError.simulatedFailure
                }
            } catch {
                // Expected
            }
        }
        
        // Should still be closed (4 failures out of 9 requests)
        let state1 = await breaker.getCurrentState()
        switch state1 {
        case .closed:
            XCTAssertTrue(true, "Circuit should remain closed")
        default:
            XCTFail("Circuit should be closed, but was \(state1)")
        }
        
        // One more failure should open it (5 failures = threshold)
        do {
            _ = try await breaker.execute {
                throw TestError.simulatedFailure
            }
        } catch {
            // Expected
        }
        
        // Should now be open
        let state2 = await breaker.getCurrentState()
        switch state2 {
        case .open:
            XCTAssertTrue(true, "Circuit should be open after reaching threshold")
        default:
            XCTFail("Circuit should be open, but was \(state2)")
        }
    }
    
    func testMetricsCollection() async throws {
        let breaker = EnhancedCircuitBreaker(logger: logger)
        
        // Generate some activity
        for i in 0..<3 {
            _ = try? await breaker.execute {
                if i % 2 == 0 {
                    return "success"
                } else {
                    throw TestError.simulatedFailure
                }
            }
        }
        
        let metrics = await breaker.getMetrics()
        XCTAssertGreaterThan(metrics.windowMetrics.totalCount, 0)
        XCTAssertGreaterThan(metrics.windowMetrics.successCount, 0)
        XCTAssertGreaterThan(metrics.windowMetrics.failureCount, 0)
        XCTAssertGreaterThan(metrics.windowMetrics.failureRate, 0)
        XCTAssertLessThan(metrics.windowMetrics.failureRate, 1)
    }
    
    func testStateChangeNotifications() async throws {
        let config = CircuitBreakerConfig(
            failureThreshold: 1,
            minimumRequests: 1
        )
        let breaker = EnhancedCircuitBreaker(config: config, logger: logger)
        
        let expectation = XCTestExpectation(description: "State change notification")
        var capturedOldState: CircuitBreakerState?
        var capturedNewState: CircuitBreakerState?
        
        await breaker.onStateChange { oldState, newState in
            capturedOldState = oldState
            capturedNewState = newState
            expectation.fulfill()
        }
        
        // Trigger state change
        do {
            _ = try await breaker.execute {
                throw TestError.simulatedFailure
            }
        } catch {
            // Expected
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        // Verify notification
        switch capturedOldState {
        case .closed:
            XCTAssertTrue(true)
        default:
            XCTFail("Old state should be closed")
        }
        
        switch capturedNewState {
        case .open:
            XCTAssertTrue(true)
        default:
            XCTFail("New state should be open")
        }
    }
    
    func testConsecutiveSuccessesRequiredToClose() async throws {
        let config = CircuitBreakerConfig(
            failureThreshold: 1,
            resetTimeout: 0.1,
            halfOpenMaxAttempts: 5,
            minimumRequests: 1
        )
        let breaker = EnhancedCircuitBreaker(config: config, logger: logger)
        
        // Open the circuit
        do {
            _ = try await breaker.execute {
                throw TestError.simulatedFailure
            }
        } catch {
            // Expected
        }
        
        // Wait for half-open
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // First two successes shouldn't close the circuit
        for i in 0..<2 {
            _ = try await breaker.execute {
                return "success \(i)"
            }
            
            let state = await breaker.getCurrentState()
            switch state {
            case .halfOpen:
                XCTAssertTrue(true, "Should remain half-open after \(i + 1) success(es)")
            default:
                XCTFail("Should be half-open, but was \(state)")
            }
        }
        
        // Third success should close the circuit
        _ = try await breaker.execute {
            return "final success"
        }
        
        let finalState = await breaker.getCurrentState()
        switch finalState {
        case .closed:
            XCTAssertTrue(true, "Circuit should close after consecutive successes")
        default:
            XCTFail("Circuit should be closed, but was \(finalState)")
        }
    }
    
    func testReset() async throws {
        let config = CircuitBreakerConfig(
            failureThreshold: 1,
            minimumRequests: 1
        )
        let breaker = EnhancedCircuitBreaker(config: config, logger: logger)
        
        // Open the circuit
        do {
            _ = try await breaker.execute {
                throw TestError.simulatedFailure
            }
        } catch {
            // Expected
        }
        
        // Verify it's open
        let openState = await breaker.getCurrentState()
        switch openState {
        case .open:
            XCTAssertTrue(true)
        default:
            XCTFail("Should be open")
        }
        
        // Reset
        await breaker.reset()
        
        // Should be closed now
        let closedState = await breaker.getCurrentState()
        switch closedState {
        case .closed:
            XCTAssertTrue(true, "Circuit should be closed after reset")
        default:
            XCTFail("Circuit should be closed after reset, but was \(closedState)")
        }
        
        // And should work normally
        let result = try await breaker.execute {
            return "works"
        }
        XCTAssertEqual(result, "works")
    }
    
    // MARK: - Sliding Window Tests
    
    func testSlidingWindowCounter() async throws {
        let window = SlidingWindowCounter(windowSize: 5, bucketSize: 1)
        
        // Record some events
        for _ in 0..<3 {
            await window.recordSuccess()
        }
        for _ in 0..<2 {
            await window.recordFailure()
        }
        
        let metrics = await window.getMetrics()
        XCTAssertEqual(metrics.successCount, 3)
        XCTAssertEqual(metrics.failureCount, 2)
        XCTAssertEqual(metrics.totalCount, 5)
        XCTAssertEqual(metrics.failureRate, 0.4, accuracy: 0.01)
    }
    
    func testSlidingWindowExpiration() async throws {
        let window = SlidingWindowCounter(windowSize: 0.2, bucketSize: 0.1) // 200ms window
        
        // Record events
        await window.recordFailure()
        
        // Wait for window to expire
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms
        
        // Record new event
        await window.recordSuccess()
        
        // Old failure should be expired
        let metrics = await window.getMetrics()
        XCTAssertEqual(metrics.failureCount, 0)
        XCTAssertEqual(metrics.successCount, 1)
    }
    
    // MARK: - Helpers
    
    enum TestError: Error {
        case simulatedFailure
    }
}

// MARK: - Integration Tests

final class CircuitBreakerIntegrationTests: XCTestCase {
    var app: Application!
    
    override func setUp() async throws {
        app = Application(.testing)
        try await configure(app)
    }
    
    override func tearDown() async throws {
        app.shutdown()
    }
    
    func testCircuitBreakerWithHTTPClient() async throws {
        // This would test the actual HTTP client integration
        // For now, we'll skip as it requires a running server
        XCTSkip("Requires running server for integration test")
    }
    
    func testFallbackStrategies() async throws {
        let messageQueue = InMemoryMessageQueue(logger: app.logger)
        let fallback = MessageQueueFallback(
            messageQueue: messageQueue,
            logger: app.logger
        )
        
        let event = FacebookWebhookEvent(
            object: "page",
            entry: [
                FacebookEntry(
                    id: "123",
                    time: 1234567890,
                    messaging: []
                )
            ]
        )
        
        try await fallback.execute(event)
        
        let queueSize = try await messageQueue.size()
        XCTAssertEqual(queueSize, 1, "Message should be queued")
    }
    
    func testResponseCache() async throws {
        let cache = ResponseCache(maxSize: 10, ttl: 60)
        
        let senderInfo = SenderInfo(firstName: "Test", lastName: "User")
        await cache.set("user123", value: senderInfo)
        
        if let cached = await cache.get("user123") as? SenderInfo {
            XCTAssertEqual(cached.firstName, "Test")
            XCTAssertEqual(cached.lastName, "User")
        } else {
            XCTFail("Should retrieve cached value")
        }
    }
}