# Bootstrap Scripts Guide

After deploying Loki, bootstrap scripts configure your agent with security baselines, development tools, and integrations. These scripts live in the `bootstraps/` directory of the [lowkey](https://github.com/inceptionstack/lowkey) repository, organized into three subdirectories:

- **`bootstraps/essential/`** — Core setup that every Loki instance needs
- **`bootstraps/optional/`** — Add-ons based on your workflow
- **`bootstraps/telegram/`** — Telegram chat integration

## How to Run Bootstraps

Connect to your Loki instance and tell it:
> "Read the files in the `bootstraps/essential/` folder one by one and execute each bootstrap."

Each bootstrap:
- Is a markdown file with instructions your agent follows
- Is **idempotent** — safe to re-run if interrupted
- Creates a marker file (e.g. `memory/.bootstrapped-security`) to track completion
- Can be skipped if the marker already exists

## Essential Bootstraps

Run these first, in any order. They set up the foundation your agent needs.

### BOOTSTRAP-SECURITY.md — Security & Budget Setup
Enables GuardDuty, Security Hub, Inspector, and Access Analyzer monitoring. Sets up AWS Budgets alerts to catch cost surprises. Creates security-focused cron jobs for ongoing monitoring.

### BOOTSTRAP-MCPORTER.md — MCP Server Tooling
Sets up MCPorter for managing MCP (Model Context Protocol) servers. Configures the AWS MCP servers for documentation search, API access, and CloudFormation schema lookups.

### BOOTSTRAP-MEMORY-SEARCH.md — Semantic Memory Search
Enables vector-based memory search using Bedrock embeddings (Cohere Embed v4). Lets Loki search its own memory files semantically instead of just by keyword.

### BOOTSTRAP-CODING-GUIDELINES.md — Coding Standards
Establishes coding conventions: all code through version control, IaC-first infrastructure, naming standards, and project structure guidelines.

### BOOTSTRAP-SECRETS-AWS.md — Secrets Manager Integration
Configures OpenClaw to fetch secrets (API keys, tokens) from AWS Secrets Manager via the EC2 instance profile. No hardcoded secrets.

### BOOTSTRAP-PLAYWRIGHT.md — Browser Automation
Sets up Playwright as an MCP server for browser automation — useful for testing web UIs, scraping, and automated workflows.

### BOOTSTRAP-DAILY-UPDATE.md — Daily AWS Digest
Configures a daily cron job that summarizes your AWS account status: costs, security findings, pipeline health, and resource changes.

### BOOTSTRAP-DISK-SPACE-STRAT.md — Disk Space Management
Sets up disk monitoring, cleanup crons, and symlinks to keep the root volume lean. Moves heavy directories (Docker, tmp, builds) to the data volume.

### BOOTSTRAP-DIAGRAMS.md — Architecture Diagrams
Style guide for generating AWS architecture diagrams using draw.io with the re:Invent dark theme.

## Optional Bootstraps

Add these based on your workflow needs.

### BOOTSTRAP-WEB-UI.md — Web Control UI
Exposes the OpenClaw control dashboard via CloudFront + Cognito authentication. Gives you a browser-based interface for managing your agent.

### BOOTSTRAP-PIPELINE-NOTIFICATIONS.md — CI/CD Alerts
Wires up CodePipeline and GitHub Actions notifications to Telegram and/or OpenClaw. Get build started/passed/failed alerts.

### BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md — AI Code Review
Adds a GitHub Action that runs Claude Code for automatic code review on PRs and commits.

### OPTIMIZE-TOO-LARGE-CONTEXT.md — Context Optimization
Tips for reducing system prompt size when hitting context limits. Covers workspace file pruning, memory consolidation, and skill management.

### BOOTSTRAP-SKILLS.md — Skills Library (Manual / Recovery)
The `openclaw` pack pre-installs the loki-skills library automatically during EC2 bootstrap, so this is usually a no-op. Run it manually only as a recovery path — `git` was missing on first boot, the clone failed, the existing skills checkout has a different origin, or you're on a non-openclaw pack that doesn't auto-install yet (hermes, nemoclaw, pi, ironclaw, kiro-cli, codex-cli, roundhouse, claude-code).

## Telegram Bootstraps

Set up Telegram as your chat interface with Loki.

### BOOTSTRAP-TELEGRAM.md — Telegram Integration
Connects Loki to a Telegram bot for chat-based interaction. Includes setup instructions for BotFather and formatting rules for Telegram messages.

### BOOTSTRAP-TELEGRAM-GROUP.md — Telegram Group Chat
Configures Loki to participate in Telegram group chats with appropriate behavior rules.
