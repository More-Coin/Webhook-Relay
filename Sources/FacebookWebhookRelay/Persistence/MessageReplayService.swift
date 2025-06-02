import Foundation
import Vapor
import RediStack

// MARK: - Message Replay Service

/// Provides comprehensive message replay capabilities for operations and recovery
actor MessageReplayService {
    private let redis: RedisClient
    private let messageQueue: PersistentMessageQueueProtocol
    private let dlqManager: DeadLetterQueueManager
    private let logger: Logger
    
    // Replay audit tracking
    private let auditStreamKey = "webhook-messages:replay:audit"
    
    init(
        redis: RedisClient,
        messageQueue: PersistentMessageQueueProtocol,
        dlqManager: DeadLetterQueueManager,
        logger: Logger
    ) {
        self.redis = redis
        self.messageQueue = messageQueue
        self.dlqManager = dlqManager
        self.logger = logger
    }
    
    // MARK: - Replay Operations
    
    /// Replay messages from a specific time range
    func replayFromTimeRange(
        from startDate: Date,
        to endDate: Date,
        filter: MessageFilter? = nil
    ) async throws -> ReplayResult {
        logger.info("Starting time-based replay", metadata: [
            "from": startDate.iso8601,
            "to": endDate.iso8601
        ])
        
        let auditId = UUID().uuidString
        let startTime = Date()
        
        // Track audit
        try await recordAuditStart(
            auditId: auditId,
            type: "time_range",
            parameters: [
                "from": startDate.iso8601,
                "to": endDate.iso8601,
                "filter": String(describing: filter)
            ]
        )
        
        var replayedCount = 0
        var failedCount = 0
        var errors: [String: String] = [:]
        
        // Get messages from all sources
        let sources = try await getMessagesFromAllSources(from: startDate, to: endDate, filter: filter)
        
        for message in sources {
            do {
                // Create fresh message for replay
                let replayMessage = PersistedMessage(
                    payload: message.payload,
                    messageType: message.messageType,
                    maxRetries: message.maxRetries,
                    metadata: message.metadata.merging(
                        ["replay_audit_id": auditId, "original_id": message.id],
                        uniquingKeysWith: { _, new in new }
                    )
                )
                
                _ = try await messageQueue.enqueuePersisted(replayMessage)
                replayedCount += 1
                
            } catch {
                failedCount += 1
                errors[message.id] = error.localizedDescription
                logger.error("Failed to replay message", metadata: [
                    "messageId": message.id,
                    "error": "\(error)"
                ])
            }
        }
        
        let result = ReplayResult(
            auditId: auditId,
            startTime: startTime,
            endTime: Date(),
            totalMessages: sources.count,
            successCount: replayedCount,
            failureCount: failedCount,
            errors: errors
        )
        
        // Record audit completion
        try await recordAuditComplete(auditId: auditId, result: result)
        
        logger.info("Completed time-based replay", metadata: [
            "auditId": auditId,
            "replayed": "\(replayedCount)",
            "failed": "\(failedCount)"
        ])
        
        return result
    }
    
    /// Replay specific messages by ID
    func replayByIds(_ messageIds: [String]) async throws -> ReplayResult {
        logger.info("Starting ID-based replay", metadata: [
            "count": "\(messageIds.count)"
        ])
        
        let auditId = UUID().uuidString
        let startTime = Date()
        
        try await recordAuditStart(
            auditId: auditId,
            type: "by_ids",
            parameters: ["messageIds": messageIds.joined(separator: ",")]
        )
        
        var replayedCount = 0
        var failedCount = 0
        var errors: [String: String] = [:]
        
        for messageId in messageIds {
            do {
                // Try to find message in DLQ first
                let dlqMessages = try await dlqManager.getMessages(limit: 1000)
                if let message = dlqMessages.first(where: { $0.id == messageId }) {
                    try await dlqManager.replayMessage(messageId)
                    replayedCount += 1
                    continue
                }
                
                // If not in DLQ, check other sources
                throw ValidationError(reason: "Message not found: \(messageId)")
                
            } catch {
                failedCount += 1
                errors[messageId] = error.localizedDescription
            }
        }
        
        let result = ReplayResult(
            auditId: auditId,
            startTime: startTime,
            endTime: Date(),
            totalMessages: messageIds.count,
            successCount: replayedCount,
            failureCount: failedCount,
            errors: errors
        )
        
        try await recordAuditComplete(auditId: auditId, result: result)
        
        return result
    }
    
    /// Replay all failed messages from DLQ
    func replayFailedMessages(filter: MessageFilter? = nil) async throws -> ReplayResult {
        logger.info("Starting DLQ replay")
        
        let auditId = UUID().uuidString
        let startTime = Date()
        
        try await recordAuditStart(
            auditId: auditId,
            type: "dlq_replay",
            parameters: ["filter": String(describing: filter)]
        )
        
        let replayedCount = try await dlqManager.replayAll(filter: filter)
        let dlqStats = try await dlqManager.getStatistics()
        
        let result = ReplayResult(
            auditId: auditId,
            startTime: startTime,
            endTime: Date(),
            totalMessages: replayedCount,
            successCount: replayedCount,
            failureCount: 0,
            errors: [:],
            metadata: [
                "dlq_remaining": String(dlqStats.totalMessages)
            ]
        )
        
        try await recordAuditComplete(auditId: auditId, result: result)
        
        return result
    }
    
    // MARK: - Audit Operations
    
    func getReplayHistory(limit: Int = 100) async throws -> [ReplayAudit] {
        let messages = try await redis.xrange(
            from: RedisKey(auditStreamKey),
            lowerBound: "-",
            upperBound: "+",
            count: limit,
            reverse: true
        )
        
        return try messages.compactMap { message in
            let fields = message.fields.compactMapValues { respValue -> String? in
                if case .bulkString(let data) = respValue {
                    return String(data: data, encoding: .utf8)
                }
                return nil
            }
            
            return try ReplayAudit.fromRedisFields(fields)
        }
    }
    
    func getReplayAudit(auditId: String) async throws -> ReplayAudit? {
        let audits = try await getReplayHistory(limit: 1000)
        return audits.first { $0.id == auditId }
    }
    
    // MARK: - Private Helper Methods
    
    private func getMessagesFromAllSources(
        from startDate: Date,
        to endDate: Date,
        filter: MessageFilter?
    ) async throws -> [PersistedMessage] {
        var allMessages: [PersistedMessage] = []
        
        // Get from DLQ
        let dlqMessages = try await dlqManager.getMessages(
            limit: filter?.limit ?? 10000,
            fromDate: startDate,
            toDate: endDate
        )
        allMessages.append(contentsOf: dlqMessages)
        
        // In a real implementation, you might also get from:
        // - Completed messages archive
        // - Failed processing logs
        // - Backup storage
        
        // Apply additional filters
        if let messageType = filter?.messageType {
            allMessages = allMessages.filter { $0.messageType == messageType }
        }
        
        if let status = filter?.status {
            allMessages = allMessages.filter { $0.status == status }
        }
        
        // Sort by creation date
        allMessages.sort { $0.createdAt < $1.createdAt }
        
        // Apply limit
        if let limit = filter?.limit {
            allMessages = Array(allMessages.prefix(limit))
        }
        
        return allMessages
    }
    
    private func recordAuditStart(
        auditId: String,
        type: String,
        parameters: [String: String]
    ) async throws {
        let audit = ReplayAudit(
            id: auditId,
            type: type,
            startTime: Date(),
            status: .running,
            parameters: parameters,
            requestedBy: "system" // In production, track actual user
        )
        
        let fields = audit.toRedisFields()
        _ = try await redis.xadd(
            to: RedisKey(auditStreamKey),
            fields: fields.mapValues { RESPValue(bulk: $0) },
            id: "*"
        )
    }
    
    private func recordAuditComplete(
        auditId: String,
        result: ReplayResult
    ) async throws {
        // Update audit record with completion
        // In a real implementation, you'd update the existing record
        let audit = ReplayAudit(
            id: auditId,
            type: "completed",
            startTime: result.startTime,
            endTime: result.endTime,
            status: result.failureCount == 0 ? .completed : .completedWithErrors,
            parameters: [:],
            requestedBy: "system",
            result: result
        )
        
        let fields = audit.toRedisFields()
        _ = try await redis.xadd(
            to: RedisKey(auditStreamKey),
            fields: fields.mapValues { RESPValue(bulk: $0) },
            id: "*"
        )
    }
}

