# Idle Shutdown & Wake — Architecture & Design

This document explains the clever wake-on-text design: when your OpenClaw instance sleeps, you just send a message to wake it up. No links, no tokens, completely transparent.

## Problem Statement

Running an EC2 agent 24/7 in a sandbox account is powerful but expensive. We want:

- **Automatic cost savings** — shutdown after user inactivity
- **Zero manual waking** — just send a message, instance wakes up
- **Transparent** — no clicking links, no entering tokens
- **Reliable** — messages don't get lost while instance is sleeping
- **Safe** — only authorized users can wake the instance

## Architecture Overview

```
┌─ EC2 Instance (running) ──────────────────────────────────┐
│                                                            │
│  OpenClaw (normal operation)                              │
│  ├─ systemd timer every 5 min                            │
│  ├─ idle-check.py scans session activity                 │
│  ├─ if idle > 1 hour: emit stop signal                   │
│  └─ ec2 stop-instances                                    │
│                                                            │
└────────────────────────────────────────────────────────────┘
                           │
                  (instance stops)
                           │
                           ▼
┌─ AWS EventBridge (runs while EC2 off) ────────────────────┐
│                                                             │
│  Listener: EC2 state = stopped                             │
│  └─ Invoke: notify-lambda                                  │
│                                                             │
│  notify-lambda:                                            │
│  ├─ Send random sleep message: "Going to sleep 😴"        │
│  ├─ Call Telegram setWebhook:                             │
│  │  • URL → webhook-lambda (wake-on-text)                 │
│  │  • Secret token (validated)                             │
│  │  • Allowed updates: message, edited_message             │
│  └─ From now on, Telegram sends messages here (not bot)   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
                           │
                 (instance is now sleeping)
                 (webhook active on Telegram)
                           │
                           ▼
                    ┌─ You (via Telegram) ─┐
                    │                       │
                    │  Type: "hello" 👋    │
                    │  (any message works) │
                    │                       │
                    └───────────────────────┘
                           │
                           ▼ (Telegram sends to webhook)
┌─ webhook-lambda (wake-on-text) ───────────────────────────┐
│                                                             │
│  Receives: Telegram message                               │
│  ├─ Validate secret token                                 │
│  ├─ Check if sender is authorized                         │
│  ├─ Check EC2 state (stopped?)                            │
│  ├─ if yes: ec2.start_instances                           │
│  ├─ Dedup check: prevent duplicate wakes                  │
│  ├─ Reply: "☕ Waking up... 60 seconds"                    │
│  └─ Return 503 to Telegram (retry, so messages queue)     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
                           │
                  (EC2 starts booting)
                           │
                           ▼
        ┌─ EC2 boots (5-60 sec) ─────────────┐
        │ OpenClaw starts                    │
        │ ├─ Fetch queued messages from TG   │
        │ ├─ Process messages (normal flow)  │
        │ └─ restore webhook to normal bot   │
        └────────────────────────────────────┘
                           │
                           ▼
        ┌─ EventBridge fires (state=running) ┐
        │ └─ notify-lambda:                  │
        │   ├─ Fetch public IP               │
        │   └─ Send: "🟢 up + IP + ssh cmd" │
        └────────────────────────────────────┘
```

## Two Lambda Functions

### 1. **notify-lambda** (EventBridge → Telegram)

Runs when EC2 state changes (stopped/running).

#### On Stop

1. **Validate state:** Check EC2 is actually stopped (stale-event guard)
2. **Dedup:** Skip if we've already processed this event
3. **Set webhook:** Tell Telegram to send *all* messages to webhook-lambda
   - URL: API Gateway → webhook-lambda
   - Secret: Telegram validates with `X-Telegram-Bot-API-Secret-Token`
   - Only messages/edits allowed (no other updates)
4. **Send sleep message:** Random message from list:
   - "Going to sleep 😴"
   - "Taking a nap 🥱"
   - "Powering down... zzzz 💤"
   - etc. (20 messages)

#### On Start

1. **Fetch public IP:** Retry 3x (EC2 eventual consistency)
2. **Send startup message:** "🟢 Machine is up\n\nIP: 1.2.3.4\n\nssh ec2-user@1.2.3.4"

### 2. **webhook-lambda** (Telegram → EC2 Wake)

Runs when Telegram sends a message (via webhook, while EC2 is stopped).

**Process:**
1. **Validate webhook secret:** Confirm it's from Telegram
2. **Authorize sender:** Check `user_id` is in `ALLOWED_USERS`
3. **Check state:** Is instance actually stopped? (avoid waking running instance)
4. **Start instance:** `ec2.start_instances()`
5. **Dedup:** Track `message_id` to avoid duplicate wakes if Telegram retries
6. **Reply:** "☕ Waking up... give me about 60 seconds."
7. **Return 503:** Tell Telegram to retry later (keeps messages queued until OpenClaw processes them on boot)

## Key Design Decisions

### Wake-on-Text (Not Links)

