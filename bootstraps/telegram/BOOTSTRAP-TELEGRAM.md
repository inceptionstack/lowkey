# BOOTSTRAP-TELEGRAM.md — Telegram Setup + Communication Rules

> **Applies to:** All agents (with agent-specific sections below)

> **Part 1** (setup) runs once. **Part 2** (formatting rules) applies permanently to every message.
> If `memory/.bootstrapped-telegram` exists, Part 1 is done — skip to Part 2 to refresh the rules.

---

## Part 1: Set Up Telegram

### Step 1: Create a Telegram Bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot`
3. Choose a name (e.g. `Loki FastStart`)
4. Choose a username (must end in `bot`, e.g. `lokifaststart_bot`)
5. BotFather replies with your **bot token** — looks like `123456789:AAF...`

Store it immediately in Secrets Manager — don't leave it in chat history:

```bash
aws secretsmanager create-secret \
  --name faststart/telegram-bot-token \
  --secret-string "YOUR_BOT_TOKEN_HERE" \
  --region us-east-1
```

> **Note:** No leading `/` in the secret name. OpenClaw's exec secret reference (`exec:aws-sm:<name>`) requires the name to start with an alphanumeric character; `/faststart/...` will fail gateway startup with a `SECRETS_RELOADER_DEGRADED` error. Slashes are allowed *inside* the name as separators.

### Step 2: Get Your Telegram Chat ID

Start a conversation with your new bot (send it any message). Then fetch your chat ID:

```bash
BOT_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id faststart/telegram-bot-token \
  --query SecretString --output text --region us-east-1)

curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" \
  | python3 -c "import sys,json; updates=json.load(sys.stdin).get('result',[]); \
    [print(f'Chat ID: {u[\"message\"][\"chat\"][\"id\"]}  From: {u[\"message\"][\"from\"].get(\"username\",\"?\")}') for u in updates if 'message' in u]"
```

Note your **numeric chat ID** (e.g. `123456789`).

### Step 3: Configure the Agent

Configuration differs by agent type. Follow the section for your agent below.

#### OpenClaw Configuration

Add the Telegram channel to OpenClaw config. Ask Loki to run:

```
/config patch channels.telegram with:
  enabled: true
  botToken: <fetched from faststart/telegram-bot-token>
  dmPolicy: allowlist
  allowFrom: [YOUR_CHAT_ID]
  groupPolicy: allowlist
  streaming: partial
```

Or use `openclaw config patch` directly:

```bash
BOT_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id faststart/telegram-bot-token \
  --query SecretString --output text --region us-east-1)

openclaw config patch <<EOF
{
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "${BOT_TOKEN}",
      "dmPolicy": "allowlist",
      "allowFrom": ["YOUR_CHAT_ID"],
      "groupPolicy": "allowlist",
      "streaming": "partial"
    }
  },
  "plugins": {
    "entries": {
      "telegram": { "enabled": true }
    }
  }
}
EOF
```

OpenClaw restarts automatically after the config change.

#### Hermes Configuration

Hermes configures Telegram via environment variables and `config.yaml`:

**Option A — Interactive setup (recommended):**

```bash
hermes gateway setup
# Select "Telegram" when prompted
# Enter your bot token and allowed user IDs
```

**Option B — Manual configuration:**

Add to `~/.hermes/.env`:

```bash
TELEGRAM_BOT_TOKEN=YOUR_BOT_TOKEN_HERE
TELEGRAM_ALLOWED_USERS=YOUR_CHAT_ID
```

To fetch the token from Secrets Manager:

```bash
BOT_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id faststart/telegram-bot-token \
  --query SecretString --output text --region us-east-1)

echo "TELEGRAM_BOT_TOKEN=${BOT_TOKEN}" >> ~/.hermes/.env
echo "TELEGRAM_ALLOWED_USERS=YOUR_CHAT_ID" >> ~/.hermes/.env
```

Then start the gateway:

```bash
hermes gateway                    # Foreground (testing)
hermes gateway install && hermes gateway start   # Systemd service (production)
```

**Optional Hermes Telegram config** in `~/.hermes/config.yaml`:

```yaml
telegram:
  require_mention: false         # true = only respond when @mentioned in groups
  mention_patterns:
    - "^\\s*loki\\b"            # Custom wake word
```

Hermes supports Telegram voice messages (auto-transcription), images, file attachments, and streaming responses out of the box.

### Step 4: Verify

Send your bot a message. You should get a response from the agent within a few seconds.

**OpenClaw test:**

```bash
BOT_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id faststart/telegram-bot-token \
  --query SecretString --output text --region us-east-1)

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="YOUR_CHAT_ID" \
  -d text="Hello from Loki setup test" \
  -d parse_mode="HTML"
```

**Hermes test:**

