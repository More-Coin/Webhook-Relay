import Vapor
import NIOCore

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
            var urlComponents = URLComponents(string: naraServerWsUrl)!
            urlComponents.queryItems = [
                URLQueryItem(name: "token", value: naraServerApiKey),
                URLQueryItem(name: "device_id", value: relayDeviceId),
                URLQueryItem(name: "platform", value: "webhook")
            ]
            
            guard let authenticatedUrl = urlComponents.url?.absoluteString else {
                logger.error("Failed to construct authenticated WebSocket URL")
                await scheduleReconnect(app: app)
                return
            }
            
            logger.info("WebSocket URL with auth: \(authenticatedUrl.replacingOccurrences(of: naraServerApiKey, with: "***TOKEN***"))")
            
            try await app.eventLoopGroup.any().makeFutureWithTask {
                try await WebSocket.connect(
                    to: authenticatedUrl,
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
    
    private func storeWebSocket(_ ws: WebSocket) async {
        self.ws = ws
        self.logger.info("✅ Connected to NaraServer WebSocket")
        
        // Add small delay to allow server to fully establish connection
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        
        // Send initial connection message
        await self.sendConnectionMessage()
        self.logger.info("Connection message sent, waiting for server response")
    }
    
    private func sendConnectionMessage() async {
        let connectionMessage: [String: String] = [
            "type": "connection",
            "device_id": relayDeviceId,
            "platform": "webhook",
            "timestamp": Date().iso8601
        ]
        
        do {
            let jsonData = try JSONEncoder().encode(connectionMessage)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                do {
                    try await ws?.send(jsonString)
                    logger.info("Sent connection message to NaraServer")
                } catch {
                    logger.error("Failed to send message through WebSocket: \(error)")
                }
            }
        } catch {
            logger.error("Failed to encode connection message: \(error)")
        }
    }
    
    private func handleServerMessage(_ data: String) async {
        guard let messageData = data.data(using: .utf8) else {
            logger.warning("Failed to convert server message to data")
            return
        }
        
        do {
            let serverMessage = try JSONDecoder().decode(ServerMessage.self, from: messageData)
            logger.info("Received server message: \(serverMessage.type)")
            
            // Convert server message to AppMessageData format and broadcast
            if let appMessageData = convertServerMessage(serverMessage) {
                await sseManager.broadcast(data: appMessageData)
            }
        } catch {
            logger.error("Failed to decode server message: \(error)")
            // Try to broadcast raw message as fallback
            if let appMessageData = createFallbackMessage(from: data) {
                await sseManager.broadcast(data: appMessageData)
            }
        }
    }
    
    private func convertServerMessage(_ serverMessage: ServerMessage) -> AppMessageData? {
        // This conversion logic will depend on your server message format
        // For now, creating a generic implementation
        switch serverMessage.type {
        case "orderChange", "customerChange", "messageUpdate":
            // Create an appropriate AppMessageData based on server message
            // This is a placeholder - adjust based on your actual server message format
            return AppMessageData(
                type: serverMessage.type,
                postbackSenderId: serverMessage.entityId,
                payload: serverMessage.action,
                timestamp: Date()
            )
        default:
            logger.warning("Unknown server message type: \(serverMessage.type)")
            return nil
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