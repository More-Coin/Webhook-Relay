import XCTest
@testable import FacebookWebhookRelay
import Vapor
import NIOHTTP1

final class CircuitBreakerHTTPTests: XCTestCase {
    var app: Application!
    var testServer: Application!
    
    override func setUp() async throws {
        // Create main app
        app = Application(.testing)
        
        // Configure circuit breaker with aggressive settings for testing
        let config = CircuitBreakerConfig(
            failureThreshold: 2,
            resetTimeout: 0.5,
            halfOpenMaxAttempts: 1,
            slidingWindowSize: 5,
            minimumRequests: 1
        )
        
        let circuitBreaker = EnhancedCircuitBreaker(config: config, logger: app.logger)
        app.circuitBreaker = circuitBreaker
        
        // Create test server
        testServer = Application(.testing)
        testServer.http.server.configuration.port = 8181
        
        // Add test endpoints
        testServer.get("success") { req in
            return HTTPStatus.ok
        }
        
        testServer.get("fail") { req in
            throw Abort(.internalServerError)
        }
        
        testServer.get("slow") { req async throws in
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            return HTTPStatus.ok
        }
        
        // Start test server
        try testServer.start()
    }
    
    override func tearDown() async throws {
        testServer.shutdown()
        app.shutdown()
    }
    
    func testSuccessfulRequestThroughCircuitBreaker() async throws {
        let uri = URI(string: "http://localhost:8181/success")
        
        let response = try await app.protectedClient.get(uri)
        XCTAssertEqual(response.status, .ok)
    }
    
    func testCircuitOpensOnRepeatedFailures() async throws {
        let uri = URI(string: "http://localhost:8181/fail")
        
        // First two failures should open the circuit
        for i in 0..<2 {
            do {
                _ = try await app.protectedClient.get(uri)
                XCTFail("Request \(i + 1) should have failed")
            } catch {
                app.logger.info("Expected failure \(i + 1): \(error)")
            }
        }
        
        // Third request should fail immediately with circuit open
        do {
            _ = try await app.protectedClient.get(uri)
            XCTFail("Request should fail with circuit open")
        } catch CircuitBreakerError.circuitOpen {
            XCTAssertTrue(true, "Circuit correctly opened")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    func testCircuitRecovery() async throws {
        let failUri = URI(string: "http://localhost:8181/fail")
        let successUri = URI(string: "http://localhost:8181/success")
        
        // Open the circuit
        for _ in 0..<2 {
            _ = try? await app.protectedClient.get(failUri)
        }
        
        // Verify circuit is open
        do {
            _ = try await app.protectedClient.get(successUri)
            XCTFail("Should fail with circuit open")
        } catch CircuitBreakerError.circuitOpen {
            // Expected
        }
        
        // Wait for reset timeout
        try await Task.sleep(nanoseconds: 600_000_000) // 600ms
        
        // Should now succeed (half-open test)
        let response = try await app.protectedClient.get(successUri)
        XCTAssertEqual(response.status, .ok)
        
        // Circuit should be closed, next request should work
        let response2 = try await app.protectedClient.get(successUri)
        XCTAssertEqual(response2.status, .ok)
    }
    
    func testRequestSpecificCircuitBreaker() async throws {
        // Create a request
        let request = Request(application: app, on: app.eventLoopGroup.next())
        
        let uri = URI(string: "http://localhost:8181/success")
        let response = try await request.protectedClient.get(uri)
        
        XCTAssertEqual(response.status, .ok)
    }
}

// MARK: - Mock HTTP Client Tests

final class MockCircuitBreakerTests: XCTestCase {
    var app: Application!
    
    override func setUp() async throws {
        app = Application(.testing)
        
        // Configure circuit breaker
        let config = CircuitBreakerConfig(
            failureThreshold: 3,
            resetTimeout: 1,
            slidingWindowSize: 10,
            minimumRequests: 1
        )
        
        let circuitBreaker = EnhancedCircuitBreaker(config: config, logger: app.logger)
        app.circuitBreaker = circuitBreaker
    }
    
    override func tearDown() async throws {
        app.shutdown()
    }
    
    func testCircuitBreakerMetricsUpdate() async throws {
        guard let breaker = app.circuitBreaker else {
            XCTFail("Circuit breaker not configured")
            return
        }
        
        // Generate some failures
        for _ in 0..<3 {
            do {
                _ = try await breaker.execute {
                    throw URLError(.badServerResponse)
                }
            } catch {
                // Expected
            }
        }
        
        let metrics = await breaker.getMetrics()
        XCTAssertTrue(metrics.state.contains("open"))
        XCTAssertEqual(metrics.windowMetrics.failureCount, 3)
    }
    
    func testConcurrentRequests() async throws {
        guard let breaker = app.circuitBreaker else {
            XCTFail("Circuit breaker not configured")
            return
        }
        
        // Run multiple concurrent operations
        await withTaskGroup(of: Result<String, Error>.self) { group in
            for i in 0..<10 {
                group.addTask {
                    do {
                        let result = try await breaker.execute {
                            if i % 3 == 0 {
                                throw URLError(.timedOut)
                            }
                            return "Success \(i)"
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var successCount = 0
            var failureCount = 0
            
            for await result in group {
                switch result {
                case .success:
                    successCount += 1
                case .failure:
                    failureCount += 1
                }
            }
            
            app.logger.info("Concurrent test results: \(successCount) successes, \(failureCount) failures")
            
            // Should have some of each
            XCTAssertGreaterThan(successCount, 0)
            XCTAssertGreaterThan(failureCount, 0)
        }
    }
}