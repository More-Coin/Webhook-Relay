import Foundation
import Vapor

/// Service responsible for converting between different message formats
struct SSEMessageConverter {
    private let logger = Logger(label: "sse-converter")
    private let useLegacyFormat: Bool
    
    init(useLegacyFormat: Bool = false) {
        self.useLegacyFormat = useLegacyFormat
    }
    
    // MARK: - ServerMessage to SSE Conversion
    
    /// Convert ServerMessage to appropriate SSE message type
    func convertServerMessage(_ serverMessage: ServerMessage) -> SSEMessage? {
        // If legacy mode is enabled, use the old conversion
        if useLegacyFormat {
            if let legacyData = convertToLegacyFormat(serverMessage) {
                return .legacy(legacyData)
            }
            return nil
        }
        
        // New conversion with full data preservation
        switch serverMessage.type {
        case "customerChange":
            return convertCustomerChange(serverMessage)
            
        case "orderChange":
            return convertOrderChange(serverMessage)
            
        case "inventoryChange":
            return convertInventoryChange(serverMessage)
            
        case "bulkChange":
            return convertBulkChange(serverMessage)
            
        case "error":
            return convertError(serverMessage)
            
        case "connected":
            return .systemStatus(SystemStatusSSE(
                status: "connected",
                message: "Successfully connected to server",
                timestamp: serverMessage.timestamp
            ))
            
        default:
            logger.warning("Unknown server message type: \(serverMessage.type)")
            return nil
        }
    }
    
    // MARK: - Specific Conversions
    
    private func convertCustomerChange(_ serverMessage: ServerMessage) -> SSEMessage? {
        let action = serverMessage.action ?? "unknown"
        let customerId = serverMessage.entityId ?? ""
        
        // Extract customer data if available
        var customerData: CustomerUpdateSSE.CustomerData?
        if let data = serverMessage.data {
            do {
                // Try to decode as customer sync data
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                
                if let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    customerData = CustomerUpdateSSE.CustomerData(
                        id: jsonObject["id"] as? String != nil ? UUID(uuidString: jsonObject["id"] as! String) : nil,
                        customerId: jsonObject["customerId"] as? String ?? customerId,
                        customerName: jsonObject["customerName"] as? String ?? "Unknown",
                        conversationId: jsonObject["conversationId"] as? String ?? "",
                        phoneNumber: jsonObject["phoneNumber"] as? String,
                        address: jsonObject["address"] as? String,
                        lastContactedAt: jsonObject["lastContactedAt"] as? String != nil
                            ? ISO8601DateFormatter().date(from: jsonObject["lastContactedAt"] as! String)
                            : nil
                    )
                }
            } catch {
                logger.error("Failed to decode customer data: \(error)")
            }
        }
        
