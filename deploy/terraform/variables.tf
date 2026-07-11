variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for infrastructure deployment. Defaults to us-east-1."
}

variable "repo_branch" {
  type        = string
  default     = "main"
  description = "Git branch to clone on the EC2 instance. Use for testing feature branches."
}

variable "profile_name" {
  type        = string
  description = "Permission profile. 'builder' = full admin. 'account_assistant' = read-only. 'personal_assistant' = Bedrock only."
  # No default — must be explicitly specified
  validation {
    condition     = contains(["builder", "account_assistant", "personal_assistant"], var.profile_name)
    error_message = "profile_name must be one of: builder, account_assistant, personal_assistant."
  }
}

variable "pack_name" {
  description = "Agent pack to deploy (openclaw, claude-code, hermes, pi, ironclaw, nemoclaw, kiro-cli, codex-cli, or roundhouse)"
  type        = string
  default     = "openclaw"
  validation {
    condition     = contains(["openclaw", "claude-code", "hermes", "pi", "ironclaw", "nemoclaw", "kiro-cli", "codex-cli", "roundhouse"], var.pack_name)
    error_message = "pack_name must be openclaw, claude-code, hermes, pi, ironclaw, nemoclaw, kiro-cli, codex-cli, or roundhouse."
  }
}

variable "environment_name" {
  type        = string
  default     = "openclaw"
  description = "A short name for this deployment (e.g. 'my-openclaw'). Used as prefix for all AWS resources. Lowercase letters, numbers, and hyphens only."

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment_name))
    error_message = "Environment name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "instance_type" {
  type        = string
  default     = "t4g.xlarge"
  description = "EC2 instance size. t4g.medium works for light use. t4g.xlarge recommended for production. All options are ARM64 Graviton."

  validation {
    condition     = can(regex("^(t4g|m7g|c7g)\\.", var.instance_type))
    error_message = "Instance type must be ARM64 Graviton (t4g, m7g, or c7g family)."
  }
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the new VPC. Change only if it conflicts with existing VPCs in your account."
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "CIDR for the public subnet. Must be within the VPC CIDR range."
}

variable "ssh_allowed_cidr" {
  type        = string
  default     = "127.0.0.1/32"
  description = "IP range allowed to SSH. Default 127.0.0.1/32 disables SSH entirely — use AWS SSM Session Manager instead (recommended). Set to your-ip/32 to enable SSH."
}

variable "root_volume_size" {
  type        = number
  default     = 40
  description = "Root disk size in GB. 40GB is sufficient for most deployments."

  validation {
    condition     = var.root_volume_size >= 20 && var.root_volume_size <= 200
    error_message = "Must be between 20 and 200."
  }
}

variable "data_volume_size" {
  type        = number
  default     = 80
  description = "Separate data volume for OpenClaw state and workspaces. Set to 0 to skip (uses root volume instead). 80GB recommended for OpenClaw, 0 for Hermes."

  validation {
    condition     = var.data_volume_size == 0 || (var.data_volume_size >= 20 && var.data_volume_size <= 500)
    error_message = "Must be 0 (skip) or between 20 and 500."
  }
}

variable "key_pair_name" {
  type        = string
  default     = ""
  description = "EC2 key pair for SSH access. Leave blank to skip — SSM Session Manager is the recommended access method."
}

variable "openclaw_gateway_port" {
  type        = number
  default     = 3001
  description = "Internal port for the OpenClaw gateway service. Change only if port 3001 conflicts with other services."

  validation {
    condition     = var.openclaw_gateway_port >= 1024 && var.openclaw_gateway_port <= 65535
    error_message = "Must be between 1024 and 65535."
  }
}

variable "bedrock_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for Bedrock API calls. us-east-1 has the widest model selection."

  validation {
    condition     = contains(["us-east-1", "us-west-2", "eu-west-1", "eu-central-1", "eu-north-1", "ap-northeast-1", "ap-southeast-1"], var.bedrock_region)
    error_message = "Must be a supported Bedrock region."
  }
}

variable "default_model" {
  type        = string
  default     = "us.anthropic.claude-opus-4-6-v1"
  description = "The primary AI model. Claude Opus 4.6 is recommended for best performance. Used when ModelMode is 'bedrock'."
}

variable "model_mode" {
  type        = string
  default     = "bedrock"
  description = "How OpenClaw connects to AI models. 'bedrock' uses AWS Bedrock (recommended, no extra keys needed). 'litellm' routes through a LiteLLM proxy. 'api-key' uses a provider API key directly."

  validation {
    condition     = contains(["bedrock", "litellm", "api-key"], var.model_mode)
    error_message = "Model mode must be 'bedrock', 'litellm', or 'api-key'."
  }
}

