# CloudFormation Deployment

Deploy Loki using a standard AWS CloudFormation template.

## Quick Start (Console)

1. Download `template.yaml`
2. Open the [CloudFormation Console](https://console.aws.amazon.com/cloudformation/home#/stacks/create)
3. Upload the template
4. Fill in parameters (defaults work for most setups)
5. Acknowledge IAM capabilities and create the stack
6. Wait for `CREATE_COMPLETE` (~8–10 minutes)

## Quick Start (CLI)

```bash
aws cloudformation create-stack \
  --stack-name my-openclaw \
  --template-body file://template.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=my-openclaw \
    ParameterKey=InstanceType,ParameterValue=t4g.xlarge \
    ParameterKey=ProfileName,ParameterValue=builder \
    ParameterKey=ModelMode,ParameterValue=bedrock \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
    # Security (all default true — set false for test deploys):
    # ParameterKey=EnableSecurityHub,ParameterValue=false \
    # ParameterKey=EnableGuardDuty,ParameterValue=false \
    # ParameterKey=EnableInspector,ParameterValue=false \
    # ParameterKey=EnableAccessAnalyzer,ParameterValue=false \
    # ParameterKey=EnableConfigRecorder,ParameterValue=false \
    # ParameterKey=LokiWatermark,ParameterValue=my-team \
```

## StackSet Deployment (Organizations)

This template is designed to work with CloudFormation StackSets for deploying across AWS Organization accounts:

```bash
aws cloudformation create-stack-set \
  --stack-set-name openclaw-instances \
  --template-body file://template.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=openclaw \
    ParameterKey=ModelMode,ParameterValue=bedrock \
  --capabilities CAPABILITY_NAMED_IAM \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false

aws cloudformation create-stack-instances \
  --stack-set-name openclaw-instances \
  --deployment-targets OrganizationalUnitIds=ou-xxxx-xxxxxxxx \
  --regions us-east-1
    # Security (all default true — set false for test deploys):
    # ParameterKey=EnableSecurityHub,ParameterValue=false \
    # ParameterKey=EnableGuardDuty,ParameterValue=false \
    # ParameterKey=EnableInspector,ParameterValue=false \
    # ParameterKey=EnableAccessAnalyzer,ParameterValue=false \
    # ParameterKey=EnableConfigRecorder,ParameterValue=false \
    # ParameterKey=LokiWatermark,ParameterValue=my-team \
```

## Outputs

| Output | Description |
|--------|-------------|
| `InstanceId` | EC2 instance ID |
| `PublicIp` | Public IP address |
| `SSMConnect` | Ready-to-use SSM connect command |
| `RoleArn` | IAM role ARN |
| `VpcId` | VPC ID |

## Notes

- Stack creation takes ~8–10 minutes (EC2 bootstrap installs Node.js, Loki, and configures the gateway)
- The `CreationPolicy` with `ResourceSignal` ensures the stack only completes when the instance is fully bootstrapped
- Requires `CAPABILITY_NAMED_IAM` due to named IAM roles and users

## VPC Block Public Access exclusion

The stack creates a VPC-wide `allow-bidirectional` VPC Block Public Access exclusion so bootstrap egress and public endpoints keep working when BPA is enabled. This exempts the **entire VPC** for internet ingress and egress, not only the LowKey instance.

| `ExistingVpcId` | `CreateVpcBpaExclusion` | Behavior |
|---|---|---|
| empty (new VPC) | `true` | Stack-owned exclusion, deleted with the stack |
| empty (new VPC) | `false` | Same as `true` — ignored, because a new VPC always needs one |
| set (reused VPC) | `true` | Created with `DeletionPolicy: Retain` / `UpdateReplacePolicy: Retain`, so it survives stack deletion |
| set (reused VPC) | `false` | Nothing created; the VPC must already have a complete `allow-bidirectional` exclusion |

Reusing a VPC that already has one **requires** `CreateVpcBpaExclusion=false`, or the stack fails trying to create a duplicate. UserData revalidates the exclusion before running any pack and aborts if it is missing.

Cleanup, once no deployment needs that VPC exempt:

```bash
aws ec2 describe-vpc-block-public-access-exclusions \
  --query 'VpcBlockPublicAccessExclusions[].[ExclusionId,ResourceArn,State]' --output text
aws ec2 delete-vpc-block-public-access-exclusion --exclusion-id <id>
```

> **Warning**
> A **new-VPC** exclusion is stack-owned and deleted with its stack. If another LowKey deployment was later pointed at that same VPC, deleting the first stack removes the exemption the second one depends on. Recreate an exclusion, or redeploy the remaining stack with `CreateVpcBpaExclusion=true`.

### Limitation: first 100 exclusions only

Exclusion discovery is deliberately not paginated. Both the installer and the instance-side check inspect only the **first 100** BPA exclusions in the region (`--max-results 100`). The default quota is well under that, so this is an accepted edge case for now.

If an account holds more than 100 exclusions and the target VPC's exclusion falls outside that first page:

- The installer treats it as absent and passes `CreateVpcBpaExclusion=true`, so CloudFormation attempts a duplicate and the stack fails with a create error.
- The instance-side check likewise does not see it and refuses to start pack bootstrap, so the deployment fails closed rather than running without internet access.

Workaround: pass `CreateVpcBpaExclusion=false` explicitly when you know the VPC already has a complete `allow-bidirectional` exclusion, or reduce the number of exclusions in the region.

## Next Steps

See [Next Steps After Deployment](../README.md#next-steps-after-deployment) for bootstrap scripts setup.
