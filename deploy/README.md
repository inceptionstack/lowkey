# Deploy Loki on AWS

Deploy a fully configured [Loki](https://github.com/inceptionstack/lowkey) (powered by [OpenClaw](https://github.com/openclaw/openclaw)) AI assistant on your own AWS account. Choose your preferred IaC tool — all three options deploy identical infrastructure.

## Prerequisites

- AWS account with admin access
- Bedrock model access enabled (the template auto-submits the use case form, but model activation can take ~15 minutes)
- One of: AWS CLI, SAM CLI, or Terraform installed

## Choose Your Deployment Method

| Method | Folder | Best For |
|--------|--------|----------|
| [CloudFormation](cloudformation/) | `deploy/cloudformation/` | Console deploys, StackSets, Organizations |
| [SAM](sam/) | `deploy/sam/` | Serverless-familiar teams, `sam deploy --guided` |
| [Terraform](terraform/) | `deploy/terraform/` | Terraform shops, multi-cloud workflows |

## What Gets Deployed

All three methods create the same architecture:

- **VPC** — isolated VPC with public subnet, internet gateway, route table
- **EC2 Instance** — ARM64 Graviton (AL2023), root + data EBS volumes (gp3, encrypted)
- **IAM** — instance role (AdministratorAccess + SSM)
- **Security Services** — SecurityHub, GuardDuty, Inspector, Access Analyzer, Config (individually toggleable via parameters, all enabled by default)
- **Bedrock** — use case form auto-submitted, optional quota increase requests
- **OpenClaw** — installed via bootstrap script, systemd gateway service, brain workspace files

## Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `EnvironmentName` | `openclaw` | Prefix for all resource names |
| `InstanceType` | `t4g.xlarge` | EC2 instance type (ARM64 Graviton only) |
| `ProfileName` | *(required)* | Permission profile: `builder` (AdministratorAccess), `account_assistant` (ReadOnly), `personal_assistant` (Bedrock only) |
| `ModelMode` | `bedrock` | `bedrock` (IAM), `litellm` (proxy), or `api-key` (direct) |
| `DefaultModel` | `us.anthropic.claude-opus-4-6-v1` | Bedrock model ID |
| `BedrockRegion` | `us-east-1` | Region for Bedrock API calls |
| `SSHAllowedCidr` | `127.0.0.1/32` | SSH access CIDR (disabled by default — use SSM) |
| `LiteLLMBaseUrl` | *(empty)* | LiteLLM proxy URL (only when `ModelMode=litellm`) |
| `PackName` | `openclaw` | Agent pack to deploy (`openclaw`, `claude-code`, `hermes`, `pi`, `ironclaw`, `nemoclaw`, `kiro-cli`, `codex-cli`, `roundhouse`) |
| `EnableSecurityHub` | `true` | AWS Security Hub aggregates security findings. (~$0.001 per finding/month) |
| `EnableGuardDuty` | `true` | Amazon GuardDuty threat detection via CloudTrail, VPC Flow Logs, DNS. (~$4/million events) |
| `EnableInspector` | `true` | Amazon Inspector vulnerability scanning. (~$0.01-$1.25 per resource/month) |
| `EnableAccessAnalyzer` | `true` | IAM Access Analyzer finds external shares. (Free) |
| `EnableConfigRecorder` | `true` | AWS Config records configuration changes. (~$0.003 per item/month) |
| `LokiWatermark` | `lowkey` | Custom identifier tag on all resources |

## Post-Deployment

### Connect via SSM Session Manager

```bash
aws ssm start-session --target <instance-id> --region us-east-1
```

### Check OpenClaw Status

```bash
loki gateway
openclaw logs --follow
```

### Configure a Chat Channel

```bash
openclaw configure
# Follow the wizard to set up Telegram, Discord, Slack, etc.
```

## Next Steps After Deployment

Once Loki is running and you've connected via SSM, point your agent at the bootstrap scripts to complete setup:

### Essential Bootstraps (run these first)

Tell your Loki agent:
> "Read the files in the `essential/` folder one by one and execute each bootstrap."

These set up security baselines, coding guidelines, MCP tools, memory search, and more. Each bootstrap is idempotent — safe to re-run.

| Bootstrap | What It Does |
|-----------|-------------|
| `BOOTSTRAP-SECURITY.md` | Security hardening + AWS Budgets alerts |
| `BOOTSTRAP-MCPORTER.md` | Sets up MCP server tooling |
| `BOOTSTRAP-CODING-GUIDELINES.md` | Coding standards and project conventions |
| `BOOTSTRAP-SECRETS-AWS.md` | AWS Secrets Manager integration |
| `BOOTSTRAP-PLAYWRIGHT.md` | Browser automation via Playwright MCP |
| `BOOTSTRAP-DAILY-UPDATE.md` | Daily AWS account digest briefing |
| `BOOTSTRAP-DISK-SPACE-STRAT.md` | EC2 disk space management strategy |
| `BOOTSTRAP-DIAGRAMS.md` | Diagram style guide for architecture docs |

### Optional Bootstraps

Browse the `optional/` folder for additional capabilities:

| Bootstrap | What It Does |
|-----------|-------------|
| `BOOTSTRAP-TELEGRAM.md` | Connect Loki to Telegram |
| `BOOTSTRAP-WEB-UI.md` | Expose control UI via CloudFront + Cognito |
| `BOOTSTRAP-PIPELINE-NOTIFICATIONS.md` | CI/CD pipeline alerts to Telegram |
| `BOOTSTRAP-OUTLINE-NOTES.md` | Self-hosted Outline wiki |
| `BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md` | Automatic PR code review with Claude |
| `OPTIMIZE-TOO-LARGE-CONTEXT.md` | Context window optimization tips |

Full details: [Bootstrap Scripts Guide](https://github.com/inceptionstack/lowkey/wiki/Bootstrap-Scripts-Guide)

## Shared Files

Files at the `deploy/` level are used by all deployment methods:

- `bootstrap.sh` — generic EC2 bootstrap dispatcher (installs system deps, runs pack install scripts)
- `brain/` — template workspace files (SOUL.md, AGENTS.md, etc.) copied to each new instance
