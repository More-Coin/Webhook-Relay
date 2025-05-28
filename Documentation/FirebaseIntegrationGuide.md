# Firebase Integration Guide for Webhook Relay Developers

## Overview

This guide provides everything you need to know about Firebase integration in the Facebook Webhook Relay server. The relay uses Firebase for structured logging and operational monitoring.

**Important Note**: Firebase Analytics is NOT available for server-side Swift applications. The webhook relay implements a custom logging system that mimics Firebase Analytics events locally.

## Quick Start

### 1. Environment Variables Required

Add these to your `.env` file or deployment configuration:

```bash
# Firebase Configuration (Optional but recommended for monitoring)
FIREBASE_API_KEY=your_firebase_api_key
FIREBASE_AUTH_DOMAIN=your-project.firebaseapp.com
FIREBASE_PROJECT_ID=your-project-id
FIREBASE_STORAGE_BUCKET=your-project.appspot.com
FIREBASE_MESSAGING_SENDER_ID=123456789
FIREBASE_APP_ID=1:123456789:web:abcdef123456
FIREBASE_MEASUREMENT_ID=G-XXXXXXXXXX  # Optional
```

### 2. Getting Firebase Credentials

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Create a new project or select existing
3. Click the web icon (`</>`) to add a web app
4. Copy the configuration values from the setup screen

### 3. What Firebase Does in This Project

Since Firebase Analytics isn't available server-side, the relay uses Firebase Core for:
- Configuration management
- Structured local logging that mimics Analytics events
- Foundation for future Firebase services (if needed)

## Architecture & Implementation

### FirebaseService.swift

Located at `Sources/FacebookWebhookRelay/FirebaseService.swift`, this is an actor that handles all Firebase operations:

```swift
actor FirebaseService {
    // Configures Firebase on startup
    func configure(with config: FirebaseConfiguration) async
    
    // Logs events locally (Analytics not available server-side)
    func logEvent(_ name: String, parameters: [String: Any]? = nil)
    
    // Specialized logging methods for different events
    func logWebhookReceived(...)
    func logMessageForwarded(...)
    func logSSEConnection(...)
    func logServerConnection(...)
    func logError(...)
    // ... and more
}
```

### Integration Points

Firebase logging is integrated throughout the application:

1. **routes.swift** - Main integration point
   - Initializes Firebase service on startup
   - Logs all webhook events
   - Tracks SSE connections
   - Monitors errors and rate limits

2. **configure.swift** - Application configuration
   - Logs relay startup event

3. **NaraServerConnection.swift** - WebSocket monitoring
   - Could be extended to log connection events

## Events Being Tracked

### Core Events

| Event Name | When Fired | Parameters |
|------------|------------|------------|
| `webhook_received` | Facebook webhook arrives | source, message_count, webhook_type, page_id, timestamp |
| `message_forwarded` | Message sent to NaraServer | destination, success, response_time_ms, message_size_bytes, timestamp |
| `sse_connection` | SSE client connects/disconnects | action, connection_count, client_info, connection_duration_seconds, timestamp |
| `server_connection` | WebSocket status changes | connected, server, reconnection_count, latency_ms, timestamp |

### Operational Events

| Event Name | When Fired | Parameters |
|------------|------------|------------|
| `relay_started` | Server starts | port, mode, version, timestamp |
| `relay_shutdown` | Server stops | reason, timestamp |
| `error_occurred` | Any error happens | category, message, stack_trace, context, timestamp |
| `api_proxy_request` | Proxy endpoint used | endpoint, method, success, response_time_ms, timestamp |
| `rate_limit_exceeded` | Rate limit hit | client_ip, endpoint, timestamp |

### Error Categories

```swift
enum ErrorCategory: String {
    case webhookProcessing = "webhook_processing"
    case naraServerConnection = "nara_server_connection"
    case sseDelivery = "sse_delivery"
    case configuration = "configuration"
    case rateLimit = "rate_limit"
}
```

## Current Limitations

1. **No Real Analytics**: Events are logged locally only. They don't go to Firebase Analytics.
2. **No Remote Config**: Firebase Remote Config isn't available server-side.
3. **No Crashlytics**: Server-side crash reporting needs alternative solution.
4. **No Performance Monitoring**: Firebase Performance SDK not available.

## Future Enhancements

### Option 1: Custom Analytics Endpoint
Create an endpoint to forward events to Firebase Functions:

```swift
// Potential implementation
func forwardToFirebaseFunction(event: String, parameters: [String: Any]) async {
    // POST to your Firebase Function
    let url = "https://your-project.cloudfunctions.net/logEvent"
    // ... implementation
}
```

### Option 2: BigQuery Integration
Export logs directly to BigQuery for analysis:

```swift
// Use Google Cloud SDK to write events
// Requires additional setup and authentication
```

### Option 3: Alternative Analytics
Consider server-friendly alternatives:
- Mixpanel Server API
- Segment Server SDK
- Custom analytics solution

## Testing Firebase Integration

### 1. Check Initialization
Look for this log message on startup:
```
✅ Firebase service created (configuration pending)
```

### 2. Verify Event Logging
Events appear in logs with this format:
```
📊 Firebase Event: webhook_received | Parameters: [source=facebook, message_count=1, timestamp=1234567890]
```

### 3. Test Without Firebase
The relay works fine without Firebase configuration. You'll see:
```
⚠️ Firebase not configured: Missing required Firebase environment variable: FIREBASE_API_KEY
```

## Common Issues & Solutions

### Issue: "Firebase not configured" warning
**Solution**: This is OK! Firebase is optional. The relay works without it.

### Issue: No events in Firebase Console
**Expected**: Firebase Analytics doesn't work server-side. Events are logged locally only.

### Issue: Missing environment variables
**Solution**: Double-check your `.env` file has all required Firebase variables.

## Code Examples

### Logging Custom Events

```swift
// In your route handler
if let firebase = firebaseService {
    await firebase.logEvent("custom_event", parameters: [
        "user_id": userId,
        "action": "special_action",
        "value": 42
    ])
}
```

### Error Tracking

```swift
// Log errors with context
if let firebase = firebaseService {
    await firebase.logError(
        category: .webhookProcessing,
        message: "Failed to process webhook: \(error)",
        stackTrace: error.localizedDescription,
        context: ["webhook_id": webhookId, "retry_count": retryCount]
    )
}
```

### Performance Tracking

```swift
// Track operation timing
let startTime = Date()
// ... perform operation ...
let duration = Date().timeIntervalSince(startTime)

if let firebase = firebaseService {
    await firebase.logEvent("operation_completed", parameters: [
        "operation": "webhook_forward",
        "duration_ms": Int(duration * 1000),
        "success": true
    ])
}
```

## Deployment Checklist

- [ ] Firebase project created in console
- [ ] Environment variables set in deployment platform
- [ ] Verify logs show Firebase initialization
- [ ] Test event logging in development
- [ ] Consider implementing custom analytics endpoint (optional)
- [ ] Document which events are important for your use case

## Resources

- [Firebase iOS SDK Docs](https://firebase.google.com/docs/ios/setup) (Note: Limited server-side features)
- [Server-Side Analytics Alternatives](https://segment.com/docs/connections/sources/catalog/libraries/server/)
- [Project Firebase Setup Guide](FIREBASE_SETUP.md) - Detailed setup instructions
- [Testing Guide](TestingGuide.md) - Includes Firebase service tests

---

**Remember**: The current implementation provides structured logging that mimics Firebase Analytics. For production analytics, consider implementing a custom solution to forward these events to an actual analytics service. 