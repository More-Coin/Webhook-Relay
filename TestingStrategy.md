# Complete Testing Strategy for Nara V2 + Facebook Webhook Relay

## Overview

This document outlines a comprehensive testing strategy for integrating the Nara V2 iOS app with the Facebook Webhook Relay. The strategy covers unit tests, integration tests, end-to-end tests, performance testing, and chaos engineering to ensure robust and reliable operation.

## Test Environment Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Mock Facebook  │────▶│  Webhook Relay   │────▶│ Mock NaraServer │
│   Simulator     │     │   (Real/Mock)    │     │                 │
└─────────────────┘     └──────────────────┘     └─────────────────┘
                               │ SSE                      │ WebSocket
                               ▼                          ▼
                        ┌──────────────────┐     ┌─────────────────┐
                        │   Nara V2 App    │     │  Relay (WS)     │
                        │  (Test Target)   │◀────│                 │
                        └──────────────────┘     └─────────────────┘
```

## Testing Layers

### Layer 1: Unit Tests (Nara V2 App)

Create test files in your Nara V2 project:

#### Message Processing Tests
```swift
// Tests/MessageProcessingTests.swift
import XCTest
@testable import Nara_V2

class MessageProcessingTests: XCTestCase {
    func testProcessConversationsWithThankYouMessage() {
        // Test the message processing logic
        let mockMessenger = FacebookMessenger(apiKey: "test", pageId: "test")
        let response = createMockConversationsResponse()
        
        MessageProcessing.processConversations(
            response,
            messenger: mockMessenger,
            conversations: &mockMessenger.conversations
        )
        
        XCTAssertEqual(mockMessenger.conversations.count, 1)
    }
    
    func testOrderDetectionInThaiMessages() {
        let orderMessages = TestMessageTemplates.orderMessages
        
        for message in orderMessages {
            let isOrder = MessageProcessing.detectOrder(in: message)
            XCTAssertTrue(isOrder, "Should detect order in: \(message)")
        }
    }
    
    func testNonOrderMessageDetection() {
        let nonOrderMessages = TestMessageTemplates.nonOrderMessages
        
        for message in nonOrderMessages {
            let isOrder = MessageProcessing.detectOrder(in: message)
            XCTAssertFalse(isOrder, "Should not detect order in: \(message)")
        }
    }
}
```

#### SSE Client Tests
```swift
// Tests/SSEClientTests.swift
class SSEClientTests: XCTestCase {
    func testSSEEventParsing() async {
        let sseClient = try! SSEClient(
            relayURL: "http://localhost:8080",
            apiKey: "test",
            certificatePinner: CertificatePinner(certificates: [])
        )
        
        // Test parsing different SSE event types
        let jsonString = """
        {"type":"new_message","message":{"id":"123","text":"Test"}}
        """
        
        let event = try sseClient.parseEvent(from: jsonString)
        XCTAssertEqual(event.type, "new_message")
        XCTAssertEqual(event.message?.text, "Test")
    }
    
    func testSSEConnectionRecovery() async {
        let sseClient = try! SSEClient(relayURL: "http://localhost:8080")
        
        // Simulate connection drop
        await sseClient.simulateConnectionDrop()
        
        // Verify reconnection
        let reconnected = await sseClient.waitForReconnection(timeout: 10)
        XCTAssertTrue(reconnected, "SSE client should reconnect automatically")
    }
}
```

### Layer 2: Integration Tests (Relay + App)

Create a test harness that runs both components:

#### Relay Integration Tests
```swift
// Tests/Integration/RelayIntegrationTests.swift
class RelayIntegrationTests: XCTestCase {
    var relayProcess: Process?
    var app: XCUIApplication?
    var mockNaraServer: MockNaraServer?
    var sseClient: TestSSEClient?
    
    override func setUp() {
        super.setUp()
        
        // Start mock NaraServer
        mockNaraServer = MockNaraServer()
        mockNaraServer?.start()
        
        // Start the webhook relay in test mode
        startWebhookRelay()
        
        // Setup SSE client for monitoring
        sseClient = TestSSEClient(url: "http://localhost:8080/events")
        
        // Launch the app
        app = XCUIApplication()
        app.launchEnvironment = [
            "WEBHOOK_RELAY_URL": "http://localhost:8080",
            "TEST_MODE": "1"
        ]
        app.launch()
    }
    