```bash
hermes gateway status   # Should show "running"
# Then send a message to your bot in Telegram
```

### Step 5: Security — allowlist only

Both agents use allowlists by default — the agent only responds to explicitly authorized user IDs.

**OpenClaw:** `dmPolicy: allowlist` + `allowFrom` in `openclaw.json`. Never set `dmPolicy: all` on a production instance.

To add more users:
```bash
openclaw config patch '{"channels":{"telegram":{"allowFrom":["CHAT_ID_1","CHAT_ID_2"]}}}'
```

**Hermes:** `TELEGRAM_ALLOWED_USERS` in `~/.hermes/.env` (comma-separated). Alternatively, Hermes supports DM pairing — unknown users get a one-time pairing code:

```bash
hermes pairing approve telegram PAIRING_CODE    # Approve a user
hermes pairing list                              # View pending + approved
hermes pairing revoke telegram USER_ID           # Remove access
```

Never set `GATEWAY_ALLOW_ALL_USERS=true` on a production instance.

---

## Part 2: Formatting Rules (Permanent)

Telegram renders markdown differently from most surfaces. These rules prevent broken messages.

### NEVER use

- **Markdown tables** — Telegram renders them as raw pipe characters `| col | col |`
- **Markdown headers** (`# H1`, `## H2`) — don't render as headers, show as `# text`
- **Bare absolute media paths** (`MEDIA:/home/...`) — blocked for security

### ALWAYS use instead

**Tables → bullet lists with bold labels:**

❌ Wrong:
```
| Model | Dims | Speed |
|-------|------|-------|
| Titan | 1024 | Fast  |
```

✅ Right:
```
• **Titan Embed V2** — 1024 dims, fastest
• **Cohere Embed v4** — 1536 dims, best quality
```

**Headers → bold or CAPS:**

❌ Wrong: `## Summary`
✅ Right: `**Summary**` or `SUMMARY`

### Links — suppress embeds

Wrap multiple links in `<>` to prevent Telegram from generating large previews:

```
<https://github.com/inceptionstack/embedrock>
<https://github.com/inceptionstack/lowkey>
```

Single important links can be left unwrapped if the preview is useful.

### Inline buttons for actions

Use inline buttons for confirmations and quick actions — Telegram renders them natively:

```
Ask Loki to send buttons like:
  "Deploy to prod?" [Yes, deploy ✅] [Cancel ❌]
```

The OpenClaw `message` tool supports this via `buttons`:
```json
buttons: [[
  {"text": "Yes, deploy", "callback_data": "deploy_yes", "style": "success"},
  {"text": "Cancel",      "callback_data": "deploy_no",  "style": "danger"}
]]
```

Use these for:
- Destructive operations (deletes, deploys, SCP changes)
- Yes/no confirmations before long-running tasks

### Reactions

Reactions are available but use them sparingly — at most 1 per 5–10 exchanges. Only react when it genuinely adds signal (acknowledging something important, expressing real appreciation). Don't react to every message.

---

## Add to SOUL.md or AGENTS.md

```markdown
## Platform Formatting
- **Telegram:** No markdown tables — use bullet lists. No headers — use **bold** or CAPS.
- Wrap multiple links in `<>` to suppress embeds.
- Use inline buttons for destructive operation confirmations.
```

> **Note:** These formatting rules apply regardless of agent type — Telegram renders markdown the same way for both OpenClaw and Hermes.

## Pi-Specific Configuration

**Not applicable.** Pi is a CLI tool with no Telegram support. It cannot send or receive Telegram messages natively. For Telegram delivery of Pi output, pipe results to a script that calls the Telegram Bot API directly.

## IronClaw-Specific Configuration

IronClaw supports Telegram via WASM channels. Configure the bot token and allowed users in `~/.ironclaw/.env`:

```bash
TELEGRAM_BOT_TOKEN=YOUR_BOT_TOKEN_HERE
TELEGRAM_ALLOWED_USERS=YOUR_CHAT_ID
```

To fetch the token from Secrets Manager:

```bash
BOT_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id faststart/telegram-bot-token \
  --query SecretString --output text --region us-east-1)

echo "TELEGRAM_BOT_TOKEN=${BOT_TOKEN}" >> ~/.ironclaw/.env
echo "TELEGRAM_ALLOWED_USERS=YOUR_CHAT_ID" >> ~/.ironclaw/.env
```

Start IronClaw with the Telegram channel enabled:

```bash
ironclaw --channel telegram
```

Or configure it to start with Telegram as the default channel. Refer to IronClaw's documentation for channel startup flags and systemd service setup.

> **Note:** The formatting rules in Part 2 apply regardless of agent type — Telegram renders markdown the same way for all agents.

---

## Finish

```bash
mkdir -p memory && echo "Telegram bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-telegram
```
