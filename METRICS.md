# Webhook Relay Metrics Documentation

This document describes the metrics exposed by the Facebook Webhook Relay service at the `/metrics` endpoint.

## Metrics Endpoint

- **URL**: `GET /metrics`
- **Format**: Prometheus text format (version 0.0.4)
- **Content-Type**: `text/plain; version=0.0.4`

## Available Metrics

### Message Processing Metrics

#### `webhook_messages_received_total`
- **Type**: Counter
- **Description**: Total number of messages received from Facebook
- **Labels**: 
  - `source`: Always "facebook"
- **Usage**: Track incoming webhook volume

#### `webhook_messages_forwarded_total`
- **Type**: Counter
- **Description**: Total number of messages successfully forwarded to NaraServer
- **Labels**:
  - `destination`: Always "naraserver"
- **Usage**: Track successful message delivery

#### `webhook_messages_failed_total`
- **Type**: Counter
- **Description**: Total number of messages that failed to forward
- **Labels**:
  - `reason`: Error reason (e.g., "network_error", "timeout", "server_error")
- **Usage**: Monitor forwarding failures

#### `webhook_forwarding_duration_seconds`
- **Type**: Histogram
- **Description**: Time taken to forward messages to NaraServer (in seconds)
- **Usage**: Monitor forwarding performance and latency

### Queue Metrics

#### `webhook_queue_depth`
- **Type**: Gauge
- **Description**: Current number of messages in the queue
- **Usage**: Monitor queue backlog

#### `webhook_messages_enqueued_total`
- **Type**: Counter
- **Description**: Total messages added to the queue
- **Usage**: Track queue input rate

#### `webhook_messages_dequeued_total`
- **Type**: Counter
- **Description**: Total messages removed from the queue for processing
- **Usage**: Track queue processing rate

### Connection Metrics

#### `webhook_sse_connections_active`
- **Type**: Gauge
- **Description**: Number of active Server-Sent Events connections
- **Usage**: Monitor client connections

#### `webhook_websocket_connected`
- **Type**: Gauge
- **Description**: WebSocket connection status to NaraServer
- **Values**: 1 (connected) or 0 (disconnected)
- **Usage**: Monitor server connectivity

### Error Metrics

#### `webhook_rate_limit_errors_total`
- **Type**: Counter
- **Description**: Total number of requests rejected due to rate limiting
- **Usage**: Monitor rate limit violations

#### `webhook_authentication_errors_total`
- **Type**: Counter
- **Description**: Total number of authentication failures
- **Usage**: Monitor security issues

#### `webhook_network_errors_total`
- **Type**: Counter
- **Description**: Total number of network-related errors
- **Usage**: Monitor connectivity issues

### Health Metrics

#### `webhook_health_status`
- **Type**: Gauge
- **Description**: Overall health status of the relay
- **Values**: 1 (healthy) or 0 (unhealthy)
- **Usage**: Basic health monitoring

## Alerting Thresholds

Based on typical usage patterns, consider setting alerts for:

1. **High Error Rate**
   ```
   rate(webhook_messages_failed_total[5m]) > 0.05
   ```
   Alert when more than 5% of messages fail over 5 minutes

2. **Queue Backup**
   ```
   webhook_queue_depth > 1000
   ```
   Alert when queue depth exceeds 1000 messages

3. **WebSocket Disconnection**
   ```
   webhook_websocket_connected == 0
   ```
   Alert when connection to NaraServer is lost

4. **High Latency**
   ```
   histogram_quantile(0.95, webhook_forwarding_duration_seconds) > 2
   ```
   Alert when 95th percentile latency exceeds 2 seconds

5. **Rate Limiting**
   ```
   rate(webhook_rate_limit_errors_total[5m]) > 10
   ```
   Alert when rate limiting is triggered frequently

## Grafana Dashboard Example

```json
{
  "dashboard": {
    "title": "Webhook Relay Monitoring",
    "panels": [
      {
        "title": "Message Rate",
        "targets": [
          {
            "expr": "rate(webhook_messages_received_total[5m])",
            "legendFormat": "Received"
          },
          {
            "expr": "rate(webhook_messages_forwarded_total[5m])",
            "legendFormat": "Forwarded"
          }
        ]
      },
      {
        "title": "Error Rate",
        "targets": [
          {
            "expr": "rate(webhook_messages_failed_total[5m]) / rate(webhook_messages_received_total[5m])",
            "legendFormat": "Error %"
          }
        ]
      },
      {
        "title": "Queue Depth",
        "targets": [
          {
            "expr": "webhook_queue_depth",
            "legendFormat": "Queue Size"
          }
        ]
      },
      {
        "title": "Forwarding Latency",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, webhook_forwarding_duration_seconds)",
            "legendFormat": "95th percentile"
          },
          {
            "expr": "histogram_quantile(0.50, webhook_forwarding_duration_seconds)",
            "legendFormat": "Median"
          }
        ]
      }
    ]
  }
}
```

## Usage Example

```bash
# Fetch current metrics
curl http://localhost:8080/metrics

# Example output:
# HELP webhook_messages_received_total Total number of messages received from Facebook
# TYPE webhook_messages_received_total counter
webhook_messages_received_total{source="facebook"} 12543 1704067200000

# HELP webhook_messages_forwarded_total Total number of messages successfully forwarded
# TYPE webhook_messages_forwarded_total counter
webhook_messages_forwarded_total{destination="naraserver"} 12501 1704067200000

# HELP webhook_queue_depth Current message queue depth
# TYPE webhook_queue_depth gauge
webhook_queue_depth 42 1704067200000
```