    func testMessageFlowFromWebhookToApp() async {
        // Send mock webhook to relay
        let webhook = MockFacebookWebhooks.generateMessageWebhook(
            text: "ขอบคุณครับ สั่งซื้อน้ำมันปลา 2 ขวด",
            senderId: "test_customer_123"
        )
        
        let response = try await sendWebhookToRelay(webhook)
        XCTAssertEqual(response.statusCode, 200)
        
        // Verify forwarding to NaraServer
        let forwardedWebhook = try await mockNaraServer?.waitForWebhook(timeout: 5)
        XCTAssertNotNil(forwardedWebhook)
        
        // Verify SSE broadcast
        let sseEvent = try await sseClient?.waitForEvent(timeout: 5)
        XCTAssertEqual(sseEvent?.type, "new_message")
        
        // Wait for message to appear in app
        let messageCell = app?.cells["message_test_customer_123"]
        XCTAssertTrue(messageCell?.waitForExistence(timeout: 5) ?? false)
    }
    
    func testMessageStateConsistency() async throws {
        let testMessage = "ขอบคุณครับ สั่งซื้อน้ำมันปลา"
        
        // Send message
        let webhook = MockFacebookWebhooks.generateMessageWebhook(text: testMessage)
        _ = try await sendWebhookToRelay(webhook)
        
        // Verify state in all components
        let relaySSE = try await sseClient?.waitForEvent(timeout: 5)
        let naraWebhook = try await mockNaraServer?.waitForWebhook(timeout: 5)
        
        // Verify message content is identical across all systems
        XCTAssertEqual(relaySSE?.message?.text, testMessage)
        XCTAssertEqual(naraWebhook?.entry[0].messaging[0].message.text, testMessage)
        
        // Verify app state
        let appMessage = try await getMessageFromApp(id: relaySSE?.message?.id)
        XCTAssertEqual(appMessage.text, testMessage)
    }
}
```

### Layer 3: End-to-End Test Scenarios

Create comprehensive test scenarios:

#### Message Flow Tests
```swift
// Tests/E2E/MessageFlowTests.swift
class MessageFlowE2ETests: XCTestCase {
    
    func testCompleteMessageFlow() async throws {
        // 1. Setup
        let testMessage = "ขอบคุณครับ สั่งซื้อน้ำมันปลา 2 ขวด"
        let customerId = "test_customer_123"
        
        // 2. Send webhook to relay
        let webhook = MockFacebookWebhooks.generateMessageWebhook(
            text: testMessage,
            senderId: customerId,
            includeThankYou: true
        )
        
        let signature = MockFacebookWebhooks.generateValidSignature(
            payload: webhook,
            secret: TestConfig.appSecret
        )
        
        let webhookResponse = try await sendToRelay(
            webhook: webhook,
            signature: signature
        )
        
        XCTAssertEqual(webhookResponse.statusCode, 200)
        
        // 3. Verify forwarding to NaraServer
        let forwardedWebhook = try await mockNaraServer.waitForWebhook(timeout: 5)
        XCTAssertNotNil(forwardedWebhook)
        XCTAssertEqual(forwardedWebhook.entry[0].messaging[0].message.text, testMessage)
        
        // 4. Verify SSE broadcast
        let sseEvent = try await sseClient.waitForEvent(timeout: 5)
        XCTAssertEqual(sseEvent.type, "new_message")
        XCTAssertEqual(sseEvent.message?.text, testMessage)
        
        // 5. Verify app UI update
        let app = XCUIApplication()
        let messageCell = app.cells.containing(.staticText, identifier: testMessage)
        XCTAssertTrue(messageCell.waitForExistence(timeout: 5))
    }
    
    func testMessageLatency() async throws {
        let startTime = Date()
        
        // Send webhook
        let webhook = MockFacebookWebhooks.generateMessageWebhook(text: "Latency Test")
        _ = try await sendToRelay(webhook: webhook)
        
        // Wait for SSE event
        let sseEvent = try await sseClient.waitForEvent(timeout: 5)
        
        let latency = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(latency, 1.0, "Message latency should be under 1 second")
        
        // Measure app UI update time
        let messageAppeared = app.cells.containing(.staticText, identifier: "Latency Test")
            .waitForExistence(timeout: 2)
        
        let totalLatency = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(totalLatency, 2.0, "End-to-end latency should be under 2 seconds")
    }
    
