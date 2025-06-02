import Vapor
import RediStack
import Metrics

public func configure(_ app: Application) async throws {
    // Initialize metrics system
    configureMetrics(app)
    
    // Initialize Firebase if configuration is available (optional)
    // Firebase configuration will be handled in routes.swift where the types are available
    
    // Increase body collection limit if you expect large payloads,
    // though Facebook webhooks are usually small. Default is 16KB.
    app.routes.defaultMaxBodySize = "10mb"
    
    // Configure Redis and Message Queue
    try await configureMessageQueue(app)
    
    // Configure Circuit Breaker
    configureCircuitBreaker(app)
    
    // Set up circuit breaker recovery handling
    app.setupCircuitBreakerRecovery()

    // Configure CORS
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all, // Be more specific in production if possible
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [
            .accept,
            .authorization,
            .contentType,
            .origin,
            HTTPHeaders.Name("X-Requested-With"), // Corrected
            .userAgent,
            .accessControlAllowOrigin,
            HTTPHeaders.Name("X-Hub-Signature-256"), // Corrected
            .cacheControl
        ]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    // IMPORTANT: Add CORS middleware before routes
    app.middleware.use(cors, at: .beginning)
    
    // Serve files from /Public directory if you have any (not needed for this webhook)
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Register routes
    try routes(app)

    // Set port from environment or default
    let port = Int(Environment.get("PORT") ?? "8080") ?? 8080
    app.http.server.configuration.port = port
    
    // Firebase disabled for now due to configuration issues
    // TODO: Re-enable Firebase once proper credentials are available
    app.logger.info("⚠️ Firebase disabled - using local logging only")
    
    /*
    Task {
        do {
            let firebaseConfig = try FirebaseConfiguration.fromEnvironment()
            let service = FirebaseService()
            await service.configure(with: firebaseConfig)
            await service.logRelayStarted(port: port, mode: relayMode)
        } catch {
            app.logger.warning("⚠️ Firebase configuration failed, continuing without Firebase: \(error)")
        }
    }
    */
}

// MARK: - Redis Storage

extension Application {
    struct RedisKey: StorageKey {
        typealias Value = RedisClient
    }
    
    var redis: RedisClient? {
        get {
            storage[RedisKey.self]
        }
        set {
            storage[RedisKey.self] = newValue
        }
    }
}

// MARK: - Message Queue Configuration

private func configureMessageQueue(_ app: Application) async throws {
    let logger = app.logger
    
    // Get configuration from environment
    let redisURL = Environment.get("REDIS_URL") ?? "redis://localhost:6379"
    let maxSize = Int(Environment.get("QUEUE_MAX_SIZE") ?? "10000") ?? 10000
    let ttl = TimeInterval(Int(Environment.get("QUEUE_TTL") ?? "3600") ?? 3600)
    
    let config = MessageQueueConfig(
        maxSize: maxSize,
        ttl: ttl,
        streamKey: "webhook-messages",
        consumerGroup: "webhook-processors",
        consumerName: Environment.get("RELAY_DEVICE_ID") ?? "webhook_relay_1"
    )
    
    do {
        // Parse Redis URL
        guard let url = URL(string: redisURL) else {
            throw MessageQueueError.redisConnectionFailed(
                URLError(.badURL, userInfo: [NSURLErrorFailingURLStringErrorKey: redisURL])
            )
        }
        
        let host = url.host ?? "localhost"
        let port = url.port ?? 6379
        let password = url.password
        
        // Create Redis client
        let redis = RedisClient(
            configuration: .init(
                hostname: host,
                port: port,
                password: password,
                connectionTimeout: .seconds(10),
                commandTimeout: .seconds(30)
            ),
            eventLoopGroup: app.eventLoopGroup
        )
        
        // Test Redis connection
        do {
            _ = try await redis.ping()
            logger.info("✅ Redis connection successful - \\(host):\\(port)")
            
            // Store Redis client for other services
            app.redis = redis
            
            // Configure enhanced persistent message queue
            let persistentQueue = PersistentMessageQueue(
                redis: redis,
                config: config,
                logger: logger
            )
            app.messageQueue = persistentQueue
            
            logger.info("📬 Enhanced persistent message queue configured - maxSize: \\(maxSize), ttl: \\(Int(ttl))s")
            
            // Set up additional persistence services
            configurePersistenceServices(app)
            
        } catch {
            logger.warning("⚠️ Redis connection failed, falling back to in-memory queue: \\(error)")
            throw error
        }
        
    } catch {
        logger.warning("⚠️ Failed to configure Redis message queue, using in-memory fallback: \\(error)")
        
        // Fallback to in-memory queue
        app.messageQueue = InMemoryMessageQueue(
            config: config,
            logger: logger
        )
        
        logger.info("📬 Message queue configured with in-memory fallback - maxSize: \\(maxSize)")
    }
}

