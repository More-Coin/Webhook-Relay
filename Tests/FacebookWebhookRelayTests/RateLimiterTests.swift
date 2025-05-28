import Testing
import Vapor
@testable import FacebookWebhookRelay

@Suite("Rate Limiter Tests")
struct RateLimiterTests {
    
    @Test("Allows requests under limit")
    func allowsRequestsUnderLimit() async {
        let rateLimiter = RateLimiter(maxRequests: 5, windowSeconds: 60)
        let key = "test-client"
        
        // Make 5 requests - all should be allowed
        for i in 1...5 {
            let allowed = await rateLimiter.shouldAllow(key: key)
            #expect(allowed, "Request \(i) should be allowed")
        }
        
        // 6th request should be denied
        let denied = await rateLimiter.shouldAllow(key: key)
        #expect(!denied, "6th request should be denied")
    }
    
    @Test("Different keys have separate limits")
    func separateLimitsPerKey() async {
        let rateLimiter = RateLimiter(maxRequests: 2, windowSeconds: 60)
        
        // Client 1 makes 2 requests
        let allowed1_1 = await rateLimiter.shouldAllow(key: "client1")
        let allowed1_2 = await rateLimiter.shouldAllow(key: "client1")
        let denied1 = await rateLimiter.shouldAllow(key: "client1")
        
        #expect(allowed1_1)
        #expect(allowed1_2)
        #expect(!denied1)
        
        // Client 2 should still be able to make requests
        let allowed2_1 = await rateLimiter.shouldAllow(key: "client2")
        let allowed2_2 = await rateLimiter.shouldAllow(key: "client2")
        
        #expect(allowed2_1)
        #expect(allowed2_2)
    }
    
    @Test("Window cleanup removes old requests")
    func windowCleanup() async throws {
        let rateLimiter = RateLimiter(maxRequests: 2, windowSeconds: 1) // 1 second window
        let key = "test-client"
        
        // Make 2 requests - hit the limit
        let allowed1 = await rateLimiter.shouldAllow(key: key)
        let allowed2 = await rateLimiter.shouldAllow(key: key)
        let denied = await rateLimiter.shouldAllow(key: key)
        
        #expect(allowed1)
        #expect(allowed2)
        #expect(!denied)
        
        // Wait for window to expire
        try await Task.sleep(nanoseconds: 1_100_000_000) // 1.1 seconds
        
        // Should be able to make requests again
        let allowedAfterWindow = await rateLimiter.shouldAllow(key: key)
        #expect(allowedAfterWindow, "Should allow requests after window expires")
    }
    
    @Test("Concurrent access safety")
    func concurrentAccess() async {
        let rateLimiter = RateLimiter(maxRequests: 100, windowSeconds: 60)
        let key = "concurrent-client"
        
        // Make 100 concurrent requests
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 1...100 {
                group.addTask {
                    await rateLimiter.shouldAllow(key: key)
                }
            }
            
            var allowed = 0
            for await result in group {
                if result {
                    allowed += 1
                }
            }
            return allowed
        }
        
        // Exactly 100 requests should be allowed
        #expect(results == 100, "Expected exactly 100 requests to be allowed, got \(results)")
        
        // 101st request should be denied
        let denied = await rateLimiter.shouldAllow(key: key)
        #expect(!denied)
    }
    
    @Test("Zero requests limit")
    func zeroRequestsLimit() async {
        let rateLimiter = RateLimiter(maxRequests: 0, windowSeconds: 60)
        
        let denied = await rateLimiter.shouldAllow(key: "test")
        #expect(!denied, "Should deny all requests when limit is 0")
    }
} 