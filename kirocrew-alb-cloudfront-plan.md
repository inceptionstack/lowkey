# KiroCrew ALB + CloudFront Plan

## Problem

KiroCrew gateway dashboard runs on port 5476 (EC2 public IP, plain HTTP).
Remote users access it at `http://<ip>:5476/?token=<token>`.

Issues:
- **No HTTPS** — login tokens travel in plaintext over the internet
- **Direct IP exposure** — no CDN, no DDoS protection, no caching
- **Port-based access** — some corporate firewalls block non-standard ports
- **No stable hostname** — IP changes on stop/start

## Architecture

```
User → CloudFront (HTTPS, *.cloudfront.net)
         → ALB (HTTPS, internal or internet-facing)
              → EC2 target (port 5476, HTTP)
```

### Why ALB (not direct CF → EC2)?
- Health checks (auto-remove unhealthy targets)
- HTTPS termination with ACM cert (free, auto-renewing)
- Security group isolation (EC2 only accepts ALB traffic)
- Future-proof: multi-instance, blue/green, WebSocket support

### Why CloudFront on top?
- Stable hostname (*.cloudfront.net or custom domain later)
- Global edge caching for static dashboard assets (JS/CSS/images)
- Free managed HTTPS certificate
- WAF integration (optional, for token brute-force protection)
- Header injection (x-origin-verify to lock ALB to CF-only traffic)

## Components to Add (all conditional on `IsKiroCrew`)

### 1. Second Public Subnet (ALB multi-AZ requirement)

ALB requires subnets in at least 2 AZs.

```yaml
KiroCrewSubnet2:
  Type: AWS::EC2::Subnet
  Condition: KiroCrewWithNewVpc
  Properties:
    VpcId: !Ref VPC
    CidrBlock: '10.0.2.0/24'  # or parameterized
    MapPublicIpOnLaunch: true
    AvailabilityZone: !Select [1, !GetAZs '']
    Tags:
      - Key: Name
        Value: !Sub '${EnvironmentName}-public-2'
```

Plus route table association to the existing public route table.

### 2. ALB Security Group

```yaml
KiroCrewALBSecurityGroup:
  Type: AWS::EC2::SecurityGroup
  Condition: IsKiroCrew
  Properties:
    GroupDescription: ALB for KiroCrew dashboard
    VpcId: !If [CreateNewVpc, !Ref VPC, !Ref ExistingVpcId]
    SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 443
        ToPort: 443
        CidrIp: '0.0.0.0/0'
        Description: HTTPS from CloudFront
      - IpProtocol: tcp
        FromPort: 80
        ToPort: 80
        CidrIp: '0.0.0.0/0'
        Description: HTTP redirect to HTTPS
```

### 3. ALB + Target Group + Listener

```yaml
KiroCrewALB:
  Type: AWS::ElasticLoadBalancingV2::LoadBalancer
  Condition: IsKiroCrew
  Properties:
    Scheme: internet-facing
    Type: application
    Subnets:
      - !Ref PublicSubnet
      - !Ref KiroCrewSubnet2
    SecurityGroups:
      - !Ref KiroCrewALBSecurityGroup

KiroCrewTargetGroup:
  Type: AWS::ElasticLoadBalancingV2::TargetGroup
  Condition: IsKiroCrew
  Properties:
    Port: 5476
    Protocol: HTTP
    VpcId: !If [CreateNewVpc, !Ref VPC, !Ref ExistingVpcId]
    TargetType: instance
    Targets:
      - Id: !Ref EC2Instance
    HealthCheckPath: /health  # or / — verify what kirocrew serves
    HealthCheckIntervalSeconds: 30
    HealthyThresholdCount: 2
    UnhealthyThresholdCount: 3

KiroCrewHTTPSListener:
  Type: AWS::ElasticLoadBalancingV2::Listener
  Condition: IsKiroCrew
  Properties:
    LoadBalancerArn: !Ref KiroCrewALB
    Port: 443
    Protocol: HTTPS
    Certificates:
      - CertificateArn: !Ref KiroCrewCertificate
    DefaultActions:
      - Type: forward
        TargetGroupArn: !Ref KiroCrewTargetGroup

KiroCrewHTTPRedirectListener:
  Type: AWS::ElasticLoadBalancingV2::Listener
  Condition: IsKiroCrew
  Properties:
    LoadBalancerArn: !Ref KiroCrewALB
    Port: 80
    Protocol: HTTP
    DefaultActions:
      - Type: redirect
        RedirectConfig:
          Protocol: HTTPS
          Port: '443'
          StatusCode: HTTP_301
```

### 4. ACM Certificate (for ALB)

Option A: **CloudFront-only HTTPS** (simpler, no custom domain needed)
- ALB uses HTTP listener only
- CloudFront terminates HTTPS and connects to ALB over HTTP
- Requires `x-origin-verify` header to prevent ALB bypass

Option B: **Full HTTPS chain** (ALB also has cert)
- Requires a custom domain + Route53 hosted zone (or DNS validation)
- More complex for a fresh install

**Recommendation: Option A** — CloudFront handles HTTPS, ALB is HTTP-only (port 80), locked down via origin-verify header. No custom domain required for initial setup.

Revised listener (Option A):
```yaml
KiroCrewHTTPListener:
  Type: AWS::ElasticLoadBalancingV2::Listener
  Condition: IsKiroCrew
  Properties:
    LoadBalancerArn: !Ref KiroCrewALB
    Port: 80
    Protocol: HTTP
    DefaultActions:
      - Type: forward
        TargetGroupArn: !Ref KiroCrewTargetGroup
```

