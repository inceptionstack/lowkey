import json
import os
import random
import time
import urllib.request
import urllib.parse
import boto3

# Random sleep messages sent when instance shuts down
SLEEP_MESSAGES = [
    "Going to sleep 😴",
    "Taking a nap 🥱",
    "Shutting my eyes for a bit 😪",
    "BRB, hibernating 🐻",
    "Powering down... zzzz 💤",
    "Offline. Don't miss me too much 🌙",
    "Gone to the land of nod 🛌",
    "See you on the flip side 😴",
    "Hitting the bed 🛌",
    "Out cold 🥶",
    "Clocking out ⏰",
    "Lights out 💡",
    "Dreaming of electric sheep 🐑",
    "Do not disturb 🚫",
    "Saving state and suspending 💾",
    "Gone fishing 🎣",
    "In maintenance mode 🔧",
    "Recharging 🔋",
    "Away from keyboard... and everything else 👋",
    "CPU at rest 🧠",
]

HTTP_TIMEOUT = 10


def handler(event, context):
    """EventBridge handler for EC2 state changes.
    
    On stop: Send random sleeping message + set Telegram webhook for wake-on-text.
    On start: Send "woke up" message with public IP.
    """
    instance_id = event['detail']['instance-id']
    state = event['detail']['state']
    event_id = event.get('id', '')

    target_instance = os.environ.get('INSTANCE_ID')
    if target_instance and instance_id != target_instance:
        return

    ssm = boto3.client('ssm')

    try:
        telegram_token = ssm.get_parameter(
            Name='/openclaw/wake-config/telegram-bot-token', WithDecryption=True
        )['Parameter']['Value']
    except Exception as e:
        print(f"FATAL: Cannot load Telegram token from SSM: {e}")
        raise

    chat_id = os.environ['TELEGRAM_CHAT_ID']

    if state == 'stopped':
        """Instance stopped. Send sleep message + enable wake-on-Telegram-text."""
        
        # Verify instance is actually stopped (stale-event guard)
        try:
            ec2_check = boto3.client('ec2')
            check_resp = ec2_check.describe_instances(InstanceIds=[instance_id])
            actual_state = check_resp['Reservations'][0]['Instances'][0]['State']['Name']
            if actual_state not in ('stopped', 'stopping'):
                print(f"event_id={event_id} — stale stopped event, instance is {actual_state}")
                return
        except Exception as e:
            print(f"WARNING: EC2 state check failed: {e}")
            return

        # Dedup: don't send multiple sleep messages for the same event
        dedup_param = '/openclaw/wake-config/last-stop-event-id'
        if event_id:
            try:
                last_event = ssm.get_parameter(Name=dedup_param)['Parameter']['Value']
                if last_event == event_id:
                    print(f"event_id={event_id} — duplicate, skipping")
                    return
            except ssm.exceptions.ParameterNotFound:
                pass
            except Exception as e:
                print(f"WARNING: Dedup check failed: {e}")

        # Record this event for future dedup
        if event_id:
            try:
                ssm.put_parameter(Name=dedup_param, Value=event_id, Type='String', Overwrite=True)
            except Exception as e:
                print(f"WARNING: Dedup marker write failed: {e}")

        # === Set Telegram webhook for wake-on-text ===
        # Now that the instance is stopped, set the webhook so ANY Telegram message
        # triggers the wake Lambda instead of the normal message handler.
        try:
            webhook_url = ssm.get_parameter(
                Name='/openclaw/wake-config/telegram-webhook-url'
            )['Parameter']['Value']
            webhook_secret = ssm.get_parameter(
                Name='/openclaw/wake-config/webhook-secret', WithDecryption=True
            )['Parameter']['Value']
            webhook_data = urllib.parse.urlencode({
                'url': webhook_url,
                'secret_token': webhook_secret,
                'allowed_updates': '["message","edited_message"]'
            }).encode()
            webhook_req = urllib.request.Request(
                f"https://api.telegram.org/bot{telegram_token}/setWebhook",
                data=webhook_data,
                headers={'Content-Type': 'application/x-www-form-urlencoded'}
            )
            webhook_resp = urllib.request.urlopen(webhook_req, timeout=HTTP_TIMEOUT)
            print(f"event_id={event_id} — webhook set: {webhook_resp.read().decode()}")
        except Exception as e:
            print(f"WARNING: setWebhook failed (wake-on-text unavailable): {e}")

        # Send random sleep message
        message = random.choice(SLEEP_MESSAGES)

    elif state == 'running':
        """Instance started. Send message with public IP + SSH command."""
        ec2 = boto3.client('ec2')

        # Fetch public IP (with retries)
        public_ip = None
        for attempt in range(3):
            try:
                response = ec2.describe_instances(InstanceIds=[instance_id])
                public_ip = response['Reservations'][0]['Instances'][0].get('PublicIpAddress')
            except Exception as e:
                print(f"WARNING: DescribeInstances attempt {attempt+1} failed: {e}")
            if public_ip:
                break
            if attempt < 2:
                time.sleep(5)

        if not public_ip:
            message = '🟡 Machine is running but public IP not available yet.'
        else:
            message = f"🟢 Machine is up and running\n\nPublic IP: {public_ip}\n\nssh ec2-user@{public_ip}"

    else:
        return

    # Send message to Telegram
    try:
        tg_body = json.dumps({
            'chat_id': chat_id,
            'text': message,
            'disable_web_page_preview': True
        }).encode()
        tg_req = urllib.request.Request(
            f"https://api.telegram.org/bot{telegram_token}/sendMessage",
            data=tg_body,
            headers={'Content-Type': 'application/json'}
        )
        urllib.request.urlopen(tg_req, timeout=HTTP_TIMEOUT)
    except Exception as e:
        print(f"WARNING: Telegram notification failed: {e}")

    print(f"event_id={event_id} state={state} — message sent")
