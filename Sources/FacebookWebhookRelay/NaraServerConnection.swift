import Vapor
import NIOCore
import AsyncHTTPClient

actor NaraServerConnection {
    private var ws: WebSocket?
    private let logger = Logger(label: "nara-server-connection")
    private let sseManager: SSEManager
    private let naraServerWsUrl: String
    private let naraServerApiKey: String
    private let relayDeviceId: String
    private var reconnectTask: Task<Void, Never>?
    private var isConnecting = false
    
    init(sseManager: SSEManager, naraServerWsUrl: String, naraServerApiKey: String, relayDeviceId: String) {
        self.sseManager = sseManager
        self.naraServerWsUrl = naraServerWsUrl
        self.naraServerApiKey = naraServerApiKey
        self.relayDeviceId = relayDeviceId
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
    }
    
    private func handleServerMessage(_ data: String) async {
        guard let messageData = data.data(using: .utf8) else {
            logger.warning("Failed to convert server message to data")
            return
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
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
            
            // Convert server message to AppMessageData format and broadcast
            if let appMessageData = convertServerMessage(serverMessage) {
                await sseManager.broadcast(data: appMessageData)
                logger.info("📡 Broadcasted \(serverMessage.type) to SSE clients")
            }
        } catch {
            logger.error("Failed to decode server message: \(error)")
            logger.debug("Raw message: \(data)")
            
            // Try to broadcast raw message as fallback
            if let appMessageData = createFallbackMessage(from: data) {
                await sseManager.broadcast(data: appMessageData)
            }
        }
    }
    
    private func convertServerMessage(_ serverMessage: ServerMessage) -> AppMessageData? {
        // Convert NaraServer messages to your app's format
        switch serverMessage.type {
        case "customerChange":
            return AppMessageData(
                type: "customer_update",
                postbackSenderId: serverMessage.entityId ?? "unknown",
                payload: "\(serverMessage.action ?? "unknown") customer \(serverMessage.entityId ?? "")",
                timestamp: serverMessage.timestamp
            )
            
        case "orderChange":
            return AppMessageData(
                type: "order_update", 
                postbackSenderId: serverMessage.entityId ?? "unknown",
                payload: "\(serverMessage.action ?? "unknown") order \(serverMessage.entityId ?? "")",
                timestamp: serverMessage.timestamp
            )
            
        case "inventoryChange":
            return AppMessageData(
                type: "inventory_update",
                postbackSenderId: serverMessage.entityId ?? "unknown", 
                payload: "\(serverMessage.action ?? "unknown") \(serverMessage.entityType ?? "item") \(serverMessage.entityId ?? "")",
                timestamp: serverMessage.timestamp
            )
            
        case "bulkChange":
            // Handle bulk changes
            if let bulkChanges = serverMessage.bulkChanges {
                let summary = "\(bulkChanges.count) bulk changes"
                return AppMessageData(
                    type: "bulk_update",
                    postbackSenderId: "system",
                    payload: summary,
                    timestamp: serverMessage.timestamp
                )
            }
            return nil
            
        case "messageUpdate":
            return AppMessageData(
                type: "message_update",
                postbackSenderId: serverMessage.entityId ?? "unknown",
                payload: "\(serverMessage.action ?? "unknown") message",
                timestamp: serverMessage.timestamp
            )
            
        default:
            logger.warning("Unknown server message type: \(serverMessage.type)")
            return AppMessageData(
                type: "unknown_update",
                postbackSenderId: serverMessage.entityId ?? "unknown",
                payload: "Unknown update type: \(serverMessage.type)",
                timestamp: serverMessage.timestamp
            )
        }
    }
    
    private func createFallbackMessage(from data: String) -> AppMessageData? {
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
            logger.warning("Cannot send message - WebSocket not connected")
            return
        }
        
        do {
            try await ws.send(message)
            logger.debug("Sent message to NaraServer: \(message.prefix(100))...")
        } catch {
            logger.error("Failed to send message: \(error)")
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