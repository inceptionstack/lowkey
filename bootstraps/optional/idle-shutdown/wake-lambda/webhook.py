import json
import os
import boto3
import urllib.request

"""Telegram webhook Lambda for wake-on-text.

Intercepted by Telegram while EC2 is stopped.
When user sends any message, this Lambda wakes the instance.

Dedup protection: tracks last message_id to avoid duplicate wake requests
(Telegram may retry webhook delivery).
"""

ssm = boto3.client('ssm', region_name=os.environ.get('REGION', 'us-east-1'))
ec2 = boto3.client('ec2', region_name=os.environ.get('REGION', 'us-east-1'))

INSTANCE_ID = os.environ['INSTANCE_ID']
ALLOWED_USERS = set(os.environ.get('ALLOWED_USERS', '').split(','))
BOT_TOKEN_PARAM = os.environ.get('SSM_BOT_TOKEN_PARAM', '/openclaw/wake-config/telegram-bot-token')
WEBHOOK_SECRET_PARAM = os.environ.get('SSM_WEBHOOK_SECRET_PARAM', '/openclaw/wake-config/webhook-secret')
LAST_WAKE_ID_PARAM = '/openclaw/wake-config/last-wake-update-id'


def get_param(name, decrypt=False):
    """Fetch SSM parameter."""
    return ssm.get_parameter(Name=name, WithDecryption=decrypt)['Parameter']['Value']


def put_param(name, value):
    """Store SSM parameter."""
    try:
        ssm.put_parameter(Name=name, Value=str(value), Type='String', Overwrite=True)
    except Exception as e:
        print(f"SSM put error: {e}")


def send_telegram(bot_token, chat_id, text, reply_to_message_id=None):
    """Send Telegram message (best-effort)."""
    body = {
        "chat_id": chat_id,
        "text": text
    }
    if reply_to_message_id:
        body["reply_parameters"] = {"message_id": reply_to_message_id}
    
    try:
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{bot_token}/sendMessage",
            json.dumps(body).encode(),
            {"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=8)
    except Exception as e:
        print(f"Telegram send error: {e}")


def handler(event, context):
    """Main webhook handler.
    
    Called by Telegram when:
    - User sends a message
    - User edits a message
    
    Only accepts messages from allowed users.
    Only wakes if instance is stopped (prevents duplicate wakes).
    Dedup-protected via message_id tracking.
    """
    
    # === Validate webhook secret ===
    headers = {k.lower(): v for k, v in (event.get('headers') or {}).items()}
    secret = headers.get('x-telegram-bot-api-secret-token', '')
    
    try:
        expected_secret = get_param(WEBHOOK_SECRET_PARAM, decrypt=True)
    except Exception:
        return {'statusCode': 403, 'body': 'forbidden'}
    
    if secret != expected_secret:
        return {'statusCode': 403, 'body': 'forbidden'}
    
    # === Parse Telegram update ===
    try:
        update = json.loads(event.get('body', '{}'))
    except:
        return {'statusCode': 200, 'body': 'ok'}
    
    # Handle both new messages and edited messages
    message = update.get('message') or update.get('edited_message') or {}
    chat_id = message.get('chat', {}).get('id')
    user_id = str(message.get('from', {}).get('id', ''))
    message_id = message.get('message_id')
    
    if not chat_id or user_id not in ALLOWED_USERS:
        return {'statusCode': 200, 'body': 'ok'}
    
    # === Check instance state ===
    try:
        status = ec2.describe_instance_status(
            InstanceIds=[INSTANCE_ID],
            IncludeAllInstances=True
        )['InstanceStatuses'][0]['InstanceState']['Name']
    except Exception as e:
        print(f"EC2 describe error: {e}")
        return {'statusCode': 200, 'body': 'ok'}
    
    # Load bot token for response
    try:
        bot_token = get_param(BOT_TOKEN_PARAM, decrypt=True)
    except Exception as e:
        print(f"Failed to load bot token: {e}")
        return {'statusCode': 200, 'body': 'ok'}
    
    # === Wake if stopped ===
    if status == 'stopped':
        # Dedup check: don't wake twice for the same message
        try:
            last_message_id = get_param(LAST_WAKE_ID_PARAM)
        except:
            last_message_id = None
        
        if str(message_id) != str(last_message_id):
            # This is a new message, wake the instance
            try:
                ec2.start_instances(InstanceIds=[INSTANCE_ID])
                send_telegram(bot_token, chat_id, "☕ Waking up... give me about 60 seconds.", message_id)
                put_param(LAST_WAKE_ID_PARAM, message_id)
            except Exception as e:
                print(f"Start error: {e}")
                send_telegram(bot_token, chat_id, f"⚠️ Failed to wake: {e}", message_id)
    
    # Always return 503 to Telegram so messages stay queued until we process them on boot
    # This ensures no messages are lost while instance is sleeping
    return {'statusCode': 503, 'body': 'retry'}