// MARK: - Supporting Types

struct ReplayResult: Content {
    let auditId: String
    let startTime: Date
    let endTime: Date
    let totalMessages: Int
    let successCount: Int
    let failureCount: Int
    let errors: [String: String]
    let metadata: [String: String]
    
    init(
        auditId: String,
        startTime: Date,
        endTime: Date,
        totalMessages: Int,
        successCount: Int,
        failureCount: Int,
        errors: [String: String],
        metadata: [String: String] = [:]
    ) {
        self.auditId = auditId
        self.startTime = startTime
        self.endTime = endTime
        self.totalMessages = totalMessages
        self.successCount = successCount
        self.failureCount = failureCount
        self.errors = errors
        self.metadata = metadata
    }
    
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
    
    var successRate: Double {
        guard totalMessages > 0 else { return 0 }
        return Double(successCount) / Double(totalMessages) * 100
    }
}

enum ReplayStatus: String, Codable {
    case running
    case completed
    case completedWithErrors
    case failed
}

struct ReplayAudit: Codable {
    let id: String
    let type: String
    let startTime: Date
    let endTime: Date?
    let status: ReplayStatus
    let parameters: [String: String]
    let requestedBy: String
    let result: ReplayResult?
    
    func toRedisFields() -> [String: String] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        var fields: [String: String] = [
            "id": id,
            "type": type,
            "startTime": startTime.iso8601,
            "status": status.rawValue,
            "requestedBy": requestedBy
        ]
        
