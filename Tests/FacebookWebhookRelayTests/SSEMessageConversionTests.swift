import XCTest
@testable import FacebookWebhookRelay
import Foundation

final class SSEMessageConversionTests: XCTestCase {
    
    var converter: SSEMessageConverter!
    var legacyConverter: SSEMessageConverter!
    
    override func setUp() {
        super.setUp()
        converter = SSEMessageConverter(useLegacyFormat: false)
        legacyConverter = SSEMessageConverter(useLegacyFormat: true)
    }
    
    // MARK: - Customer Change Tests
    
    func testCustomerChangeConversion() throws {
        // Create test data
        let customerData = [
            "id": "123e4567-e89b-12d3-a456-426614174000",
            "customerId": "CUST001",
            "customerName": "John Doe",
            "conversationId": "CONV123",
            "phoneNumber": "+1234567890",
            "address": "123 Main St",
            "lastContactedAt": Date().iso8601
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: customerData, options: [])
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "CUST001",
            entityType: "customer",
            action: "updated",
            timestamp: Date(),
            data: jsonData,
            bulkChanges: nil
        )
        
        // Convert to SSE
        let sseMessage = converter.convertServerMessage(serverMessage)
        
        // Verify
        XCTAssertNotNil(sseMessage)
        
        if case .customerUpdate(let update) = sseMessage {
            XCTAssertEqual(update.action, "updated")
            XCTAssertEqual(update.customerId, "CUST001")
            XCTAssertNotNil(update.customerData)
            XCTAssertEqual(update.customerData?.customerName, "John Doe")
            XCTAssertEqual(update.customerData?.phoneNumber, "+1234567890")
            XCTAssertEqual(update.version, SSEMessageVersion.current)
        } else {
            XCTFail("Expected customerUpdate message")
        }
    }
    
    // MARK: - Order Change Tests
    
    func testOrderChangeConversion() throws {
        // Create test data with items
        let orderData = [
            "id": "456e7890-e89b-12d3-a456-426614174111",
            "orderMessageId": "ORDER001",
            "date": Date().iso8601,
            "customerId": "CUST001",
            "customerName": "John Doe",
            "totalAmount": 150.50,
            "isCancelled": false,
            "items": [
                ["name": "Product A", "quantity": 2, "price": 50.25],
                ["name": "Product B", "quantity": 1, "price": 50.00]
            ]
        ] as [String: Any]
        
        let jsonData = try JSONSerialization.data(withJSONObject: orderData, options: [])
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "orderChange",
            entityId: "ORDER001",
            entityType: "order",
            action: "created",
            timestamp: Date(),
            data: jsonData,
            bulkChanges: nil
        )
        
        // Convert to SSE
        let sseMessage = converter.convertServerMessage(serverMessage)
        
        // Verify
        XCTAssertNotNil(sseMessage)
        
        if case .orderUpdate(let update) = sseMessage {
            XCTAssertEqual(update.action, "created")
            XCTAssertEqual(update.orderId, "ORDER001")
            XCTAssertNotNil(update.orderData)
            XCTAssertEqual(update.orderData?.customerName, "John Doe")
            XCTAssertEqual(update.orderData?.totalAmount, 150.50)
            XCTAssertEqual(update.orderData?.items?.count, 2)
            XCTAssertEqual(update.orderData?.items?.first?.name, "Product A")
        } else {
            XCTFail("Expected orderUpdate message")
        }
    }
    
    // MARK: - Inventory Change Tests
    
    func testInventoryChangeConversion() throws {
        let inventoryData = [
            "id": "789e0123-e89b-12d3-a456-426614174222",
            "itemName": "Widget X",
            "quantity": 50,
            "type": "purchase",
            "date": Date().iso8601,
            "currentStock": 150
        ] as [String: Any]
        
        let jsonData = try JSONSerialization.data(withJSONObject: inventoryData, options: [])
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "inventoryChange",
            entityId: "ITEM001",
            entityType: "inventory",
            action: "create",
            timestamp: Date(),
            data: jsonData,
            bulkChanges: nil
        )
        
        // Convert to SSE
        let sseMessage = converter.convertServerMessage(serverMessage)
        
        // Verify
        XCTAssertNotNil(sseMessage)
        
        if case .inventoryUpdate(let update) = sseMessage {
            XCTAssertEqual(update.action, "create")
            XCTAssertEqual(update.itemId, "ITEM001")
            XCTAssertNotNil(update.inventoryData)
            XCTAssertEqual(update.inventoryData?.itemName, "Widget X")
            XCTAssertEqual(update.inventoryData?.quantity, 50)
            XCTAssertEqual(update.inventoryData?.currentStock, 150)
        } else {
            XCTFail("Expected inventoryUpdate message")
        }
    }
    
    // MARK: - Bulk Change Tests
    
    func testBulkChangeConversion() throws {
        let change1Data = ["customerId": "CUST001", "status": "active"]
        let change2Data = ["orderId": "ORDER001", "status": "completed"]
        
        let change1 = BulkChangeItem(
            entityId: "CUST001",
            entityType: "customer",
            action: "updated",
            data: try JSONSerialization.data(withJSONObject: change1Data, options: [])
        )
        
        let change2 = BulkChangeItem(
            entityId: "ORDER001",
            entityType: "order",
            action: "updated",
            data: try JSONSerialization.data(withJSONObject: change2Data, options: [])
        )
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "bulkChange",
            entityId: nil,
            entityType: nil,
            action: nil,
            timestamp: Date(),
            data: nil,
            bulkChanges: [change1, change2]
        )
        
        // Convert to SSE
        let sseMessage = converter.convertServerMessage(serverMessage)
        
        // Verify
        XCTAssertNotNil(sseMessage)
        
        if case .bulkUpdate(let update) = sseMessage {
            XCTAssertEqual(update.changeCount, 2)
            XCTAssertEqual(update.changes.count, 2)
            XCTAssertEqual(update.changes[0].entityId, "CUST001")
            XCTAssertEqual(update.changes[0].entityType, "customer")
            XCTAssertEqual(update.changes[1].entityId, "ORDER001")
            XCTAssertEqual(update.changes[1].entityType, "order")
        } else {
            XCTFail("Expected bulkUpdate message")
        }
    }
    
    // MARK: - Legacy Format Tests
    
    func testLegacyFormatConversion() throws {
        let customerData = [
            "customerId": "CUST001",
            "customerName": "John Doe"
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: customerData, options: [])
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "CUST001",
            entityType: "customer",
            action: "updated",
            timestamp: Date(),
            data: jsonData,
            bulkChanges: nil
        )
        
        // Convert to SSE using legacy converter
        let sseMessage = legacyConverter.convertServerMessage(serverMessage)
        
        // Verify it's a legacy format
        XCTAssertNotNil(sseMessage)
        
        if case .legacy(let appData) = sseMessage {
            XCTAssertEqual(appData.type, "customer_update")
            XCTAssertEqual(appData.senderId, "system")
            XCTAssertNotNil(appData.postbackPayload)
            
            // Verify payload contains the data
            if let payloadData = appData.postbackPayload?.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: payloadData, options: []) as? [String: Any] {
                XCTAssertEqual(payload["action"] as? String, "updated")
                XCTAssertEqual(payload["entityId"] as? String, "CUST001")
                XCTAssertNotNil(payload["data"])
            } else {
                XCTFail("Failed to parse legacy payload")
            }
        } else {
            XCTFail("Expected legacy message format")
        }
    }
    
    // MARK: - Edge Cases
    
    func testMissingDataConversion() throws {
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "CUST001",
            entityType: "customer",
            action: "deleted",
            timestamp: Date(),
            data: nil,
            bulkChanges: nil
        )
        
        // Convert to SSE
        let sseMessage = converter.convertServerMessage(serverMessage)
        
        // Verify
        XCTAssertNotNil(sseMessage)
        
        if case .customerUpdate(let update) = sseMessage {
            XCTAssertEqual(update.action, "deleted")
            XCTAssertEqual(update.customerId, "CUST001")
            XCTAssertNil(update.customerData) // Should be nil when no data
        } else {
            XCTFail("Expected customerUpdate message")
        }
    }
    
    func testInvalidDataConversion() throws {
        let invalidData = "This is not JSON".data(using: .utf8)!
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "CUST001",
            entityType: "customer",
            action: "updated",
            timestamp: Date(),
            data: invalidData,
            bulkChanges: nil
        )
        
        // Convert to SSE - should handle gracefully
        let sseMessage = converter.convertServerMessage(serverMessage)
        
        // Verify
        XCTAssertNotNil(sseMessage)
        
        if case .customerUpdate(let update) = sseMessage {
            XCTAssertEqual(update.action, "updated")
            XCTAssertEqual(update.customerId, "CUST001")
            XCTAssertNil(update.customerData) // Should be nil when data is invalid
        } else {
            XCTFail("Expected customerUpdate message")
        }
    }
    
    func testTimestampPreservation() throws {
        let testDate = Date(timeIntervalSince1970: 1700000000) // Fixed date for testing
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "CUST001",
            entityType: "customer",
            action: "created",
            timestamp: testDate,
            data: nil,
            bulkChanges: nil
        )
        
        // Convert to SSE
        let sseMessage = converter.convertServerMessage(serverMessage)
        
        // Verify
        XCTAssertNotNil(sseMessage)
        
        if case .customerUpdate(let update) = sseMessage {
            // Verify timestamp is preserved
            let updateDate = ISO8601DateFormatter().date(from: update.timestamp)
            XCTAssertNotNil(updateDate)
            XCTAssertEqual(updateDate?.timeIntervalSince1970, testDate.timeIntervalSince1970, accuracy: 1.0)
        } else {
            XCTFail("Expected customerUpdate message")
        }
    }
    
    // MARK: - Performance Tests
    
    func testConversionPerformance() throws {
        let customerData = [
            "id": UUID().uuidString,
            "customerId": "CUST001",
            "customerName": "Performance Test User",
            "conversationId": "CONV123",
            "phoneNumber": "+1234567890",
            "address": "123 Performance St",
            "lastContactedAt": Date().iso8601
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: customerData, options: [])
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "CUST001",
            entityType: "customer",
            action: "updated",
            timestamp: Date(),
            data: jsonData,
            bulkChanges: nil
        )
        
        measure {
            // Measure conversion performance
            for _ in 0..<1000 {
                _ = converter.convertServerMessage(serverMessage)
            }
        }
    }
}