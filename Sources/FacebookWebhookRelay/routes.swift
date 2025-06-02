import Vapor
import Crypto // For HMAC
import NIOCore
import NIOHTTP1 // For NIOConnectionError
import Foundation // For pow function

// Simple in-memory rate limiter
actor RateLimiter {
    private var requests: [String: [Date]] = [:]
    private let maxRequests: Int
    private let windowSeconds: TimeInterval
    
    init(maxRequests: Int = 100, windowSeconds: TimeInterval = 60) {
        self.maxRequests = maxRequests
        self.windowSeconds = windowSeconds
    }
    
    func shouldAllow(key: String) -> Bool {
        let now = Date()
        let windowStart = now.addingTimeInterval(-windowSeconds)
        
        // Clean old requests
        requests[key] = requests[key]?.filter { $0 > windowStart } ?? []
        
        // Check if under limit
        let requestCount = requests[key]?.count ?? 0
        if requestCount < maxRequests {
            requests[key, default: []].append(now)
            return true
        }
        
        return false
    }
}

func routes(_ app: Application) throws {
    // --- Firebase Initialization (Disabled for now) ---
    let firebaseService: FirebaseService? = nil
    
    /*
    let firebaseService: FirebaseService? = {
        do {
            _ = try FirebaseConfiguration.fromEnvironment()
            let service = FirebaseService()
            // Configure Firebase synchronously for now
            // TODO: Make this async when needed
            app.logger.info("✅ Firebase service created (configuration pending)")
            return service
        } catch {
            app.logger.warning("⚠️ Firebase not configured: \(error)")
            return nil
        }
    }()
    */
    
    // --- Environment Variables ---
    guard let verifyToken = Environment.get("VERIFY_TOKEN") else {
        fatalError("VERIFY_TOKEN not set in environment")
    }
    guard let appSecret = Environment.get("APP_SECRET") else {
        fatalError("APP_SECRET not set in environment")
    }
    guard let pageAccessToken = Environment.get("PAGE_ACCESS_TOKEN") else {
        fatalError("PAGE_ACCESS_TOKEN not set in environment")
    }
    
    // --- NaraServer Configuration ---
    guard let naraServerUrl = Environment.get("NARA_SERVER_URL") else {
        fatalError("NARA_SERVER_URL not set in environment")
    }
    guard let naraServerApiKey = Environment.get("NARA_SERVER_API_KEY") else {
        fatalError("NARA_SERVER_API_KEY not set in environment")
    }
    let naraServerWsUrl = Environment.get("NARA_SERVER_WS_URL") ?? "\(naraServerUrl.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://"))/live"
    let relayDeviceId = Environment.get("RELAY_DEVICE_ID") ?? "webhook_relay_1"
    let relayMode = Environment.get("RELAY_MODE") ?? "forward"

    // --- SSE Management ---
    let sseManager = SSEManager()
    
    // --- Rate Limiting ---
    let rateLimiter = RateLimiter(maxRequests: 100, windowSeconds: 60)
    
    // --- NaraServer WebSocket Connection ---
    let naraServerConnection = NaraServerConnection(
        sseManager: sseManager,
        naraServerWsUrl: naraServerWsUrl,
        naraServerApiKey: naraServerApiKey,
        relayDeviceId: relayDeviceId
    )
    
    // Connect to NaraServer WebSocket on startup
    Task {
        await naraServerConnection.connect(app: app)
    }
    
    // Start periodic status reporting (every 30 seconds)
    let statusReportingTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            
            // Only send status if connected
            if await naraServerConnection.isConnected() {
                await naraServerConnection.sendRelayStatus()
            }
        }
    }
    
    // Ensure clean shutdown
    app.lifecycle.use(NaraServerConnectionLifecycleHandler(connection: naraServerConnection))
    
    // Cancel status reporting on shutdown
    app.lifecycle.use(
        LifecycleHandler(
            shutdownAsync: { app in
                app.logger.info("Cancelling status reporting task")
                statusReportingTask.cancel()
            }
        )
    )

    // --- Middleware for Signature Verification ---
    let facebookSignatureMiddleware = FacebookSignatureMiddleware(appSecret: appSecret)

    // --- Webhook Verification (GET) ---
    app.get("webhook") { req -> Response in
        req.logger.info("Received GET /webhook request")
        guard let mode = req.query[String.self, at: "hub.mode"],
              let token = req.query[String.self, at: "hub.verify_token"],
              let challenge = req.query[String.self, at: "hub.challenge"] else {
            req.logger.error("❌ Webhook verification failed: Missing query parameters")
            throw Abort(.badRequest, reason: "Missing hub.mode, hub.verify_token, or hub.challenge")
        }

        if mode == "subscribe" && token == verifyToken {
            req.logger.info("✅ Webhook verified successfully")
            return Response(status: .ok, body: .init(string: challenge))
        } else {
            req.logger.error("❌ Webhook verification failed: Mode or token mismatch.")
            req.logger.info("Mode: \(mode), Token: \(token), Expected Token: \(verifyToken)")
            throw Abort(.forbidden, reason: "Webhook verification failed")
        }
    }

    // --- Webhook Event Handler (POST) ---
    // Apply the signature middleware only to this route
    app.grouped(facebookSignatureMiddleware).post("webhook") { req -> HTTPStatus in
        req.logger.info("Received POST /webhook request")
        
        // Track message received
        WebhookRelayMetrics.messagesReceived.increment()
        
        // Apply rate limiting based on sender IP
        let clientIP = req.headers.first(name: "X-Forwarded-For") ?? req.remoteAddress?.description ?? "unknown"
        let allowed = await rateLimiter.shouldAllow(key: clientIP)
        
        guard allowed else {
            req.logger.warning("Rate limit exceeded for IP: \(clientIP)")
            
            // Track rate limit error
            WebhookRelayMetrics.rateLimitErrors.increment()
            
            // Log rate limit exceeded to Firebase
            if let firebase = firebaseService {
                await firebase.logRateLimitExceeded(clientIP: clientIP, endpoint: "/webhook")
            }
            
            throw Abort(.tooManyRequests, reason: "Rate limit exceeded")
        }
        
        let webhookEvent: FacebookWebhookEvent
        do {
            webhookEvent = try req.content.decode(FacebookWebhookEvent.self)
        } catch {
            req.logger.error("Failed to decode webhook event: \(error)")
            
            // Log error to Firebase
            if let firebase = firebaseService {
                await firebase.logError(
                    category: .webhookProcessing,
                    message: "Failed to decode webhook event: \(error.localizedDescription)",
                    context: ["endpoint": "/webhook", "method": "POST"]
                )
            }
            
            // Facebook expects a 200 OK even if we can't process, to avoid being disabled.
            // However, if the signature was invalid, the middleware would have aborted earlier.
            return .ok
        }

        // Log webhook received event to Firebase
        if let firebase = firebaseService {
            let messageCount = webhookEvent.entry.reduce(0) { total, entry in
                total + (entry.messaging?.count ?? 0)
            }
            let pageId = webhookEvent.entry.first?.id
            await firebase.logWebhookReceived(
                source: "facebook", 
                messageCount: messageCount,
                webhookType: webhookEvent.object,
                pageId: pageId
            )
        }

        // Forward to NaraServer if in forward mode
        if relayMode == "forward" || relayMode == "both" {
            let forwardStartTime = Date()
            do {
                try await forwardToNaraServer(webhookEvent, req: req, naraServerUrl: naraServerUrl, naraServerApiKey: naraServerApiKey, firebaseService: firebaseService)
                
                // Track successful forward
                let forwardDuration = Date().timeIntervalSince(forwardStartTime)
                WebhookRelayMetrics.recordSuccessfulForward(duration: forwardDuration)
                
                // Log successful forwarding
                if let firebase = firebaseService {
                    let responseTime = Date().timeIntervalSince(forwardStartTime)
                    let messageSize = try? JSONEncoder().encode(webhookEvent).count
                    await firebase.logMessageForwarded(
                        destination: "nara_server", 
                        success: true,
                        responseTime: responseTime,
                        messageSize: messageSize
                    )
                }
            } catch let error as CircuitBreakerError {
                // Circuit breaker is open - use fallback strategy
                req.logger.warning("Circuit breaker prevented forward: \(error)")
                
                // Queue the message for later delivery
                let fallback = MessageQueueFallback(
                    messageQueue: req.application.messageQueue,
                    logger: req.logger
                )
                
                try await fallback.execute(webhookEvent)
                
                // Track circuit breaker rejection
                WebhookRelayMetrics.recordFailedForward(reason: "circuit_open")
                
                // Continue processing locally as fallback
            } catch {
                req.logger.error("Failed to forward webhook to NaraServer: \(error)")
                
                // Track failed forward
                let errorReason = (error as? Abort)?.reason ?? "network_error"
                WebhookRelayMetrics.recordFailedForward(reason: errorReason)
                
                // Track network errors specifically
                if error is URLError || error is NIOConnectionError {
                    WebhookRelayMetrics.networkErrors.increment()
                }
                
                // Log failed forwarding and error
                if let firebase = firebaseService {
                    let responseTime = Date().timeIntervalSince(forwardStartTime)
                    await firebase.logMessageForwarded(
                        destination: "nara_server", 
                        success: false,
                        responseTime: responseTime
                    )
                    
                    await firebase.logError(
                        category: .naraServerConnection,
                        message: "Failed to forward webhook: \(error.localizedDescription)",
                        context: ["server_url": naraServerUrl, "response_time_ms": Int(responseTime * 1000)]
                    )
                }
                // Continue processing locally as fallback during migration
            }
        }

        // Process locally if in process mode or both
        if relayMode == "process" || relayMode == "both" {
            if webhookEvent.object == "page" {
                for entry in webhookEvent.entry {
                    if let messagingEvents = entry.messaging {
                        for event in messagingEvents {
                            await handleMessagingEvent(event, req: req, sseManager: sseManager, pageAccessToken: pageAccessToken)
                        }
                    }
                }
            }
        }
        
        req.logger.info("✅ EVENT_RECEIVED (mode: \(relayMode))")
        return .ok
    }

    // In routes.swift
    app.get("events") { req -> Response in
        // ... (setup code for producer, sourceForYielding, etc. remains the same) ...
        req.logger.info("New SSE connection request")
        let id = UUID()

        let nilDelegate = NIOAsyncSequenceProducerDelegateNil()

        let producer = NIOAsyncSequenceProducer.makeSequence(
            elementType: String.self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: 1,
                highWatermark: 5
            ),
            finishOnDeinit: false,
            delegate: nilDelegate
        )
        
        let stringAsyncSequence = producer.sequence
        let sourceForYielding = producer.source

        //print("Type of sourceForYielding in routes.swift: \(type(of: sourceForYielding))")

        let promise = req.eventLoop.makePromise(of: Void.self)
        await sseManager.addConnection(id: id, source: sourceForYielding, promise: promise)

        let initialData = """
        data: {"type": "connected", "timestamp": "\(Date().iso8601)"}\n\n
        """
        _ = sourceForYielding.yield(initialData)
        
        req.logger.info("SSE connection \(id) established. Sending initial data.")
        
        // Log SSE connection to Firebase
        if let firebase = firebaseService {
            let connectionCount = await sseManager.getConnectionCount()
            await firebase.logSSEConnection(action: "connected", connectionCount: connectionCount)
        }

        _ = req.eventLoop.makeFutureWithTask {
            try? await promise.futureResult.get()
            sourceForYielding.finish()
            await sseManager.removeConnection(id: id)
            req.logger.info("SSE connection \(id) closed by client or server.")
            
            // Log SSE disconnection to Firebase
            if let firebase = firebaseService {
                let connectionCount = await sseManager.getConnectionCount()
                await firebase.logSSEConnection(action: "disconnected", connectionCount: connectionCount)
            }
        }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/event-stream")
        // ... (other headers)

        let responseBody = Response.Body(stream: { writer in
            Task {
                do {
                    for try await sseString in stringAsyncSequence {
                        var buffer = req.application.allocator.buffer(capacity: sseString.utf8.count)
                        buffer.writeString(sseString)
                        // writer.write returns an EventLoopFuture<Void>. We need to await its result.
                        try await writer.write(.buffer(buffer)).get() // Use .get() to await the future
                    }
                    try await writer.write(.end).get() // Also await the future from .end
                } catch {
                    req.logger.error("Error streaming SSE events: \(error)")
                    // Attempt to end the stream, awaiting the future
                    try? await writer.write(.end).get()
                }
            }
        })

        return Response(
            status: .ok,
            headers: headers,
            body: responseBody
        )
    }

    // --- Health Check Endpoint ---
    app.get("health") { req async -> HealthStatus in
        let count = await sseManager.getConnectionCount()
        let serverConnected = await naraServerConnection.isConnected()
        
        // Get circuit breaker status if available
        var circuitBreakerStatus: String? = nil
        if let circuitBreaker = req.application.circuitBreaker {
            let metrics = await circuitBreaker.getMetrics()
            circuitBreakerStatus = metrics.state
            
            // Update circuit breaker metrics
            let stateValue: Double = metrics.state.contains("closed") ? 0 : (metrics.state.contains("open") ? 1 : 2)
            WebhookRelayMetrics.circuitBreakerState.record(stateValue)
            WebhookRelayMetrics.circuitBreakerFailureRate.record(metrics.windowMetrics.failureRate)
        }
        
        return HealthStatus(
            status: "healthy",
            timestamp: Date().iso8601,
            connections: count,
            serverConnected: serverConnected,
            circuitBreakerState: circuitBreakerStatus
        )
    }
    
    // --- Queue Health Check Endpoint ---
    app.get("health", "queue") { req async throws -> QueueHealth in
        let messageQueue = req.application.messageQueue
        
        if let redisQueue = messageQueue as? RedisMessageQueue {
            return try await redisQueue.healthCheck()
        } else {
            // For in-memory queue, create basic health info
            let size = try await messageQueue.size()
            let maxSize = 10000 // Default max size
            return QueueHealth(
                size: size,
                maxSize: maxSize,
                isHealthy: size < maxSize,
                utilizationPercent: Double(size) / Double(maxSize) * 100
            )
        }
    }
    
    // --- Circuit Breaker Status Endpoint ---
    app.get("circuit-breaker") { req async throws -> Response in
        guard let circuitBreaker = req.application.circuitBreaker else {
            throw Abort(.notFound, reason: "Circuit breaker not configured")
        }
        
        let metrics = await circuitBreaker.getMetrics()
        return try await metrics.encodeResponse(for: req)
    }
    
    // --- Queue Management Endpoints ---
    
    // Get queue statistics
    app.get("admin", "queue", "stats") { req async throws -> Response in
        guard let queue = req.application.messageQueue as? PersistentMessageQueueProtocol else {
            throw Abort(.internalServerError, reason: "Persistent queue not configured")
        }
        
        let stats = try await queue.getStatistics()
        return try await stats.encodeResponse(for: req)
    }
    
    // Get DLQ messages
    app.get("admin", "queue", "dlq") { req async throws -> Response in
        guard let dlqManager = req.application.deadLetterQueueManager else {
            throw Abort(.internalServerError, reason: "DLQ manager not configured")
        }
        
        let limit = req.query[Int.self, at: "limit"] ?? 100
        let messages = try await dlqManager.getMessages(limit: limit)
        
        return try await Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: JSONEncoder().encode(messages))
        )
    }
    
    // Replay message from DLQ
    app.post("admin", "queue", "dlq", "replay", ":messageId") { req async throws -> HTTPStatus in
        guard let dlqManager = req.application.deadLetterQueueManager else {
            throw Abort(.internalServerError, reason: "DLQ manager not configured")
        }
        
        let messageId = req.parameters.get("messageId") ?? ""
        try await dlqManager.replayMessage(messageId)
        
        return .ok
    }
    
    // Replay messages by time range
    app.post("admin", "queue", "replay", "time-range") { req async throws -> Response in
        guard let replayService = req.application.messageReplayService else {
            throw Abort(.internalServerError, reason: "Replay service not configured")
        }
        
        struct TimeRangeRequest: Content {
            let from: Date
            let to: Date
            let messageType: String?
            let limit: Int?
        }
        
        let request = try req.content.decode(TimeRangeRequest.self)
        
        let filter = MessageFilter(
            messageType: request.messageType,
            fromDate: request.from,
            toDate: request.to,
            limit: request.limit ?? 1000
        )
        
        let result = try await replayService.replayFromTimeRange(
            from: request.from,
            to: request.to,
            filter: filter
        )
        
        return try await result.encodeResponse(for: req)
    }
    
    // Get queue health
    app.get("admin", "queue", "health") { req async throws -> Response in
        guard let monitor = req.application.queueMonitor else {
            throw Abort(.internalServerError, reason: "Queue monitor not configured")
        }
        
        let health = try await monitor.getQueueHealth()
        return try await health.encodeResponse(for: req)
    }
    
    // --- Metrics Endpoint ---
    app.get("metrics") { req async throws -> Response in
        // Update real-time metrics before export
        let queueSize = try await req.application.messageQueue.size()
        WebhookRelayMetrics.updateQueueMetrics(depth: queueSize)
        
        let sseConnections = await sseManager.getConnectionCount()
        let websocketConnected = await naraServerConnection.isConnected()
        WebhookRelayMetrics.updateConnectionMetrics(
            sseConnections: sseConnections,
            websocketConnected: websocketConnected
        )
        
        // Export metrics in Prometheus format
        let metricsText = PrometheusExporter.export()
        
        return Response(
            status: .ok,
            headers: ["Content-Type": "text/plain; version=0.0.4"],
            body: .init(string: metricsText)
        )
    }
    
    // --- Message Sending Proxy (Updated for Callback Pattern) ---
    app.post("api", "facebook", "send") { req async throws -> Response in
        req.logger.info("📤 Received message send request")
        
        // Verify authentication if needed
        // For now, we'll just forward the request
        
        let uri = URI(string: "\(naraServerUrl)/api/v1/messages/send")
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        headers.add(name: .authorization, value: "Bearer \(naraServerApiKey)")
        
        // Add callback URL so NaraServer knows where to send the processed message
        let callbackUrl = Environment.get("CALLBACK_BASE_URL") ?? "http://localhost:8080"
        headers.add(name: "X-Callback-URL", value: "\(callbackUrl)/callback/facebook/send")
        
        // Collect the request body
        let bodyBuffer = try await req.body.collect(max: 10 * 1024 * 1024).get() // 10MB max
        
        // Forward the request body to NaraServer with circuit breaker protection
        let response = try await req.protectedClient.post(uri, headers: headers) { clientReq in
            if let buffer = bodyBuffer {
                clientReq.body = .init(buffer: buffer)
            }
        }
        
        req.logger.info("📨 Forwarded message to NaraServer, status: \(response.status)")
        
        // Return the response from NaraServer (might be an acknowledgment)
        return Response(
            status: response.status,
            headers: response.headers,
            body: .init(buffer: response.body ?? ByteBuffer())
        )
    }
    
    // --- Callback Endpoint for NaraServer to Send Processed Messages ---
    app.post("callback", "facebook", "send") { req async throws -> HTTPStatus in
        req.logger.info("📥 Received callback from NaraServer for message send")
        
        // Verify this is from NaraServer (basic auth check)
        guard let authHeader = req.headers.first(name: .authorization),
              authHeader == "Bearer \(naraServerApiKey)" else {
            req.logger.warning("❌ Unauthorized callback request")
            throw Abort(.unauthorized, reason: "Invalid authorization")
        }
        
        // Try to decode as flattened format first, then fall back to nested format
        let messageRequest: FacebookSendMessageRequest
        do {
            // Try flattened format first
            let flattenedRequest = try req.content.decode(FlattenedMessageRequest.self)
            messageRequest = flattenedRequest.toFacebookRequest()
            req.logger.info("📝 Decoded flattened message for recipient '\(flattenedRequest.recipientPSID)': \(flattenedRequest.text)")
            req.logger.info("📋 Conversation ID: \(flattenedRequest.conversationId ?? "none")")
        } catch {
            // Fall back to nested format
            do {
                messageRequest = try req.content.decode(FacebookSendMessageRequest.self)
                req.logger.info("📝 Decoded nested message for recipient '\(messageRequest.recipient.id)': \(messageRequest.message.text ?? "No text")")
            } catch {
                req.logger.error("❌ Failed to decode callback message in any format. Flattened error: \(error)")
                
                // Log error to Firebase if available
                if let firebase = firebaseService {
                    await firebase.logError(
                        category: .webhookProcessing,
                        message: "Failed to decode callback message: \(error.localizedDescription)",
                        context: ["endpoint": "/callback/facebook/send", "method": "POST"]
                    )
                }
                
                throw Abort(.badRequest, reason: "Invalid message format: \(error.localizedDescription)")
            }
        }
        
        // Add test mode handling
        if messageRequest.recipient.id == "test" || messageRequest.recipient.id.hasPrefix("test_") {
            req.logger.info("🧪 Test mode - skipping Facebook API call for recipient: \(messageRequest.recipient.id)")
            req.logger.info("✅ Would have sent message: '\(messageRequest.message.text ?? "No text")'")
            return .ok
        }
        
        // Send the message to Facebook with enhanced error handling
        let maxRetries = 3
        var lastError: (any Error)?
        
        for attempt in 1...maxRetries {
            do {
                try await sendMessageToFacebookWithRetry(messageRequest, pageAccessToken: pageAccessToken, req: req, attempt: attempt)
                req.logger.info("✅ Successfully sent message to Facebook (attempt \(attempt)/\(maxRetries))")
                
                // Log successful callback to Firebase
                if let firebase = firebaseService {
                    await firebase.logApiProxyRequest(
                        endpoint: "/callback/facebook/send",
                        method: "POST",
                        success: true
                    )
                }
                
                return .ok
            } catch {
                lastError = error
                req.logger.warning("⚠️ Failed to send message to Facebook (attempt \(attempt)/\(maxRetries)): \(error)")
                
                if attempt < maxRetries {
                    // Exponential backoff: 1s, 2s, 4s
                    let delayNanoseconds = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } else {
                    // Log final failure to Firebase
                    if let firebase = firebaseService {
                        await firebase.logApiProxyRequest(
                            endpoint: "/callback/facebook/send",
                            method: "POST",
                            success: false
                        )
                        
                        await firebase.logError(
                            category: .webhookProcessing,
                            message: "Failed to send message to Facebook after \(maxRetries) attempts: \(error.localizedDescription)",
                            context: [
                                "endpoint": "/callback/facebook/send",
                                "attempts": maxRetries,
                                "recipient_id": messageRequest.recipient.id
                            ]
                        )
                    }
                }
            }
        }
        
        req.logger.error("❌ Failed to send message to Facebook after \(maxRetries) attempts: \(lastError?.localizedDescription ?? "Unknown error")")
        throw Abort(.internalServerError, reason: "Failed to send to Facebook after \(maxRetries) attempts")
    }
}

