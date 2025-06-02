import XCTest
@testable import FacebookWebhookRelay
import Foundation

/// Performance benchmarks for SSE message conversion
final class SSEConversionBenchmarks: XCTestCase {
    
    var converter: SSEMessageConverter!
    var legacyConverter: SSEMessageConverter!
    
    // Test data
    var simpleServerMessage: ServerMessage!
    var complexServerMessage: ServerMessage!
    var bulkServerMessage: ServerMessage!
    
    override func setUp() {
        super.setUp()
        
        converter = SSEMessageConverter(useLegacyFormat: false)
        legacyConverter = SSEMessageConverter(useLegacyFormat: true)
        
        // Create test messages
        simpleServerMessage = createSimpleMessage()
        complexServerMessage = createComplexMessage()
        bulkServerMessage = createBulkMessage()
    }
    
    // MARK: - Benchmark Tests
    
    func testSimpleConversionPerformance() {
        measure {
            for _ in 0..<1000 {
                _ = converter.convertServerMessage(simpleServerMessage)
            }
        }
    }
    
    func testComplexConversionPerformance() {
        measure {
            for _ in 0..<500 {
                _ = converter.convertServerMessage(complexServerMessage)
            }
        }
    }
    
    func testBulkConversionPerformance() {
        measure {
            for _ in 0..<100 {
                _ = converter.convertServerMessage(bulkServerMessage)
            }
        }
    }
    
    func testLegacyVsNewFormatPerformance() {
        let iterations = 1000
        
        // Measure new format
        let newFormatStart = Date()
        for _ in 0..<iterations {
            _ = converter.convertServerMessage(complexServerMessage)
        }
        let newFormatDuration = Date().timeIntervalSince(newFormatStart)
        
        // Measure legacy format
        let legacyFormatStart = Date()
        for _ in 0..<iterations {
            _ = legacyConverter.convertServerMessage(complexServerMessage)
        }
        let legacyFormatDuration = Date().timeIntervalSince(legacyFormatStart)
        
        print("New format: \(newFormatDuration)s for \(iterations) iterations")
        print("Legacy format: \(legacyFormatDuration)s for \(iterations) iterations")
        print("Performance difference: \((newFormatDuration - legacyFormatDuration) / legacyFormatDuration * 100)%")
        
        // Assert that new format isn't significantly slower (allow 20% overhead)
        XCTAssertLessThan(newFormatDuration, legacyFormatDuration * 1.2, 
                         "New format should not be more than 20% slower than legacy format")
    }
    
    func testMemoryUsage() {
        // This test measures memory allocation during conversion
        let iterations = 10000
        
        let initialMemory = getMemoryUsage()
        
        for _ in 0..<iterations {
            autoreleasepool {
                _ = converter.convertServerMessage(complexServerMessage)
            }
        }
        
        let finalMemory = getMemoryUsage()
        let memoryIncrease = finalMemory - initialMemory
        
        print("Memory usage increased by \(memoryIncrease / 1024 / 1024) MB for \(iterations) conversions")
        
        // Assert reasonable memory usage (less than 50MB for 10k conversions)
        XCTAssertLessThan(memoryIncrease, 50 * 1024 * 1024, 
                         "Memory usage should be reasonable")
    }
    
    // MARK: - Helper Methods
    
    private func createSimpleMessage() -> ServerMessage {
        let data = try! JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "customerId": "CUST001",
            "customerName": "Test User"
        ], options: [])
        
        return ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "CUST001",
            entityType: "customer",
            action: "updated",
            timestamp: Date(),
            data: data,
            bulkChanges: nil
        )
    }
    
    private func createComplexMessage() -> ServerMessage {
        let orderData: [String: Any] = [
            "id": UUID().uuidString,
            "orderMessageId": "ORDER001",
            "date": Date().iso8601,
            "customerId": "CUST001",
            "customerName": "Complex Test User",
            "totalAmount": 999.99,
            "isCancelled": false,
            "items": (0..<50).map { i in
                [
                    "name": "Product \(i)",
                    "quantity": Int.random(in: 1...10),
                    "price": Double.random(in: 10...100)
                ]
            },
            "metadata": [
                "source": "web",
                "ip": "192.168.1.1",
                "userAgent": "Mozilla/5.0",
                "sessionId": UUID().uuidString
            ]
        ]
        
        let data = try! JSONSerialization.data(withJSONObject: orderData, options: [])
        
        return ServerMessage(
            id: UUID(),
            type: "orderChange",
            entityId: "ORDER001",
            entityType: "order",
            action: "created",
            timestamp: Date(),
            data: data,
            bulkChanges: nil
        )
    }
    
    private func createBulkMessage() -> ServerMessage {
        let changes = (0..<100).map { i in
            let changeData = [
                "id": UUID().uuidString,
                "status": "updated",
                "value": Double.random(in: 0...1000)
            ]
            
            return BulkChangeItem(
                entityId: "ENTITY\(i)",
                entityType: i % 3 == 0 ? "customer" : i % 3 == 1 ? "order" : "inventory",
                action: "updated",
                data: try! JSONSerialization.data(withJSONObject: changeData, options: [])
            )
        }
        
        return ServerMessage(
            id: UUID(),
            type: "bulkChange",
            entityId: nil,
            entityType: nil,
            action: nil,
            timestamp: Date(),
            data: nil,
            bulkChanges: changes
        )
    }
    
    private func getMemoryUsage() -> Int64 {
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
        
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}

// MARK: - Performance Targets

extension SSEConversionBenchmarks {
    /// Expected performance targets for different message types
    struct PerformanceTargets {
        static let simpleMessageConversionTime: TimeInterval = 0.0001 // 0.1ms per message
        static let complexMessageConversionTime: TimeInterval = 0.001 // 1ms per message
        static let bulkMessageConversionTime: TimeInterval = 0.01 // 10ms per bulk message
    }
}