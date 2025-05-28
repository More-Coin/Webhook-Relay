# Swift/Vapor Webhook Relay Integration Task List

## Phase 1: Remove Local Processing Logic
- [x] Remove `processMessageForOrders()` function - order detection should happen on server
- [x] Remove order keyword detection logic
- [x] Remove the "potential_order" event type from broadcasting
- [x] Keep only raw message forwarding functionality

## Phase 2: Add NaraServer Integration
- [x] Add NaraServer URL to environment variables:
  ```swift
  guard let naraServerUrl = Environment.get("NARA_SERVER_URL") else {
      fatalError("NARA_SERVER_URL not set in environment")
  }
  guard let naraServerApiKey = Environment.get("NARA_SERVER_API_KEY") else {
      fatalError("NARA_SERVER_API_KEY not set in environment")
  }
  ```

- [x] Create a service to forward webhooks to NaraServer:
  ```swift
  func forwardToNaraServer(_ webhookEvent: FacebookWebhookEvent, req: Request) async throws {
      let uri = URI(string: "\(naraServerUrl)/webhook/facebook")
      var headers = HTTPHeaders()
      headers.add(name: .contentType, value: "application/json")
      
      let response = try await req.client.post(uri, headers: headers) { clientReq in
          try clientReq.content.encode(webhookEvent)
      }
      
      guard response.status == .ok else {
          req.logger.error("Failed to forward to NaraServer: \(response.status)")
          throw Abort(.internalServerError)
      }
  }
  ```

- [x] Modify the webhook handler to forward instead of process:
  ```swift
  app.grouped(facebookSignatureMiddleware).post("webhook") { req -> HTTPStatus in
      let webhookEvent = try req.content.decode(FacebookWebhookEvent.self)
      
      // Forward to NaraServer
      try await forwardToNaraServer(webhookEvent, req: req)
      
      // Still return 200 to Facebook
      return .ok
  }
  ```

## Phase 3: Add WebSocket Client to NaraServer
- [x] Add WebSocket dependencies to Package.swift (already included via Vapor)
- [x] Create WebSocket client service:
  ```swift
  actor NaraServerConnection {
      private var ws: WebSocket?
      private let logger = Logger(label: "nara-server-connection")
      private let sseManager: SSEManager
      
      func connect(app: Application, sseManager: SSEManager) async {
          // Connect to NaraServer WebSocket
          // Handle incoming messages and broadcast via SSE
      }
  }
  ```

- [x] Handle server messages and broadcast to SSE clients:
  ```swift
  func handleServerMessage(_ data: String) async {
      guard let messageData = data.data(using: .utf8),
            let serverMessage = try? JSONDecoder().decode(ServerMessage.self, from: messageData) else {
          return
      }
      
      // Convert server message to AppMessageData format
      let appMessageData = convertServerMessage(serverMessage)
      await sseManager.broadcast(data: appMessageData)
  }
  ```

## Phase 4: Create Models for Server Communication
- [x] Add server message models:
  ```swift
  struct ServerMessage: Codable {
      let type: String // "orderChange", "customerChange", etc.
      let entityId: String
      let action: String
      let timestamp: String
      let data: JSON // Use SwiftyJSON or similar for dynamic data
  }
  ```

## Phase 5: Add Message Sending Proxy (Optional)
- [x] Create endpoint to forward message sending requests:
  ```swift
  app.post("api", "facebook", "send") { req -> Response in
      // Verify authentication
      // Forward to NaraServer /api/v1/messages/send
      // Return response
  }
  ```

## Phase 6: Update SSE Message Format
- [x] Ensure SSE messages match what iOS/macOS apps expect
- [x] Add message source identifier to distinguish relay vs server messages

## Phase 7: Add Resilience Features
- [x] Implement reconnection logic for WebSocket to NaraServer
- [x] Add retry logic for webhook forwarding
- [x] Implement request timeout handling
- [ ] Add circuit breaker pattern for server communication

## Phase 8: Update Monitoring
- [x] Add NaraServer connection status to health check:
  ```swift
  struct HealthStatus: Content {
      let status: String
      let timestamp: String
      let connections: Int
      let serverConnected: Bool  // New field
  }
  ```

- [x] Add structured logging for all forwarding operations
- [ ] Track forwarding latency metrics

## Phase 9: Security Updates
- [ ] Add authentication for SSE connections (if needed by iOS/macOS apps)
- [x] Validate all data before forwarding
- [x] Implement rate limiting

## Phase 10: Testing
- [ ] Update tests for forwarding behavior
- [ ] Add integration tests with mock NaraServer
- [ ] Test reconnection scenarios
- [ ] Load test forwarding capacity

## Phase 11: Documentation
- [x] Update README with new architecture
- [x] Document environment variables
- [x] Create migration guide for iOS/macOS apps

## Phase 12: Deployment Updates
- [x] Update Dockerfile with new environment variables
- [x] Update docker-compose.yml
- [ ] Create deployment scripts

## Phase 13: Migration Strategy
- [x] Deploy in parallel mode (both forward and process)
- [x] Add feature flag to toggle between modes
- [x] Monitor both paths
- [ ] Gradually migrate traffic
- [ ] Remove local processing code

## Environment Variables to Add:
```bash
# Existing
VERIFY_TOKEN=your_verify_token
APP_SECRET=your_app_secret  
PAGE_ACCESS_TOKEN=your_page_access_token

# New
NARA_SERVER_URL=https://your-server.com
NARA_SERVER_API_KEY=Vk0KvGEKsuhUMkULHdhtWhVHlgRYdI2sCeG6vCaH384
NARA_SERVER_WS_URL=wss://your-server.com/live
RELAY_DEVICE_ID=webhook_relay_1
RELAY_MODE=forward  # or "process" for legacy mode
```

## Summary
The key changes needed:
1. **Stop processing messages locally** - Remove order detection and parsing ✅
2. **Forward all webhooks to NaraServer** - Add HTTP client to forward Facebook webhooks ✅
3. **Connect to NaraServer via WebSocket** - Receive processed updates from server ✅
4. **Broadcast server updates to iOS/macOS apps** - Use existing SSE infrastructure ✅
5. **Add resilience and monitoring** - Handle failures gracefully ✅

This maintains your existing Swift/Vapor architecture while converting it from a processing relay to a forwarding relay.