        if let endTime = endTime {
            fields["endTime"] = endTime.iso8601
        }
        
        if !parameters.isEmpty,
           let paramsData = try? encoder.encode(parameters),
           let paramsString = String(data: paramsData, encoding: .utf8) {
            fields["parameters"] = paramsString
        }
        
        if let result = result,
           let resultData = try? encoder.encode(result),
           let resultString = String(data: resultData, encoding: .utf8) {
            fields["result"] = resultString
        }
        
        return fields
    }
    
    static func fromRedisFields(_ fields: [String: String]) throws -> ReplayAudit {
        guard let id = fields["id"],
              let type = fields["type"],
              let startTimeString = fields["startTime"],
              let statusString = fields["status"],
              let status = ReplayStatus(rawValue: statusString),
              let requestedBy = fields["requestedBy"] else {
            throw ValidationError(reason: "Invalid audit fields")
        }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let startTime = formatter.date(from: startTimeString) else {
            throw ValidationError(reason: "Invalid start time")
        }
        
        let endTime = fields["endTime"].flatMap { formatter.date(from: $0) }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let parameters: [String: String] = fields["parameters"].flatMap { paramsString in
            guard let data = paramsString.data(using: .utf8),
                  let decoded = try? decoder.decode([String: String].self, from: data) else {
                return nil
            }
            return decoded
        } ?? [:]
        
        let result: ReplayResult? = fields["result"].flatMap { resultString in
            guard let data = resultString.data(using: .utf8),
                  let decoded = try? decoder.decode(ReplayResult.self, from: data) else {
                return nil
            }
            return decoded
        }
        
        return ReplayAudit(
            id: id,
            type: type,
            startTime: startTime,
            endTime: endTime,
            status: status,
            parameters: parameters,
            requestedBy: requestedBy,
            result: result
        )
    }
}

// MARK: - Application Extension

extension Application {
    struct ReplayServiceKey: StorageKey {
        typealias Value = MessageReplayService
    }
    
    var messageReplayService: MessageReplayService? {
        get {
            storage[ReplayServiceKey.self]
        }
        set {
            storage[ReplayServiceKey.self] = newValue
        }
    }
}