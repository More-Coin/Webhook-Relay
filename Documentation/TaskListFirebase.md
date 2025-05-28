# Firebase Integration Task List for Swift/Vapor Webhook Relay

## Overview
This task list outlines the Firebase integration tasks for the Swift/Vapor webhook relay server. The relay acts as a bridge between Facebook Messenger, NaraServer, and iOS/macOS apps.

## Current Architecture
- **Language**: Swift 6.0 with Vapor framework
- **Purpose**: Relay Facebook webhooks to NaraServer and broadcast updates via SSE
- **Firebase SDK**: Using Firebase iOS SDK (limited server-side capabilities)

## Phase 1: Complete Firebase Analytics Implementation ✅ (Partially Done)

### 1.1 Fix Firebase Analytics Import ⚠️ (Modified Approach)
- [x] Update `Package.swift` to properly include FirebaseAnalytics product
  - **Note**: Firebase Analytics is not available for server-side Swift
  - Using FirebaseCore only for configuration
- [x] Fix the Analytics import in `FirebaseService.swift`
  - Removed Analytics import as it's not available server-side
- [x] Update the `logEvent` method to actually send events to Firebase
  - Implemented structured local logging instead
  - Added TODO for custom analytics endpoint
- [ ] Test analytics events are appearing in logs (Firebase Console not applicable)

### 1.2 Enhance Current Analytics Events ✅
- [x] Add more detailed parameters to existing events:
  - `webhook_received`: Add webhook type, page_id
  - `message_forwarded`: Add response time, message size
  - `sse_connection`: Add client info, connection duration
  - `server_connection`: Add reconnection count, latency

### 1.3 Add New Analytics Events ✅
- [x] `relay_started` - When the relay server starts
- [x] `relay_shutdown` - Clean shutdown events
- [x] `error_occurred` - Track errors with categories
- [x] `api_proxy_request` - Track proxy endpoint usage
- [x] `rate_limit_exceeded` - Track rate limiting events

## Phase 2: Enhanced Error Tracking and Monitoring

### 2.1 Structured Error Logging ✅
- [x] Create error categories enum:
  ```swift
  enum ErrorCategory: String {
      case webhookProcessing = "webhook_processing"
      case naraServerConnection = "nara_server_connection"
      case sseDelivery = "sse_delivery"
      case configuration = "configuration"
      case rateLimit = "rate_limit"
  }
  ```
- [x] Log errors with Firebase Analytics including:
  - Error category
  - Error message
  - Stack trace (if available)
  - Request context

### 2.2 Performance Monitoring
- [ ] Track and log performance metrics:
  - Webhook processing time
  - NaraServer forwarding latency
  - SSE broadcast time
  - Memory usage snapshots
- [ ] Create performance thresholds and alert when exceeded

## Phase 3: Configuration Management

### 3.1 Environment-Based Configuration
- [ ] Create a `ConfigurationManager` to centralize all config:
  ```swift
  actor ConfigurationManager {
      // Rate limiting config
      var maxRequestsPerMinute: Int
      var sseHeartbeatInterval: TimeInterval
      var webhookTimeout: TimeInterval
      var maxRetryAttempts: Int
      // etc.
  }
  ```
- [ ] Load configuration from environment variables with defaults
- [ ] Add configuration validation on startup

### 3.2 Dynamic Configuration Updates (Future)
- [ ] Research Firebase Remote Config availability for server-side Swift
- [ ] If not available, implement alternative solution:
  - Periodic config fetch from NaraServer
  - Config update via admin endpoint
  - Config stored in a simple JSON file

## Phase 4: Security Enhancements

### 4.1 Request Validation
- [ ] Add request origin validation for SSE connections
- [ ] Implement API key validation for proxy endpoints
- [ ] Add request signing for NaraServer communication
- [ ] Log all security-related events to Firebase

### 4.2 Rate Limiting Improvements
- [ ] Make rate limiting configurable per endpoint
- [ ] Add different rate limit tiers (IP-based, authenticated)
- [ ] Track rate limit violations in Firebase Analytics
- [ ] Implement exponential backoff for repeat offenders

## Phase 5: Reliability Improvements

### 5.1 Connection Management
- [ ] Implement connection pool for NaraServer requests
- [ ] Add circuit breaker pattern for NaraServer failures
- [ ] Improve WebSocket reconnection logic with jitter
- [ ] Track all connection state changes in Firebase

### 5.2 Message Queue (In-Memory)
- [ ] Implement in-memory queue for failed webhook forwards
- [ ] Add retry mechanism with exponential backoff
- [ ] Set maximum queue size and overflow handling
- [ ] Log queue statistics to Firebase