// --- NaraServer Integration ---
func forwardToNaraServer(_ webhookEvent: FacebookWebhookEvent, req: Request, naraServerUrl: String, naraServerApiKey: String, firebaseService: FirebaseService? = nil) async throws {
    let uri = URI(string: "\(naraServerUrl)/webhook/facebook")
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    headers.add(name: .authorization, value: "Bearer \(naraServerApiKey)")
    
    let maxRetries = 3
    let timeoutSeconds: Int64 = 30
    var lastError: (any Error)?
    
    for attempt in 1...maxRetries {
        do {
            // Create a timeout task
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw Abort(.requestTimeout, reason: "Request to NaraServer timed out after \(timeoutSeconds) seconds")
            }
            
            // Create the request task with circuit breaker protection
            let requestTask = Task {
                try await req.protectedClient.post(uri, headers: headers) { clientReq in
                    try clientReq.content.encode(webhookEvent)
                }
            }
            
            // Race between timeout and request
            let response = try await withTaskCancellationHandler {
                try await requestTask.value
            } onCancel: {
                timeoutTask.cancel()
                requestTask.cancel()
            }
            
            // Cancel the timeout task if request succeeded
            timeoutTask.cancel()
            
            guard response.status == .ok else {
                let error = Abort(.internalServerError, reason: "NaraServer returned status: \(response.status)")
                lastError = error
                
                if attempt < maxRetries {
                    req.logger.warning("Failed to forward to NaraServer (attempt \(attempt)/\(maxRetries)): \(response.status)")
                    // Exponential backoff
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
                
                throw error
            }
            
            req.logger.info("✅ Successfully forwarded webhook to NaraServer (attempt \(attempt)/\(maxRetries))")
            return
            
        } catch {
            lastError = error
            
            if attempt < maxRetries {
                req.logger.warning("Failed to forward to NaraServer (attempt \(attempt)/\(maxRetries)): \(error)")
                // Exponential backoff
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                continue
            }
        }
    }
    
    req.logger.error("Failed to forward to NaraServer after \(maxRetries) attempts")
    throw lastError ?? Abort(.internalServerError, reason: "Failed to forward webhook to NaraServer")
}