    func testConnectionRecovery() async throws {
        // Test SSE reconnection
        await sseClient.simulateConnectionDrop()
        let reconnected = await sseClient.waitForReconnection(timeout: 10)
        XCTAssertTrue(reconnected)
        
        // Test WebSocket reconnection
        await mockNaraServer.simulateConnectionDrop()
        let wsReconnected = await mockNaraServer.waitForReconnection(timeout: 10)
        XCTAssertTrue(wsReconnected)
        
        // Test message queuing during disconnection
        let webhook = MockFacebookWebhooks.generateMessageWebhook(text: "Recovery Test")
        _ = try await sendToRelay(webhook: webhook)
        
        let event = try await sseClient.waitForEvent(timeout: 5)
        XCTAssertEqual(event.message?.text, "Recovery Test")
    }
    
    func testErrorScenarios() async throws {
        // Test invalid signatures
        let webhook = MockFacebookWebhooks.generateMessageWebhook(text: "Invalid Test")
        let response = try await sendToRelay(webhook: webhook, signature: "invalid")
        XCTAssertEqual(response.statusCode, 401)
        
        // Test NaraServer down
        await mockNaraServer.stop()
        let webhookResponse = try await sendToRelay(webhook: webhook)
        XCTAssertEqual(webhookResponse.statusCode, 200) // Should still accept webhook
        
        // Test rate limiting
        for i in 0..<105 {
            let response = try await sendToRelay(webhook: webhook)
            if i < 100 {
                XCTAssertEqual(response.statusCode, 200)
            } else {
                XCTAssertEqual(response.statusCode, 429)
            }
        }
    }
    
    func testChaosScenarios() async throws {
        // Test random service failures
        let scenarios = [
            { await mockNaraServer.simulateDowntime(duration: 5) },
            { await relayService.simulateHighLatency(delay: 2) },
            { await sseClient.simulateConnectionDrop() }
        ]
        
        for scenario in scenarios {
            await scenario()
            
            // Send test message during chaos
            let webhook = MockFacebookWebhooks.generateMessageWebhook(text: "Chaos test")
            
            // Verify system recovers and processes message
            let result = try await sendToRelayWithRetry(webhook: webhook, maxRetries: 3)
            XCTAssertTrue(result.success, "System should recover from chaos")
        }
    }
}
```

## Mock Services Setup

### Mock Facebook Webhook Generator

```swift
// TestUtilities/MockFacebookWebhooks.swift
struct MockFacebookWebhooks {
    static func generateMessageWebhook(
        text: String,
        senderId: String = "123456",
        includeThankYou: Bool = false
    ) -> Data {
        let message = includeThankYou ? "ขอบคุณครับ \(text)" : text
        let json = """
        {
            "object": "page",
            "entry": [{
                "id": "test_page",
                "time": \(Date().timeIntervalSince1970 * 1000),
                "messaging": [{
                    "sender": {"id": "\(senderId)"},
                    "recipient": {"id": "page_123"},
                    "timestamp": \(Date().timeIntervalSince1970 * 1000),
                    "message": {
                        "mid": "mid.\(UUID().uuidString)",
                        "text": "\(message)"
                    }
                }]
            }]
        }
        """
        return json.data(using: .utf8)!
    }
    
    static func generateValidSignature(payload: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: payload)
        let signature = hmac.finalize()
        return "sha256=" + signature.map { String(format: "%02hhx", $0) }.joined()
    }
    
    static func generatePostbackWebhook(
        payload: String,
        senderId: String = "123456"
    ) -> Data {
        let json = """
        {
            "object": "page",
            "entry": [{
                "id": "test_page",
                "time": \(Date().timeIntervalSince1970 * 1000),
                "messaging": [{
                    "sender": {"id": "\(senderId)"},
                    "recipient": {"id": "page_123"},
                    "timestamp": \(Date().timeIntervalSince1970 * 1000),
                    "postback": {
                        "payload": "\(payload)",
                        "title": "Button Clicked"
                    }
                }]
            }]
        }
        """
        return json.data(using: .utf8)!
    }
}
```

### Test Data Management

```swift
// TestData/MessageTemplates.swift
struct TestMessageTemplates {
    static let orderMessages = [
        "ขอบคุณครับ สั่งซื้อน้ำมันปลา 2 ขวด",
        "ขอบคุณค่ะ ต้องการสั่งวิตามิน C 1 กล่อง",
        "Thank you! I'd like to order fish oil supplements",
        "ขอบคุณมากครับ สั่งซื้อโปรตีน 3 กล่อง",
        "ขอบคุณค่ะ อยากได้อาหารเสริม 5 ชิ้น"
    ]
    