// MARK: - Metrics Configuration

private func configureMetrics(_ app: Application) {
    // Initialize the metrics system with our simple Prometheus factory
    let metricsFactory = PrometheusMetricsFactory()
    MetricsSystem.bootstrap(metricsFactory)
    
    // Store factory in app storage for later access
    app.storage[MetricsFactoryKey.self] = metricsFactory
    
    app.logger.info("📊 Metrics system initialized")
}

// Storage key for metrics factory
struct MetricsFactoryKey: StorageKey {
    typealias Value = PrometheusMetricsFactory
}

// MARK: - Circuit Breaker Configuration

private func configureCircuitBreaker(_ app: Application) {
    let config = CircuitBreakerConfig(
        failureThreshold: Int(Environment.get("CIRCUIT_BREAKER_FAILURE_THRESHOLD") ?? "5") ?? 5,
        resetTimeout: TimeInterval(Int(Environment.get("CIRCUIT_BREAKER_RESET_TIMEOUT") ?? "60") ?? 60),
        halfOpenMaxAttempts: Int(Environment.get("CIRCUIT_BREAKER_HALF_OPEN_ATTEMPTS") ?? "3") ?? 3,
        slidingWindowSize: TimeInterval(Int(Environment.get("CIRCUIT_BREAKER_WINDOW_SIZE") ?? "60") ?? 60),
        minimumRequests: Int(Environment.get("CIRCUIT_BREAKER_MIN_REQUESTS") ?? "10") ?? 10
    )
    
    // Initialize enhanced circuit breaker
    let circuitBreaker = EnhancedCircuitBreaker(config: config, logger: app.logger)
    
    // Set up state change notifications
    circuitBreaker.onStateChange { oldState, newState in
        app.logger.warning("Circuit breaker state changed", metadata: [
            "from": "\(oldState)",
            "to": "\(newState)"
        ])
        
        // Track state changes in metrics
        WebhookRelayMetrics.circuitBreakerStateChanges.increment(dimensions: [
            ("from", describeState(oldState)),
            ("to", describeState(newState))
        ])
        
        // Send notifications for critical state changes
        Task {
            let notifications = app.circuitBreakerNotifications
            
            switch newState {
            case .open:
                await notifications.notifyCircuitOpen(reason: "Failure threshold exceeded")
            case .closed:
                await notifications.notifyCircuitClosed()
            default:
                break
            }
        }
    }
    
    // Store in application storage
    app.circuitBreaker = circuitBreaker
    
    app.logger.info("⚡ Circuit breaker configured", metadata: [
        "failureThreshold": "\(config.failureThreshold)",
        "resetTimeout": "\(config.resetTimeout)",
        "slidingWindowSize": "\(config.slidingWindowSize)"
    ])
}

// Helper to describe circuit breaker state
private func describeState(_ state: CircuitBreakerState) -> String {
    switch state {
    case .closed:
        return "closed"
    case .open:
        return "open"
    case .halfOpen:
        return "half-open"
    }
}

// MARK: - Persistence Services Configuration

private func configurePersistenceServices(_ app: Application) {
    guard let messageQueue = app.messageQueue as? PersistentMessageQueueProtocol else {
        app.logger.warning("Cannot configure persistence services - PersistentMessageQueue not available")
        return
    }
    
    // Set up Dead Letter Queue Manager
    app.setupDeadLetterQueueManager()
    
    // Set up Message Retry Scheduler
    app.setupMessageRetryScheduler()
    
    // Set up Message Replay Service
    if let redis = app.redis,
       let dlqManager = app.deadLetterQueueManager {
        let replayService = MessageReplayService(
            redis: redis,
            messageQueue: messageQueue,
            dlqManager: dlqManager,
            logger: app.logger
        )
        app.messageReplayService = replayService
        app.logger.info("📼 Message replay service configured")
    }
    
    // Set up Queue Monitoring
    app.setupQueueMonitoring()
    
    app.logger.info("✅ All persistence services configured")
}
