import XCTest
@testable import FacebookWebhookRelay
import Foundation

final class MessageConversionTests: XCTestCase {
    
    // MARK: - Test Data Preservation
    
    func testCustomerChangePreservesAllData() throws {
        // Given: A ServerMessage with customer change and rich data
        let customerData = [
            "id": "123",
            "name": "John Doe",
            "email": "john@example.com",
            "totalOrders": 5
        ]
        let dataPayload = try JSONSerialization.data(withJSONObject: customerData)
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "123",
            entityType: "customer",
            action: "updated",
            timestamp: Date(),
            data: dataPayload,
            bulkChanges: nil
        )
        
        // When: Converting to AppMessageData
        let connection = NaraServerConnection(
            serverURL: "https://example.com",
            token: "test",
            deviceId: "test",
            sseManager: SSEManager()
        )
        
        let result = connection.convertServerMessage(serverMessage)
        
        // Then: All data should be preserved
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, "customer_update")
        XCTAssertEqual(result?.senderId, "system") // Not using entityId as senderId
        
        // Parse the payload to verify data preservation
        let payloadData = result?.postbackPayload?.data(using: .utf8) ?? Data()
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        
        XCTAssertEqual(payload?["action"] as? String, "updated")
        XCTAssertEqual(payload?["entityId"] as? String, "123")
        XCTAssertEqual(payload?["entityType"] as? String, "customer")
        
        // Verify the full data is preserved
        let preservedData = payload?["data"] as? [String: Any]
        XCTAssertEqual(preservedData?["id"] as? String, "123")
        XCTAssertEqual(preservedData?["name"] as? String, "John Doe")
        XCTAssertEqual(preservedData?["email"] as? String, "john@example.com")
        XCTAssertEqual(preservedData?["totalOrders"] as? Int, 5)
    }
    
    func testOrderChangePreservesAllData() throws {
        // Given: A ServerMessage with order change and complex data
        let orderData = [
            "orderId": "ORD-456",
            "customerId": "123",
            "items": [
                ["productId": "P1", "quantity": 2, "price": 19.99],
                ["productId": "P2", "quantity": 1, "price": 29.99]
            ],
            "total": 69.97,
            "status": "completed"
        ] as [String : Any]
        let dataPayload = try JSONSerialization.data(withJSONObject: orderData)
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "orderChange",
            entityId: "ORD-456",
            entityType: "order",
            action: "created",
            timestamp: Date(),
            data: dataPayload,
            bulkChanges: nil
        )
        
        // When: Converting to AppMessageData
        let connection = NaraServerConnection(
            serverURL: "https://example.com",
            token: "test",
            deviceId: "test",
            sseManager: SSEManager()
        )
        
        let result = connection.convertServerMessage(serverMessage)
        
        // Then: All data should be preserved
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, "order_update")
        XCTAssertEqual(result?.senderId, "system")
        
        let payloadData = result?.postbackPayload?.data(using: .utf8) ?? Data()
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        
        let preservedData = payload?["data"] as? [String: Any]
        XCTAssertEqual(preservedData?["orderId"] as? String, "ORD-456")
        XCTAssertEqual(preservedData?["total"] as? Double, 69.97)
        XCTAssertEqual(preservedData?["status"] as? String, "completed")
        
        let items = preservedData?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 2)
    }
    
    func testBulkChangePreservesAllData() throws {
        // Given: A ServerMessage with bulk changes
        let change1Data = try JSONSerialization.data(withJSONObject: ["quantity": 10])
        let change2Data = try JSONSerialization.data(withJSONObject: ["quantity": 5])
        
        let bulkChanges = [
            BulkChangeItem(entityId: "P1", entityType: "product", action: "updated", data: change1Data),
            BulkChangeItem(entityId: "P2", entityType: "product", action: "updated", data: change2Data)
        ]
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "bulkChange",
            entityId: nil,
            entityType: nil,
            action: nil,
            timestamp: Date(),
            data: nil,
            bulkChanges: bulkChanges
        )
        
        // When: Converting to AppMessageData
        let connection = NaraServerConnection(
            serverURL: "https://example.com",
            token: "test",
            deviceId: "test",
            sseManager: SSEManager()
        )
        
        let result = connection.convertServerMessage(serverMessage)
        
        // Then: All bulk changes should be preserved
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, "bulk_update")
        XCTAssertEqual(result?.senderId, "system")
        
        let payloadData = result?.postbackPayload?.data(using: .utf8) ?? Data()
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        
        XCTAssertEqual(payload?["changeCount"] as? Int, 2)
        
        let changes = payload?["changes"] as? [[String: Any]]
        XCTAssertEqual(changes?.count, 2)
        
        let firstChange = changes?[0]
        XCTAssertEqual(firstChange?["entityId"] as? String, "P1")
        let firstChangeData = firstChange?["data"] as? [String: Any]
        XCTAssertEqual(firstChangeData?["quantity"] as? Int, 10)
    }
    
    func testMessageUpdateExtractsSenderIdFromData() throws {
        // Given: A ServerMessage with message update containing senderId in data
        let messageData = [
            "messageId": "MSG-789",
            "senderId": "USER-123",
            "text": "Hello, world!",
            "timestamp": "2024-01-01T12:00:00Z"
        ]
        let dataPayload = try JSONSerialization.data(withJSONObject: messageData)
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "messageUpdate",
            entityId: "MSG-789",
            entityType: "message",
            action: "created",
            timestamp: Date(),
            data: dataPayload,
            bulkChanges: nil
        )
        
        // When: Converting to AppMessageData
        let connection = NaraServerConnection(
            serverURL: "https://example.com",
            token: "test",
            deviceId: "test",
            sseManager: SSEManager()
        )
        
        let result = connection.convertServerMessage(serverMessage)
        
        // Then: SenderId should be extracted from data, not entityId
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, "message_update")
        XCTAssertEqual(result?.senderId, "USER-123") // Extracted from data, not entityId
        
        let payloadData = result?.postbackPayload?.data(using: .utf8) ?? Data()
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        
        let preservedData = payload?["data"] as? [String: Any]
        XCTAssertEqual(preservedData?["text"] as? String, "Hello, world!")
    }
    
    func testUnknownMessageTypePreservesData() throws {
        // Given: A ServerMessage with unknown type
        let unknownData = ["custom": "data", "value": 42] as [String : Any]
        let dataPayload = try JSONSerialization.data(withJSONObject: unknownData)
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customType",
            entityId: "CUSTOM-1",
            entityType: "custom",
            action: "processed",
            timestamp: Date(),
            data: dataPayload,
            bulkChanges: nil
        )
        
        // When: Converting to AppMessageData
        let connection = NaraServerConnection(
            serverURL: "https://example.com",
            token: "test",
            deviceId: "test",
            sseManager: SSEManager()
        )
        
        let result = connection.convertServerMessage(serverMessage)
        
        // Then: Data should still be preserved
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, "unknown_update")
        XCTAssertEqual(result?.senderId, "system")
        
        let payloadData = result?.postbackPayload?.data(using: .utf8) ?? Data()
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        
        XCTAssertEqual(payload?["type"] as? String, "customType")
        let preservedData = payload?["data"] as? [String: Any]
        XCTAssertEqual(preservedData?["custom"] as? String, "data")
        XCTAssertEqual(preservedData?["value"] as? Int, 42)
    }
    
    // MARK: - Test Timestamp Formatting
    
    func testTimestampFormattingConsistency() throws {
        // Given: Various ServerMessages with different timestamps
        let testDate = Date()
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "123",
            entityType: "customer",
            action: "created",
            timestamp: testDate,
            data: nil,
            bulkChanges: nil
        )
        
        // When: Converting to AppMessageData
        let connection = NaraServerConnection(
            serverURL: "https://example.com",
            token: "test",
            deviceId: "test",
            sseManager: SSEManager()
        )
        
        let result = connection.convertServerMessage(serverMessage)
        
        // Then: Timestamp should be in ISO8601 format
        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.timestamp)
        
        // Verify ISO8601 format
        let formatter = ISO8601DateFormatter()
        let parsedDate = formatter.date(from: result!.timestamp)
        XCTAssertNotNil(parsedDate)
        
        // Verify millisecond precision is maintained
        let timeInterval = abs(testDate.timeIntervalSince(parsedDate!))
        XCTAssertLessThan(timeInterval, 1.0) // Within 1 second
    }
    
    // MARK: - Test Edge Cases
    
    func testNilDataHandling() throws {
        // Given: ServerMessage with nil data
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "123",
            entityType: "customer",
            action: "deleted",
            timestamp: Date(),
            data: nil,
            bulkChanges: nil
        )
        
        // When: Converting to AppMessageData
        let connection = NaraServerConnection(
            serverURL: "https://example.com",
            token: "test",
            deviceId: "test",
            sseManager: SSEManager()
        )
        
        let result = connection.convertServerMessage(serverMessage)
        
        // Then: Should handle gracefully without data field
        XCTAssertNotNil(result)
        
        let payloadData = result?.postbackPayload?.data(using: .utf8) ?? Data()
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        
        XCTAssertEqual(payload?["action"] as? String, "deleted")
        XCTAssertEqual(payload?["entityId"] as? String, "123")
        XCTAssertNil(payload?["data"]) // No data field when source data is nil
    }
    
    func testInvalidJSONDataHandling() throws {
        // Given: ServerMessage with invalid JSON data
        let invalidData = "This is not JSON".data(using: .utf8)!
        
        let serverMessage = ServerMessage(
            id: UUID(),
            type: "customerChange",
            entityId: "123",
            entityType: "customer",
            action: "updated",
            timestamp: Date(),
            data: invalidData,
            bulkChanges: nil
        )
        
        // When: Converting to AppMessageData
        let connection = NaraServerConnection(
            serverURL: "https://example.com",
            token: "test",
            deviceId: "test",
            sseManager: SSEManager()
        )
        
        let result = connection.convertServerMessage(serverMessage)
        
        // Then: Should handle gracefully, excluding invalid data
        XCTAssertNotNil(result)
        
        let payloadData = result?.postbackPayload?.data(using: .utf8) ?? Data()
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        
        XCTAssertEqual(payload?["action"] as? String, "updated")
        XCTAssertNil(payload?["data"]) // Invalid JSON data is not included
    }
}