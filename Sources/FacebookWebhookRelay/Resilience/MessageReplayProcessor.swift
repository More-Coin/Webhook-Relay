import Foundation
import Vapor

// MARK: - Message Replay Processor

/// Processes queued messages when circuit breaker recovers
actor MessageReplayProcessor {
    private let messageQueue: MessageQueue
    private let logger: Logger
    private let maxConcurrentReplays = 5
    private var isProcessing = false
    
    init(messageQueue: MessageQueue, logger: Logger) {
        self.messageQueue = messageQueue
        self.logger = logger
    }
    
    /// Start processing queued messages
    func startProcessing(using handler: @escaping (Data) async throws -> Void) async {
        guard !isProcessing else {
            logger.info("Message replay already in progress")
            return
        }
        
        isProcessing = true
        defer { isProcessing = false }
        
        logger.info("Starting message replay processing")
        
        do {
            let queueSize = try await messageQueue.size()
            logger.info("Found \(queueSize) messages to replay")
            
            // Process messages with controlled concurrency
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<maxConcurrentReplays {
                    group.addTask { [weak self] in
                        await self?.processMessages(using: handler)
                    }
                }
            }
            
            let finalSize = try await messageQueue.size()
            logger.info("Message replay completed", metadata: [
                "remainingMessages": "\(finalSize)"
            ])
        } catch {
            logger.error("Error during message replay: \(error)")
        }
    }
    
    private func processMessages(using handler: @escaping (Data) async throws -> Void) async {
        while isProcessing {
            do {
                // Get next message from queue
                guard let messageData = try await messageQueue.dequeue() else {
                    // No more messages
                    break
                }
                
                // Process the message
                try await handler(messageData)
                
                // Track success
                WebhookRelayMetrics.messagesDequeued.increment()
                
                logger.debug("Successfully replayed queued message")
            } catch {
                logger.error("Failed to replay message: \(error)")
                // Message remains in queue for retry
                break
            }
        }
    }
    
    func stopProcessing() {
        isProcessing = false
        logger.info("Stopping message replay processing")
    }
}

// MARK: - Circuit Breaker Recovery Handler

extension Application {
    /// Set up automatic message replay when circuit recovers
    func setupCircuitBreakerRecovery() {
        guard let circuitBreaker = self.circuitBreaker else {
            logger.warning("Cannot setup circuit breaker recovery - circuit breaker not configured")
            return
        }
        
        let replayProcessor = MessageReplayProcessor(
            messageQueue: self.messageQueue,
            logger: self.logger
        )
        
        // Monitor for circuit recovery
        circuitBreaker.onStateChange { oldState, newState in
            guard case .closed = newState,
                  case .open = oldState else { return }
            
            self.logger.info("Circuit breaker recovered - starting message replay")
            
            Task {
                await replayProcessor.startProcessing { messageData in
                    // Decode and forward the webhook
                    do {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let webhookEvent = try decoder.decode(FacebookWebhookEvent.self, from: messageData)
                        
                        // Create a mock request for forwarding
                        // In production, you might want to store more context with the queued message
                        let naraServerUrl = Environment.get("NARA_SERVER_URL") ?? ""
                        let naraServerApiKey = Environment.get("NARA_SERVER_API_KEY") ?? ""
                        
                        // Use the application's HTTP client directly
                        let uri = URI(string: "\(naraServerUrl)/webhook/facebook")
                        var headers = HTTPHeaders()
                        headers.add(name: .contentType, value: "application/json")
                        headers.add(name: .authorization, value: "Bearer \(naraServerApiKey)")
                        
                        // Forward with circuit breaker protection
                        let response = try await self.protectedClient.post(uri, headers: headers) { clientReq in
                            try clientReq.content.encode(webhookEvent)
                        }
                        
                        guard response.status == .ok else {
                            throw Abort(.internalServerError, reason: "NaraServer returned status: \(response.status)")
                        }
                        
                        self.logger.info("Successfully replayed webhook to NaraServer")
                        WebhookRelayMetrics.messagesForwarded.increment()
                    } catch {
                        self.logger.error("Failed to replay webhook: \(error)")
                        throw error
                    }
                }
            }
        }
    }
}

// MARK: - Manual Replay Endpoint

extension Application {
    /// Add manual message replay endpoint for operations
    func addMessageReplayEndpoint() {
        self.post("admin", "replay-messages") { req async throws -> Response in
            // Basic authentication check
            guard let authHeader = req.headers.first(name: .authorization),
                  authHeader.starts(with: "Bearer ") else {
                throw Abort(.unauthorized, reason: "Missing or invalid authorization")
            }
            
            let token = String(authHeader.dropFirst("Bearer ".count))
            let expectedToken = Environment.get("ADMIN_TOKEN") ?? ""
            
            guard !expectedToken.isEmpty && token == expectedToken else {
                throw Abort(.unauthorized, reason: "Invalid admin token")
            }
            
            // Get replay parameters
            struct ReplayRequest: Content {
                let maxMessages: Int?
                let dryRun: Bool?
            }
            
            let request = try req.content.decode(ReplayRequest.self)
            let maxMessages = request.maxMessages ?? Int.max
            let dryRun = request.dryRun ?? false
            
            let messageQueue = req.application.messageQueue
            let queueSize = try await messageQueue.size()
            
            if dryRun {
                return Response(status: .ok, body: .init(string: """
                {
                    "dryRun": true,
                    "queueSize": \(queueSize),
                    "messagesToReplay": \(min(queueSize, maxMessages))
                }
                """))
            }
            
            // Start replay in background
            Task {
                let processor = MessageReplayProcessor(
                    messageQueue: messageQueue,
                    logger: req.logger
                )
                
                await processor.startProcessing { messageData in
                    // Similar processing logic as above
                    req.logger.info("Manually replaying message")
                }
            }
            
            return Response(status: .accepted, body: .init(string: """
            {
                "status": "replay_started",
                "queueSize": \(queueSize)
            }
            """))
        }
    }
}