// --- Helper Functions ---
func handleMessagingEvent(_ event: FacebookMessagingEvent, req: Request, sseManager: SSEManager, pageAccessToken: String) async {
    req.logger.info("📨 Received messaging event: \(String(reflecting: event))")

    let senderId = event.sender.id
    // let recipientId = event.recipient.id // Useful if your bot manages multiple pages
    let timestamp = Date(timeIntervalSince1970: TimeInterval(event.timestamp / 1000)) // FB timestamp is ms

    if let messageContent = event.message {
        await handleMessage(messageContent, senderId: senderId, timestamp: timestamp, req: req, sseManager: sseManager, pageAccessToken: pageAccessToken)
    } else if let postback = event.postback {
        await handlePostback(postback, senderId: senderId, req: req, sseManager: sseManager)
    }
}

func handleMessage(_ message: FacebookMessageContent, senderId: String, timestamp: Date, req: Request, sseManager: SSEManager, pageAccessToken: String) async {
    guard let messageText = message.text else {
        req.logger.info("Received message without text content from \(senderId)")
        return
    }
    let messageId = message.mid

    req.logger.info("📱 Message from \(senderId): \(messageText)")

    let senderInfo = await getSenderInfo(senderId: senderId, req: req, pageAccessToken: pageAccessToken)
    
    let appMsg = AppMessage(
        id: messageId,
        senderId: senderId,
        senderName: senderInfo.name.isEmpty ? "Unknown User" : senderInfo.name,
        text: messageText,
        timestamp: timestamp.iso8601,
        isFromCustomer: true,
        conversationId: senderId, // Using sender ID as conversation ID
        customerName: senderInfo.name.isEmpty ? "Unknown User" : senderInfo.name,
        customerId: senderId
    )
    let messageData = AppMessageData(type: "new_message", appMessage: appMsg, timestamp: timestamp)

    await sseManager.broadcast(data: messageData)
}

