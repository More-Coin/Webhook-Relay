#!/usr/bin/env node

const crypto = require('crypto');

// Your webhook body (the JSON you're sending)
const body = JSON.stringify({
  "object": "page",
  "entry": [
    {
      "id": "597164376811779",
      "time": 1703123456,
      "messaging": [
        {
          "sender": {
            "id": "1234567890123456"
          },
          "recipient": {
            "id": "597164376811779"
          },
          "timestamp": 1703123456789,
          "message": {
            "mid": "m_test_message_001",
            "text": "#ข้อมูลการสั่งซื้อ\n\nชัยพัทธ์ วรเศรษฐพงษ์\n847 ถ.ริมทางรถไฟ เขตธนบุรี\nแขวงตลาดพลู กทม 10600\n(084-681-3739)\n\nน้ำมันปลา 500mg(50) *2\n#ชำระปลายทาง 384 บาท"
          }
        }
      ]
    }
  ]
});

// Replace with your actual APP_SECRET
const appSecret = process.env.APP_SECRET || 'YOUR_APP_SECRET_HERE';

if (appSecret === 'YOUR_APP_SECRET_HERE') {
  console.log('❌ Please set your APP_SECRET environment variable or edit this file');
  console.log('Usage: APP_SECRET=your_secret node calculate-signature.js');
  process.exit(1);
}

// Calculate HMAC-SHA256
const signature = crypto
  .createHmac('sha256', appSecret)
  .update(body)
  .digest('hex');

console.log('📝 Webhook Body:');
console.log(body);
console.log('\n🔐 Signature:');
console.log(`sha256=${signature}`);
console.log('\n📋 Use this in your Postman header:');
console.log(`X-Hub-Signature-256: sha256=${signature}`); 