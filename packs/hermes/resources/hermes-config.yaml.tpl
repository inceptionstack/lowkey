# Hermes Agent — native Bedrock (Converse API, no proxy needed)
model:
  default: "${MODEL}"
  provider: bedrock
  base_url: https://bedrock-runtime.${REGION}.amazonaws.com

bedrock:
  region: ${REGION}

terminal:
  backend: "local"
  cwd: "."
  timeout: 180

agent:
  max_turns: 60
  reasoning_effort: "medium"

compression:
  enabled: true
  threshold: 0.50
  summary_model: "${MODEL}"

display:
  streaming: true
  tool_progress: all
