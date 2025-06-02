import Vapor
import NIOCore // For EventLoopPromise and NIOAsyncSequenceProducer types

actor SSEManager {
    // Use the fully qualified type for the source
    typealias ProducerSource = NIOAsyncSequenceProducer<String, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, NIOAsyncSequenceProducerDelegateNil>.Source
    
    private var connections: [UUID: (source: ProducerSource, promise: EventLoopPromise<Void>)] = [:]
    private let logger = Logger(label: "sse-manager")

    func addConnection(id: UUID, source: ProducerSource, promise: EventLoopPromise<Void>) {
        connections[id] = (source: source, promise: promise)
        logger.info("SSE connection added: \(id). Total: \(connections.count)")
        // No longer need to log the type here as it's now strongly typed
    }

    func removeConnection(id: UUID) {
        // When removing, we might also want to ensure the source is finished
        // if finishOnDeinit was false and it wasn't finished by the route handler.
        // However, the route handler's promise fulfillment should trigger source.finish().
        if let (_, promise) = connections.removeValue(forKey: id) {
            promise.succeed(()) // Fulfill promise to signal closure (if not already)
            logger.info("SSE connection removed: \(id). Total: \(connections.count)")
        }
    }

    func broadcast(data: AppMessageData) {
        // Legacy method - convert to SSE message and broadcast
        broadcast(message: .legacy(data))
    }
    
    func broadcast(message: SSEMessage) {
        guard !connections.isEmpty else {
            // logger.debug("No SSE connections to broadcast to.") // Optional: less verbose log
            return
        }

        // Determine which format to use based on environment variable
        let useLegacyFormat = Environment.get("SSE_LEGACY_FORMAT") == "true"
        
        let dataToEncode: Encodable = useLegacyFormat && message.toLegacyFormat() != nil
            ? message.toLegacyFormat()!
            : message
        
        guard let jsonData = try? JSONEncoder().encode(dataToEncode),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to encode SSE message for broadcast.")
            return
        }

        let eventString = "data: \(jsonString)\n\n"
        // logger.debug("Broadcasting to \(connections.count) SSE connections: \(eventString.prefix(100))...") // Optional: less verbose log

        var connectionsToRemove: [UUID] = []

        for (id, connection) in connections {
            let yieldResult = connection.source.yield(eventString)
            switch yieldResult {
            case .produceMore:
                break
            case .stopProducing:
                logger.info("SSE ID \(id): Consumer requested to stop producing.")
            case .dropped:
                logger.warning("SSE ID \(id): Dropped data — removing connection.")
                connectionsToRemove.append(id)
            }
        }

        // Now remove all stale connections
        for id in connectionsToRemove {
            if let (_, promise) = connections.removeValue(forKey: id) {
                promise.succeed(())
                logger.info("🔌 Removed stale SSE connection: \(id)")
            }
        }

        
        if connections.count > 0 && connectionsToRemove.isEmpty {
             logger.info("📡 Broadcasted to \(connections.count) active connections.")
        }
    }
    
    func getConnectionCount() -> Int {
        connections.count
    }
}

// This helper struct should remain (can be in this file or Models.swift)
// Ensure NIOCore is imported where this is defined if it's in a separate file.
public struct NIOAsyncSequenceProducerDelegateNil: NIOAsyncSequenceProducerDelegate {
    public typealias Element = String
    public typealias DelegateResult = Void // This is important for the Source's generic signature

    public init() {}

    public func produceMore() {
        // logger.debug("NIOAsyncSequenceProducerDelegateNil: produceMore called") // Optional
    }

    public func didTerminate() {
        // logger.debug("NIOAsyncSequenceProducerDelegateNil: didTerminate called") // Optional
    }
}
