import Testing
import Vapor
import VaporTesting
@testable import FacebookWebhookRelay

@Suite("Webhook Integration Tests")
struct WebhookIntegrationTests {
    
    private func setupTestEnvironment() {
        for (key, value) in TestFixtures.testEnvironment {
            setenv(key, value, 1)
        }
    }
    
    @Test("GET webhook verification works correctly")
    func webhookVerification() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            // Test valid verification
            try await app.testing().test(.GET, "webhook", beforeRequest: { req in
                req.url.query = "hub.mode=subscribe&hub.verify_token=test_verify_token&hub.challenge=test_challenge_123"
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "test_challenge_123")
            })
            
            // Test invalid token
            try await app.testing().test(.GET, "webhook", beforeRequest: { req in
                req.url.query = "hub.mode=subscribe&hub.verify_token=wrong_token&hub.challenge=test_challenge_123"
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
            
            // Test missing parameters
            try await app.testing().test(.GET, "webhook", beforeRequest: { req in
                req.url.query = "hub.mode=subscribe"
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }
    
    @Test("Complete webhook processing flow")
    func completeWebhookFlow() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            let payload = TestFixtures.validWebhookPayload
            let signature = TestFixtures.generateSignature(
                payload: payload,
                secret: TestFixtures.testEnvironment["APP_SECRET"]!
            )
            
            // Test webhook processing
            try await app.testing().test(.POST, "webhook", beforeRequest: { req in
                req.headers.add(name: "X-Hub-Signature-256", value: signature)
                req.headers.contentType = .json
                req.body = ByteBuffer(data: payload.data(using: .utf8)!)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }
    
    @Test("Webhook with multiple messages")
    func webhookWithMultipleMessages() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            let payload = TestFixtures.webhookWithMultipleMessages
            let signature = TestFixtures.generateSignature(
                payload: payload,
                secret: TestFixtures.testEnvironment["APP_SECRET"]!
            )
            
            try await app.testing().test(.POST, "webhook", beforeRequest: { req in
                req.headers.add(name: "X-Hub-Signature-256", value: signature)
                req.headers.contentType = .json
                req.body = ByteBuffer(data: payload.data(using: .utf8)!)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }
    
    @Test("Postback webhook handling")
    func postbackWebhook() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            let payload = TestFixtures.postbackWebhookPayload
            let signature = TestFixtures.generateSignature(
                payload: payload,
                secret: TestFixtures.testEnvironment["APP_SECRET"]!
            )
            
            try await app.testing().test(.POST, "webhook", beforeRequest: { req in
                req.headers.add(name: "X-Hub-Signature-256", value: signature)
                req.headers.contentType = .json
                req.body = ByteBuffer(data: payload.data(using: .utf8)!)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }
    
    @Test("Malformed webhook payload handling")
    func malformedWebhookPayload() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            let payload = TestFixtures.malformedWebhookPayload
            let signature = TestFixtures.generateSignature(
                payload: payload,
                secret: TestFixtures.testEnvironment["APP_SECRET"]!
            )
            
            // Should still return 200 OK per Facebook requirements
            try await app.testing().test(.POST, "webhook", beforeRequest: { req in
                req.headers.add(name: "X-Hub-Signature-256", value: signature)
                req.headers.contentType = .json
                req.body = ByteBuffer(data: payload.data(using: .utf8)!)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }
    
    @Test("Health check endpoint")
    func healthCheckEndpoint() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "health", afterResponse: { res async in
                #expect(res.status == .ok)
                
                do {
                    let healthStatus = try res.content.decode(HealthStatus.self)
                    #expect(healthStatus.status == "healthy")
                    #expect(healthStatus.connections >= 0)
                    #expect(healthStatus.serverConnected == false || healthStatus.serverConnected == true)
                    #expect(!healthStatus.timestamp.isEmpty)
                } catch {
                    #expect(false, "Failed to decode health status: \(error)")
                }
            })
        }
    }
} 