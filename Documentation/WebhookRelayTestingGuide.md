# Facebook Webhook Relay Testing Guide

A comprehensive step-by-step guide for testing the Facebook Webhook Relay in isolation, including Docker setup and component testing.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Environment Setup](#environment-setup)
3. [Docker Setup & Running](#docker-setup--running)
4. [Testing Components](#testing-components)
5. [Troubleshooting](#troubleshooting)

## Prerequisites

Before starting, ensure you have:
- Docker Desktop installed ([Download here](https://www.docker.com/products/docker-desktop/))
- A terminal/command line application
- A text editor for creating `.env` files
- curl or Postman for API testing
- (Optional) ngrok for testing with real Facebook webhooks

## Environment Setup

### Step 1: Create a Test Environment File

Create a `.env` file in the project root:

```bash
# Create the file
touch .env

# Open in your editor (e.g., nano, vim, or VS Code)
nano .env
```

### Step 2: Add Test Environment Variables

Add these variables to your `.env` file:

```bash
# Facebook Configuration (use test values for isolated testing)
VERIFY_TOKEN=test_verify_token_12345
APP_SECRET=test_app_secret_67890
PAGE_ACCESS_TOKEN=test_page_access_token_abcdef

# NaraServer Configuration (use mock values)
NARA_SERVER_URL=http://mock-nara-server:8081
NARA_SERVER_API_KEY=test_api_key_xyz123
NARA_SERVER_WS_URL=ws://mock-nara-server:8081/live
RELAY_DEVICE_ID=test_relay_001
RELAY_MODE=forward

# Optional: Firebase Configuration (leave empty for basic testing)
FIREBASE_API_KEY=
FIREBASE_AUTH_DOMAIN=
FIREBASE_PROJECT_ID=
FIREBASE_STORAGE_BUCKET=
FIREBASE_MESSAGING_SENDER_ID=
FIREBASE_APP_ID=
FIREBASE_MEASUREMENT_ID=

# Server Configuration
PORT=8080
LOG_LEVEL=debug
```

## Docker Setup & Running

### Step 3: Build the Docker Image

```bash
# Navigate to project directory
cd /path/to/FacebookWebhookRelay

# Build the Docker image
docker compose build

# OR build with specific tag
docker build -t facebook-webhook-relay:test .
```

Expected output:
```
[+] Building 45.2s (15/15) FINISHED
 => [internal] load build definition from Dockerfile
 => => transferring dockerfile: 2.5KB
 => [build 1/8] FROM swift:6.0-noble
 => [build 8/8] RUN swift build -c release
 => exporting to image
 => => naming to docker.io/library/facebookwebhookrelay:latest
```

### Step 4: Run the Container

```bash
# Using docker-compose (recommended)
docker compose up app

# OR run directly with Docker
docker run --rm -p 8080:8080 \
  --env-file .env \
  --name webhook-relay-test \
  facebook-webhook-relay:test
```

Expected output:
```
webhook-relay-test | [ NOTICE ] Server starting on http://0.0.0.0:8080
webhook-relay-test | ✅ Firebase service created (configuration pending)
webhook-relay-test | Connecting to NaraServer WebSocket at ws://mock-nara-server:8081/live
```

### Step 5: Verify the Server is Running

In a new terminal:

```bash
# Check health endpoint
curl http://localhost:8080/health

# Expected response:
# {
#   "status": "healthy",
#   "timestamp": "2024-01-20T10:30:00Z",
#   "connections": 0,
#   "serverConnected": false
# }
```

## Testing Components

### Test 1: Facebook Webhook Verification (GET)

This tests the initial Facebook webhook setup handshake:

```bash
# Test valid verification
curl -X GET "http://localhost:8080/webhook?hub.mode=subscribe&hub.verify_token=test_verify_token_12345&hub.challenge=challenge_abc123"

# Expected: challenge_abc123

# Test invalid token
curl -X GET "http://localhost:8080/webhook?hub.mode=subscribe&hub.verify_token=wrong_token&hub.challenge=challenge_abc123"

# Expected: 403 Forbidden error
```

### Test 2: Facebook Webhook Reception (POST)

First, create a test webhook payload file:

```bash
# Create test-webhook.json
cat > test-webhook.json << 'EOF'
{
  "object": "page",
  "entry": [
    {
      "id": "123456789",
      "time": 1234567890,
      "messaging": [
        {
          "sender": {"id": "1234567890"},
          "recipient": {"id": "0987654321"},
          "timestamp": 1234567890000,
          "message": {
            "mid": "mid.1234567890",
            "text": "Hello, this is a test message"
          }
        }
      ]
    }
  ]
}
EOF
```

Generate a valid signature and send the webhook:

```bash
# Generate signature (on macOS/Linux)
PAYLOAD=$(cat test-webhook.json)
SECRET="test_app_secret_67890"
SIGNATURE="sha256=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)"

# Send webhook with signature
curl -X POST http://localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $SIGNATURE" \
  -d @test-webhook.json

# Expected: 200 OK (empty response)
```

### Test 3: SSE Connection and Broadcasting

Open SSE connection in one terminal:

```bash
# Connect to SSE endpoint
curl -N http://localhost:8080/events

# Expected initial output:
# data: {"type": "connected", "timestamp": "2024-01-20T10:35:00Z"}
# 
# (keeps connection open waiting for events)
```

In another terminal, send a webhook to trigger broadcasting:

```bash
# Use the same signature generation as Test 2
curl -X POST http://localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $SIGNATURE" \
  -d @test-webhook.json
```

The SSE terminal should show:
```
data: {"type":"new_message","message":{"id":"mid.1234567890","senderId":"1234567890",...},"timestamp":"..."}
```

### Test 4: Rate Limiting

Test the rate limiter by sending multiple requests:

```bash
# Create a script to send 100+ requests
for i in {1..105}; do
  echo "Request $i"
  curl -X POST http://localhost:8080/webhook \
    -H "Content-Type: application/json" \
    -H "X-Hub-Signature-256: $SIGNATURE" \
    -d @test-webhook.json \
    -w "%{http_code}\n" \
    -o /dev/null \
    -s
done

# Expected: First 100 return 200, then 429 (Too Many Requests)
```

### Test 5: Testing with Invalid Signatures

```bash
# Test with invalid signature
curl -X POST http://localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=invalid_signature_here" \
  -d @test-webhook.json

# Expected: 401 Unauthorized

# Test without signature
curl -X POST http://localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -d @test-webhook.json

# Expected: 401 Unauthorized
```

### Test 6: Postback Testing

Create a postback test file:

```bash
cat > test-postback.json << 'EOF'
{
  "object": "page",
  "entry": [
    {
      "id": "123456789",
      "time": 1234567890,
      "messaging": [
        {
          "sender": {"id": "1234567890"},
          "recipient": {"id": "0987654321"},
          "timestamp": 1234567890000,
          "postback": {
            "payload": "USER_CLICKED_BUTTON",
            "title": "Get Started"
          }
        }
      ]
    }
  ]
}
EOF
```

Send the postback:

```bash
# Generate signature for postback
POSTBACK_PAYLOAD=$(cat test-postback.json)
POSTBACK_SIGNATURE="sha256=$(echo -n "$POSTBACK_PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)"

# Send postback
curl -X POST http://localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $POSTBACK_SIGNATURE" \
  -d @test-postback.json
```

### Test 7: Performance Testing

Test with multiple messages in one webhook:

```bash
cat > test-bulk.json << 'EOF'
{
  "object": "page",
  "entry": [
    {
      "id": "123456789",
      "time": 1234567890,
      "messaging": [
        {
          "sender": {"id": "1111111111"},
          "recipient": {"id": "0987654321"},
          "timestamp": 1234567890000,
          "message": {"mid": "mid.1111", "text": "Message 1"}
        },
        {
          "sender": {"id": "2222222222"},
          "recipient": {"id": "0987654321"},
          "timestamp": 1234567891000,
          "message": {"mid": "mid.2222", "text": "Message 2"}
        },
        {
          "sender": {"id": "3333333333"},
          "recipient": {"id": "0987654321"},
          "timestamp": 1234567892000,
          "message": {"mid": "mid.3333", "text": "Message 3"}
        }
      ]
    }
  ]
}
EOF

# Send bulk webhook
BULK_PAYLOAD=$(cat test-bulk.json)
BULK_SIGNATURE="sha256=$(echo -n "$BULK_PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)"

curl -X POST http://localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $BULK_SIGNATURE" \
  -d @test-bulk.json
```

## Advanced Testing

### Test 8: Load Testing with Multiple SSE Clients

```bash
# Open 10 SSE connections in background
for i in {1..10}; do
  curl -N http://localhost:8080/events > sse-client-$i.log 2>&1 &
done

# Check health to see connection count
curl http://localhost:8080/health

# Send a webhook to broadcast to all
curl -X POST http://localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $SIGNATURE" \
  -d @test-webhook.json

# Kill all background curl processes
killall curl

# Check logs
cat sse-client-*.log
```

### Test 9: Testing with Real Facebook Webhooks (using ngrok)

```bash
# Install ngrok if not already installed
# brew install ngrok (macOS) or download from https://ngrok.com

# Start ngrok tunnel
ngrok http 8080

# Copy the HTTPS URL (e.g., https://abc123.ngrok.io)
# Use this URL in Facebook App webhook configuration
# Set verify token to: test_verify_token_12345
```

### Test 10: Docker Container Logs and Debugging

```bash
# View real-time logs
docker compose logs -f app

# View last 100 lines
docker compose logs --tail=100 app

# Check container resource usage
docker stats webhook-relay-test

# Execute commands inside container
docker exec -it webhook-relay-test /bin/bash

# Inside container, check environment
env | grep -E "VERIFY_TOKEN|NARA_SERVER|RELAY_MODE"
```

## Automated Testing Script

Create a comprehensive test script:

```bash
cat > run-all-tests.sh << 'EOF'
#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "🧪 Starting Facebook Webhook Relay Tests..."

# Test 1: Health Check
echo -e "\n${GREEN}Test 1: Health Check${NC}"
curl -s http://localhost:8080/health | jq .

# Test 2: Webhook Verification
echo -e "\n${GREEN}Test 2: Webhook Verification${NC}"
RESPONSE=$(curl -s -w "%{http_code}" -o /dev/null "http://localhost:8080/webhook?hub.mode=subscribe&hub.verify_token=test_verify_token_12345&hub.challenge=test123")
if [ "$RESPONSE" = "200" ]; then
    echo "✅ Verification passed"
else
    echo "❌ Verification failed: HTTP $RESPONSE"
fi

# Test 3: Valid Webhook
echo -e "\n${GREEN}Test 3: Valid Webhook${NC}"
PAYLOAD='{"object":"page","entry":[{"id":"123","time":1234567890,"messaging":[{"sender":{"id":"123"},"recipient":{"id":"456"},"timestamp":1234567890000,"message":{"mid":"mid.123","text":"Test"}}]}]}'
SECRET="test_app_secret_67890"
SIGNATURE="sha256=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)"

RESPONSE=$(curl -s -w "%{http_code}" -o /dev/null -X POST http://localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $SIGNATURE" \
  -d "$PAYLOAD")

if [ "$RESPONSE" = "200" ]; then
    echo "✅ Webhook processing passed"
else
    echo "❌ Webhook processing failed: HTTP $RESPONSE"
fi

echo -e "\n✅ All tests completed!"
EOF

chmod +x run-all-tests.sh
./run-all-tests.sh
```

## Troubleshooting

### Common Issues and Solutions

1. **Container won't start**
   ```bash
   # Check Docker daemon is running
   docker info
   
   # Check for port conflicts
   lsof -i :8080
   ```

2. **Signature verification failures**
   ```bash
   # Verify your APP_SECRET matches
   docker exec webhook-relay-test env | grep APP_SECRET
   
   # Test signature generation manually
   echo -n '{"test":"data"}' | openssl dgst -sha256 -hmac "test_app_secret_67890"
   ```

3. **SSE connections dropping**
   ```bash
   # Check container logs for errors
   docker logs webhook-relay-test | grep -i error
   
   # Increase client timeout
   curl -N --max-time 3600 http://localhost:8080/events
   ```

4. **Rate limiting issues**
   ```bash
   # Wait 60 seconds for rate limit window to reset
   sleep 60
   
   # Or restart container to reset limits
   docker compose restart app
   ```

## Cleanup

After testing:

```bash
# Stop and remove containers
docker compose down

# Remove test files
rm test-webhook.json test-postback.json test-bulk.json sse-client-*.log

# Remove Docker images (optional)
docker rmi facebook-webhook-relay:test
docker rmi facebookwebhookrelay:latest

# Clean up unused Docker resources
docker system prune -a
```

## Next Steps

1. **Integration Testing**: Connect to a real NaraServer instance
2. **Performance Testing**: Use Apache Bench or JMeter for load testing
3. **Security Testing**: Test with various malformed payloads
4. **Monitoring**: Set up Prometheus/Grafana for metrics

---

**Quick Reference Card**

| Component | Test Command | Expected Result |
|-----------|--------------|-----------------|
| Health | `curl http://localhost:8080/health` | 200 OK with JSON |
| Verify | `curl "http://localhost:8080/webhook?hub.mode=subscribe&hub.verify_token=test_verify_token_12345&hub.challenge=abc"` | Returns "abc" |
| Webhook | `curl -X POST -H "X-Hub-Signature-256: $SIG" -d @webhook.json http://localhost:8080/webhook` | 200 OK |
| SSE | `curl -N http://localhost:8080/events` | Keeps connection open |
| Logs | `docker compose logs -f app` | Real-time logs |

---

Happy Testing! 🚀 