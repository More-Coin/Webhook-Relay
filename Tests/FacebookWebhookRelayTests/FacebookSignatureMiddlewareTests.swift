import Testing
import Vapor
import VaporTesting
@testable import FacebookWebhookRelay

@Suite("Facebook Signature Middleware Tests")
struct FacebookSignatureMiddlewareTests {
    
    private func setupTestEnvironment() {
        for (key, value) in TestFixtures.testEnvironment {
            setenv(key, value, 1)
        }
    }
    
    @Test("Valid signature passes verification")
    func validSignature() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            // Generate valid signature
            let payload = TestFixtures.validWebhookPayload
            let signature = TestFixtures.generateSignature(
                payload: payload,
                secret: TestFixtures.testEnvironment["APP_SECRET"]!
            )
            
            // Make request with valid signature
            try await app.testing().test(.POST, "webhook", beforeRequest: { req in
                req.headers.add(name: "X-Hub-Signature-256", value: signature)
                req.headers.contentType = .json
                req.body = ByteBuffer(data: payload.data(using: .utf8)!)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }
    
    @Test("Invalid signature fails verification")
    func invalidSignature() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            let payload = TestFixtures.validWebhookPayload
            
            // Make request with invalid signature
            try await app.testing().test(.POST, "webhook", beforeRequest: { req in
                req.headers.add(name: "X-Hub-Signature-256", value: "sha256=invalid_signature")
                req.headers.contentType = .json
                req.body = ByteBuffer(data: payload.data(using: .utf8)!)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }
    
    @Test("Missing signature header fails")
    func missingSignatureHeader() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            let payload = TestFixtures.validWebhookPayload
            
            // Make request without signature header
            try await app.testing().test(.POST, "webhook", beforeRequest: { req in
                req.headers.contentType = .json
                req.body = ByteBuffer(data: payload.data(using: .utf8)!)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }
    
    @Test("Malformed signature format fails")
    func malformedSignatureFormat() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            let payload = TestFixtures.validWebhookPayload
            
            // Make request with malformed signature (no sha256= prefix)
            try await app.testing().test(.POST, "webhook", beforeRequest: { req in
                req.headers.add(name: "X-Hub-Signature-256", value: "invalid_format_signature")
                req.headers.contentType = .json
                req.body = ByteBuffer(data: payload.data(using: .utf8)!)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }
    
    @Test("Empty body fails")
    func emptyBodyFails() async throws {
        setupTestEnvironment()
        
        try await withApp(configure: configure) { app in
            // Make request with empty body
            try await app.testing().test(.POST, "webhook", beforeRequest: { req in
                req.headers.add(name: "X-Hub-Signature-256", value: "sha256=doesntmatter")
                // No body set
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }
} 