        return .customerUpdate(CustomerUpdateSSE(
            action: action,
            customerId: customerId,
            customerData: customerData,
            timestamp: serverMessage.timestamp
        ))
    }
    
    private func convertOrderChange(_ serverMessage: ServerMessage) -> SSEMessage? {
        let action = serverMessage.action ?? "unknown"
        let orderId = serverMessage.entityId ?? ""
        
        // Extract order data if available
        var orderData: OrderUpdateSSE.OrderData?
        if let data = serverMessage.data {
            do {
                if let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    // Parse items if available
                    var items: [OrderUpdateSSE.OrderItem]?
                    if let itemsArray = jsonObject["items"] as? [[String: Any]] {
                        items = itemsArray.compactMap { item in
                            guard let name = item["name"] as? String,
                                  let quantity = item["quantity"] as? Int,
                                  let price = item["price"] as? Double else {
                                return nil
                            }
                            return OrderUpdateSSE.OrderItem(name: name, quantity: quantity, price: price)
                        }
                    }
                    
                    orderData = OrderUpdateSSE.OrderData(
                        id: jsonObject["id"] as? String != nil ? UUID(uuidString: jsonObject["id"] as! String) : nil,
                        orderMessageId: jsonObject["orderMessageId"] as? String ?? orderId,
                        date: jsonObject["date"] as? String != nil
                            ? ISO8601DateFormatter().date(from: jsonObject["date"] as! String) ?? Date()
                            : Date(),
                        customerId: jsonObject["customerId"] as? String ?? "",
                        customerName: jsonObject["customerName"] as? String ?? "Unknown",
                        totalAmount: jsonObject["totalAmount"] as? Double ?? 0.0,
                        isCancelled: jsonObject["isCancelled"] as? Bool ?? false,
                        items: items
                    )
                }
            } catch {
                logger.error("Failed to decode order data: \(error)")
            }
        }
        
        return .orderUpdate(OrderUpdateSSE(
            action: action,
            orderId: orderId,
            orderData: orderData,
            timestamp: serverMessage.timestamp
        ))
    }
    
    private func convertInventoryChange(_ serverMessage: ServerMessage) -> SSEMessage? {
        let action = serverMessage.action ?? "unknown"
        let itemId = serverMessage.entityId ?? ""
        
        // Extract inventory data if available
        var inventoryData: InventoryUpdateSSE.InventoryData?
        if let data = serverMessage.data {
            do {
                if let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    inventoryData = InventoryUpdateSSE.InventoryData(
                        id: jsonObject["id"] as? String != nil ? UUID(uuidString: jsonObject["id"] as! String) : nil,
                        itemName: jsonObject["itemName"] as? String ?? "Unknown Item",
                        quantity: jsonObject["quantity"] as? Int ?? 0,
                        transactionType: jsonObject["type"] as? String ?? "unknown",
                        date: jsonObject["date"] as? String != nil
                            ? ISO8601DateFormatter().date(from: jsonObject["date"] as! String) ?? Date()
                            : Date(),
                        currentStock: jsonObject["currentStock"] as? Int
                    )
                }
            } catch {
                logger.error("Failed to decode inventory data: \(error)")
            }
        }
        
        return .inventoryUpdate(InventoryUpdateSSE(
            action: action,
            itemId: itemId,
            inventoryData: inventoryData,
            timestamp: serverMessage.timestamp
        ))
    }
    
    private func convertBulkChange(_ serverMessage: ServerMessage) -> SSEMessage? {
        guard let bulkChanges = serverMessage.bulkChanges else {
            logger.warning("Bulk change message missing bulkChanges array")
            return nil
        }
        
        let changes = bulkChanges.map { change in
            var changeData: AnyCodable?
            if let data = change.data {
                do {
                    if let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) {
                        changeData = AnyCodable(jsonObject)
                    }
                } catch {
                    logger.error("Failed to decode bulk change data: \(error)")
                }
            }
            
            return BulkUpdateSSE.BulkChange(
                entityType: change.entityType,
                entityId: change.entityId,
                action: change.action,
                data: changeData
            )
        }
        
        return .bulkUpdate(BulkUpdateSSE(
            changes: changes,
            timestamp: serverMessage.timestamp
        ))
    }
    
    private func convertError(_ serverMessage: ServerMessage) -> SSEMessage? {
        let errorMessage = serverMessage.entityId ?? "Unknown error"
        var details: [String: AnyCodable]?
        
        if let data = serverMessage.data {
            do {
                if let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    details = jsonObject.mapValues { AnyCodable($0) }
                }
            } catch {
                logger.error("Failed to decode error details: \(error)")
            }
        }
        
        return .error(ErrorSSE(
            errorCode: "SERVER_ERROR",
            errorMessage: errorMessage,
            details: details,
            timestamp: serverMessage.timestamp
        ))
    }
    
    // MARK: - Legacy Conversion
    
    private func convertToLegacyFormat(_ serverMessage: ServerMessage) -> AppMessageData? {
        // This maintains the existing conversion logic for backward compatibility
        switch serverMessage.type {
        case "customerChange", "orderChange", "inventoryChange":
            var payloadData: [String: Any] = [
                "action": serverMessage.action ?? "unknown",
                "entityId": serverMessage.entityId ?? "",
                "entityType": serverMessage.entityType ?? serverMessage.type.replacingOccurrences(of: "Change", with: "")
            ]
            
            if let data = serverMessage.data,
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) {
                payloadData["data"] = jsonObject
            }
            
            let payloadString = (try? JSONSerialization.data(withJSONObject: payloadData, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\": \"serialization_failed\"}"
            
            return AppMessageData(
                type: serverMessage.type.replacingOccurrences(of: "Change", with: "_update"),
                postbackSenderId: "system",
                payload: payloadString,
                timestamp: serverMessage.timestamp
            )
            
        case "bulkChange":
            if let bulkChanges = serverMessage.bulkChanges {
                var payloadData: [String: Any] = [
                    "changeCount": bulkChanges.count,
                    "changes": bulkChanges.map { change in
                        var changeData: [String: Any] = [
                            "entityId": change.entityId,
                            "entityType": change.entityType,
                            "action": change.action
                        ]
                        
                        if let data = change.data,
                           let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) {
                            changeData["data"] = jsonObject
                        }
                        
                        return changeData
                    }
                ]
                
                let payloadString = (try? JSONSerialization.data(withJSONObject: payloadData, options: []))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\": \"serialization_failed\"}"
                
                return AppMessageData(
                    type: "bulk_update",
                    postbackSenderId: "system",
                    payload: payloadString,
                    timestamp: serverMessage.timestamp
                )
            }
            
        default:
            break
        }
        
        return nil
    }
    
    // MARK: - Facebook Event to SSE Conversion
    
    /// Convert Facebook messaging event to SSE message
    func convertFacebookEvent(_ event: FacebookMessagingEvent, senderInfo: SenderInfo?, conversationId: String) -> SSEMessage? {
        if let message = event.message {
            // Convert to new message
            let appMessage = AppMessage(
                id: message.mid,
                senderId: event.sender.id,
                senderName: senderInfo?.name ?? "Unknown User",
                text: message.text ?? "",
                timestamp: Date(timeIntervalSince1970: TimeInterval(event.timestamp / 1000)).iso8601,
                isFromCustomer: true,
                conversationId: conversationId,
                customerName: senderInfo?.name ?? "Unknown User",
                customerId: event.sender.id
            )
            
            return useLegacyFormat
                ? .legacy(AppMessageData(type: "new_message", appMessage: appMessage))
                : .newMessage(MessageSSE(message: appMessage))
        } else if let postback = event.postback {
            // Convert to postback
            return useLegacyFormat
                ? .legacy(AppMessageData(
                    type: "postback",
                    postbackSenderId: event.sender.id,
                    payload: postback.payload,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(event.timestamp / 1000))
                ))
                : .postback(PostbackSSE(
                    senderId: event.sender.id,
                    payload: postback.payload,
                    title: postback.title,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(event.timestamp / 1000))
                ))
        }
        
        return nil
    }
}