## Phase 6: Monitoring Dashboard Integration

### 6.1 Health Check Enhancements
- [ ] Add Firebase connection status to health check
- [ ] Include more detailed metrics:
  - Uptime
  - Total webhooks processed
  - Current queue size
  - Error rate (last 5 minutes)
  - Average response time

### 6.2 Metrics Endpoint
- [ ] Create `/metrics` endpoint with Prometheus-compatible format
- [ ] Include custom metrics:
  - `webhook_relay_connections_active`
  - `webhook_relay_messages_forwarded_total`
  - `webhook_relay_errors_total`
  - `webhook_relay_response_time_seconds`

## Phase 7: Testing and Validation

### 7.1 Unit Tests
- [ ] Test Firebase initialization
- [ ] Test analytics event logging
- [ ] Test error tracking
- [ ] Test configuration loading

### 7.2 Integration Tests
- [ ] Test full webhook flow with Firebase logging
- [ ] Test SSE delivery with analytics
- [ ] Test error scenarios and recovery
- [ ] Verify all events appear in Firebase Console

### 7.3 Load Testing
- [ ] Test with high webhook volume
- [ ] Monitor Firebase quota usage
- [ ] Verify no event loss under load
- [ ] Check memory usage patterns

## Phase 8: Documentation and Deployment

### 8.1 Documentation Updates
- [ ] Update README with Firebase features
- [ ] Document all analytics events
- [ ] Create troubleshooting guide
- [ ] Add Firebase Console setup instructions

### 8.2 Deployment Configuration
- [ ] Update Docker image with Firebase requirements
- [ ] Add Firebase environment variables to deployment scripts
- [ ] Create monitoring alerts based on Firebase data
- [ ] Set up Firebase budget alerts

## Phase 9: Post-Launch Optimization

### 9.1 Analytics Review
- [ ] Review Firebase Analytics data after 1 week
- [ ] Identify performance bottlenecks
- [ ] Optimize based on real usage patterns
- [ ] Adjust rate limits based on data

### 9.2 Cost Optimization
- [ ] Monitor Firebase usage and costs
- [ ] Implement event sampling if needed
- [ ] Optimize event parameter sizes
- [ ] Review and adjust retention policies

## Implementation Priority

### Must Have (Week 1)
1. Complete Firebase Analytics implementation
2. Add comprehensive error tracking
3. Enhance health check endpoint
4. Basic performance monitoring

### Should Have (Week 2)
1. Security enhancements
2. Reliability improvements
3. Configuration management
4. Testing suite

### Nice to Have (Week 3+)
1. Metrics endpoint
2. Advanced monitoring
3. Load testing
4. Cost optimization

## Success Metrics

### Technical Metrics
- All events successfully logged to Firebase
- Error rate < 0.1%
- Average response time < 100ms
- Zero data loss during normal operation

### Operational Metrics
- Clear visibility into system health
- Reduced debugging time with better logs
- Proactive issue detection
- Improved reliability metrics

## Notes

- Focus on what's achievable with Firebase iOS SDK on server
- Prioritize operational visibility and reliability
- Keep the implementation simple and maintainable
- Consider Firebase alternatives for features not available in Swift

## Dependencies

### Technical Requirements
- Swift 6.0+
- Vapor 4.x
- Firebase iOS SDK (latest)
- Docker for deployment

### External Services
- Firebase project with Analytics enabled
- Access to Firebase Console
- NaraServer API credentials
- Facebook App credentials

---

## Implementation Progress Summary

### ✅ Completed (Phase 1 & 2.1)
1. **Firebase Core Integration**
   - Configured Firebase SDK for server-side Swift
   - Implemented structured logging system
   - Note: Firebase Analytics not available server-side, using local logging

2. **Enhanced Analytics Events**
   - Added detailed parameters to all events
   - Implemented new operational events
   - Added error tracking with categories

3. **Error Tracking**
   - Created error category enum
   - Integrated error logging throughout the application
   - Added context to error events

### 🚧 Next Steps
- Phase 2.2: Performance Monitoring
- Phase 3: Configuration Management
- Phase 4: Security Enhancements

### 📝 Important Notes
- Firebase Analytics is not available for server-side Swift
- All events are logged locally with structured format
- Consider implementing custom analytics endpoint for production

---

**Document Version**: 1.1  
**Last Updated**: [Current Date]  
**Status**: In Progress - Phase 1 & 2.1 Complete 