    static let nonOrderMessages = [
        "สวัสดีครับ",
        "ราคาเท่าไหร่ครับ",
        "มีสินค้าอะไรบ้าง",
        "Hello there",
        "What products do you have?",
        "How much does it cost?"
    ]
    
    static let edgeCaseMessages = [
        "", // Empty message
        "🎉🎊✨", // Emoji only
        String(repeating: "A", count: 2000), // Very long message
        "ขอบคุณ" + String(repeating: "\n", count: 100), // Many newlines
        "Special chars: !@#$%^&*()_+-=[]{}|;':\",./<>?",
        "Mixed: ขอบคุณ 123 ABC !@# 🎉"
    ]
    
    static let performanceTestMessages = (0..<1000).map { i in
        "Performance test message #\(i) - ขอบคุณครับ สั่งซื้อสินค้า \(i) ชิ้น"
    }
}
```

### Enhanced Mock NaraServer

```javascript
// test-servers/mock-nara-server.js
const express = require('express');
const WebSocket = require('ws');

const app = express();
app.use(express.json());

// Store received webhooks for verification
const receivedWebhooks = [];
const connectedClients = new Set();

// Handle webhook forwarding
app.post('/webhook/facebook', (req, res) => {
    const scenario = req.headers['x-test-scenario'];
    
    console.log('Received webhook:', req.body);
    receivedWebhooks.push({
        ...req.body,
        receivedAt: new Date().toISOString(),
        scenario: scenario
    });
    
    switch (scenario) {
        case 'slow':
            setTimeout(() => {
                res.status(200).send('OK');
                simulateProcessingAndBroadcast(req.body);
            }, 2000);
            break;
        case 'error':
            res.status(500).send('Server Error');
            break;
        case 'timeout':
            // Don't respond (simulate timeout)
            break;
        default:
            res.status(200).send('OK');
            // Simulate processing and broadcast via WebSocket
            setTimeout(() => {
                simulateProcessingAndBroadcast(req.body);
            }, 100);
    }
});

function simulateProcessingAndBroadcast(webhook) {
    // Simulate different types of server messages
    const messageTypes = ['orderChange', 'customerChange', 'messageUpdate'];
    const randomType = messageTypes[Math.floor(Math.random() * messageTypes.length)];
    
    broadcast({
        type: randomType,
        entityId: `entity_${Date.now()}`,
        action: 'created',
        timestamp: new Date().toISOString(),
        data: {
            originalWebhook: webhook,
            processed: true
        }
    });
}

// Add webhook history endpoint for test verification
app.get('/test/webhooks', (req, res) => {
    res.json(receivedWebhooks);
});

// Add client count endpoint
app.get('/test/clients', (req, res) => {
    res.json({ count: connectedClients.size });
});

// Clear test data
app.delete('/test/clear', (req, res) => {
    receivedWebhooks.length = 0;
    res.json({ cleared: true });
});

// Simulate downtime
app.post('/test/simulate-downtime', (req, res) => {
    const duration = req.body.duration || 5000;
    
    // Close all WebSocket connections
    connectedClients.forEach(client => {
        if (client.readyState === WebSocket.OPEN) {
            client.close();
        }
    });
    
    setTimeout(() => {
        console.log('Simulated downtime ended');
    }, duration);
    
    res.json({ downtime: duration });
});

// WebSocket server
const wss = new WebSocket.Server({ port: 8081 });

wss.on('connection', (ws) => {
    connectedClients.add(ws);
    console.log('WebSocket client connected. Total:', connectedClients.size);
    
    ws.on('close', () => {
        connectedClients.delete(ws);
        console.log('WebSocket client disconnected. Total:', connectedClients.size);
    });
    
    ws.on('message', (message) => {
        console.log('Received WebSocket message:', message.toString());
    });
});