variable "litellm_base_url" {
  type        = string
  default     = ""
  description = "URL of your LiteLLM proxy server. Only needed when Model Access Mode is 'litellm'. Leave empty otherwise."
}

variable "litellm_api_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "API key for authenticating with the LiteLLM proxy. Only needed when Model Access Mode is 'litellm'."
}

variable "litellm_model" {
  type        = string
  default     = "claude-opus-4-6"
  description = "Default model alias on your LiteLLM proxy (e.g. 'claude-opus-4-6'). Only used when Model Access Mode is 'litellm'."
}

variable "provider_api_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Direct API key from your AI provider (e.g. Anthropic). Only needed when Model Access Mode is 'api-key'."
}

variable "kiro_from_secret" {
  type        = string
  default     = ""
  description = "AWS Secrets Manager secret id/arn whose SecretString is the Kiro API key (kiro-cli pack, headless mode). The raw key is NOT stored in Terraform state — the instance resolves the secret at install time via its IAM role."
}

variable "telegram_bot_token_secret" {
  type        = string
  default     = ""
  description = "AWS Secrets Manager secret id/arn containing the Telegram bot token (roundhouse pack only). The instance resolves the secret at install time via its IAM role."
}

variable "telegram_user" {
  type        = string
  default     = ""
  description = "Telegram username for bot pairing (roundhouse pack only, without @ prefix)."
}

variable "request_quota_increases" {
  type        = string
  default     = "false"
  description = "Automatically request higher Bedrock rate limits during deployment. Set to 'true' if you expect heavy usage."

  validation {
    condition     = contains(["true", "false"], var.request_quota_increases)
    error_message = "Must be true or false."
  }
}

variable "enable_bedrock_form" {
  type        = string
  default     = "false"
  description = "Submit the Bedrock model access use-case form. Only needed once per account — skip if Bedrock is already enabled."

  validation {
    condition     = contains(["true", "false"], var.enable_bedrock_form)
    error_message = "Must be true or false."
  }
}

variable "enable_security_hub" {
  type        = bool
  default     = true
  description = "Enable AWS Security Hub — aggregates security findings from multiple services into a single dashboard. Enables CIS Benchmarks and AWS Foundational Security Best Practices standards. (~$0.001 per finding/month)"
}

variable "enable_guardduty" {
  type        = bool
  default     = true
  description = "Enable Amazon GuardDuty — provides intelligent threat detection by analyzing CloudTrail, VPC Flow Logs, and DNS queries. Alerts on suspicious activity like cryptocurrency mining, data exfiltration, or unauthorized access. (~$4/million events)"
}

variable "enable_inspector" {
  type        = bool
  default     = true
  description = "Enable Amazon Inspector — automatically scans EC2 instances, container images, and Lambda functions for software vulnerabilities and unintended network exposure. (~$0.01-$1.25 per resource/month)"
}

variable "enable_access_analyzer" {
  type        = bool
  default     = true
  description = "Enable IAM Access Analyzer — identifies resources shared with external entities and validates IAM policies. Helps ensure least-privilege access. (Free)"
}

variable "enable_config_recorder" {
  type        = bool
  default     = true
  description = "Enable AWS Config Recorder — records resource configuration changes and evaluates compliance against rules. Required by Security Hub for many checks. (~$0.003 per item recorded/month)"
}

variable "loki_watermark" {
  type        = string
  default     = "lowkey"
  description = "Custom identifier tag applied to all resources. Use to distinguish multiple Loki deployments or mark team ownership (e.g. 'team-alpha', 'dev-loki')."
}

variable "existing_vpc_id" {
  type        = string
  default     = ""
  description = "Reuse an existing Loki VPC. Leave empty to create a new VPC."
  validation {
    condition     = var.existing_vpc_id == "" || can(regex("^vpc-[a-z0-9]+$", var.existing_vpc_id))
    error_message = "existing_vpc_id must be empty or a valid VPC ID (vpc-xxx)."
  }
}

variable "existing_subnet_id" {
  type        = string
  default     = ""
  description = "Public subnet ID in the existing VPC. Required if existing_vpc_id is set."
  validation {
    condition     = var.existing_subnet_id == "" || can(regex("^subnet-[a-z0-9]+$", var.existing_subnet_id))
    error_message = "existing_subnet_id must be empty or a valid subnet ID (subnet-xxx)."
  }
}