**Why this is better:**
- No tokens to share/copy/forget
- No "tap link" friction
- Works from any device (phone, web, CLI)
- Natural: just send a message like normal
- No credentials in URLs (safer than token links)

**Cost:**
- `setWebhook` call: 1 per stop (EC2 charges: $0)
- Webhook Lambda: on-demand (free tier covers thousands)
- Total: **~$0/month**

### Return 503 from Webhook

When webhook-lambda returns `503 Retry`, Telegram *requeues* the message instead of confirming receipt. This ensures:

- While EC2 is sleeping: messages accumulate in Telegram's queue
- On boot: OpenClaw's normal bot handler processes all queued messages
- No message loss, no duplicate processing

### Webhook Secret Validation

Telegram sends `X-Telegram-Bot-API-Secret-Token` header with every webhook call. We validate it against SSM before processing:

```python
if secret_token != ssm.get_parameter(WEBHOOK_SECRET_PARAM):
    return 403  # Unauthorized
```

This prevents:
- Random internet traffic from triggering wakes
- DDoS attacks on the endpoint
- Accidental invocations

### Dedup via message_id

Telegram may retry webhook delivery if we don't respond quickly. Track `message_id` in SSM to skip duplicate wakes:

```python
last_id = ssm.get_parameter(LAST_WAKE_ID_PARAM)
if message_id != last_id:
    ec2.start_instances()  # New message, wake it
    ssm.put_parameter(LAST_WAKE_ID_PARAM, message_id)
```

### Stale-Event Guard

EventBridge may deliver events out-of-order. Before setting the webhook, verify the instance is *actually* stopped:

```python
actual_state = ec2.describe_instances(InstanceIds=[id])['State']['Name']
if actual_state not in ('stopped', 'stopping'):
    return  # Don't overwrite webhook (instance is still running)
```

### User Authorization

Only allow specific Telegram users to wake the instance:

```bash
--allowed-users 123456789,987654321
```

Environment variable: `ALLOWED_USERS` (comma-separated user IDs).

## Failure Modes & Recovery

| Failure | Symptom | Recovery |
|---------|---------|----------|
| Webhook not set | Message sent but nothing happens | Manually wake from AWS console, check logs |
| Invalid secret | 403 from webhook | Regenerate `webhook-secret` SSM param |
| User not authorized | Message received, no wake | Add user ID to `ALLOWED_USERS` |
| EC2 describe fails | No wake response | AWS issue, check instance health |
| Message_id dedup stale | Duplicate wake on retry | Harmless (instance already starting) |
| Return 503 breaks | Messages lost if we confirm receipt | Telegram deques, but OpenClaw on boot won't see them |

## Installation

The installer (install-idle.sh) creates:

- **notify-lambda:** EventBridge → Telegram (on stop, send sleep message + set webhook)
- **webhook-lambda:** Telegram → EC2 wake (on message, start instance if stopped)
- **EventBridge rule:** Listens for EC2 state changes (stopped/running)
- **API Gateway:** HTTP endpoint for webhook
- **SSM parameters:**
  - Bot token
  - Webhook secret
  - Webhook URL
  - Allowed users

## Operational Thresholds

Tunable in idle-check.sh:

| Variable | Default | Meaning |
|----------|---------|---------|
| `IDLE_THRESHOLD_HOURS` | `1.0` | Stop after 1 hour idle |
| `MIN_UPTIME_HOURS` | `0.25` | Skip checks if booted < 15 min ago |
| `MAX_NO_ACTIVITY_HOURS` | `1.0` | If no messages ever, stop after 1 hour uptime |

## Cost Analysis

- **EventBridge:** Free (included in CloudWatch Events)
- **Lambda (notify):** ~2 invocations/month → free tier
- **Lambda (webhook):** On-demand, typically < 100/month → **~$0.00**
- **API Gateway:** $1/million requests → ~0 requests (webhook is direct)
- **SSM:** 5 parameters → free tier
- **EC2 start/stop:** Free operation

**Total: ~$0/month** for this feature (you're already paying for the instance).

## Future Enhancements

- **Smart wake:** Wake on priority messages only (e.g., `/wake` command)
- **Scheduled wake:** "Wake me at 9am Monday"
- **Wake on CI/CD:** GitHub webhook triggers wake
- **Multiple instances:** One webhook, multiple EC2 instances
- **Rate limiting:** Prevent spam wakes
- **Admin commands:** `/status`, `/force-sleep`, etc. via Telegram

## Testing

### Dry-run the idle check

```bash
~/.openclaw/workspace/idle-check.sh --dry-run
tail ~/.openclaw/logs/idle-check.log
```

### Trigger a stop manually

```bash
aws ec2 stop-instances --instance-ids i-xxxxx
```

### Test webhook delivery

```bash
# Send a message via Telegram bot (@your_bot) while instance is stopped
# Check Lambda logs in CloudWatch
aws logs tail /aws/lambda/openclaw-telegram-wake-webhook --follow
```

### Verify webhook is active

```bash
curl -s https://api.telegram.org/bot{TOKEN}/getWebhookInfo | jq .
```

Should show webhook URL + secret token.