function broadcast(data) {
    const message = JSON.stringify(data);
    connectedClients.forEach(client => {
        if (client.readyState === WebSocket.OPEN) {
            client.send(message);
        }
    });
    console.log('Broadcasted to', connectedClients.size, 'clients:', data.type);
}

app.listen(8082, () => {
    console.log('Mock NaraServer HTTP running on :8082');
    console.log('Mock NaraServer WebSocket running on :8081');
});
```

## Performance and Load Testing

### Load Tests
```swift
// Tests/Performance/LoadTests.swift
class LoadTests: XCTestCase {
    
    func testHighVolumeMessageProcessing() {
        measure {
            // Send 100 webhooks rapidly
            let group = DispatchGroup()
            
            for i in 0..<100 {
                group.enter()
                Task {
                    let webhook = MockFacebookWebhooks.generateMessageWebhook(
                        text: TestMessageTemplates.performanceTestMessages[i % 1000],
                        senderId: "customer_\(i)"
                    )
                    _ = try? await sendToRelay(webhook: webhook)
                    group.leave()
                }
            }
            
            group.wait()
        }
    }
    
    func testSSEBroadcastPerformance() {
        measure {
            // Connect 50 SSE clients
            let clients = (0..<50).map { _ in TestSSEClient() }
            
            // Send messages and measure broadcast time
            let webhook = MockFacebookWebhooks.generateMessageWebhook(text: "Performance test")
            let startTime = Date()
            
            _ = try? await sendToRelay(webhook: webhook)
            
            // Wait for all clients to receive the message
            let allReceived = clients.allSatisfy { client in
                client.waitForEvent(timeout: 5) != nil
            }
            
            let broadcastTime = Date().timeIntervalSince(startTime)
            XCTAssertTrue(allReceived)
            XCTAssertLessThan(broadcastTime, 2.0, "Broadcast should complete within 2 seconds")
        }
    }
    
    func testMemoryUsageUnderLoad() {
        let initialMemory = getMemoryUsage()
        
        // Send 1000 messages
        for i in 0..<1000 {
            let webhook = MockFacebookWebhooks.generateMessageWebhook(
                text: "Memory test \(i)"
            )
            _ = try? await sendToRelay(webhook: webhook)
        }
        
        let finalMemory = getMemoryUsage()
        let memoryIncrease = finalMemory - initialMemory
        
        // Memory increase should be reasonable (less than 100MB)
        XCTAssertLessThan(memoryIncrease, 100_000_000, "Memory usage should not increase excessively")
    }
}
```

## Test Utilities

### Relay Test Client
```swift
// TestUtilities/RelayTestClient.swift
class RelayTestClient {
    private let baseURL: String
    
    init(baseURL: String = "http://localhost:8080") {
        self.baseURL = baseURL
    }
    
    func sendWebhook(_ webhook: Data, signature: String) async throws -> HTTPResponse {
        var request = URLRequest(url: URL(string: "\(baseURL)/webhook")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signature, forHTTPHeaderField: "X-Hub-Signature-256")
        request.httpBody = webhook
        
        let (data, response) = try await URLSession.shared.data(for: request)
        return HTTPResponse(data: data, response: response as! HTTPURLResponse)
    }
    
    func getHealth() async throws -> HealthStatus {
        let url = URL(string: "\(baseURL)/health")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(HealthStatus.self, from: data)
    }
    
    func connectSSE() -> TestSSEClient {
        return TestSSEClient(url: "\(baseURL)/events")
    }
}

struct HTTPResponse {
    let data: Data
    let statusCode: Int
    
    init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.statusCode = response.statusCode
    }
}
```

### Test SSE Client
```swift
// TestUtilities/TestSSEClient.swift
class TestSSEClient {
    private let url: String
    private var eventSource: EventSource?
    private var receivedEvents: [SSEEvent] = []
    private let eventQueue = DispatchQueue(label: "sse-events")
    
    init(url: String) {
        self.url = url
        connect()
    }
    
    private func connect() {
        eventSource = EventSource(url: URL(string: url)!)
        
        eventSource?.onMessage { [weak self] id, event, data in
            guard let self = self,
                  let eventData = data?.data(using: .utf8),
                  let sseEvent = try? JSONDecoder().decode(SSEEvent.self, from: eventData) else {
                return
            }
            
            self.eventQueue.async {
                self.receivedEvents.append(sseEvent)
            }
        }
    }
    