ALB SG revised (Option A — only allow CloudFront IPs or use x-origin-verify):
```yaml
# Use AWS managed prefix list for CloudFront
SecurityGroupIngress:
  - IpProtocol: tcp
    FromPort: 80
    ToPort: 80
    SourcePrefixListId: pl-3b927c52  # com.amazonaws.global.cloudfront.origin-facing
    Description: HTTP from CloudFront only
```

### 5. CloudFront Distribution

```yaml
KiroCrewOriginVerifySecret:
  Type: AWS::SecretsManager::Secret
  Condition: IsKiroCrew
  Properties:
    Name: !Sub '/lowkey/${EnvironmentName}/kirocrew-origin-verify'
    GenerateSecretString:
      ExcludePunctuation: true
      PasswordLength: 32

KiroCrewDistribution:
  Type: AWS::CloudFront::Distribution
  Condition: IsKiroCrew
  Properties:
    DistributionConfig:
      Enabled: true
      Comment: !Sub 'KiroCrew dashboard (${EnvironmentName})'
      DefaultCacheBehavior:
        TargetOriginId: kirocrew-alb
        ViewerProtocolPolicy: redirect-to-https
        AllowedMethods: [GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE]
        CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad  # CachingDisabled
        OriginRequestPolicyId: 216adef6-5c7f-47e4-b989-5492eafa07d3  # AllViewer
      Origins:
        - Id: kirocrew-alb
          DomainName: !GetAtt KiroCrewALB.DNSName
          CustomOriginConfig:
            OriginProtocolPolicy: http-only
            HTTPPort: 80
          OriginCustomHeaders:
            - HeaderName: x-origin-verify
              HeaderValue: !Sub '{{resolve:secretsmanager:${KiroCrewOriginVerifySecret}}}'
      ViewerCertificate:
        CloudFrontDefaultCertificate: true
      HttpVersion: http2and3
```

### 6. EC2 Security Group Change

Remove the current `0.0.0.0/0:5476` ingress rule. Replace with ALB-SG-only:

```yaml
- !If
  - IsKiroCrew
  - IpProtocol: tcp
    FromPort: 5476
    ToPort: 5476
    SourceSecurityGroupId: !Ref KiroCrewALBSecurityGroup
    Description: KiroCrew gateway from ALB only
  - !Ref 'AWS::NoValue'
```

### 7. KiroCrew Gateway: Validate x-origin-verify Header

The kirocrew gateway needs to reject requests that don't carry the correct
`x-origin-verify` header. Two options:

**Option A (app-level):** KiroCrew gateway checks the header itself.
- Requires pack install to configure the secret value in kirocrew config
- May not be supported by the kirocrew binary

**Option B (ALB rule):** Not applicable since ALB is forwarding, not blocking.

**Option C (SG-only, simplest):** Rely on SG to block direct access.
CloudFront prefix list ensures only CF can reach ALB on port 80.
SG ensures only ALB can reach EC2 on port 5476.
Two-hop chain = sufficient isolation without app-level header checking.

**Recommendation: Option C + x-origin-verify as defense-in-depth.**
If kirocrew supports custom middleware/header checks, wire it up. Otherwise,
SG chain is the primary security layer.

## Conditions

```yaml
KiroCrewWithNewVpc: !And [!Condition IsKiroCrew, !Condition CreateNewVpc]
```

For existing VPC case, user must provide a second subnet (or we auto-discover
via `!GetAZs` and fail gracefully if only 1 AZ is available).

## Outputs

```yaml
KiroCrewDashboardUrl:
  Condition: IsKiroCrew
  Value: !Sub 'https://${KiroCrewDistribution.DomainName}'
  Description: KiroCrew dashboard URL (CloudFront HTTPS)
```

## Changes to install.sh (post-install output)

Update the post-install notice in `packs/kirocrew/install.sh` to show the
CloudFront URL instead of (or in addition to) the raw IP URL. The CF domain
can be passed via SSM parameter or resolved from stack outputs.

## Changes to Main install.sh

The CloudFront URL should be displayed in the deploy summary/completion output.
Read it from the stack outputs after deploy completes.

## File Summary

| File | Change |
|------|--------|
| `deploy/cloudformation/template.yaml` | Add: second subnet, ALB SG, ALB, TG, listener, CF distribution, origin-verify secret, conditions, outputs. Modify: EC2 SG rule (ALB-only). |
| `packs/kirocrew/install.sh` | Update post-install notice to show CF URL |
| `install.sh` | Display CF dashboard URL after successful deploy |

## Security Notes

- No port 5476 exposed to internet (ALB-SG-only)
- HTTPS for all user-facing traffic (CloudFront edge)
- Origin-verify header prevents ALB bypass
- Token auth still active (kirocrew's built-in auth layer)
- With HTTPS, tokens in URL query strings are encrypted in transit
- CloudFront prefix list restricts ALB ingress to CF edge IPs only

## Resolved Questions

1. **Health check path** — `/health` (per kiro.dev/docs/crew/running-24-7 + pack PLAN.md)
2. **WebSocket support** — YES. Caching disabled on all behaviors (CachingDisabled policy). ALB + CF both support WS upgrade pass-through with cache disabled.
3. **Existing VPC** — Auto-discover AZs from provided subnet's VPC.
4. **Custom domain** — No. Use `*.cloudfront.net` (d-prefix domain).
5. **WAF** — Future iteration.
