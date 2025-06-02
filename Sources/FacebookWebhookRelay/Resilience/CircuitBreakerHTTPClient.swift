import Vapor
import Foundation

// MARK: - Circuit Breaker HTTP Client Extension

extension Application {
    /// HTTP client with circuit breaker protection
    var protectedClient: CircuitBreakerHTTPClient {
        return CircuitBreakerHTTPClient(app: self)
    }
}

struct CircuitBreakerHTTPClient {
    let app: Application
    
    private var circuitBreaker: EnhancedCircuitBreaker? {
        app.circuitBreaker
    }
    
    private var logger: Logger {
        app.logger
    }
    
    /// Execute an HTTP request with circuit breaker protection
    func execute<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        guard let circuitBreaker = circuitBreaker else {
            // No circuit breaker configured, execute directly
            return try await operation()
        }
        
        return try await circuitBreaker.execute(operation)
    }
    
    /// POST request with circuit breaker protection
    func post(_ uri: URI, headers: HTTPHeaders = [:], beforeSend: @escaping (inout ClientRequest) throws -> () = { _ in }) async throws -> ClientResponse {
        return try await execute {
            try await app.client.post(uri, headers: headers, beforeSend: beforeSend)
        }
    }
    
    /// GET request with circuit breaker protection
    func get(_ uri: URI, headers: HTTPHeaders = [:], beforeSend: @escaping (inout ClientRequest) throws -> () = { _ in }) async throws -> ClientResponse {
        return try await execute {
            try await app.client.get(uri, headers: headers, beforeSend: beforeSend)
        }
    }
    
    /// PUT request with circuit breaker protection
    func put(_ uri: URI, headers: HTTPHeaders = [:], beforeSend: @escaping (inout ClientRequest) throws -> () = { _ in }) async throws -> ClientResponse {
        return try await execute {
            try await app.client.put(uri, headers: headers, beforeSend: beforeSend)
        }
    }
    
    /// DELETE request with circuit breaker protection
    func delete(_ uri: URI, headers: HTTPHeaders = [:], beforeSend: @escaping (inout ClientRequest) throws -> () = { _ in }) async throws -> ClientResponse {
        return try await execute {
            try await app.client.delete(uri, headers: headers, beforeSend: beforeSend)
        }
    }
}

// MARK: - Request Extension

extension Request {
    /// HTTP client with circuit breaker protection
    var protectedClient: RequestCircuitBreakerHTTPClient {
        return RequestCircuitBreakerHTTPClient(request: self)
    }
}

struct RequestCircuitBreakerHTTPClient {
    let request: Request
    
    private var circuitBreaker: EnhancedCircuitBreaker? {
        request.application.circuitBreaker
    }
    
    private var logger: Logger {
        request.logger
    }
    
    /// Execute an HTTP request with circuit breaker protection
    func execute<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        guard let circuitBreaker = circuitBreaker else {
            // No circuit breaker configured, execute directly
            return try await operation()
        }
        
        do {
            return try await circuitBreaker.execute(operation)
        } catch let error as CircuitBreakerError {
            // Log circuit breaker specific errors
            switch error {
            case .circuitOpen:
                logger.warning("Circuit breaker is open - request blocked")
                WebhookRelayMetrics.circuitBreakerRejections.increment()
            case .halfOpenLimitReached:
                logger.warning("Circuit breaker half-open limit reached")
                WebhookRelayMetrics.circuitBreakerRejections.increment()
            }
            throw error
        }
    }
    
    /// POST request with circuit breaker protection
    func post(_ uri: URI, headers: HTTPHeaders = [:], beforeSend: @escaping (inout ClientRequest) throws -> () = { _ in }) async throws -> ClientResponse {
        return try await execute {
            try await request.client.post(uri, headers: headers, beforeSend: beforeSend)
        }
    }
    
    /// GET request with circuit breaker protection
    func get(_ uri: URI, headers: HTTPHeaders = [:], beforeSend: @escaping (inout ClientRequest) throws -> () = { _ in }) async throws -> ClientResponse {
        return try await execute {
            try await request.client.get(uri, headers: headers, beforeSend: beforeSend)
        }
    }
    
    /// PUT request with circuit breaker protection
    func put(_ uri: URI, headers: HTTPHeaders = [:], beforeSend: @escaping (inout ClientRequest) throws -> () = { _ in }) async throws -> ClientResponse {
        return try await execute {
            try await request.client.put(uri, headers: headers, beforeSend: beforeSend)
        }
    }
    
    /// DELETE request with circuit breaker protection
    func delete(_ uri: URI, headers: HTTPHeaders = [:], beforeSend: @escaping (inout ClientRequest) throws -> () = { _ in }) async throws -> ClientResponse {
        return try await execute {
            try await request.client.delete(uri, headers: headers, beforeSend: beforeSend)
        }
    }
}