    func waitForEvent(timeout: TimeInterval) async -> SSEEvent? {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if let event = eventQueue.sync(execute: { receivedEvents.popFirst() }) {
                return event
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        return nil
    }
    
    func simulateConnectionDrop() {
        eventSource?.disconnect()
    }
    
    func waitForReconnection(timeout: TimeInterval) async -> Bool {
        connect()
        
        // Wait for connection event
        let connectionEvent = await waitForEvent(timeout: timeout)
        return connectionEvent?.type == "connected"
    }
}

struct SSEEvent: Codable {
    let type: String
    let message: Message?
    let timestamp: String
    
    struct Message: Codable {
        let id: String
        let text: String
        let senderId: String
    }
}
```

## Test Configuration

```swift
// Tests/TestConfig.swift
struct TestConfig {
    static let relayURL = "http://localhost:8080"
    static let mockNaraServerURL = "http://localhost:8082"
    static let mockNaraServerWSURL = "ws://localhost:8081"
    static let appSecret = "test_app_secret_67890"
    static let verifyToken = "test_verify_token_12345"
    static let pageAccessToken = "test_page_access_token"
    
    static var relayEnvironment: [String: String] {
        return [
            "VERIFY_TOKEN": verifyToken,
            "APP_SECRET": appSecret,
            "PAGE_ACCESS_TOKEN": pageAccessToken,
            "NARA_SERVER_URL": mockNaraServerURL,
            "NARA_SERVER_WS_URL": mockNaraServerWSURL,
            "NARA_SERVER_API_KEY": "test_api_key",
            "RELAY_MODE": "forward",
            "LOG_LEVEL": "debug"
        ]
    }
    
    static var appTestEnvironment: [String: String] {
        return [
            "WEBHOOK_RELAY_URL": relayURL,
            "TEST_MODE": "1",
            "MOCK_FACEBOOK_API": "1"
        ]
    }
}
```

## Docker Test Environment

### Test Docker Compose
```yaml
# docker-compose.test.yml
version: '3.8'

services:
  webhook-relay:
    build: .
    ports:
      - "8080:8080"
    environment:
      VERIFY_TOKEN: test_verify_token_12345
      APP_SECRET: test_app_secret_67890
      PAGE_ACCESS_TOKEN: test_page_access_token
      NARA_SERVER_URL: http://mock-nara-server:8082
      NARA_SERVER_WS_URL: ws://mock-nara-server:8081
      NARA_SERVER_API_KEY: test_api_key
      RELAY_MODE: forward
      LOG_LEVEL: debug
    depends_on:
      - mock-nara-server
    networks:
      - test-network

