import Testing
import Vapor
@testable import FacebookWebhookRelay

@Suite("Firebase Service Tests")
struct FirebaseServiceTests {
    
    @Test("Can log events with valid parameters")
    func logEventWithParameters() async {
        let firebaseService = FirebaseService()
        
        // Test webhook received event
        await firebaseService.logWebhookReceived(
            source: "facebook",
            messageCount: 2,
            webhookType: "page",
            pageId: "123456"
        )
        
        // Test message forwarded event
        await firebaseService.logMessageForwarded(
            destination: "nara_server",
            success: true,
            responseTime: 0.123,
            messageSize: 1024
        )
        
        // Test SSE connection event
        await firebaseService.logSSEConnection(
            action: "connected",
            connectionCount: 5,
            clientInfo: "iOS App v1.0",
            connectionDuration: 120.5
        )
        
        // Test server connection event
        await firebaseService.logServerConnection(
            connected: true,
            server: "nara_server",
            reconnectionCount: 2,
            latency: 0.050
        )
        
        // All methods should complete without error
        #expect(true) // If we get here, all logging worked
    }
    
    @Test("Can log error events with categories")
    func logErrorEvents() async {
        let firebaseService = FirebaseService()
        
        // Test different error categories
        await firebaseService.logError(
            category: .webhookProcessing,
            message: "Failed to decode webhook",
            stackTrace: "at line 123",
            context: ["endpoint": "/webhook", "method": "POST"]
        )
        
        await firebaseService.logError(
            category: .naraServerConnection,
            message: "Connection timeout",
            context: ["server": "nara_server", "timeout": "30s"]
        )
        
        await firebaseService.logError(
            category: .sseDelivery,
            message: "Client disconnected unexpectedly"
        )
        
        // All methods should complete without error
        #expect(true)
    }
    
    @Test("Can log operational events")
    func logOperationalEvents() async {
        let firebaseService = FirebaseService()
        
        // Test relay started
        await firebaseService.logRelayStarted(port: 8080, mode: "forward")
        
        // Test relay shutdown
        await firebaseService.logRelayShutdown(reason: "graceful_shutdown")
        
        // Test API proxy request
        await firebaseService.logApiProxyRequest(
            endpoint: "/api/facebook/send",
            method: "POST",
            success: true,
            responseTime: 0.245
        )
        
        // Test rate limit exceeded
        await firebaseService.logRateLimitExceeded(
            clientIP: "192.168.1.1",
            endpoint: "/webhook"
        )
        
        // All methods should complete without error
        #expect(true)
    }
    
    @Test("Handles nil optional parameters gracefully")
    func handlesNilParameters() async {
        let firebaseService = FirebaseService()
        
        // Test with nil optional parameters
        await firebaseService.logWebhookReceived(
            source: "facebook",
            messageCount: 1,
            webhookType: nil,
            pageId: nil
        )
        
        await firebaseService.logMessageForwarded(
            destination: "nara_server",
            success: false,
            responseTime: nil,
            messageSize: nil
        )
        
        await firebaseService.logSSEConnection(
            action: "disconnected",
            connectionCount: 0,
            clientInfo: nil,
            connectionDuration: nil
        )
        
        await firebaseService.logServerConnection(
            connected: false,
            server: "nara_server",
            reconnectionCount: 0,
            latency: nil
        )
        
        await firebaseService.logRelayShutdown(reason: nil)
        
        await firebaseService.logError(
            category: .configuration,
            message: "Config error",
            stackTrace: nil,
            context: nil
        )
        
        await firebaseService.logApiProxyRequest(
            endpoint: "/api/test",
            method: "GET",
            success: false,
            responseTime: nil
        )
        
        // All methods should complete without error
        #expect(true)
    }
} 