func handlePostback(_ postback: FacebookPostback, senderId: String, req: Request, sseManager: SSEManager) async {
    req.logger.info("🔄 Postback from \(senderId): \(postback.payload)")
    
    let postbackData = AppMessageData(
        postbackSenderId: senderId, // The type defaults to "postback"
        payload: postback.payload,
        timestamp: Date()
    )
    await sseManager.broadcast(data: postbackData)
}

func getSenderInfo(senderId: String, req: Request, pageAccessToken: String) async -> SenderInfo {
    let uri = URI(string: "https://graph.facebook.com/v19.0/\(senderId)?fields=first_name,last_name&access_token=\(pageAccessToken)")

    var headers = HTTPHeaders()
    headers.add(name: .accept, value: "application/json")

    do {
        let response = try await req.protectedClient.get(uri, headers: headers)
        let senderInfo = try response.content.decode(SenderInfo.self)
        
        // Cache successful response
        await req.application.responseCache.set(senderId, value: senderInfo)
        
        return senderInfo
    } catch let error as CircuitBreakerError {
        // Circuit breaker is open - use cached response
        req.logger.warning("Circuit breaker prevented Facebook API call: \(error)")
        
        let fallback = CachedResponseFallback(
            cache: req.application.responseCache,
            logger: req.logger
        )
        
        return (try? await fallback.execute(senderId)) ?? SenderInfo(firstName: "Unknown", lastName: "User")
    } catch {
        req.logger.error("Error getting sender info for \(senderId): \(error)")
        
        // Try cache as last resort
        if let cached = await req.application.responseCache.get(senderId) as? SenderInfo {
            req.logger.info("Using cached sender info due to error")
            return cached
        }
        
        return SenderInfo(firstName: "Unknown", lastName: "User")
    }
}