  mock-nara-server:
    build:
      context: ./test-servers
      dockerfile: Dockerfile.mock-nara
    ports:
      - "8082:8082"
      - "8081:8081"
    networks:
      - test-network

networks:
  test-network:
    driver: bridge
```

## Test Execution Scripts

### Main Test Script
```bash
#!/bin/bash
# test-all.sh

set -e

echo "🚀 Starting Complete Test Suite"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to print colored output
print_status() {
    echo -e "${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

# 1. Start mock services
print_status "📡 Starting mock services..."
docker-compose -f docker-compose.test.yml up -d

# Wait for services to be ready
print_status "⏳ Waiting for services to start..."
sleep 10

# Health check
if curl -f http://localhost:8080/health > /dev/null 2>&1; then
    print_status "✅ Webhook relay is healthy"
else
    print_error "❌ Webhook relay health check failed"
    exit 1
fi

if curl -f http://localhost:8082/test/webhooks > /dev/null 2>&1; then
    print_status "✅ Mock NaraServer is healthy"
else
    print_error "❌ Mock NaraServer health check failed"
    exit 1
fi

# 2. Run webhook relay tests
print_status "🔧 Testing Webhook Relay..."
cd FacebookWebhookRelay
if swift test; then
    print_status "✅ Webhook relay tests passed"
else
    print_error "❌ Webhook relay tests failed"
    exit 1
fi
cd ..

# 3. Run app unit tests
print_status "📱 Testing Nara V2 App Unit Tests..."
if xcodebuild test \
    -workspace "Nara V2.xcworkspace" \
    -scheme "Nara V2" \
    -destination "platform=iOS Simulator,name=iPhone 15" \
    -testPlan "UnitTests"; then
    print_status "✅ App unit tests passed"
else
    print_error "❌ App unit tests failed"
    exit 1
fi

# 4. Run integration tests
print_status "🔗 Running Integration Tests..."
if xcodebuild test \
    -workspace "Nara V2.xcworkspace" \
    -scheme "Nara V2" \
    -destination "platform=iOS Simulator,name=iPhone 15" \
    -testPlan "IntegrationTests"; then
    print_status "✅ Integration tests passed"
else
    print_error "❌ Integration tests failed"
    exit 1
fi

# 5. Run performance tests
print_status "⚡ Running Performance Tests..."
if xcodebuild test \
    -workspace "Nara V2.xcworkspace" \
    -scheme "Nara V2" \
    -destination "platform=iOS Simulator,name=iPhone 15" \
    -testPlan "PerformanceTests"; then
    print_status "✅ Performance tests passed"
else
    print_warning "⚠️ Performance tests failed (non-blocking)"
fi

# 6. Run E2E tests
print_status "🎯 Running End-to-End Tests..."
if xcodebuild test \
    -workspace "Nara V2.xcworkspace" \
    -scheme "Nara V2" \
    -destination "platform=iOS Simulator,name=iPhone 15" \
    -testPlan "E2ETests"; then
    print_status "✅ E2E tests passed"
else
    print_error "❌ E2E tests failed"
    exit 1
fi

# 7. Generate test report
print_status "📊 Generating Test Report..."
./generate-test-report.sh

# 8. Cleanup
print_status "🧹 Cleaning up..."
docker-compose -f docker-compose.test.yml down

print_status "✅ Test Suite Complete!"
echo ""
print_status "📋 Test Summary:"
echo "  - Webhook Relay Tests: ✅"
echo "  - App Unit Tests: ✅"
echo "  - Integration Tests: ✅"
echo "  - Performance Tests: ⚡"
echo "  - E2E Tests: ✅"
```

### Quick Test Script
```bash
#!/bin/bash
# quick-test.sh

echo "🚀 Running Quick Test Suite"

# Start services
docker-compose -f docker-compose.test.yml up -d
sleep 5

# Run basic tests
echo "🔧 Basic webhook relay test..."
cd FacebookWebhookRelay
swift test --filter "FacebookSignatureMiddlewareTests"
cd ..

echo "📱 Basic app tests..."
xcodebuild test \
    -workspace "Nara V2.xcworkspace" \
    -scheme "Nara V2" \
    -destination "platform=iOS Simulator,name=iPhone 15" \
    -only-testing "MessageProcessingTests"

# Cleanup
docker-compose -f docker-compose.test.yml down

echo "✅ Quick tests complete!"
```

## CI/CD Integration

### GitHub Actions Workflow
```yaml
# .github/workflows/test.yml
name: Test Suite

on: 
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: macos-latest
    
    steps:
    - name: Checkout code
      uses: actions/checkout@v4
      
    - name: Setup Swift
      uses: swift-actions/setup-swift@v1
      with:
        swift-version: '6.0'
        
    - name: Setup Xcode
      uses: maxim-lobanov/setup-xcode@v1
      with:
        xcode-version: '15.0'
        
    - name: Install dependencies
      run: |
        brew install docker-compose
        npm install -g nodemon
        
    - name: Start test services
      run: |
        docker-compose -f docker-compose.test.yml up -d
        sleep 10
        
    - name: Run webhook relay tests
      run: |
        cd FacebookWebhookRelay
        swift test
        cd ..
        
    - name: Run app tests
      run: |
        xcodebuild test \
          -workspace "Nara V2.xcworkspace" \
          -scheme "Nara V2" \
          -destination "platform=iOS Simulator,name=iPhone 15" \
          -resultBundlePath TestResults.xcresult
          
    - name: Upload test results
      uses: actions/upload-artifact@v4
      if: always()
      with:
        name: test-results
        path: |
          TestResults.xcresult
          test-reports/
          
    - name: Cleanup
      if: always()
      run: |
        docker-compose -f docker-compose.test.yml down
        
    - name: Comment PR with results
      if: github.event_name == 'pull_request'
      uses: actions/github-script@v7
      with:
        script: |
          const fs = require('fs');
          if (fs.existsSync('test-summary.md')) {
            const summary = fs.readFileSync('test-summary.md', 'utf8');
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: summary
            });
          }
