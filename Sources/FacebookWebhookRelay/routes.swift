import Vapor
import Crypto // For HMAC
import NIOCore

func routes(_ app: Application) throws {
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

    // --- SSE Management ---
    let sseManager = SSEManager()

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
        
        let webhookEvent: FacebookWebhookEvent
        do {
            webhookEvent = try req.content.decode(FacebookWebhookEvent.self)
        } catch {
            req.logger.error("Failed to decode webhook event: \(error)")
            // Facebook expects a 200 OK even if we can't process, to avoid being disabled.
            // However, if the signature was invalid, the middleware would have aborted earlier.
            return .ok
        }

        if webhookEvent.object == "page" {
            for entry in webhookEvent.entry {
                if let messagingEvents = entry.messaging {
                    for event in messagingEvents {
                        await handleMessagingEvent(event, req: req, sseManager: sseManager, pageAccessToken: pageAccessToken)
                    }
                }
            }
            req.logger.info("✅ EVENT_RECEIVED")
            return .ok
        } else {
            req.logger.warning("Received non-page object: \(webhookEvent.object)")
            throw Abort(.notFound)
        }
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

        _ = req.eventLoop.makeFutureWithTask {
            try? await promise.futureResult.get()
            sourceForYielding.finish()
            await sseManager.removeConnection(id: id)
            req.logger.info("SSE connection \(id) closed by client or server.")
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
        return HealthStatus(
            status: "healthy",
            timestamp: Date().iso8601,
            connections: count
        )
    }
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
    await processMessageForOrders(appMsg, req: req, sseManager: sseManager)
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


func processMessageForOrders(_ message: AppMessage, req: Request, sseManager: SSEManager) async {
    let orderKeywords = ["สั่ง", "ขอ", "order", "buy", "purchase"] // Ensure your keywords match expected input
    let hasOrderKeyword = orderKeywords.contains { keyword in
        message.text.lowercased().contains(keyword.lowercased())
    }

    if hasOrderKeyword {
        req.logger.info("🛒 Potential order detected in message: \(message.text)")
        
        let orderEvent = AppMessageData(
            type: "potential_order",
            appMessage: message, // Assuming 'message' here is of type AppMessage
            timestamp: Date()
        )
        await sseManager.broadcast(data: orderEvent)
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