struct FacebookSignatureMiddleware: AsyncMiddleware {
    let appSecret: String

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let maxBodySize = 10 * 1024 * 1024 // 10MB
        guard let bodyBuffer = try await request.body.collect(max: maxBodySize).get() else {
            request.logger.error("❌ Request body is empty or could not be collected.")
            throw Abort(.badRequest, reason: "Request body is empty or could not be collected.")
        }

        // Convert ByteBuffer to Data for HMAC computation
        let bodyData = Data(buffer: bodyBuffer)

        guard let signatureHeader = request.headers.first(name: "X-Hub-Signature-256") else {
            request.logger.warning("⚠️ No signature found in request to /webhook")
            throw Abort(.unauthorized, reason: "Missing X-Hub-Signature-256 header")
        }

        guard signatureHeader.starts(with: "sha256=") else {
            request.logger.error("❌ Invalid signature format.")
            throw Abort(.badRequest, reason: "Invalid signature format. Expected 'sha256=...'")
        }
        
        let signature = String(signatureHeader.dropFirst("sha256=".count))

        let secretKey = SymmetricKey(data: Data(appSecret.utf8))
        var hmac = HMAC<SHA256>(key: secretKey)
        hmac.update(data: bodyData)
        let computedHash = hmac.finalize()
        