```

## Testing Checklist

### Pre-Test Setup
- [ ] **Environment Setup**
  - [ ] Docker and Docker Compose installed
  - [ ] Xcode and iOS Simulator configured
  - [ ] Node.js for mock server
  - [ ] Test certificates and keys

- [ ] **Service Configuration**
  - [ ] Mock NaraServer running
  - [ ] Webhook relay configured with test environment
  - [ ] Test data prepared
  - [ ] Network connectivity verified

### Unit Tests
- [ ] **Message Processing Logic**
  - [ ] Order detection in Thai messages
  - [ ] Non-order message filtering
  - [ ] Edge case handling (empty, emoji, long messages)
  - [ ] Message parsing and validation

- [ ] **SSE Client**
  - [ ] Event parsing and deserialization
  - [ ] Connection management
  - [ ] Reconnection logic
  - [ ] Error handling

- [ ] **Data Persistence**
  - [ ] Message storage and retrieval
  - [ ] Conversation management
  - [ ] Data consistency

### Integration Tests
- [ ] **Webhook Flow**
  - [ ] Facebook → Relay → NaraServer
  - [ ] Signature verification
  - [ ] Error propagation
  - [ ] Retry mechanisms

- [ ] **Real-time Updates**
  - [ ] WebSocket → Relay → SSE
  - [ ] Message broadcasting
  - [ ] Connection recovery
  - [ ] State synchronization

### End-to-End Tests
- [ ] **Complete Message Flow**
  - [ ] Webhook reception to app display
  - [ ] Order detection and processing
  - [ ] UI updates and notifications
  - [ ] Data persistence verification

- [ ] **Error Scenarios**
  - [ ] Network failures
  - [ ] Service unavailability
  - [ ] Invalid data handling
  - [ ] Recovery procedures

### Performance Tests
- [ ] **Load Testing**
  - [ ] High volume message processing
  - [ ] Multiple concurrent SSE clients
  - [ ] Memory usage under load
  - [ ] Response time benchmarks

- [ ] **Stress Testing**
  - [ ] Rate limiting verification
  - [ ] Resource exhaustion scenarios
  - [ ] Graceful degradation
  - [ ] Recovery after overload

### Security Tests
- [ ] **Authentication**
  - [ ] Webhook signature validation
  - [ ] API key verification
  - [ ] Certificate pinning

- [ ] **Data Protection**
  - [ ] Message encryption in transit
  - [ ] Sensitive data handling
  - [ ] Access control verification

## Success Metrics

### Functional Metrics
- **Test Coverage**: >90% for critical paths
- **Pass Rate**: >95% for all test suites
- **Bug Detection**: Early detection of integration issues
- **Regression Prevention**: No breaking changes to existing functionality

### Performance Metrics
- **Message Latency**: <1 second end-to-end
- **Throughput**: >100 messages/second
- **Memory Usage**: <100MB increase under load
- **Connection Recovery**: <10 seconds for reconnection

### Reliability Metrics
- **Uptime**: >99.9% during testing
- **Error Rate**: <0.1% for normal operations
- **Data Consistency**: 100% message delivery accuracy
- **Recovery Time**: <30 seconds from failure

## Maintenance and Updates

### Regular Maintenance
- **Weekly**: Review test results and update test data
- **Monthly**: Performance benchmark comparison
- **Quarterly**: Test strategy review and optimization
- **Annually**: Complete test suite overhaul

### Continuous Improvement
- **Monitor**: Test execution times and flakiness
- **Optimize**: Slow or unreliable tests
- **Expand**: Coverage for new features
- **Refactor**: Test code for maintainability

---

## Conclusion

This comprehensive testing strategy ensures robust integration between the Nara V2 app and Facebook Webhook Relay. By implementing all layers of testing - from unit tests to chaos engineering - we can confidently deploy and maintain a reliable, high-performance system.

The strategy emphasizes:
- **Early detection** of integration issues
- **Comprehensive coverage** of all critical paths
- **Performance validation** under realistic loads
- **Automated execution** for continuous integration
- **Maintainable test code** for long-term success

Regular execution of this test suite will provide confidence in system reliability and enable rapid, safe deployment of new features and updates. 