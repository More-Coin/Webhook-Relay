// Postman Pre-request Script for Facebook Webhook Signature Calculation
// This script automatically calculates the X-Hub-Signature-256 header

// Get the APP_SECRET from Postman environment variable
const appSecret = pm.environment.get("APP_SECRET") || pm.globals.get("APP_SECRET");

if (!appSecret) {
    console.log("❌ APP_SECRET not found in environment or global variables");
    console.log("Please set APP_SECRET in your Postman environment");
    throw new Error("APP_SECRET is required");
}

// Get the request body as string
const requestBody = pm.request.body.raw;

if (!requestBody) {
    console.log("❌ No request body found");
    throw new Error("Request body is required for signature calculation");
}

// Calculate HMAC-SHA256 signature
const signature = CryptoJS.HmacSHA256(requestBody, appSecret).toString();

// Set the signature header
pm.request.headers.add({
    key: 'X-Hub-Signature-256',
    value: `sha256=${signature}`
});

// Log for debugging
console.log("🔐 Signature calculated and set:");
console.log(`X-Hub-Signature-256: sha256=${signature}`);
console.log("📝 Request body length:", requestBody.length);

// Optional: Log the first 100 characters of the body for verification
console.log("📄 Body preview:", requestBody.substring(0, 100) + "..."); 