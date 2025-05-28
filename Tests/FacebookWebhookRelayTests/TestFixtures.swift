import Foundation
import Crypto
@testable import FacebookWebhookRelay

enum TestFixtures {
    // MARK: - Webhook Payloads
    
    static let validWebhookPayload = """
    {
        "object": "page",
        "entry": [
            {
                "id": "123456789",
                "time": 1234567890,
                "messaging": [
                    {
                        "sender": {
                            "id": "1234567890"
                        },
                        "recipient": {
                            "id": "0987654321"
                        },
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
    """
    
    static let webhookWithMultipleMessages = """
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
                        "message": {
                            "mid": "mid.1111111111",
                            "text": "First message"
                        }
                    },
                    {
                        "sender": {"id": "2222222222"},
                        "recipient": {"id": "0987654321"},
                        "timestamp": 1234567891000,
                        "message": {
                            "mid": "mid.2222222222",
                            "text": "Second message"
                        }
                    }
                ]
            }
        ]
    }
    """
    
    static let postbackWebhookPayload = """
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
                            "payload": "PAYLOAD_TEST",
                            "title": "Test Button"
                        }
                    }
                ]
            }
        ]
    }
    """
    
    static let malformedWebhookPayload = """
    {
        "object": "page",
        "entry": "invalid"
    }
    """
    
    static let missingRequiredFieldsPayload = """
    {
        "entry": []
    }
    """
    
    // MARK: - Signatures
    
    static func generateSignature(payload: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Data(payload.utf8))
        let signature = hmac.finalize()
        return "sha256=" + signature.map { String(format: "%02hhx", $0) }.joined()
    }
    
    // MARK: - Environment Configuration
    
    static let testEnvironment: [String: String] = [
        "VERIFY_TOKEN": "test_verify_token",
        "APP_SECRET": "test_app_secret",
        "PAGE_ACCESS_TOKEN": "test_page_access_token",
        "NARA_SERVER_URL": "http://localhost:8081",
        "NARA_SERVER_API_KEY": "test_api_key",
        "RELAY_MODE": "forward"
    ]
    
    // MARK: - Mock Responses
    
    static let mockSenderInfo = """
    {
        "first_name": "Test",
        "last_name": "User"
    }
    """
} 