        let expectedSignature = computedHash.map { String(format: "%02hhx", $0) }.joined()

        if signature == expectedSignature {
            request.logger.info("✅ Signature verified for /webhook POST")
            return try await next.respond(to: request)
        } else {
            request.logger.error("❌ Invalid signature for /webhook POST. Expected: \(expectedSignature), Got: \(signature)")
            throw Abort(.unauthorized, reason: "Invalid signature.")
        }
    }
}

// --- Facebook API Integration ---
func sendMessageToFacebook(_ messageRequest: FacebookSendMessageRequest, pageAccessToken: String, req: Request) async throws {
    let pageId = "597164376811779" // Your page ID - should come from environment in production
    let uri = URI(string: "https://graph.facebook.com/v19.0/\(pageId)/messages")
    
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    headers.add(name: .accept, value: "application/json")
    
    // Prepare the Facebook API request
    var facebookRequest: [String: Any] = [
        "recipient": ["id": messageRequest.recipient.id],
        "message": [:],
        "access_token": pageAccessToken
    ]
    
    // Add message content
    var messageContent: [String: Any] = [:]
    if let text = messageRequest.message.text {
        messageContent["text"] = text
    }
    
    if let attachment = messageRequest.message.attachment {
        messageContent["attachment"] = [
            "type": attachment.type,
            "payload": [
                "url": attachment.payload.url ?? "",
                "template_type": attachment.payload.templateType ?? ""
            ]
        ]
    }
    
    facebookRequest["message"] = messageContent
    
    // Add messaging type if specified
    if let messagingType = messageRequest.messagingType {
        facebookRequest["messaging_type"] = messagingType
    }
    
    // Add tag if specified
    if let tag = messageRequest.tag {
        facebookRequest["tag"] = tag
    }
    
    req.logger.info("🌐 Sending message to Facebook API: \(uri)")
    
    // Convert to Data for the request
    let jsonData = try JSONSerialization.data(withJSONObject: facebookRequest)
    
    // Send the request to Facebook with circuit breaker protection
    let response = try await req.protectedClient.post(uri, headers: headers) { clientReq in
        clientReq.body = .init(data: jsonData)
    }
    
    guard response.status.code >= 200 && response.status.code < 300 else {
        let errorBody = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0) ?? "No error details"
        req.logger.error("❌ Facebook API error (\(response.status)): \(errorBody)")
        throw Abort(.internalServerError, reason: "Facebook API error: \(response.status)")
    }
    
    req.logger.info("✅ Message sent to Facebook successfully")
}

