import Foundation
import Vapor

// MARK: - Shared WebSocket Message Protocol

/// Base protocol for all WebSocket messages
/// This mirrors the protocol in NaraServer for compatibility
protocol WebSocketMessage: Codable {
    var messageType: String { get }
    var messageVersion: String { get }
    var timestamp: Date { get }
    var correlationId: String { get }
}

// MARK: - Message Type Constants

enum WebSocketMessageType {
    // Existing message types (for backward compatibility)
    static let connected = "connected"
    static let customerChange = "customerChange"
    static let orderChange = "orderChange"
    static let inventoryChange = "inventoryChange"
    static let bulkChange = "bulkChange"
    static let error = "error"
    
    // New relay-specific message types
    static let relayStatus = "relay_status"
    static let relayCoordination = "relay_coordination"
    static let webhookForward = "webhook_forward"
    static let processingResult = "processing_result"
}

// MARK: - Version Support

struct MessageVersioning {
    static let currentVersion = "1.0"
    static let supportedVersions = ["1.0"]
    
    static func isVersionSupported(_ version: String) -> Bool {
        supportedVersions.contains(version)
    }
}

// MARK: - Relay Messages

/// Status message sent by relay to server
struct RelayStatusMessage: WebSocketMessage {
    let messageType = WebSocketMessageType.relayStatus
    let messageVersion: String
    let timestamp: Date
    let correlationId: String
    let relayId: String
    let status: RelayStatus
    let metrics: RelayMetrics
    let connectedClients: Int
    let metadata: [String: String]?
    
    init(
        messageVersion: String = MessageVersioning.currentVersion,
        timestamp: Date = Date(),
        correlationId: String = UUID().uuidString,
        relayId: String,
        status: RelayStatus,
        metrics: RelayMetrics,
        connectedClients: Int,
        metadata: [String: String]? = nil
    ) {
        self.messageVersion = messageVersion
        self.timestamp = timestamp
        self.correlationId = correlationId
        self.relayId = relayId
        self.status = status
        self.metrics = metrics
        self.connectedClients = connectedClients
        self.metadata = metadata
    }
}

/// Coordination message for relay commands
struct RelayCoordinationMessage: WebSocketMessage {
    let messageType = WebSocketMessageType.relayCoordination
    let messageVersion: String
    let timestamp: Date
    let correlationId: String
    let command: RelayCommand
    let parameters: [String: String]
    let timeoutSeconds: Int?
    
    init(
        messageVersion: String = MessageVersioning.currentVersion,
        timestamp: Date = Date(),
        correlationId: String = UUID().uuidString,
        command: RelayCommand,
        parameters: [String: String] = [:],
        timeoutSeconds: Int? = nil
    ) {
        self.messageVersion = messageVersion
        self.timestamp = timestamp
        self.correlationId = correlationId
        self.command = command
        self.parameters = parameters
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Message for forwarding webhooks via WebSocket
struct WebhookForwardMessage: WebSocketMessage {
    let messageType = WebSocketMessageType.webhookForward
    let messageVersion: String
    let timestamp: Date
    let correlationId: String
    let relayId: String
    let webhookData: Data
    let originalHeaders: [String: String]
    let signature: String
    let sourceIP: String?
    
    init(
        messageVersion: String = MessageVersioning.currentVersion,
        timestamp: Date = Date(),
        correlationId: String = UUID().uuidString,
        relayId: String,
        webhookData: Data,
        originalHeaders: [String: String],
        signature: String,
        sourceIP: String? = nil
    ) {
        self.messageVersion = messageVersion
        self.timestamp = timestamp
        self.correlationId = correlationId
        self.relayId = relayId
        self.webhookData = webhookData
        self.originalHeaders = originalHeaders
        self.signature = signature
        self.sourceIP = sourceIP
    }
}

/// Processing result from server
struct ProcessingResultMessage: WebSocketMessage {
    let messageType = WebSocketMessageType.processingResult
    let messageVersion: String
    let timestamp: Date
    let correlationId: String
    let originalCorrelationId: String
    let success: Bool
    let processedEntities: [ProcessedEntity]
    let errors: [ProcessingError]
    let processingDurationMs: Int
}

// MARK: - Supporting Types

enum RelayStatus: String, Codable {
    case healthy
    case degraded
    case unhealthy
}

struct RelayMetrics: Codable {
    let messagesReceived: Int
    let messagesForwarded: Int
    let messagesFailed: Int
    let queueDepth: Int
    let uptimeSeconds: Int
    let avgForwardingLatencyMs: Double?
    let memoryUsageMB: Double?
    let cpuUsagePercent: Double?
}

enum RelayCommand: String, Codable {
    case restart = "restart"
    case clearQueue = "clear_queue"
    case updateConfig = "update_config"
    case healthCheck = "health_check"
    case enableMaintenanceMode = "enable_maintenance"
    case disableMaintenanceMode = "disable_maintenance"
    case flushMetrics = "flush_metrics"
}

struct ProcessedEntity: Codable {
    let entityType: String
    let entityId: String
    let action: String
    let success: Bool
}

struct ProcessingError: Codable {
    let code: String
    let message: String
    let entityType: String?
    let entityId: String?
}

// MARK: - Backward Compatibility

/// Extension to make existing ServerMessage compatible with WebSocketMessage
extension ServerMessage {
    /// Convert ServerMessage to a WebSocketMessage format
    func toWebSocketMessage() -> WebSocketMessage {
        // This will be implemented based on the message type
        // For now, create a generic message
        return GenericServerMessage(
            messageType: self.type,
            messageVersion: "1.0",
            timestamp: self.timestamp,
            correlationId: self.id.uuidString,
            serverMessage: self
        )
    }
}

/// Generic wrapper for ServerMessage to WebSocketMessage conversion
struct GenericServerMessage: WebSocketMessage {
    let messageType: String
    let messageVersion: String
    let timestamp: Date
    let correlationId: String
    let serverMessage: ServerMessage
}

// MARK: - Message Factory

/// Factory for creating WebSocket messages
struct WebSocketMessageFactory {
    /// Create a relay status message with current metrics
    static func createStatusMessage(
        relayId: String,
        metrics: WebhookRelayMetrics,
        connectedClients: Int
    ) -> RelayStatusMessage {
        // Determine health status based on metrics
        let status: RelayStatus = {
            // Add your health check logic here
            return .healthy
        }()
        
        let relayMetrics = RelayMetrics(
            messagesReceived: 0, // These would come from actual metrics
            messagesForwarded: 0,
            messagesFailed: 0,
            queueDepth: 0,
            uptimeSeconds: Int(Date().timeIntervalSince1970), // Calculate from start time
            avgForwardingLatencyMs: nil,
            memoryUsageMB: nil,
            cpuUsagePercent: nil
        )
        
        return RelayStatusMessage(
            relayId: relayId,
            status: status,
            metrics: relayMetrics,
            connectedClients: connectedClients
        )
    }
    
    /// Create a webhook forward message
    static func createWebhookForward(
        relayId: String,
        webhookData: Data,
        headers: HTTPHeaders,
        signature: String,
        sourceIP: String?
    ) -> WebhookForwardMessage {
        // Convert HTTPHeaders to dictionary
        var headerDict: [String: String] = [:]
        for (name, value) in headers {
            headerDict[name] = value
        }
        
        return WebhookForwardMessage(
            relayId: relayId,
            webhookData: webhookData,
            originalHeaders: headerDict,
            signature: signature,
            sourceIP: sourceIP
        )
    }
}