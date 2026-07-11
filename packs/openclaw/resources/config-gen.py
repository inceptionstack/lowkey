#!/usr/bin/env python3
"""Generate OpenClaw config. Args: bedrock_region model gw_port gw_token model_mode litellm_url litellm_key litellm_model provider_key
Sensitive values (gw_token, litellm_key, provider_key) can also be passed via env vars:
  GW_TOKEN_ENV, LITELLM_KEY_ENV, PROVIDER_KEY_ENV (env takes precedence over argv)"""
import json, sys, os

if len(sys.argv) < 5:
    print("Usage: config-gen.py bedrock_region model gw_port gw_token [model_mode litellm_url litellm_key litellm_model provider_key]", file=sys.stderr)
    sys.exit(1)

bedrock_region = sys.argv[1]
model = sys.argv[2]
gw_port = sys.argv[3]
gw_token = os.environ.get("GW_TOKEN_ENV") or sys.argv[4]
model_mode = sys.argv[5] if len(sys.argv) > 5 else "bedrock"
litellm_url = sys.argv[6] if len(sys.argv) > 6 else ""
litellm_key = os.environ.get("LITELLM_KEY_ENV") or (sys.argv[7] if len(sys.argv) > 7 else "")
litellm_model = sys.argv[8] if len(sys.argv) > 8 else "claude-opus-4-6"
provider_key = os.environ.get("PROVIDER_KEY_ENV") or (sys.argv[9] if len(sys.argv) > 9 else "")
home = os.path.expanduser("~")

# Explicit model entries with correct contextWindow (200K, not the 32K default
# from Bedrock auto-discovery). Uses global. prefix for cross-region routing.
# Critical: Opus has -v1 suffix, Sonnet does NOT.
bedrock_models = [
    {
        "id": "global.anthropic.claude-opus-4-6-v1",
        "name": "Claude Opus 4.6",
        "contextWindow": 200000,
        "maxTokens": 16384,
        "reasoning": True,
        "input": ["text", "image"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
    },
    {
        "id": "global.anthropic.claude-sonnet-4-6",
        "name": "Claude Sonnet 4.6",
        "contextWindow": 200000,
        "maxTokens": 16384,
        "reasoning": True,
        "input": ["text", "image"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
    }
]

# Default model IDs using global. prefix
PRIMARY_MODEL = "amazon-bedrock/global.anthropic.claude-sonnet-4-6"
FALLBACK_MODEL = "amazon-bedrock/global.anthropic.claude-sonnet-4-20250514-v1:0"
HEARTBEAT_MODEL = "amazon-bedrock/global.anthropic.claude-sonnet-4-6"

cfg = {
  "models": {"providers": {"amazon-bedrock": {"baseUrl": f"https://bedrock-runtime.{bedrock_region}.amazonaws.com", "auth": "aws-sdk", "api": "bedrock-converse-stream", "models": bedrock_models}}},
  "plugins": {"entries": {"amazon-bedrock": {"enabled": True, "config": {"discovery": {"enabled": True}}}}},
  "agents": {"defaults": {"model": {"primary": PRIMARY_MODEL, "fallbacks": [FALLBACK_MODEL]}, "workspace": f"{home}/.openclaw/workspace", "compaction": {"mode": "safeguard"}, "heartbeat": {"model": HEARTBEAT_MODEL, "target": "telegram", "every": "30m", "lightContext": True, "isolatedSession": True}, "maxConcurrent": 4, "subagents": {"maxConcurrent": 8}}},
  "tools": {"web": {"search": {"enabled": False}, "fetch": {"enabled": True}}},
  "hooks": {"internal": {"enabled": True, "entries": {"boot-md": {"enabled": True}, "bootstrap-extra-files": {"enabled": True}, "command-logger": {"enabled": True}, "session-memory": {"enabled": True}}}},
  "gateway": {"port": int(gw_port), "mode": "local", "bind": "loopback", "auth": {"mode": "token", "token": gw_token}}
}

if model_mode == "litellm" and litellm_url and litellm_key:
  cfg["models"]["providers"]["litellm"] = {"baseUrl": litellm_url, "apiKey": litellm_key, "api": "openai-completions", "models": [
    {"id": "claude-opus-4-6", "name": "Claude Opus 4.6", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "claude-sonnet-4-6", "name": "Claude Sonnet 4.6", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "claude-3.5-haiku", "name": "Claude 3.5 Haiku", "reasoning": False, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 8192}]}
  cfg["agents"]["defaults"]["model"] = {"primary": f"litellm/{litellm_model}", "fallbacks": ["litellm/claude-sonnet-4-6", PRIMARY_MODEL]}
elif model_mode == "api-key" and provider_key:
  cfg["models"]["providers"]["anthropic"] = {"apiKey": provider_key, "models": []}
  cfg["agents"]["defaults"]["model"] = {"primary": "anthropic/claude-opus-4-6-20260514", "fallbacks": ["anthropic/claude-sonnet-4-6-20260514", PRIMARY_MODEL]}

with open(f"{home}/.openclaw/openclaw.json", "w") as f:
  json.dump(cfg, f, indent=2)
print(f"Config written (mode={model_mode})")
