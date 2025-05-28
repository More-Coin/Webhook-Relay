# Firebase Setup Guide for Facebook Webhook Relay

This guide will help you set up Firebase for your webhook relay. 

**Important Note**: Firebase Analytics is not available for server-side Swift applications. The webhook relay uses Firebase Core for configuration and implements structured local logging that mimics Firebase Analytics events. For production use, consider implementing a custom analytics endpoint to forward these events to Firebase Functions or another analytics service.

## Prerequisites

1. A Google account
2. Access to the [Firebase Console](https://console.firebase.google.com/)

## Step 1: Create a Firebase Project

1. Go to the [Firebase Console](https://console.firebase.google.com/)
2. Click "Create a project" or "Add project"
3. Enter your project name (e.g., "facebook-webhook-relay")
4. **Enable Google Analytics** when prompted (recommended for tracking)
5. Choose or create a Google Analytics account
6. Click "Create project"

## Step 2: Add a Web App to Your Project

1. In your Firebase project dashboard, click the web icon (`</>`) to add a web app
2. Enter an app nickname (e.g., "webhook-relay-server")
3. **Check "Also set up Firebase Hosting"** if you plan to use Firebase Hosting (optional)
4. Click "Register app"

## Step 3: Get Your Firebase Configuration

After registering your app, you'll see a configuration object like this:

```javascript
const firebaseConfig = {
  apiKey: "AIzaSyC...",
  authDomain: "your-project.firebaseapp.com",
  projectId: "your-project-id",
  storageBucket: "your-project.appspot.com",
  messagingSenderId: "123456789",
  appId: "1:123456789:web:abcdef123456",
  measurementId: "G-XXXXXXXXXX"
};
```

## Step 4: Set Environment Variables

Add these environment variables to your deployment:

```bash
# Firebase Configuration
FIREBASE_API_KEY=AIzaSyC...
FIREBASE_AUTH_DOMAIN=your-project.firebaseapp.com
FIREBASE_PROJECT_ID=your-project-id
FIREBASE_STORAGE_BUCKET=your-project.appspot.com
FIREBASE_MESSAGING_SENDER_ID=123456789
FIREBASE_APP_ID=1:123456789:web:abcdef123456
FIREBASE_MEASUREMENT_ID=G-XXXXXXXXXX
```

### For Local Development

Create a `.env` file in your project root:

```bash
# Copy your existing environment variables
VERIFY_TOKEN=your_verify_token
APP_SECRET=your_app_secret
PAGE_ACCESS_TOKEN=your_page_access_token
NARA_SERVER_URL=https://your-server.com
NARA_SERVER_API_KEY=your_api_key

# Add Firebase configuration
FIREBASE_API_KEY=AIzaSyC...
FIREBASE_AUTH_DOMAIN=your-project.firebaseapp.com
FIREBASE_PROJECT_ID=your-project-id
FIREBASE_STORAGE_BUCKET=your-project.appspot.com
FIREBASE_MESSAGING_SENDER_ID=123456789
FIREBASE_APP_ID=1:123456789:web:abcdef123456
FIREBASE_MEASUREMENT_ID=G-XXXXXXXXXX
```

### For Docker Deployment

Update your `docker-compose.yml` or Docker run command with the Firebase environment variables.

### For Production Deployment

Set these environment variables in your hosting platform:
- **Heroku**: Use `heroku config:set FIREBASE_API_KEY=...`
- **Railway**: Add in the Variables section
- **DigitalOcean App Platform**: Add in the Environment Variables section
- **AWS/GCP**: Set in your container/function environment

## Step 5: Verify Setup

1. Deploy your webhook relay with the Firebase environment variables
2. Send a test webhook to your relay
3. Check the Firebase Console:
   - Go to **Analytics > Events** to see real-time events
   - Look for custom events like `webhook_received`, `message_forwarded`, etc.

## Analytics Events Tracked

The webhook relay automatically tracks these events:

### `webhook_received`
- **When**: A Facebook webhook is received
- **Parameters**:
  - `source`: "facebook"
  - `message_count`: Number of messages in the webhook
  - `timestamp`: Unix timestamp

### `message_forwarded`
- **When**: A message is forwarded to NaraServer
- **Parameters**:
  - `destination`: "nara_server"
  - `success`: true/false
  - `timestamp`: Unix timestamp

### `sse_connection`
- **When**: SSE client connects or disconnects
- **Parameters**:
  - `action`: "connected" or "disconnected"
  - `connection_count`: Current number of active connections
  - `timestamp`: Unix timestamp

### `server_connection`
- **When**: WebSocket connection to NaraServer changes
- **Parameters**:
  - `connected`: true/false
  - `server`: Server identifier
  - `timestamp`: Unix timestamp

## Viewing Analytics Data

### Real-time Events
1. Go to Firebase Console > Analytics > Events
2. Select "View real-time events"
3. You'll see events as they happen

### Historical Data
1. Go to Firebase Console > Analytics > Events
2. Select time ranges to view historical data
3. Create custom reports and dashboards

### Custom Dashboards
1. Go to Firebase Console > Analytics > Custom Definitions
2. Create custom parameters and audiences
3. Use Google Analytics 4 for advanced reporting

## Troubleshooting

### No Events Appearing
1. **Check environment variables**: Ensure all Firebase config vars are set correctly
2. **Check logs**: Look for Firebase initialization messages in your app logs
3. **Verify project ID**: Make sure `FIREBASE_PROJECT_ID` matches your Firebase project
4. **Check Analytics**: Ensure Google Analytics is enabled in your Firebase project

### Configuration Errors
1. **Invalid API key**: Double-check `FIREBASE_API_KEY`
2. **Project not found**: Verify `FIREBASE_PROJECT_ID`
3. **Permission errors**: Ensure your Firebase project has Analytics enabled

### Events Not Showing in Analytics
1. **Wait time**: Analytics data can take up to 24 hours to appear in reports
2. **Real-time view**: Use the real-time events view for immediate feedback
3. **Debug mode**: Enable debug mode in Firebase for testing

## Security Considerations

1. **Environment Variables**: Never commit Firebase config to version control
2. **API Key**: The Firebase API key is safe to expose in client-side code, but keep it in environment variables for consistency
3. **Project Access**: Limit Firebase project access to necessary team members
4. **Analytics Data**: Be mindful of what data you're tracking for privacy compliance

## Optional: Advanced Setup

### Custom Events
You can add more custom events by modifying `FirebaseService.swift`:

```swift
func logCustomEvent(_ name: String, parameters: [String: Any]? = nil) {
    logEvent(name, parameters: parameters)
}
```

### User Properties
Set user properties to segment your analytics:

```swift
// In FirebaseService.swift
func setUserProperty(_ value: String, forName name: String) {
    // Analytics.setUserProperty(value, forName: name)
}
```

### Conversion Events
Mark important events as conversions in the Firebase Console for better tracking.

## Support

- [Firebase Documentation](https://firebase.google.com/docs)
- [Firebase Analytics Guide](https://firebase.google.com/docs/analytics)
- [Google Analytics 4 Help](https://support.google.com/analytics/answer/9304153) 