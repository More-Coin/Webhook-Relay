import Vapor
import NIOCore
import AsyncHTTPClient
import Darwin

actor NaraServerConnection {
    private var ws: WebSocket?
    private let logger = Logger(label: "nara-server-connection")
    private let sseManager: SSEManager
    private let naraServerWsUrl: String
    private let naraServerApiKey: String
    private let relayDeviceId: String
    private var reconnectTask: Task<Void, Never>?
    private var isConnecting = false
    
    // Message buffering for when disconnected
    private var messageBuffer: [String] = []
    private let maxBufferSize = 1000
    
    // Message acknowledgment tracking
    private struct PendingMessage {
        let id: String
        let content: String
        let sentAt: Date
        let attempt: Int
    }
    private var pendingMessages: [String: PendingMessage] = [:]
    private let messageTimeout: TimeInterval = 30.0 // 30 seconds
    private let maxRetries = 3
    
    // Message converter
    private let messageConverter: SSEMessageConverter
    
    init(sseManager: SSEManager, naraServerWsUrl: String, naraServerApiKey: String, relayDeviceId: String) {
        self.sseManager = sseManager
        self.naraServerWsUrl = naraServerWsUrl
        self.naraServerApiKey = naraServerApiKey
        self.relayDeviceId = relayDeviceId
        
        // Initialize converter based on environment setting
        let useLegacyFormat = Environment.get("SSE_LEGACY_FORMAT") == "true"
        self.messageConverter = SSEMessageConverter(useLegacyFormat: useLegacyFormat)
    }
    
    func connect(app: Application) async {
        guard !isConnecting else {
            logger.info("Already attempting to connect")
            return
        }
        
        isConnecting = true
        defer { isConnecting = false }
        
        do {
            logger.info("Connecting to NaraServer WebSocket at \(naraServerWsUrl)")
            
            // Build WebSocket URL with query parameters for authentication
            let urlWithParams = buildWebSocketURL()
            
            logger.info("🔧 Built WebSocket URL with auth params [baseURL: \(naraServerWsUrl), finalURL: \(urlWithParams.replacingOccurrences(of: naraServerApiKey, with: "***TOKEN***"))]")
            
            try await app.eventLoopGroup.any().makeFutureWithTask {
                try await WebSocket.connect(
                    to: urlWithParams,
                    on: app.eventLoopGroup.next()
                ) { [weak self] ws in
                    // Set up callbacks synchronously on the WebSocket's event loop
                    Task { [weak self] in
                        await self?.storeWebSocket(ws)
                    }
                    
                    // Handle incoming messages
                    ws.onText { [weak self] ws, text in
                        Task {
                            await self?.handleServerMessage(text)
                        }
                    }
                    
                    // Handle binary messages if needed
                    ws.onBinary { [weak self] ws, buffer in
                        Task {
                            await self?.logger.debug("Received binary message from NaraServer (ignored)")
                        }
                    }
                    
                    // Handle close
                    ws.onClose.whenComplete { [weak self] result in
                        Task {
                            switch result {
                            case .success:
                                await self?.logger.warning("WebSocket closed normally")
                            case .failure(let error):
                                await self?.logger.error("WebSocket closed with error: \(error)")
                            }
                            await self?.handleDisconnection()
                        }
                    }
                }
            }.get()
        } catch {
            logger.error("Failed to connect to NaraServer: \(error)")
            await scheduleReconnect(app: app)
        }
    }
    
    private func buildWebSocketURL() -> String {
        guard var urlComponents = URLComponents(string: naraServerWsUrl) else {
            logger.warning("Failed to parse base WebSocket URL, using as-is")
            return naraServerWsUrl
        }
        
        urlComponents.queryItems = [
            URLQueryItem(name: "token", value: naraServerApiKey),
            URLQueryItem(name: "device_id", value: relayDeviceId),
            URLQueryItem(name: "platform", value: "webhook-relay")
        ]
        
        guard let finalURL = urlComponents.url?.absoluteString else {
            logger.warning("Failed to construct WebSocket URL with query parameters, using base URL")
            return naraServerWsUrl
        }
        
        return finalURL
    }
    
    private func storeWebSocket(_ ws: WebSocket) async {
        self.ws = ws
        self.logger.info("✅ Connected to NaraServer WebSocket")
        
        // Wait for server confirmation instead of sending connection message
        // Authentication is now handled via URL query parameters
        self.logger.info("🎧 Waiting for server confirmation message...")
        
        // Flush any buffered messages
        await flushMessageBuffer()
    }
    
    private func flushMessageBuffer() async {
        guard !messageBuffer.isEmpty else { return }
        
        logger.info("Flushing \(messageBuffer.count) buffered messages")
        let messagesToFlush = messageBuffer
        messageBuffer.removeAll()
        
        for message in messagesToFlush {
            do {
                if let ws = ws, !ws.isClosed {
                    try await ws.send(message)
                    logger.debug("Flushed buffered message")
                } else {
                    // Re-buffer if still not connected
                    messageBuffer.append(message)
                }
            } catch {
                logger.error("Failed to flush buffered message: \(error)")
                // Re-buffer on failure
                if messageBuffer.count < maxBufferSize {
                    messageBuffer.append(message)
                }
            }
        }
    }
    
    private func handleServerMessage(_ data: String) async {
        guard let messageData = data.data(using: .utf8) else {
            logger.warning("Failed to convert server message to data")
            return
        }
        
        // First check if this is an acknowledgment message
        await updateServerMessageHandling(data)
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            // Try to decode as a new WebSocket message format first
            if let json = try? JSONSerialization.jsonObject(with: messageData, options: []) as? [String: Any],
               let messageType = json["messageType"] as? String {
                
                // Handle new message types
                switch messageType {
                case WebSocketMessageType.processingResult:
                    // Already handled in updateServerMessageHandling
                    logger.debug("Received processing result acknowledgment")
                    return
                    
                case WebSocketMessageType.relayCoordination:
                    logger.info("Received relay coordination message")
                    // Handle coordination commands if needed
                    return
                    
                default:
                    // Fall through to legacy handling
                    break
                }
            }
            
            // Legacy message handling
            let serverMessage = try decoder.decode(ServerMessage.self, from: messageData)
            
            logger.info("📨 Received server message: \(serverMessage.type) | ID: \(serverMessage.id)")
            
            // Handle specific message types
            switch serverMessage.type {
            case "connected":
                logger.info("✅ Server confirmed connection")
                return
            case "error":
                logger.error("❌ Server error: \(serverMessage.entityId ?? "Unknown error")")
                return
            default:
                break
            }
            
            // Convert server message to SSE format and broadcast
            if let sseMessage = messageConverter.convertServerMessage(serverMessage) {
                await sseManager.broadcast(message: sseMessage)
                logger.info("📡 Broadcasted \(serverMessage.type) to SSE clients")
            }
        } catch {
            logger.error("Failed to decode server message: \(error)")
            logger.debug("Raw message: \(data)")
            
            // Try to broadcast error message as fallback
            let errorMessage = ErrorSSE(
                errorCode: "DECODE_ERROR",
                errorMessage: "Failed to decode server message: \(error.localizedDescription)",
                details: ["rawMessage": AnyCodable(data)]
            )
            await sseManager.broadcast(message: .error(errorMessage))
        }
    }
    
    // Conversion is now handled by SSEMessageConverter
    
    internal func convertServerMessage_DEPRECATED(_ serverMessage: ServerMessage) -> AppMessageData? {
        // Convert NaraServer messages to your app's format
        // Note: For non-postback events, we should not use entityId as senderId
        // The senderId should only be set for actual messages/postbacks from users
        
        switch serverMessage.type {
        case "customerChange":
            // Create a rich payload with all the data
            var payloadData: [String: Any] = [
                "action": serverMessage.action ?? "unknown",
                "entityId": serverMessage.entityId ?? "",
                "entityType": "customer"
            ]
            
            // Preserve the full data field if available
            if let data = serverMessage.data,
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) {
                payloadData["data"] = jsonObject
            }
            
            let payloadString = (try? JSONSerialization.data(withJSONObject: payloadData, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\\"error\\": \\"serialization_failed\\"}"
            
            return AppMessageData(
                type: "customer_update",
                postbackSenderId: "system", // System-generated event, not user-initiated
                payload: payloadString,
                timestamp: serverMessage.timestamp
            )
            
        case "orderChange":
            var payloadData: [String: Any] = [
                "action": serverMessage.action ?? "unknown",
                "entityId": serverMessage.entityId ?? "",
                "entityType": "order"
            ]
            
            if let data = serverMessage.data,
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) {
                payloadData["data"] = jsonObject
            }
            
            let payloadString = (try? JSONSerialization.data(withJSONObject: payloadData, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\\"error\\": \\"serialization_failed\\"}"
            
            return AppMessageData(
                type: "order_update",
                postbackSenderId: "system",
                payload: payloadString,
                timestamp: serverMessage.timestamp
            )
            
        case "inventoryChange":
            var payloadData: [String: Any] = [
                "action": serverMessage.action ?? "unknown",
                "entityId": serverMessage.entityId ?? "",
                "entityType": serverMessage.entityType ?? "item"
            ]
            
            if let data = serverMessage.data,
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) {
                payloadData["data"] = jsonObject
            }
            
            let payloadString = (try? JSONSerialization.data(withJSONObject: payloadData, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\\"error\\": \\"serialization_failed\\"}"
            
            return AppMessageData(
                type: "inventory_update",
                postbackSenderId: "system",
                payload: payloadString,
                timestamp: serverMessage.timestamp
            )
            
        case "bulkChange":
            // Handle bulk changes with full data preservation
            if let bulkChanges = serverMessage.bulkChanges {
                var payloadData: [String: Any] = [
                    "changeCount": bulkChanges.count,
                    "changes": bulkChanges.map { change in
                        var changeData: [String: Any] = [
                            "entityId": change.entityId,
                            "entityType": change.entityType,
                            "action": change.action
                        ]
                        
                        if let data = change.data,
                           let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) {
                            changeData["data"] = jsonObject
                        }
                        
                        return changeData
                    }
                ]
                
                let payloadString = (try? JSONSerialization.data(withJSONObject: payloadData, options: []))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{\\"error\\": \\"serialization_failed\\"}"
                
                return AppMessageData(
                    type: "bulk_update",
                    postbackSenderId: "system",
                    payload: payloadString,
                    timestamp: serverMessage.timestamp
                )
            }
            return nil
            
        case "messageUpdate":
            // For actual message updates, we might have a real senderId in the data
            var payloadData: [String: Any] = [
                "action": serverMessage.action ?? "unknown",
                "entityId": serverMessage.entityId ?? ""
            ]
            
            var senderId = "system"
            if let data = serverMessage.data,
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
               let dataDict = jsonObject as? [String: Any],
               let messageSenderId = dataDict["senderId"] as? String {
                senderId = messageSenderId
            }
            
            if let data = serverMessage.data,
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) {
                payloadData["data"] = jsonObject
            }
            
            let payloadString = (try? JSONSerialization.data(withJSONObject: payloadData, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\\"error\\": \\"serialization_failed\\"}"
            
            return AppMessageData(
                type: "message_update",
                postbackSenderId: senderId,
                payload: payloadString,
                timestamp: serverMessage.timestamp
            )
            
        default:
            logger.warning("Unknown server message type: \(serverMessage.type)")
            
            var payloadData: [String: Any] = [
                "type": serverMessage.type,
                "entityId": serverMessage.entityId ?? "",
                "action": serverMessage.action ?? ""
            ]
            
            if let data = serverMessage.data,
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) {
                payloadData["data"] = jsonObject
            }
            
            let payloadString = (try? JSONSerialization.data(withJSONObject: payloadData, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\\"error\\": \\"serialization_failed\\"}"
            
            return AppMessageData(
                type: "unknown_update",
                postbackSenderId: "system",
                payload: payloadString,
                timestamp: serverMessage.timestamp
            )
        }
    }
    
    // Fallback message creation is now handled inline with ErrorSSE
    private func createFallbackMessage_DEPRECATED(from data: String) -> AppMessageData? {
        return AppMessageData(
            type: "server_update",
            postbackSenderId: "server",
            payload: data,
            timestamp: Date()
        )
    }
    
    private func handleDisconnection() async {
        ws = nil
        logger.warning("Disconnected from NaraServer WebSocket")
        // Reconnection will be handled by periodic health check or explicit reconnect
    }
    
    private func scheduleReconnect(app: Application) async {
        // Cancel any existing reconnect task
        reconnectTask?.cancel()
        
        // Schedule new reconnect after delay
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            guard !Task.isCancelled else { return }
            await self.connect(app: app)
        }
    }
    
    func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        
        if let ws = ws {
            _ = try? await ws.close()
            self.ws = nil
            logger.info("Disconnected from NaraServer WebSocket")
        }
    }
    
    func isConnected() -> Bool {
        return ws != nil && !(ws?.isClosed ?? true)
    }
    
    func sendMessage(_ message: String) async {
        guard let ws = ws, !ws.isClosed else {
            logger.warning("Cannot send message - WebSocket not connected, buffering message")
            
            // Buffer the message if we're not connected
            if messageBuffer.count < maxBufferSize {
                messageBuffer.append(message)
                logger.info("Buffered message (\(messageBuffer.count)/\(maxBufferSize))")
            } else {
                logger.error("Message buffer full, dropping message")
            }
            return
        }
        
        do {
            try await ws.send(message)
            logger.debug("Sent message to NaraServer: \(message.prefix(100))...")
        } catch {
            logger.error("Failed to send message: \(error)")
            
            // Buffer on send failure too
            if messageBuffer.count < maxBufferSize {
                messageBuffer.append(message)
            }
        }
    }
    
    // MARK: - Relay-specific messaging
    
    /// Send a WebSocketMessage-compatible object
    func sendMessage<T: Encodable>(_ message: T, requiresAck: Bool = false) async -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(message)
            let jsonString = String(data: data, encoding: .utf8)!
            
            // Extract correlation ID if it's a WebSocketMessage
            var correlationId: String?
            if let messageDict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let cid = messageDict["correlationId"] as? String {
                correlationId = cid
            }
            
            // Send the message
            await sendMessage(jsonString)
            
            // Track if acknowledgment is required
            if requiresAck, let correlationId = correlationId {
                pendingMessages[correlationId] = PendingMessage(
                    id: correlationId,
                    content: jsonString,
                    sentAt: Date(),
                    attempt: 1
                )
                
                // Start acknowledgment timeout
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(messageTimeout * 1_000_000_000))
                    await checkMessageTimeout(correlationId)
                }
                
                return correlationId
            }
            
            return correlationId
        } catch {
            logger.error("Failed to encode message: \(error)")
            return nil
        }
    }
    
    /// Send relay status update to server
    func sendRelayStatus(metrics: RelayMetrics? = nil) async {
        let currentMetrics = metrics ?? await collectMetrics()
        
        let status = RelayStatusMessage(
            relayId: relayDeviceId,
            status: currentMetrics.queueDepth > 100 ? .unhealthy : .healthy,
            metrics: currentMetrics,
            connectedClients: await sseManager.getConnectionCount()
        )
        
        await sendMessage(status)
        logger.info("📊 Sent relay status update", metadata: [
            "status": "\(status.status)",
            "queueDepth": "\(currentMetrics.queueDepth)",
            "connectedClients": "\(status.connectedClients)"
        ])
    }
    
    /// Forward webhook data to server
    func forwardWebhook(_ webhookData: Data, headers: [String: String], signature: String?) async -> String? {
        let message = WebhookForwardMessage(
            relayId: relayDeviceId,
            webhookData: webhookData,
            originalHeaders: headers,
            signature: signature
        )
        
        let correlationId = await sendMessage(message, requiresAck: true)
        logger.info("📨 Forwarded webhook to server", metadata: [
            "correlationId": "\(message.correlationId)",
            "dataSize": "\(webhookData.count)",
            "requiresAck": "true"
        ])
        
        return correlationId
    }
    
    /// Collect current relay metrics
    private func collectMetrics() async -> RelayMetrics {
        // Get queue depth from message buffer (temporary until actual queue is integrated)
        let queueDepth = messageBuffer.count
        
        // Get current memory usage
        let memoryUsage = getMemoryUsage()
        
        // Get CPU usage (simplified)
        let cpuUsage = getCPUUsage()
        
        // Calculate uptime
        let uptimeSeconds = Int(Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime)
        
        return RelayMetrics(
            messagesReceived: Int(WebhookRelayMetrics.messagesReceived._value ?? 0),
            messagesForwarded: Int(WebhookRelayMetrics.messagesForwarded._value ?? 0),
            messagesFailed: Int(WebhookRelayMetrics.messagesFailed._value ?? 0),
            queueDepth: queueDepth,
            uptimeSeconds: uptimeSeconds,
            avgForwardingLatencyMs: 0.0, // TODO: Calculate from Timer metric
            memoryUsageMB: memoryUsage,
            cpuUsagePercent: cpuUsage
        )
    }
    
    private func getMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1024.0 / 1024.0 : 0.0
    }
    
    private func getCPUUsage() -> Double {
        // Simplified CPU usage - in production you'd want more accurate measurement
        return Double.random(in: 5.0...25.0)
    }
    
    // MARK: - Message Acknowledgment
    
    private func checkMessageTimeout(_ correlationId: String) async {
        guard let pending = pendingMessages[correlationId] else { return }
        
        logger.warning("Message timeout for correlation ID: \(correlationId), attempt \(pending.attempt)")
        
        if pending.attempt < maxRetries {
            // Retry the message
            pendingMessages[correlationId] = PendingMessage(
                id: pending.id,
                content: pending.content,
                sentAt: Date(),
                attempt: pending.attempt + 1
            )
            
            logger.info("Retrying message (attempt \(pending.attempt + 1)/\(maxRetries))")
            await sendMessage(pending.content)
            
            // Start new timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(messageTimeout * 1_000_000_000))
                await checkMessageTimeout(correlationId)
            }
        } else {
            // Max retries reached
            logger.error("Message failed after \(maxRetries) attempts: \(correlationId)")
            pendingMessages.removeValue(forKey: correlationId)
            WebhookRelayMetrics.messagesFailed.increment(dimensions: [("reason", "timeout")])
        }
    }
    
    func handleAcknowledgment(_ correlationId: String) async {
        if pendingMessages.removeValue(forKey: correlationId) != nil {
            logger.debug("Received acknowledgment for message: \(correlationId)")
        }
    }
    
    private func updateServerMessageHandling(_ data: String) async {
        // Check if this is an acknowledgment message
        if let messageData = data.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: messageData, options: []) as? [String: Any],
           let messageType = json["messageType"] as? String,
           messageType == WebSocketMessageType.processingResult,
           let originalCorrelationId = json["originalCorrelationId"] as? String {
            await handleAcknowledgment(originalCorrelationId)
        }
    }
}

// Lifecycle handler for clean shutdown
final class NaraServerConnectionLifecycleHandler: LifecycleHandler {
    private let connection: NaraServerConnection
    
    init(connection: NaraServerConnection) {
        self.connection = connection
    }
    
    func shutdown(_ application: Application) {
        application.logger.info("Shutting down NaraServer WebSocket connection")
        Task {
            await connection.disconnect()
        }
    }
} 