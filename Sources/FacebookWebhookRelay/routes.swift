import Vapor
import Crypto // For HMAC
import NIOCore

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
    // --- Firebase Initialization (Optional) ---
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
    
    // Ensure clean shutdown
    app.lifecycle.use(NaraServerConnectionLifecycleHandler(connection: naraServerConnection))

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
        
        // Apply rate limiting based on sender IP
        let clientIP = req.headers.first(name: "X-Forwarded-For") ?? req.remoteAddress?.description ?? "unknown"
        let allowed = await rateLimiter.shouldAllow(key: clientIP)
        
        guard allowed else {
            req.logger.warning("Rate limit exceeded for IP: \(clientIP)")
            
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
            } catch {
                req.logger.error("Failed to forward webhook to NaraServer: \(error)")
                
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
        return HealthStatus(
            status: "healthy",
            timestamp: Date().iso8601,
            connections: count,
            serverConnected: serverConnected
        )
    }
    
    // --- Message Sending Proxy ---
    app.post("api", "facebook", "send") { req async throws -> Response in
        // Verify authentication if needed
        // For now, we'll just forward the request
        
        let uri = URI(string: "\(naraServerUrl)/api/v1/messages/send")
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        headers.add(name: .authorization, value: "Bearer \(naraServerApiKey)")
        
        // Collect the request body
        let bodyBuffer = try await req.body.collect(max: 10 * 1024 * 1024).get() // 10MB max
        
        // Forward the request body
        let response = try await req.client.post(uri, headers: headers) { clientReq in
            if let buffer = bodyBuffer {
                clientReq.body = .init(buffer: buffer)
            }
        }
        
        // Return the response from NaraServer
        return Response(
            status: response.status,
            headers: response.headers,
            body: .init(buffer: response.body ?? ByteBuffer())
        )
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
            
            // Create the request task
            let requestTask = Task {
                try await req.client.post(uri, headers: headers) { clientReq in
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
        let response = try await req.client.get(uri, headers: headers)
        let senderInfo = try response.content.decode(SenderInfo.self)
        return senderInfo
    } catch {
        req.logger.error("Error getting sender info for \(senderId): \(error)")
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
