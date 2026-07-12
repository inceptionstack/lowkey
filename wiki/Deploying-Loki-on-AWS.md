# Deploy Your Own Loki on AWS

A complete guide to deploying an always-on AI ops assistant builder in your own AWS account. Covers everything from zero to a running Loki instance you can build with.

---

## Table of Contents

- [TL;DR — Quick Playbook](#tldr--quick-playbook)
- [Before You Start](#before-you-start)
- [Step 1: Prepare Your AWS Account](#step-1-prepare-your-aws-account)
- [Step 2: Choose a Deployment Method](#step-2-choose-a-deployment-method)
- [Step 3: Deploy](#step-3-deploy)
- [Step 4: Connect and Verify](#step-4-connect-and-verify)
- [Step 5: Set Up a Chat Channel](#step-5-set-up-a-chat-channel)
- [Step 6: Set Budget Alerts](#step-6-set-budget-alerts)
- [Security Best Practices](#security-best-practices)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)

---

## TL;DR — Quick Playbook

If you know what you're doing:

```bash
# 1. Clone the repo
git clone https://github.com/inceptionstack/lowkey.git
cd lowkey/deploy/cloudformation

# 2. Deploy (change region/instance as needed)
aws cloudformation create-stack \
  --stack-name my-openclaw \
  --template-body file://template.yaml \
  --parameters ParameterKey=EnvironmentName,ParameterValue=my-openclaw \
               ParameterKey=ProfileName,ParameterValue=builder \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# 3. Wait ~10 min, then connect
aws ssm start-session --target <instance-id> --region us-east-1

# 4. Talk to it
openclaw tui
```

**Estimated monthly cost:** $50–150 depending on instance size and model usage. [Set budget alerts first.](#step-6-set-budget-alerts)

---

> **What is Loki?** Loki is an AI ops assistant builder powered by [OpenClaw](https://github.com/openclaw/openclaw) under the hood. You use the `openclaw` CLI to manage it, but the brain, skills, and personality are all Loki. Think of OpenClaw as the engine, Loki as the car.

## Before You Start

### ⚠️ Important Warnings

1. **Use a dedicated AWS account.** Loki gets `AdministratorAccess` on the EC2 instance. This is intentional — it needs broad access to manage AWS resources on your behalf. But it means you should **never deploy this in a production account with existing workloads.** Use a clean sandbox account, ideally inside an AWS Organizations setup with SCPs limiting blast radius.

2. **Set budget alerts before deploying.** AI model API calls (Bedrock) can add up. A busy Opus 4 session can cost $5-20/day. Set a $100/month alert at minimum. See [Step 6](#step-6-set-budget-alerts).

3. **This is an always-on service.** The EC2 instance runs 24/7. A `t4g.medium` costs ~$25/month, `t4g.xlarge` ~$100/month. Stop the instance when not in use to save costs.

4. **Review what you're deploying.** The template is open source — read it before running. It creates a VPC, EC2 instance, IAM roles, Lambda functions, and enables security services.

### What You Need

- **AWS account** with admin access (IAM user or SSO with AdministratorAccess)
- **AWS CLI** installed and configured (`aws configure`)
- **Bedrock model access** — the template auto-submits the use case form, but model activation can take ~15 minutes after first deployment
- **AWS CLI**

### Recommended: AWS Organizations Sandbox

The safest deployment pattern:

1. Create an AWS Organization (if you don't have one)
2. Create a **Sandbox OU** (Organizational Unit) with restrictive SCPs
3. Provision a new account inside the Sandbox OU
4. Deploy Loki in that account

This way, even if something goes wrong, the blast radius is limited to a throwaway sandbox account. The rest of your organization is protected by SCPs.

---

## Step 1: Prepare Your AWS Account

### Verify Bedrock Access

Bedrock model access varies by region. The template defaults to `us-east-1` which has the widest model selection.

```bash
# Check if you can invoke models (should return a response, not an error)
aws bedrock list-foundation-models --region us-east-1 --query 'modelSummaries[?contains(modelId, `anthropic`)].modelId' --output text | head -5
```

If you see models listed, you're good. If you get an access error, you may need to:
1. Go to **Bedrock Console → Model access → Manage model access**
2. Enable the Anthropic Claude models
3. Wait ~15 minutes for activation

The deployment template also auto-submits the Bedrock use case form, so this may resolve itself during deployment.

### Choose an Instance Size

| Size | vCPU | RAM | Monthly Cost* | Best For |
|------|------|-----|---------------|----------|
| `t4g.medium` | 2 | 4GB | ~$25 | Light use, testing, single user |
| `t4g.large` | 2 | 8GB | ~$50 | Regular use, small team |
| `t4g.xlarge` | 4 | 16GB | ~$100 | Production, heavy use, parallel agents |

*Approximate US East pricing. Actual costs vary by region.

All instances are ARM64 Graviton — better price/performance than x86.

---

## Step 2: Choose a Deployment Method

Deployment is CloudFormation-based, via the AWS Console or the AWS CLI:

| Method | Best For | Docs |
|--------|----------|------|
| **CloudFormation** | AWS Console users, CLI users, StackSets, Organizations | [deploy/cloudformation/](../deploy/cloudformation/) |

**Recommendation for new users:** Use CloudFormation via the AWS Console. Upload the template, fill in the form, click Create. No CLI needed.

---

## Step 3: Deploy

### CloudFormation via Console or CLI

**Via AWS Console (no CLI needed):**
1. Download [`deploy/cloudformation/template.yaml`](../deploy/cloudformation/template.yaml)
2. Open the [CloudFormation Console](https://console.aws.amazon.com/cloudformation/home#/stacks/create)
3. Choose "Upload a template file" → select the downloaded file
4. Fill in parameters:
   - **Environment Name:** a short name like `my-openclaw`
   - **Instance Size:** `t4g.medium` for testing, `t4g.xlarge` for production
   - Everything else can stay default
5. Click through, acknowledge IAM capabilities, and **Create stack**
6. Wait ~8-10 minutes for `CREATE_COMPLETE`

**Via CLI:**
```bash
aws cloudformation create-stack \
  --stack-name my-openclaw \
  --template-body file://deploy/cloudformation/template.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=my-openclaw \
    ParameterKey=InstanceType,ParameterValue=t4g.medium \
    ParameterKey=ProfileName,ParameterValue=builder \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# Watch progress
aws cloudformation wait stack-create-complete --stack-name my-openclaw --region us-east-1
```

## Step 4: Connect and Verify

### Get Your Instance ID

**CloudFormation:**
```bash
aws cloudformation describe-stacks --stack-name my-openclaw \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text
```

### Connect via SSM Session Manager

```bash
aws ssm start-session --target <instance-id> --region us-east-1
```

> **Why SSM, not SSH?** SSH requires opening port 22 to the internet (security risk) and managing key pairs. SSM works through the AWS API — no open ports, no keys to manage, full audit trail in CloudTrail. The template disables SSH by default for this reason.

### Check Loki Status

Once connected:
```bash
loki gateway
```

You should see the gateway as `running` and the model configured.

### Talk to It

```bash
openclaw tui
```

This opens the terminal UI where you can chat directly with your Loki instance.

---

## Step 5: Set Up a Chat Channel

Loki supports Telegram, Discord, Slack, Signal, and more. To connect a chat channel:

```bash
openclaw configure
# Select "Channels" and follow the wizard
```

**Recommended for getting started:** Telegram is the easiest to set up — create a bot via [@BotFather](https://t.me/BotFather), get the token, paste it in the wizard.

---

## Step 6: Set Budget Alerts

**Do this before anything else.** AI model costs can surprise you.

### Quick Budget Setup

```bash
# Create a $100/month budget with email alerts at 50%, 80%, and 100%
aws budgets create-budget \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget '{
    "BudgetName": "Loki Monthly",
    "BudgetLimit": {"Amount": "100", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[
    {"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":50},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"YOUR-EMAIL@EXAMPLE.COM"}]},
    {"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"YOUR-EMAIL@EXAMPLE.COM"}]},
    {"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":100},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"YOUR-EMAIL@EXAMPLE.COM"}]}
  ]'
```

Replace `YOUR-EMAIL@EXAMPLE.COM` with your actual email.

### Cost Breakdown

| Component | Estimated Monthly Cost |
|-----------|----------------------|
| EC2 `t4g.medium` (24/7) | ~$25 |
| EC2 `t4g.xlarge` (24/7) | ~$100 |
| EBS volumes (40GB root + 80GB data) | ~$10 |
| Bedrock (Claude Opus, moderate use) | $30–100 |
| Bedrock (Claude Opus, heavy use) | $100–500+ |
| Security services (GuardDuty, etc.) | ~$5 |
| **Typical total (light use)** | **$60–80** |
| **Typical total (heavy use)** | **$200–400** |

**Cost-saving tips:**
- Stop the EC2 instance when not using it (`aws ec2 stop-instances --instance-ids <id>`)
- Use `t4g.medium` for testing, upgrade later if needed
- Use Claude Sonnet instead of Opus for less critical tasks (5-10x cheaper)

---

## Security Best Practices

### Why AdministratorAccess?

Loki's value comes from being able to manage AWS resources on your behalf — creating Lambda functions, deploying CloudFormation stacks, managing IAM, etc. This requires broad permissions.

**Mitigations the template provides:**
- Deploys in an **isolated VPC** — no access to your other networks
- **SSH disabled by default** — SSM Session Manager is the only access path
- **Security services auto-enabled** — GuardDuty, SecurityHub, Inspector, Access Analyzer, and Config are all turned on by the deployment
- **Encrypted EBS volumes** — both root and data volumes use EBS encryption
- **Config files secured** — `chmod 600` on config, `chmod 700` on state directories
- **Gateway binds to localhost** — the Loki API is not exposed to the network

### What You Should Do

1. **Deploy in a dedicated account** — not your production account
2. **Use AWS Organizations with SCPs** — limit what the account can do (e.g. prevent creating new IAM users outside the account, restrict regions)
3. **Set budget alerts** — see [Step 6](#step-6-set-budget-alerts)
4. **Review GuardDuty findings** — the template enables GuardDuty. Check the console periodically for suspicious activity
5. **Don't install unknown skills** — Loki's [ClawhHub](https://clawhub.com) marketplace has community skills. Treat them like npm packages — review before installing, don't blindly trust them
6. **Keep Loki updated** — run `openclaw update` periodically for security patches

### Why Is It Locked Down by Default?

- **No SSH** — reduces attack surface. SSM is more secure (no open ports, IAM-authenticated, CloudTrail logged)
- **No public API** — the Loki gateway only listens on localhost. To expose it, you'd need to explicitly configure a reverse proxy
- **No ClawhHub skills pre-installed** — the base install has no third-party code. You choose what to add
- **Security services enabled** — GuardDuty and Inspector are watching from minute one

---

## FAQ

### How long does deployment take?
About 8-10 minutes. The stack creates in ~3 minutes, then the EC2 instance takes another 5-7 minutes to bootstrap (install Node.js, Loki (via OpenClaw), configure the gateway).

### Can I deploy in a region other than us-east-1?
Yes — change the `BedrockRegion` parameter. However, `us-east-1` has the widest Bedrock model selection. The EC2 instance can be in any region, but Bedrock API calls go to the region you specify.

### What if Bedrock model access isn't working?
The template auto-submits the Bedrock use case form. Model activation can take up to 15 minutes. If it still doesn't work after 15 minutes:
1. Go to **Bedrock Console → Model access**
2. Click **Manage model access**
3. Enable Anthropic Claude models manually
4. Wait 5-10 minutes

### Can I use my own Anthropic API key instead of Bedrock?
Yes — set `ModelMode` to `api-key` and provide your key in `ProviderApiKey`. This bypasses Bedrock entirely and calls the Anthropic API directly.

### Can I use a LiteLLM proxy?
Yes — set `ModelMode` to `litellm`, provide the proxy URL in `LiteLLMBaseUrl`, and the API key in `LiteLLMApiKey`.

### How do I update Loki?
SSH/SSM into the instance and run:
```bash
openclaw update
```
Or from within a chat session, ask Loki to update itself.

### How do I stop/start the instance to save costs?
```bash
# Stop (preserves data, stops billing for compute)
aws ec2 stop-instances --instance-ids <id> --region us-east-1

# Start (resumes from where it was)
aws ec2 start-instances --instance-ids <id> --region us-east-1
```

The data volume persists across stop/start. Loki's gateway auto-starts on boot.

### How do I delete everything?
**CloudFormation:**
```bash
aws cloudformation delete-stack --stack-name my-openclaw --region us-east-1
```

This removes all resources. The data volume has `DeleteOnTermination: false` — you'll need to delete it manually if you want to remove all data.

### Is my data safe?
- EBS volumes are encrypted at rest
- The gateway only listens on localhost (not exposed to the internet)
- No data is sent anywhere except to the AI model provider you configure (Bedrock, Anthropic, or LiteLLM)
- Loki stores conversation history locally on the instance

### What security services are enabled?
- **GuardDuty** — threat detection for malicious activity
- **Security Hub** — security posture dashboard
- **Inspector** — vulnerability scanning for the EC2 instance
- **IAM Access Analyzer** — finds resources shared outside the account
- **AWS Config** — configuration compliance recording

### Should I install skills from ClawhHub?
Treat ClawhHub skills like any third-party code — they can execute shell commands, read files, and make API calls. Only install skills from trusted sources, and review the SKILL.md file before installing. The default deployment has no third-party skills installed.

---

## Troubleshooting

### Stack creation failed

Check the events:
```bash
aws cloudformation describe-stack-events --stack-name my-openclaw \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].{Resource:LogicalResourceId,Reason:ResourceStatusReason}' \
  --output table
```

Common causes:
- **VPC limit reached** — default is 5 VPCs per region. Delete unused VPCs or request a limit increase.
- **Bedrock not available** — some regions don't have Bedrock. Use `us-east-1`.

### Instance is running but Loki isn't responding

Check the setup log:
```bash
aws ssm get-parameter --name /openclaw/setup-status --query Parameter.Value --output text
# Should be "COMPLETE"

# If IN_PROGRESS, the bootstrap is still running. Wait a few minutes.
# If it never reaches COMPLETE, check the full log:
aws ssm get-parameter --name /openclaw/setup-log --query Parameter.Value --output text
```

### Can't connect via SSM

Make sure:
1. The instance has the `AmazonSSMManagedInstanceCore` policy (the template includes this)
2. Your IAM user/role has `ssm:StartSession` permission
3. You have the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) installed locally
4. The instance is in a public subnet with internet access (the template creates this)

### Model invocations failing

```bash
# Test Bedrock directly from the instance
aws bedrock-runtime invoke-model \
  --model-id us.anthropic.claude-sonnet-4-6 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":10,"messages":[{"role":"user","content":"Say OK"}]}' \
  --content-type application/json --accept application/json \
  --region us-east-1 /tmp/test.json && cat /tmp/test.json
```

If this fails, check Bedrock model access in the console.
