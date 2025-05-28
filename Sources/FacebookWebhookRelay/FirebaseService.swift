import Vapor
import FirebaseCore

/// Error categories for structured logging
enum ErrorCategory: String {
    case webhookProcessing = "webhook_processing"
    case naraServerConnection = "nara_server_connection"
    case sseDelivery = "sse_delivery"
    case configuration = "configuration"
    case rateLimit = "rate_limit"
}

/// Firebase service for handling analytics and other Firebase features
actor FirebaseService {
    private let logger = Logger(label: "firebase-service")
    private var isConfigured = false
    
    init() {}
    
    /// Configure Firebase with the provided configuration
    func configure(with config: FirebaseConfiguration) async {
        guard !isConfigured else {
            logger.info("Firebase already configured")
            return
        }
        
        // Configure Firebase
        FirebaseApp.configure(options: config.options)
        isConfigured = true
        logger.info("✅ Firebase configured successfully")
    }
    
    /// Log an analytics event
    /// Note: Firebase Analytics is not available for server-side Swift.
    /// This logs events locally and could be extended to send to a custom endpoint.
    func logEvent(_ name: String, parameters: [String: Any]? = nil) {
        guard isConfigured else {
            logger.warning("Firebase not configured - cannot log event: \(name)")
            return
        }
        
        // Firebase Analytics is not available server-side
        // Log the event locally with structured format
        var logMessage = "📊 Firebase Event: \(name)"
        if let params = parameters {
            let paramsString = params.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            logMessage += " | Parameters: [\(paramsString)]"
        }
        logger.info("\(logMessage)")
        
        // TODO: Consider implementing custom analytics endpoint
        // to send these events to Firebase Functions or custom analytics service
    }
    
    /// Log webhook received event
    func logWebhookReceived(source: String, messageCount: Int = 1, webhookType: String? = nil, pageId: String? = nil) {
        var parameters: [String: Any] = [
            "source": source,
            "message_count": messageCount,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let type = webhookType {
            parameters["webhook_type"] = type
        }
        
        if let id = pageId {
            parameters["page_id"] = id
        }
        
        logEvent("webhook_received", parameters: parameters)
    }
    
    /// Log message forwarded event
    func logMessageForwarded(destination: String, success: Bool, responseTime: TimeInterval? = nil, messageSize: Int? = nil) {
        var parameters: [String: Any] = [
            "destination": destination,
            "success": success,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let time = responseTime {
            parameters["response_time_ms"] = Int(time * 1000) // Convert to milliseconds
        }
        
        if let size = messageSize {
            parameters["message_size_bytes"] = size
        }
        
        logEvent("message_forwarded", parameters: parameters)
    }
    
    /// Log SSE connection event
    func logSSEConnection(action: String, connectionCount: Int, clientInfo: String? = nil, connectionDuration: TimeInterval? = nil) {
        var parameters: [String: Any] = [
            "action": action, // "connected" or "disconnected"
            "connection_count": connectionCount,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let info = clientInfo {
            parameters["client_info"] = info
        }
        
        if let duration = connectionDuration {
            parameters["connection_duration_seconds"] = Int(duration)
        }
        
        logEvent("sse_connection", parameters: parameters)
    }
    
    /// Log server connection status
    func logServerConnection(connected: Bool, server: String, reconnectionCount: Int = 0, latency: TimeInterval? = nil) {
        var parameters: [String: Any] = [
            "connected": connected,
            "server": server,
            "reconnection_count": reconnectionCount,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let lat = latency {
            parameters["latency_ms"] = Int(lat * 1000)
        }
        
        logEvent("server_connection", parameters: parameters)
    }
    
    /// Log relay server started event
    func logRelayStarted(port: Int, mode: String) {
        logEvent("relay_started", parameters: [
            "port": port,
            "mode": mode,
            "timestamp": Date().timeIntervalSince1970,
            "version": "1.0.0" // TODO: Get from app version
        ])
    }
    
    /// Log relay server shutdown event
    func logRelayShutdown(reason: String? = nil) {
        var parameters: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let r = reason {
            parameters["reason"] = r
        }
        
        logEvent("relay_shutdown", parameters: parameters)
    }
    
    /// Log error occurred event
    func logError(category: ErrorCategory, message: String, stackTrace: String? = nil, context: [String: Any]? = nil) {
        var parameters: [String: Any] = [
            "category": category.rawValue,
            "message": message,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let trace = stackTrace {
            parameters["stack_trace"] = trace
        }
        
        if let ctx = context {
            parameters["context"] = ctx.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }
        
        logEvent("error_occurred", parameters: parameters)
    }
    
    /// Log API proxy request event
    func logApiProxyRequest(endpoint: String, method: String, success: Bool, responseTime: TimeInterval? = nil) {
        var parameters: [String: Any] = [
            "endpoint": endpoint,
            "method": method,
            "success": success,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        if let time = responseTime {
            parameters["response_time_ms"] = Int(time * 1000)
        }
        
        logEvent("api_proxy_request", parameters: parameters)
    }
    
    /// Log rate limit exceeded event
    func logRateLimitExceeded(clientIP: String, endpoint: String) {
        logEvent("rate_limit_exceeded", parameters: [
            "client_ip": clientIP,
            "endpoint": endpoint,
            "timestamp": Date().timeIntervalSince1970
        ])
    }
}

/// Firebase configuration structure
struct FirebaseConfiguration {
    let options: FirebaseOptions
    
    init(
        apiKey: String,
        authDomain: String,
        projectId: String,
        storageBucket: String,
        messagingSenderId: String,
        appId: String,
        measurementId: String? = nil
    ) {
        self.options = FirebaseOptions(
            googleAppID: appId,
            gcmSenderID: messagingSenderId
        )
        
        options.apiKey = apiKey
        options.projectID = projectId
        options.storageBucket = storageBucket
        
        if let measurementId = measurementId {
            // Set measurement ID for Analytics
            options.setValue(measurementId, forKey: "measurementID")
        }
    }
    
    /// Create configuration from environment variables
    static func fromEnvironment() throws -> FirebaseConfiguration {
        guard let apiKey = Environment.get("FIREBASE_API_KEY") else {
            throw FirebaseConfigurationError.missingEnvironmentVariable("FIREBASE_API_KEY")
        }
        guard let authDomain = Environment.get("FIREBASE_AUTH_DOMAIN") else {
            throw FirebaseConfigurationError.missingEnvironmentVariable("FIREBASE_AUTH_DOMAIN")
        }
        guard let projectId = Environment.get("FIREBASE_PROJECT_ID") else {
            throw FirebaseConfigurationError.missingEnvironmentVariable("FIREBASE_PROJECT_ID")
        }
        guard let storageBucket = Environment.get("FIREBASE_STORAGE_BUCKET") else {
            throw FirebaseConfigurationError.missingEnvironmentVariable("FIREBASE_STORAGE_BUCKET")
        }
        guard let messagingSenderId = Environment.get("FIREBASE_MESSAGING_SENDER_ID") else {
            throw FirebaseConfigurationError.missingEnvironmentVariable("FIREBASE_MESSAGING_SENDER_ID")
        }
        guard let appId = Environment.get("FIREBASE_APP_ID") else {
            throw FirebaseConfigurationError.missingEnvironmentVariable("FIREBASE_APP_ID")
        }
        
        let measurementId = Environment.get("FIREBASE_MEASUREMENT_ID")
        
        return FirebaseConfiguration(
            apiKey: apiKey,
            authDomain: authDomain,
            projectId: projectId,
            storageBucket: storageBucket,
            messagingSenderId: messagingSenderId,
            appId: appId,
            measurementId: measurementId
        )
    }
}

enum FirebaseConfigurationError: Error, CustomStringConvertible {
    case missingEnvironmentVariable(String)
    
    var description: String {
        switch self {
        case .missingEnvironmentVariable(let variable):
            return "Missing required Firebase environment variable: \(variable)"
        }
    }
} 