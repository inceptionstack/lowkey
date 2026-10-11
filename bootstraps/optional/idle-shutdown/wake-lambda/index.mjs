import { SSMClient, GetParameterCommand, DeleteParameterCommand, PutParameterCommand } from "@aws-sdk/client-ssm";
import { EC2Client, StartInstancesCommand, DescribeInstanceStatusCommand } from "@aws-sdk/client-ec2";
import { timingSafeEqual } from "node:crypto";

const ssm = new SSMClient({});
const ec2 = new EC2Client({});
const TOKEN_PARAM = "/openclaw/wake-token";
const CONFIG_PREFIX = "/openclaw/wake-config/";

// Compare in constant time. timingSafeEqual throws when the lengths are not
// equal, so compare the byte lengths first.
function tokensMatch(given, stored) {
  if (typeof given !== "string" || typeof stored !== "string") return false;
  const a = Buffer.from(given, "utf8");
  const b = Buffer.from(stored, "utf8");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

async function getParam(name, decrypt = false) {
  const res = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: decrypt }));
  return res.Parameter.Value;
}

async function sendTelegram(botToken, chatId, text) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  try {
    const res = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
      signal: controller.signal,
    });
    if (!res.ok) {
      console.error(`Telegram API error: ${res.status} ${await res.text()}`);
    }
  } finally {
    clearTimeout(timeout);
  }
}

const html = (title, msg, emoji, statusCode = 200) => ({
  statusCode,
  headers: { "content-type": "text/html; charset=utf-8" },
  body: `<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>
  <style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:#0D1117;color:#F0F6FC;text-align:center}
  .card{background:#161B22;border:1px solid #30363D;border-radius:12px;padding:2rem;max-width:400px}
  h1{font-size:3rem;margin:0}p{color:#8B949E;font-size:1.1rem}</style></head>
  <body><div class="card"><h1>${emoji}</h1><h2>${title}</h2><p>${msg}</p></div></body></html>`
});

export const handler = async (event) => {
  const token = event.queryStringParameters?.token;
  if (!token) return html("Missing Token", "No wake token provided.", "❌", 400);

  // Validate token — do NOT consume yet
  let stored;
  try {
    stored = await getParam(TOKEN_PARAM);
  } catch (e) {
    if (e.name === "ParameterNotFound")
      return html("Expired", "This wake link has already been used or expired.", "⏰", 410);
    throw e;
  }
  if (!tokensMatch(token, stored)) return html("Invalid Token", "This wake link is not valid.", "🚫", 403);

  // Load instance ID first — this is the only config needed for the critical wake path
  let instanceId;
  try {
    instanceId = await getParam(CONFIG_PREFIX + "instance-id");
  } catch (e) {
    console.error("Failed to load instance-id from SSM:", e);
    return html("Config Error", "Could not load instance configuration. Please try again.", "⚠️", 503);
  }

  // Telegram config loaded later — notification is best-effort, not a wake blocker
  let chatId, botToken;
  try {
    [chatId, botToken] = await Promise.all([
      getParam(CONFIG_PREFIX + "telegram-chat-id"),
      getParam(CONFIG_PREFIX + "telegram-bot-token", true),
    ]);
  } catch (e) {
    console.error("Telegram config unavailable (wake will proceed without notification):", e);
    chatId = null;
    botToken = null;
  }

  // Check instance state BEFORE consuming token
  let state;
  try {
    const status = await ec2.send(new DescribeInstanceStatusCommand({
      InstanceIds: [instanceId], IncludeAllInstances: true,
    }));
    state = status.InstanceStatuses?.[0]?.InstanceState?.Name;
  } catch (e) {
    console.error("DescribeInstanceStatus failed:", e);
    return html("Check Failed", "Could not determine instance state. Please try again in a moment.", "⚠️", 503);
  }

  const notify = (text) => {
    if (botToken && chatId) return sendTelegram(botToken, chatId, text).catch(() => {});
  };

  if (state === "running") {
    await notify("🐺 Already running — no action needed.");
    return html("Already Running", "Instance is already up and running!", "✅");
  }
  if (state === "stopping") {
    await notify("🐺 Instance is still shutting down. Wait a minute and try again.");
    return html("Still Stopping", "Instance is still shutting down. Wait a moment and try the link again.", "⏳", 409);
  }
  if (state === "pending") {
    await notify("🐺 Already starting up — hang tight.");
    return html("Starting Up", "Instance is already starting. Give it a minute.", "⏳");
  }

  // State is "stopped" — START INSTANCE FIRST (critical path)
  try {
    await ec2.send(new StartInstancesCommand({ InstanceIds: [instanceId] }));
  } catch (e) {
    console.error("StartInstances failed:", e);
    if (e.name === "IncorrectInstanceState") {
      return html("Wrong State", "Instance is in an unexpected state. Try again in a moment.", "⚠️", 409);
    }
    // Start failed — don't consume token so wake link stays valid
    return html("Start Failed", "Could not start the instance. Please try again.", "⚠️", 503);
  }

  // Instance is starting — NOW consume the one-time token
  try {
    await ssm.send(new DeleteParameterCommand({ Name: TOKEN_PARAM }));
  } catch (e) {
    // Token deletion failed but instance is starting — log and continue
    if (e.name !== "ParameterNotFound") {
      console.error("Token cleanup failed (instance is starting anyway):", e);
    }
  }

  // Telegram notification is best-effort — doesn't affect wake success
  await notify("🐺 Starting up now — should be ready in about 60 seconds.");

  return html("Waking Up! 🐺", "Instance is starting. Give it about 60 seconds.", "🐺");
};