func sendMessageToFacebookWithRetry(_ messageRequest: FacebookSendMessageRequest, pageAccessToken: String, req: Request, attempt: Int) async throws {
    let maxRetries = 3 // Define maxRetries for this function
    let pageId = "597164376811779" // Your page ID - should come from environment in production
    let uri = URI(string: "https://graph.facebook.com/v19.0/\(pageId)/messages")
    
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json")
    headers.add(name: .accept, value: "application/json")
    
    // Prepare the Facebook API request
    var facebookRequest: [String: Any] = [
        "recipient": ["id": messageRequest.recipient.id],
        "message": [:],
        "access_token": pageAccessToken
    ]
    
    // Add message content
    var messageContent: [String: Any] = [:]
    if let text = messageRequest.message.text {
        messageContent["text"] = text
    }
    
    if let attachment = messageRequest.message.attachment {
        messageContent["attachment"] = [
            "type": attachment.type,
            "payload": [
                "url": attachment.payload.url ?? "",
                "template_type": attachment.payload.templateType ?? ""
            ]
        ]
    }
    
    facebookRequest["message"] = messageContent
    
    // Add messaging type if specified
    if let messagingType = messageRequest.messagingType {
        facebookRequest["messaging_type"] = messagingType
    }
    
    // Add tag if specified
    if let tag = messageRequest.tag {
        facebookRequest["tag"] = tag
    }
    
    req.logger.info("🌐 Sending message to Facebook API: \(uri)")
    
    // Convert to Data for the request
    let jsonData = try JSONSerialization.data(withJSONObject: facebookRequest)
    
    // Send the request to Facebook with circuit breaker protection
    let response = try await req.protectedClient.post(uri, headers: headers) { clientReq in
        clientReq.body = .init(data: jsonData)
    }
    
    guard response.status.code >= 200 && response.status.code < 300 else {
        let errorBody = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0) ?? "No error details"
        req.logger.error("❌ Facebook API error (\(response.status)): \(errorBody)")
        throw Abort(.internalServerError, reason: "Facebook API error: \(response.status)")
    }
    
    req.logger.info("✅ Message sent to Facebook successfully (attempt \(attempt)/\(maxRetries))")
}
