# Facebook Webhook Relay

A high-performance webhook relay service built with Swift and Vapor that forwards Facebook Messenger webhooks to NaraServer and broadcasts server updates to connected iOS/macOS clients via Server-Sent Events (SSE).

## Architecture

This relay service acts as a bridge between:
- **Facebook Messenger** → Receives webhooks and forwards to NaraServer
- **NaraServer** → Processes messages and sends updates via WebSocket
- **iOS/macOS Apps** → Receive real-time updates via SSE

## Features

- ✅ Facebook webhook signature verification
- ✅ Automatic forwarding to NaraServer with retry logic
- ✅ WebSocket connection to NaraServer for real-time updates
- ✅ SSE broadcasting to connected clients
- ✅ Rate limiting for webhook endpoints
- ✅ Health monitoring with connection status
- ✅ Message sending proxy endpoint
- ✅ Configurable relay modes (forward/process/both)
- ✅ Firebase integration with structured logging
- ✅ Comprehensive error tracking and monitoring
- ✅ Performance metrics tracking

## Environment Variables

```bash
# Facebook Configuration (Required)
VERIFY_TOKEN=your_verify_token              # Token for Facebook webhook verification
APP_SECRET=your_app_secret                  # Facebook app secret for signature verification
PAGE_ACCESS_TOKEN=your_page_access_token    # Facebook page access token

# NaraServer Configuration (Required)
NARA_SERVER_URL=https://your-server.com     # NaraServer base URL
NARA_SERVER_API_KEY=your_api_key           # API key for NaraServer authentication

# Optional Configuration
NARA_SERVER_WS_URL=wss://your-server.com/live  # WebSocket URL (auto-derived if not set)
RELAY_DEVICE_ID=webhook_relay_1                # Unique identifier for this relay instance
RELAY_MODE=forward                             # Relay mode: forward, process, or both
PORT=8080                                      # Server port

# Firebase Configuration (Optional - for analytics)
FIREBASE_API_KEY=your_firebase_api_key         # Firebase API key
FIREBASE_AUTH_DOMAIN=your-project.firebaseapp.com  # Firebase auth domain
FIREBASE_PROJECT_ID=your-project-id           # Firebase project ID
FIREBASE_STORAGE_BUCKET=your-project.appspot.com  # Firebase storage bucket
FIREBASE_MESSAGING_SENDER_ID=123456789        # Firebase messaging sender ID
FIREBASE_APP_ID=1:123456789:web:abcdef123456   # Firebase app ID
FIREBASE_MEASUREMENT_ID=G-XXXXXXXXXX          # Firebase measurement ID (for Analytics)
```

## Relay Modes

- **forward** (default): Only forwards webhooks to NaraServer
- **process**: Only processes webhooks locally (legacy mode)
- **both**: Both forwards and processes locally (migration mode)

## API Endpoints

### Webhook Endpoints
- `GET /webhook` - Facebook webhook verification
- `POST /webhook` - Receive Facebook webhooks

### Client Endpoints
- `GET /events` - SSE endpoint for real-time updates
- `GET /health` - Health check with connection status
- `POST /api/facebook/send` - Proxy for sending messages

## Getting Started

### Development

1. Install Swift 6.0+
2. Clone the repository
3. Set environment variables in `.env` file (see [Firebase Setup Guide](Documentation/FIREBASE_SETUP.md) for Firebase configuration)
4. Run the development server:
   ```bash
   swift run
   ```

### Docker Deployment

Build and run with Docker:
```bash
# Build the image
docker build -t facebook-webhook-relay .

# Run with environment variables
docker run -p 8080:8080 \
  -e VERIFY_TOKEN=your_token \
  -e APP_SECRET=your_secret \
  -e PAGE_ACCESS_TOKEN=your_page_token \
  -e NARA_SERVER_URL=https://your-server.com \
  -e NARA_SERVER_API_KEY=your_api_key \
  facebook-webhook-relay
```

Or use Docker Compose:
```bash
docker compose up
```

## SSE Event Format

The relay broadcasts events in the following format:

```json
{
  "type": "new_message|postback|orderChange|customerChange",
  "message": {
    "id": "message_id",
    "senderId": "sender_id",
    "senderName": "John Doe",
    "text": "Message content",
    "timestamp": "2024-01-01T12:00:00Z",
    "isFromCustomer": true,
    "conversationId": "conversation_id",
    "customerName": "John Doe",
    "customerId": "customer_id"
  },
  "postbackPayload": "PAYLOAD_STRING",
  "senderId": "sender_id",
  "timestamp": "2024-01-01T12:00:00Z"
}
```

## Health Check Response

```json
{
  "status": "healthy",
  "timestamp": "2024-01-01T12:00:00Z",
  "connections": 5,
  "serverConnected": true
}
```

## Firebase Analytics Events

The relay tracks the following events (logged locally as Firebase Analytics is not available server-side):

### Core Events
- **webhook_received** - When a Facebook webhook is received
  - Parameters: source, message_count, webhook_type, page_id
- **message_forwarded** - When a message is forwarded to NaraServer
  - Parameters: destination, success, response_time_ms, message_size_bytes
- **sse_connection** - When SSE clients connect/disconnect
  - Parameters: action, connection_count, client_info, connection_duration_seconds
- **server_connection** - WebSocket connection status changes
  - Parameters: connected, server, reconnection_count, latency_ms

### Operational Events
- **relay_started** - When the relay server starts
  - Parameters: port, mode, version
- **relay_shutdown** - When the relay server shuts down
  - Parameters: reason (if available)
- **error_occurred** - When errors occur
  - Parameters: category, message, stack_trace, context
- **api_proxy_request** - When proxy endpoints are used
  - Parameters: endpoint, method, success, response_time_ms
- **rate_limit_exceeded** - When rate limits are hit
  - Parameters: client_ip, endpoint

## Security

- All Facebook webhooks are verified using HMAC-SHA256 signatures
- Rate limiting prevents abuse (100 requests per minute by default)
- WebSocket connection uses Bearer token authentication
- SSE connections support authentication headers

## Migration Guide

When migrating from local processing to forwarding:

1. Deploy with `RELAY_MODE=both` to enable parallel processing
2. Monitor both local and server processing
3. Once confident, switch to `RELAY_MODE=forward`
4. Remove local processing code in next deployment

## Troubleshooting

### WebSocket Connection Issues
- Check `NARA_SERVER_WS_URL` is correct
- Verify `NARA_SERVER_API_KEY` is valid
- Check network connectivity and firewall rules

### Webhook Forwarding Failures
- Monitor logs for retry attempts
- Check NaraServer is responding
- Verify API key permissions

### SSE Connection Drops
- Implement reconnection logic in clients
- Check for proxy timeout settings
- Monitor server memory usage

## Development

### Running Tests
```bash
swift test
```

### Code Structure
- `Sources/FacebookWebhookRelay/`
  - `entrypoint.swift` - Application entry point
  - `configure.swift` - App configuration
  - `routes.swift` - Route definitions
  - `Models.swift` - Data structures
  - `SSEManager.swift` - SSE connection management
  - `NaraServerConnection.swift` - WebSocket client
  - `FirebaseService.swift` - Firebase integration

## Documentation

All documentation is organized in the `Documentation/` folder:

- **[Firebase Setup Guide](Documentation/FIREBASE_SETUP.md)** - Complete guide for setting up Firebase integration
- **[Task List](Documentation/TaskList.md)** - Original integration task list
- **[Firebase Task List](Documentation/TaskListFirebase.md)** - Firebase-specific implementation tasks and progress

## License

[Your License Here]
