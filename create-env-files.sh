#!/bin/bash

echo "🔧 Creating environment files for Facebook Webhook Relay..."

# Create .env.example
cat > .env.example << 'EOF'
# Facebook Webhook Relay Environment Configuration
# Copy this file to .env and update with your values

# ===================
# Facebook Configuration (Required)
# ===================
# Get these from https://developers.facebook.com/apps/YOUR_APP_ID/settings/basic/
VERIFY_TOKEN=your_verify_token_here
APP_SECRET=your_app_secret_here
PAGE_ACCESS_TOKEN=your_page_access_token_here

# ===================
# NaraServer Configuration (Required)
# ===================
# Your NaraServer instance details
NARA_SERVER_URL=https://your-nara-server.com
NARA_SERVER_API_KEY=your_nara_server_api_key_here

# Optional: WebSocket URL (auto-derived from NARA_SERVER_URL if not set)
# NARA_SERVER_WS_URL=wss://your-nara-server.com/live

# ===================
# Relay Configuration (Optional)
# ===================
# Unique identifier for this relay instance
RELAY_DEVICE_ID=webhook_relay_1

# Relay mode: forward (default), process, or both
RELAY_MODE=forward

# Server port (default: 8080)
PORT=8080

# Log level: debug, info, warning, error
LOG_LEVEL=info

# ===================
# Firebase Configuration (Optional)
# ===================
# Get these from Firebase Console > Project Settings > General
# Leave empty if not using Firebase
FIREBASE_API_KEY=
FIREBASE_AUTH_DOMAIN=
FIREBASE_PROJECT_ID=
FIREBASE_STORAGE_BUCKET=
FIREBASE_MESSAGING_SENDER_ID=
FIREBASE_APP_ID=
FIREBASE_MEASUREMENT_ID=

# ===================
# Test Configuration
# ===================
# Uncomment these values for local testing without real services
# VERIFY_TOKEN=test_verify_token_12345
# APP_SECRET=test_app_secret_67890
# PAGE_ACCESS_TOKEN=test_page_access_token_abcdef
# NARA_SERVER_URL=http://localhost:8081
# NARA_SERVER_API_KEY=test_api_key_xyz123
EOF

echo "✅ Created .env.example"

# Create .env.test for testing
cat > .env.test << 'EOF'
# Facebook Webhook Relay Test Environment
# Use this for local testing without real Facebook/NaraServer

# Facebook Configuration (test values)
VERIFY_TOKEN=test_verify_token_12345
APP_SECRET=test_app_secret_67890
PAGE_ACCESS_TOKEN=test_page_access_token_abcdef

# NaraServer Configuration (test values)
NARA_SERVER_URL=http://localhost:8081
NARA_SERVER_API_KEY=test_api_key_xyz123
NARA_SERVER_WS_URL=ws://localhost:8081/live
RELAY_DEVICE_ID=test_relay_001
RELAY_MODE=forward

# Server Configuration
PORT=8080
LOG_LEVEL=debug

# Firebase Configuration (leave empty for testing)
FIREBASE_API_KEY=
FIREBASE_AUTH_DOMAIN=
FIREBASE_PROJECT_ID=
FIREBASE_STORAGE_BUCKET=
FIREBASE_MESSAGING_SENDER_ID=
FIREBASE_APP_ID=
FIREBASE_MEASUREMENT_ID=
EOF

echo "✅ Created .env.test"

# Check if .env exists
if [ ! -f .env ]; then
    echo ""
    echo "📝 Creating .env from .env.example..."
    cp .env.example .env
    echo "✅ Created .env - Please update it with your actual values!"
else
    echo ""
    echo "ℹ️  .env already exists - not overwriting"
fi

echo ""
echo "🎉 Environment files created successfully!"
echo ""
echo "Next steps:"
echo "1. Edit .env with your actual Facebook and NaraServer credentials"
echo "2. Or use .env.test for local testing: cp .env.test .env"
echo "3. Run: docker compose up app"

# Make the script remove itself after execution (optional)
# rm -- "$0" 