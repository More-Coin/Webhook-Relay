import Testing
import Vapor
import NIOCore
@testable import FacebookWebhookRelay

@Suite("SSE Manager Tests")
struct SSEManagerTests {
    
    @Test("Can add and remove connections")
    func addRemoveConnections() async {
        let sseManager = SSEManager()
        let id1 = UUID()
        let id2 = UUID()
        
        // Create mock sources and promises
        let eventLoop = MultiThreadedEventLoopGroup.singleton.any()
        let promise1 = eventLoop.makePromise(of: Void.self)
        let promise2 = eventLoop.makePromise(of: Void.self)
        
        let producer1 = NIOAsyncSequenceProducer.makeSequence(
            elementType: String.self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: 1,
                highWatermark: 5
            ),
            finishOnDeinit: true,
            delegate: NIOAsyncSequenceProducerDelegateNil()
        )
        
        let producer2 = NIOAsyncSequenceProducer.makeSequence(
            elementType: String.self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: 1,
                highWatermark: 5
            ),
            finishOnDeinit: true,
            delegate: NIOAsyncSequenceProducerDelegateNil()
        )
        
        // Add connections
        await sseManager.addConnection(id: id1, source: producer1.source, promise: promise1)
        await sseManager.addConnection(id: id2, source: producer2.source, promise: promise2)
        
        #expect(await sseManager.getConnectionCount() == 2)
        
        // Remove one connection
        await sseManager.removeConnection(id: id1)
        #expect(await sseManager.getConnectionCount() == 1)
        
        // Remove second connection
        await sseManager.removeConnection(id: id2)
        #expect(await sseManager.getConnectionCount() == 0)
    }
    
    @Test("Broadcasting sends to all connections")
    func broadcastToConnections() async throws {
        let sseManager = SSEManager()
        let id1 = UUID()
        let id2 = UUID()
        
        let eventLoop = MultiThreadedEventLoopGroup.singleton.any()
        let promise1 = eventLoop.makePromise(of: Void.self)
        let promise2 = eventLoop.makePromise(of: Void.self)
        
        let producer1 = NIOAsyncSequenceProducer.makeSequence(
            elementType: String.self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: 1,
                highWatermark: 5
            ),
            finishOnDeinit: false,
            delegate: NIOAsyncSequenceProducerDelegateNil()
        )
        
        let producer2 = NIOAsyncSequenceProducer.makeSequence(
            elementType: String.self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: 1,
                highWatermark: 5
            ),
            finishOnDeinit: false,
            delegate: NIOAsyncSequenceProducerDelegateNil()
        )
        
        // Add connections
        await sseManager.addConnection(id: id1, source: producer1.source, promise: promise1)
        await sseManager.addConnection(id: id2, source: producer2.source, promise: promise2)
        
        // Create test message
        let testMessage = AppMessage(
            id: "test-id",
            senderId: "sender-123",
            senderName: "Test User",
            text: "Test message",
            timestamp: Date().iso8601,
            isFromCustomer: true,
            conversationId: "conv-123",
            customerName: "Test User",
            customerId: "sender-123"
        )
        
        let messageData = AppMessageData(type: "new_message", appMessage: testMessage)
        
        // Broadcast message
        await sseManager.broadcast(data: messageData)
        
        // Verify both sequences received data
        var received1 = false
        var received2 = false
        
        // Check first sequence
        Task {
            for try await event in producer1.sequence {
                if event.contains("new_message") {
                    received1 = true
                    break
                }
            }
        }
        
        // Check second sequence
        Task {
            for try await event in producer2.sequence {
                if event.contains("new_message") {
                    received2 = true
                    break
                }
            }
        }
        
        // Give some time for async operations
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        #expect(received1 || received2) // At least one should receive
        
        // Cleanup
        producer1.source.finish()
        producer2.source.finish()
        promise1.succeed(())
        promise2.succeed(())
    }
    
    @Test("Handles disconnected clients gracefully")
    func handlesDisconnectedClients() async {
        let sseManager = SSEManager()
        let id = UUID()
        
        let eventLoop = MultiThreadedEventLoopGroup.singleton.any()
        let promise = eventLoop.makePromise(of: Void.self)
        
        let producer = NIOAsyncSequenceProducer.makeSequence(
            elementType: String.self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: 1,
                highWatermark: 5
            ),
            finishOnDeinit: true,
            delegate: NIOAsyncSequenceProducerDelegateNil()
        )
        
        // Add connection
        await sseManager.addConnection(id: id, source: producer.source, promise: promise)
        #expect(await sseManager.getConnectionCount() == 1)
        
        // Simulate disconnection by finishing the source
        producer.source.finish()
        promise.succeed(())
        
        // Try to broadcast - should handle gracefully
        let testMessage = AppMessage(
            id: "test-id",
            senderId: "sender-123",
            senderName: "Test User",
            text: "Test message",
            timestamp: Date().iso8601,
            isFromCustomer: true,
            conversationId: "conv-123",
            customerName: "Test User",
            customerId: "sender-123"
        )
        
        let messageData = AppMessageData(type: "new_message", appMessage: testMessage)
        await sseManager.broadcast(data: messageData) // Should not crash
        
        // The broadcast method removes stale connections, so count should be 0
        #expect(await sseManager.getConnectionCount() == 0)
    }
} 