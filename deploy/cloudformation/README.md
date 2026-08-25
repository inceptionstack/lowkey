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

- New VPC: always created and owned by the stack (`CreateVpcBpaExclusion` is ignored).
- Reused VPC with `CreateVpcBpaExclusion=true`: created with `DeletionPolicy: Retain` / `UpdateReplacePolicy: Retain`, so it survives stack deletion.
- Reused VPC with `CreateVpcBpaExclusion=false`: nothing is created; the VPC must already have a complete `allow-bidirectional` exclusion.

Reusing a VPC that already has one **requires** `CreateVpcBpaExclusion=false`, or the stack fails trying to create a duplicate. UserData revalidates the exclusion before running any pack and aborts if it is missing.

## Next Steps

See [Next Steps After Deployment](../README.md#next-steps-after-deployment) for bootstrap scripts setup.
