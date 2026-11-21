# Spend Control — Initial Technical Design

**Status:** Draft for review<br>
**Target:** LowKey single-account deployments<br>
**Last updated:** 2026-08-27

## 1. Summary

LowKey should provide an optional, same-account spend-control system that observes
resource lifecycle changes, maintains a conservative local estimate of monthly
liability, and freezes agent-driven spending before the configured monthly cap is
expected to be exceeded.

The initial system combines three layers:

1. **Preventive guardrails** constrain the maximum rate and kinds of spend the agent
   can create.
2. **Rapid reconciliation** consumes CloudTrail-backed EventBridge events, resolves
   current resource state, and recalculates projected liability.
3. **Delayed independent backstops** consume AWS billing metrics and AWS Budgets
   notifications in case the local resource model misses a charge.

A CloudFront-hosted, Cognito-authenticated control application lets the account
owner inspect projections, change policy, freeze immediately, and issue an audited,
time-limited release or override. The control plane runs in the same AWS account as
the LowKey deployment but uses separate protected IAM roles and resources.

This design is a **bounded-risk circuit breaker**, not a promise that an AWS invoice
can never exceed an exact dollar amount. CloudTrail delivery and AWS billing data are
not synchronous, some usage-based charges cannot be inferred from resource creation,
and taxes or late billing adjustments are outside LowKey's control. A strict bound is
possible only for spend paths that are synchronously admitted or capped by a known
maximum.

## 2. Problem

The current `builder` profile attaches AWS managed `AdministratorAccess` to the
LowKey EC2 instance role. This is intentionally powerful enough to build complicated
prototypes, but an autonomous agent can accidentally:

- create an expensive resource shape;
- scale an existing service far beyond its intended capacity;
- start a recursive or externally amplified usage path;
- leave hourly resources running after an experiment;
- purchase a commitment or enable a service with persistent minimum charges; or
- disable a cost control that shares the same account.

AWS Budgets and Cost Explorer cannot be the primary breaker. Their cost data is
delayed, so remediation can begin hours after the underlying usage occurred. A
same-account system must instead reason about what the account has already incurred
and what its current resources are still able to incur.

## 3. Goals

1. Let a LowKey builder continue to provision non-trivial AWS prototypes.
2. Support a configurable account-level monthly cap, such as USD 500.
3. Detect create, update, scale, start, stop, and delete transitions across enabled
   AWS Regions.
4. Maintain conservative estimates for accrued spend, remaining committed liability,
   and projected month-end spend.
5. Prevent additional agent-driven spend and hibernate supported resources when the
   projection exhausts available headroom.
6. Notify a verified owner by email and publish a stable EventBridge integration
   event on every material state transition.
7. Provide an authenticated web control plane for inspection, policy changes,
   emergency freeze, temporary override, and release.
8. Keep the control plane operational while agent and workload permissions are
   frozen.
9. Reconcile with delayed AWS billing data without making it the critical path.
10. Make unsupported or unpriced resources visible rather than silently treating
    them as free.

## 4. Non-goals and guarantee boundary

The initial feature does not:

- guarantee a final invoice amount including taxes, support-plan charges, credits,
  refunds, or late billing adjustments;
- make CloudTrail an exactly-once or real-time event stream;
- infer an upper bound for arbitrary data transfer, public traffic, or API usage
  without a corresponding quota or metering gateway;
- protect against the account root user or a separate administrator deliberately
  removing the controls;
- automatically delete customer data solely to meet a cap;
- provide multi-account organization management; or
- replace AWS Cost Explorer, AWS Budgets, or Cost Anomaly Detection.

Strict mode is an admission-control and circuit-breaker capability, not an invoice
cap. It may publish a bounded residual-liability claim only when every billable path
in scope is synchronously admitted or protected by a documented service-side maximum,
every calling identity is protected, pricing is complete and fresh, and the event,
inventory, and remediation paths are healthy.

> Under those preconditions, strict mode prevents new admitted operations after the
> controller commits `FROZEN` and records the maximum remaining liability from
> in-flight work, fixed charges, retained storage, commitments, and enforcement delay.
> It does not cancel work already accepted by a service, remove fixed charges, bound
> taxes or late adjustments, or govern root, external administrators, external
> provider credentials, or unprotected account identities.

If any precondition is false or unknown, the account is `UNSAFE` or
`ESTIMATE_INCOMPLETE`. Strict mode must deny new paid operations or remain unavailable;
it must never turn an unknown path into zero cost. Observe-only mode may continue to
report estimates but makes no hard safety claim.

## 5. Constraints from the current LowKey implementation

- LowKey is single-account by design.
- The primary deployment is one CloudFormation stack in a selected Region.
- The current `builder` instance role has `AdministratorAccess`.
- Managed resources normally carry `loki:managed=true`, `loki:watermark`, and
  `loki:pack` tags, but prototypes created by the agent are not currently guaranteed
  to carry those tags.
- The instance role is named `${EnvironmentName}-role` and is attached through an
  EC2 instance profile.
- The deployment already has patterns for CloudFront, Cognito, Lambda@Edge,
  EventBridge, SQS, Lambda, and security-service enablement.
- The control plane must be deployed in the same account and its own maximum cost
  must count against the cap.

### 5.1 AdministratorAccess incompatibility

A spend controller cannot be tamper-resistant while the agent retains unconstrained
`AdministratorAccess`. The existing `builder` profile is therefore a compatibility
and monitoring profile. Attaching a deny after deployment does not make it strict,
and the UI must not display a bounded-liability claim for this profile.

Strict enforcement requires one of these roots of trust:

1. **Controlled builder:** create a separate `controlled_builder` role with the
   approved permissions boundary and permanent guard policy before the instance
   receives credentials. Every generated workload role carries the same boundary.
2. **Provisioning and runtime broker:** the agent cannot directly assume a deployment
   role or invoke paid paths. A protected controller admits CloudFormation change sets
   and runtime leases against reserved headroom.
3. **External root:** an Organizations SCP or controller in a separate security
   account protects the guard from same-account administrators.

Models 1 and 2 protect against the LowKey agent, not root or an independent
same-account administrator. Any product claim that includes those actors requires
model 3.

### 5.2 Root of trust and deployment order

Strict-mode controller, policy, trail, ledger, recovery, and guard resources are
provisioned before the agent obtains AWS credentials. The boundary is attached during
role creation, never as a later reconciliation step. Controller stacks use termination
protection, a restrictive stack policy, retained audit state, and a deployer-owned
break-glass role that the agent cannot assume or pass.

The agent cannot invoke or reconfigure controller Lambdas, state machines, queues,
rules, Cognito resources, edge authentication, or their execution roles. Existing
custom-resource patterns must be hardened before reuse: wildcard SSM command roles,
caller-controlled secret ARNs, shell interpolation, and masked setup failures are not
valid strict-mode primitives. Protected resources in the deployment Region and
`us-east-1` are treated as one recovery domain.

## 6. Cost basis and terminology

The configured cap is denominated in USD and internally stored as integer USD
microunits, never binary floating point.

The initial accounting basis is conservative **gross pre-tax usage before credits,
refunds, or discounts**. Fixed support, Marketplace, domain, Savings Plan, Reserved
Instance, and similar commitments must either be denied in strict mode or represented
as fixed reservations.

The ledger exposes four distinct values:

- **AWS-reported MTD:** delayed amount reported by AWS billing services.
- **Locally estimated accrued:** usage that the local meters estimate has already
  occurred this billing month.
- **Committed liability:** maximum additional cost permitted by active leases,
  provisioned capacity, and granted runtime allowances.
- **Projected month-end:** locally accrued plus remaining committed liability,
  month-end storage, and fixed control-plane reserve.

The admission calculation is:

```text
available headroom =
    configured monthly cap
  - locally estimated accrued
  - committed liability
  - fixed and shutdown reserve
  - uncertainty reserve
```

All arithmetic is deterministic code using decimal or integer units. The language
model never calculates billing amounts.

## 7. Architecture

```text
                         same LowKey AWS account

  Regional default EventBridge buses (all enabled Regions)
       CloudTrail API calls / service state events / Config changes
                              │
                              ▼
                 home-Region custom event bus
                              │
                              ▼
                  ResourceEventQueue + DLQ
                              │
                              ▼
                    Resource reconciler
                   ┌──────────┴──────────┐
                   │ Describe live state │
                   │ Resource adapters   │
                   │ Price manifest      │
                   └──────────┬──────────┘
                              ▼
             DynamoDB inventory and liability ledger
                              │
                              ▼
                 Conditional state transition
       NORMAL → WARNING → THROTTLED → RECONCILING → FROZEN
                     ↘ UNSAFE / ESTIMATE_INCOMPLETE
                              │
                 DynamoDB Stream / outbox
          ┌───────────────────┼────────────────────┐
          ▼                   ▼                    ▼
  Freeze Step Functions   SNS verified email   EventBridge customer event
          │
          ├─ attach explicit deny / revoke sessions
          ├─ disable usage sources
          ├─ stop or scale supported resources
          └─ retry, record failures, and reconcile

  CloudFront + private S3 SPA
             │
      Cognito authentication
             │
             ▼
  API Gateway + control API Lambda ──► policy/state tables
```

### 7.1 Home Region

The deployment Region is the spend-control home Region. It contains the custom event
bus, queues, tables, Lambdas, Step Functions state machine, API, and Cognito resources.

CloudTrail-backed EventBridge rules must exist in every enabled Region and forward
matching events to the home-Region bus. Global IAM, STS, Organizations, account, and
billing control events require explicit handling in `us-east-1` where applicable.
The installer records the enabled Region set and a scheduled reconciler periodically
checks for newly enabled Regions.

The control plane remains regional in the initial design. Preventive quotas and
permissions remain active during a home-Region outage. Strict mode fails closed after
a bounded health window by entering `UNSAFE` and denying new paid operations; whether
it also executes regional shutdown actions is a product policy. Observe-only mode may
continue with an explicit stale-controller warning.

## 8. Event ingestion and reconciliation

### 8.1 Delivery semantics

AWS service events delivered through CloudTrail are best effort. EventBridge and SQS
can redeliver events, and events from different Regions or services can arrive out of
order. Therefore an event is an **invalidation signal**, not an accounting delta.

The worker must:

1. deduplicate by CloudTrail `eventID` or a deterministic service-event key;
2. identify candidate resources from the event;
3. call the service's `Describe`, `Get`, or `List` API;
4. normalize the current state through a resource adapter;
5. write the observed state and adapter version conditionally;
6. recalculate liability from authoritative state; and
7. trigger a budget transition only through a version-checked transaction.

Deletion is recorded only after the service confirms absence or a terminal deleted
state. Deletion releases future liability but never subtracts locally accrued spend.

Strict-mode readiness requires a verified multi-Region CloudTrail management-events
trail, global-service handling in `us-east-1`, healthy encrypted delivery, generated
EventBridge rules and targets in every enabled Region, queues and DLQs, and Bedrock
model invocation logging for every covered runtime path. Event History by itself is
not the EventBridge delivery path. Event age, delivery failures, DLQ depth, trail
status, logging coverage, and scheduled-inventory age are enforcement inputs.

CloudTrail and EventBridge remain best effort and have no product-level real-time SLA.
A missing trail, stale queue, disabled logging path, incomplete high-risk inventory,
or expired price manifest transitions strict mode to `UNSAFE`, `THROTTLED`, or
`FROZEN` according to fail-closed policy. The inventory interval and its residual
liability reserve must be published.

### 8.2 Queue design

Use an encrypted SQS Standard queue with:

- a dead-letter queue;
- a visibility timeout greater than the maximum worker duration;
- partial batch failure reporting;
- bounded Lambda concurrency;
- idempotency records with expiration;
- age-of-oldest-message and DLQ alarms; and
- no catch-and-return behavior for failed reconciliation.

FIFO is not required because source ordering is not guaranteed. Per-resource
serialization can use a DynamoDB conditional version if adapters need it.

### 8.3 Scheduled reconciliation

A scheduled inventory pass is mandatory because CloudTrail is not a complete or
hard-latency resource stream. The reconciler should:

- inspect all enabled Regions;
- discover supported resources regardless of tags;
- compare them with the ledger;
- detect missing, resized, restarted, or untagged resources;
- refresh prices and adapter versions; and
- mark unsupported resources as estimate gaps.

Frequency is configurable and must have a bounded API-call budget. Event-driven
processing remains the fast path.

## 9. CloudTrail event filtering

Event filtering covers successful and failed attempts that can change spend exposure,
control-plane integrity, or shutdown state. The CloudTrail `readOnly` field is a first
pass, not a semantic classifier: the empirical sample contains high-volume
`readOnly=false` SSM telemetry, Config evaluations, KMS grants, and even read-like IoT
operations that are not spend admissions.

Generate rules from a versioned, machine-readable catalog. Each entry records exact
`eventSource` and `eventName`, classification, priority, evidence status, Region
behavior, adapter, and whether the event is only a post-acceptance invalidation:

```yaml
event_source: ec2.amazonaws.com
event_names: [RunInstances]
classification: increase
priority: P0
evidence: observed-retained-14d
adapter: ec2-instance
control: synchronous-admission
regions: regional
```

Priorities are:

- **P0:** costly create/start/scale/restore operations needing synchronous admission,
  plus mutations to IAM, trails, event routing, quotas, budgets, and the controller;
- **P1:** lifecycle/configuration changes routed durably to describe-and-reconcile;
- **P2:** telemetry, service events, usage signals, and diagnostics that must not be
  mistaken for admitted cost.

Generate separate EventBridge groups:

1. `spend-control-admission` for P0 resource/capacity events. EventBridge observes an
   already accepted call, so a broker, SCP/IAM condition, quota, or lease must block it.
2. `spend-control-resource-change` for P1 inventory and liability reconciliation.
3. `spend-control-guardrail-integrity` for IAM, CloudTrail, EventBridge, quota,
   budget, anomaly-control, and controller mutations; send these to immutable audit.
4. `spend-control-failures-and-service-events` for failed attempts and
   `AwsServiceEvent` diagnostics.

The catalog classifications are `increase`, `decrease`, `configuration`,
`commitment`, `guardrail`, `usage-gate`, `usage-signal`, and `failed-attempt`.
Appendix B is the design baseline. Empirical frequency prioritizes adapters but never
defines completeness; unobserved high-risk events remain coverage-driven entries.

## 10. Resource adapter model

Each supported resource type implements a versioned adapter:

```text
matches(event) -> candidate identifiers
discover(identifier, region) -> normalized resource state
estimate(state, price manifest, billing clock) -> accrued and committed liability
freeze(state, policy) -> idempotent remediation actions
thaw(previous state, policy) -> safe restoration plan
```

Adapters classify resources as:

- **fixed:** predictable recurring charge;
- **leased:** bounded lifetime with an immutable expiry action;
- **metered:** usage-based and allowed only with a runtime allowance;
- **commitment:** persistent purchase, denied by default; or
- **unknown:** no safe estimate, blocked or explicitly reserved in strict mode.

Initial high-value adapters should cover:

- EC2 instances, EBS volumes/snapshots, Elastic IPs, NAT gateways, and VPC endpoints;
- ECS/Fargate services, Auto Scaling groups, and EKS control planes/node groups;
- Lambda functions, provisioned concurrency, and event source mappings;
- RDS/Aurora, ElastiCache, OpenSearch, and SageMaker endpoints/jobs;
- DynamoDB provisioned/on-demand maximum throughput;
- ALB/NLB, API Gateway, CloudFront, and WAF entry points;
- S3 storage/lifecycle and CloudWatch Logs retention;
- Bedrock invocation gateways, batch jobs, custom deployments, and provisioned
  throughput; and
- Marketplace, Savings Plans, Reserved Instances, domains, and support-plan changes.

Unknown resources cause `ESTIMATE_INCOMPLETE`. Strict mode moves to `THROTTLED` until
an owner supplies a reserve or the catalog gains an adapter.

## 11. Runtime usage controls

CloudTrail resource events alone cannot bound consumption-based spend. Strict mode
requires service-specific runtime controls:

- **Bedrock:** direct invocation is denied; a metering gateway reserves maximum input
  and output token liability before invoking, then refunds unused reservation.
- **Lambda:** maximum memory, timeout, reserved concurrency, provisioned concurrency,
  and event-source parallelism are constrained.
- **ECS/Auto Scaling:** maximum capacity is priced, not merely current desired count.
- **DynamoDB:** provisioned capacity or on-demand maximum throughput is recorded and
  protected from unauthorized increases.
- **Public APIs:** API Gateway/WAF throttles and workload concurrency bound externally
  induced requests.
- **Internet egress:** unrestricted public egress cannot carry a strict guarantee;
  strict mode requires an approved, metered route or an explicit egress reserve.
- **Logs and storage:** retention, object/volume limits, and producer throughput are
  part of the adapter model.

If direct Bedrock remains available to the agent, the feature can warn and freeze but
cannot pre-authorize each invocation.

### 11.1 Bedrock prior art and reuse boundary

The AWS sample
[`sample-bedrock-spend-budget-guardrails`](https://github.com/aws-samples/sample-bedrock-spend-budget-guardrails)
is useful prior art for a dedicated Bedrock adapter. It joins Bedrock model invocation
logs with CloudTrail identity by request ID, maintains per-principal spend in
DynamoDB, applies IAM denies from a stream, refreshes prices, offers a Cloudscape UI,
and reconciles with CUR. Its measured sub-30-second p95 applies to its tested path; it
is neither an AWS delivery SLA nor an account-wide sub-two-minute guarantee.

Coverage follows the endpoint, not the model name:

| Path | Strict-mode disposition |
|---|---|
| `bedrock-runtime` `InvokeModel`, streaming, `Converse`, `ConverseStream` | Reuse the sample's identity/usage join, but require synchronous allowance reservation and a complete frozen deny |
| Selected `bedrock-agent-runtime` invocation/retrieval paths | Explicitly meter and deny, or block |
| Bedrock guardrails, flows, inline agents, batch jobs, and provisioned throughput | Add path-specific accounting and denial, or block |
| `bedrock-mantle:CreateInference` | Deny by default; the sample does not meter or enforce it and Mantle is absent from model invocation logging |
| LiteLLM, direct Anthropic/OpenAI, and standalone Codex/API-key paths | Outside an AWS-account cap unless forced through a separately controlled gateway |
| Bedrock API-key authentication | Outside ordinary IAM session revocation unless the key lifecycle is governed separately |

This is a current LowKey blocker, not a theoretical edge case: Troika configures a
Mantle model, and the deployment supports LiteLLM and direct provider credentials.
A deny on `bedrock:*` does not cover the different `bedrock-mantle` IAM prefix.
Per-principal inference denial also does not stop infrastructure that continues to
bill after its creating principal is frozen.

LowKey should adapt the sample for covered Bedrock runtime calls, not generalize it
into an all-service meter. Other adapters need authoritative usage metrics,
provisioned-capacity bounds, or synchronous admission. Counting API calls is
insufficient for token-, duration-, byte-, tier-, or routing-dependent prices. One
pre-created account-level freeze policy is preferable to generating a policy per
target and period.

Monthly rollover recalculates account exposure and unresolved liability before any
release. It never detaches a deny solely because the UTC month changed.

## 12. Budget state machine

| State | Agent behavior | Resource behavior | Exit |
|---|---|---|---|
| `NORMAL` | Allowed by the configured catalog | Normal | Projection reaches warning threshold |
| `WARNING` | Allowed; UI and email warn | Normal | Headroom recovers or throttle threshold is reached |
| `THROTTLED` | No new resources, starts, scale-up, commitments, or quota increases | Existing bounded workloads continue | Safe reconciliation or freeze condition |
| `RECONCILING` | New paid operations denied | Inventory, pricing, and prior-period liabilities reconcile | Explicit transition to `NORMAL`, `THROTTLED`, or `FROZEN` |
| `FROZEN` | Explicit deny for writes and paid invocations; approved diagnostics only | Freeze recipes execute and retry | Owner-approved release after all release invariants pass |
| `UNSAFE` / `ESTIMATE_INCOMPLETE` | New paid operations denied; strict mode unavailable | Policy may freeze supported resources | Coverage and estimates become complete, then reconcile |

`OVERRIDE` is an orthogonal, versioned lease over a base state, not a peer state. It
specifies amount, scope, reason, approver, and expiration. Expiration from a frozen
base returns to `FROZEN`, never `NORMAL`.

State transitions use a DynamoDB transaction with an expected revision. Notification
and remediation commands are emitted through a transactional outbox/DynamoDB Stream,
so duplicate events cannot send unlimited email or launch parallel workflows.

### 12.1 Freeze triggers

Freeze when any configured condition holds:

- projected month-end exposure exhausts effective headroom;
- an AWS-reported billing backstop crosses its emergency threshold;
- an unsupported high-risk resource or ungoverned paid path appears in strict mode;
- a protected control-plane mutation is attempted;
- ingestion, pricing, or inventory health cannot establish a safe upper bound within
  its bounded grace window;
- the cap is reduced below current committed exposure; or
- the owner selects **Freeze now**.

### 12.2 Release and period-rollover invariants

`FROZEN` is sticky across billing periods. Rollover starts `RECONCILING`, carries
prior-period usage, fixed charges, and unresolved resources forward, and never enters
`NORMAL` merely because the month changed. A cap increase also does not release a
freeze.

Release requires a recent owner step-up, healthy ingestion and remediation, complete
and fresh pricing, no unknown high-risk path, sufficient headroom after all reserves,
a new committed policy revision, and an approved thaw plan. Partial remediation keeps
the account frozen. Warning and throttle thresholds remain versioned policy data.

## 13. IAM and tamper resistance

### 13.1 Roles

- **Controlled LowKey agent role:** replaces raw `AdministratorAccess` in strict mode
  and receives its boundary at creation.
- **SpendControlProvisionerRole:** executes approved deployment plans; never directly
  assumable or passable by the agent.
- **SpendControlGovernorRole:** attaches freeze policy, inspects resources, and runs
  registered recipes; it cannot raise the cap or issue an override.
- **SpendControlApiRole:** reads state and requests versioned transitions; it cannot
  mutate workload resources directly.
- **Generated workload roles:** carry the approved boundary and cannot assume or pass
  controller roles.
- **External recovery role:** deployer/owner controlled, outside all agent trust paths,
  and documented for CLI break glass.

### 13.2 Permanent guard policy

The guard is a versioned, machine-readable policy artifact tested with IAM Policy
Simulator and integration tests. A boundary plus an attachable deny is insufficient
if the agent can create another identity or delegate to a privileged service role.
The coverage matrix includes:

- users, groups, login profiles, access keys, service-specific credentials, managed
  policy creation/version selection, inline policies, and policy attachments;
- role creation with an exact required permissions-boundary ARN, boundary removal,
  trust-policy changes, instance profiles, alternate STS paths, and session tags;
- `iam:PassRole` constrained by exact role pattern, boundary, ownership tags, and
  `iam:PassedToService` (there is no standalone CloudTrail `PassRole` event);
- CloudFormation stacks, change sets, StackSets, stack policy, termination protection,
  execution roles, custom resources, Lambda, Step Functions, CodeBuild, ECS, Batch,
  Glue, and SageMaker delegation paths;
- CloudTrail, EventBridge, Config, Budgets, Cost Anomaly Detection, CloudWatch,
  queues, tables, KMS, Secrets Manager, API Gateway, Cognito, CloudFront, WAF, and all
  controller data and compute;
- service-linked-role creation denied by default or constrained by
  `iam:AWSServiceName` to a reviewed allowlist; and
- quota increases, commitments, subscriptions, domain purchases/renewals, and Region
  enablement.

The agent cannot create policy versions for, detach, delete, or replace its guard and
boundary; remove its role from the protected profile; pass, invoke, or update a
controller role/function; or mutate controller stacks. Current wildcard SSM custom
resource privileges and caller-selected secret references must be removed or tightly
resource/parameter constrained before strict mode.

This same-account design protects against the controlled agent. Root and separate
human administrators remain outside its guarantee unless an external SCP or security
account enforces the guard.

### 13.3 Frozen policy and credentials

Do not add `ReadOnlyAccess`: IAM allows are additive. Pre-create a bounded set of
explicit-deny policies that close resource mutation, start/scale, delegation,
commitment, public-entry, and paid-invocation paths while preserving approved
`Describe`, SSM recovery, and control-API access.

The frozen action matrix covers all credential classes: agent role sessions, workload
roles, IAM users/access keys if any, federated sessions, service roles, service-linked
roles, Bedrock API keys, and external provider credentials. IAM role-session
revocation is defense in depth, not a universal primitive. Explicit deny propagation
is eventually consistent, and it cannot cancel in-flight requests, accepted async
jobs, running Lambda/Step Functions/Batch work, queued deliveries, service-linked-role
activity, or external-provider calls.

The deny must include the complete covered Bedrock/API surface, including streaming,
`Converse`, agent runtime, retrieval, guardrails, flows, inline agents, provisioned
throughput, and the separate Mantle prefix. Direct runtime access is prohibited in
strict mode unless its gateway is exclusive. The LowKey instance may be stopped after
a notification grace period; EBS and retained storage remain reserved liability.

## 14. Freeze and thaw orchestration

A Step Functions workflow executes idempotent adapter actions:

1. persist `FROZEN` with reason, base state, policy revision, and exposure snapshot;
2. attach the frozen deny and request credential-class-specific revocation;
3. close provisioning and runtime gateways;
4. disable schedules, event sources, public entry points, and autoscaling;
5. stop or scale supported compute/database resources;
6. cancel accepted jobs only where a safe, supported cancellation API exists;
7. snapshot and delete only resources whose owner policy permits destructive freeze;
8. reconcile retained storage, network, commitments, queues, and in-flight work;
9. publish per-resource acknowledgment and reconciled status; and
10. retry transient failures, routing exhausted failures to an operator queue.

Catching an adapter error never acknowledges success. Partial failure leaves the
account `FROZEN` and visible in the UI. State transition, command emission, action
acknowledgment, reconciliation, and notification delivery are recorded separately;
email and customer events are observability, not enforcement.

### 14.1 In-flight and retained liability

Freeze prevents newly admitted operations only after enforcement propagates. It does
not retroactively cancel service-accepted work or remove fixed charges. The exposure
snapshot reserves maximum remaining liability for active sessions, async inference,
Lambda and workflow executions, queued work, data transfer, NAT/public IPv4, EBS and
database storage, snapshots, S3/log retention, commitments, subscriptions, and the
controller itself. The UI shows the minimum feasible monthly floor and residual
liability after freeze.

### 14.2 Thaw

Thaw is not a blind reversal. It creates a restoration plan from captured pre-freeze
state, current policy, controller health, and available headroom. A stepped-up owner
approves the versioned plan. Deleted resources or expired commitments may require
recreation; failed or incomplete actions cannot be auto-released.

## 15. Billing backstops

Provision independently of the local estimator:

- an AWS Budget with actual and forecast notifications;
- CloudWatch `AWS/Billing` `EstimatedCharges` alarms in `us-east-1` where available;
- Cost Anomaly Detection notifications; and
- an emergency EventBridge/SNS route into the state machine.

Budgets, Cost Explorer, billing metrics, CUR, and anomaly detection are delayed
reconciliation and emergency signals only. They can force a freeze but cannot
pre-authorize spend or prove current headroom. Deployment uses the required global or
`us-east-1` endpoint for each billing API.

Every policy, UI view, audit row, and customer event records the accounting basis. The
initial basis is conservative gross pre-tax usage before credits and discounts;
unblended, amortized, net, invoice, tax, support, Marketplace, and late-adjustment
figures are displayed separately when available.

## 16. Customer notifications and integration event

Installation captures a notification email and creates a confirmed SNS subscription.
Do not assume that the root-account email is retrievable or appropriate.

Publish state changes on a custom event bus using a versioned schema:

```json
{
  "source": "lowkey.spend-control",
  "detail-type": "SpendStateChanged",
  "detail": {
    "schemaVersion": "1",
    "state": "FROZEN",
    "reason": "PROJECTED_CAP_EXCEEDED",
    "capUsd": "500.00",
    "awsReportedMtdUsd": "...",
    "locallyEstimatedAccruedUsd": "...",
    "committedLiabilityUsd": "...",
    "projectedMonthEndUsd": "...",
    "estimateComplete": true,
    "topCostDrivers": [],
    "policyRevision": 42,
    "occurredAt": "..."
  }
}
```

Events are emitted for warning, throttling, freezing, override, release, incomplete
estimates, remediation failure, and return to normal. Customer automation is an
extension point, never part of LowKey's primary enforcement path.

## 17. Spend-control web application

### 17.1 Components and cost bound

- private S3 bucket for the static application;
- CloudFront with Origin Access Control and HTTPS;
- a dedicated Cognito user pool by default, or a user-selected eligible existing pool;
- API Gateway with Cognito/JWT authorization;
- Lambda control API;
- DynamoDB state, policy, audit, session-version, and outbox tables; and
- WAF/API rate limits, Lambda reserved concurrency, bounded retries/log retention,
  controlled table capacity, and a fixed control-plane reserve.

The installer presents eligible existing pools and never infers one. Eligibility
requires admin-only registration, reviewed identity providers, MFA/step-up support,
known token lifetimes and app-client settings, and no conflicting identities/groups.
A new pool disables self-signup and enables short-lived access tokens plus owner
step-up. The control plane has a minimum cap floor so it can remain available while
workloads are frozen.

A public static SPA is acceptable because hiding HTML is not authorization. If the
product requires pre-auth HTML, reuse the CloudFront/Lambda@Edge cookie pattern; all
API and data controls remain server-side either way.

### 17.2 Authorization

Every API route validates signature, issuer, expiry, `token_use`, scopes, and the app
client (`client_id` for access tokens; `aud` where ID tokens are accepted), then
enforces server-side group/owner authorization:

- `SpendViewer`: view state, resources, projections, and audit history.
- `SpendAdmin`: lower limits and change reviewed thresholds, adapters, and allowances.
- `SpendOwner`: increase cap, issue override, release freeze, or authorize destructive
  remediation.

Owner actions require recent step-up plus a server-side session/version check because
previously issued JWTs retain old claims after group changes. The agent cannot read or
reset owner credentials, mutate the pool/app client/groups, invoke user-management
custom resources, or alter CloudFront/edge authentication. Authentication success
alone never grants owner authority.

### 17.3 Required controls

- Freeze now
- Change monthly cap and warning/throttle thresholds
- Block new provisioning
- Edit resource/property policy and runtime allowances
- Create a scoped, amount-bounded, expiring override lease
- Preview and approve thaw
- Inspect scope, unmanaged and unknown/unpriced resources, unbounded runtime paths,
  minimum monthly floor, residual liability, remediation failures, and cost drivers
- Subscribe and test email/EventBridge notifications

### 17.4 Recovery

Document a deployer-owned CLI break-glass path for failed stack updates, lost owner
access, corrupted state, or unavailable edge/API components. Main and `us-east-1`
edge resources share protection and recovery procedures. Recovery actions are audited
and cannot be performed by the LowKey agent.

## 18. Data model

### `BudgetPolicy`

```text
accountId, capMicrousd, accountingBasis, resourceScope, billingTimezone=UTC, mode,
warningThreshold, throttleThreshold, uncertaintyReserveMicrousd,
controlPlaneReserveMicrousd, maxInventoryAgeSeconds, resourceCatalogVersion,
priceManifestVersion, revision, updatedBy, updatedAt
```

### `ResourceRecord`

```text
resourceKey, accountId, region, resourceType, resourceArn,
normalizedState, stateHash, adapterVersion, lifecycleClass,
locallyAccruedMicrousd, committedMicrousd, estimateComplete,
firstSeenAt, lastObservedAt, lastEventId, freezeStatus, preFreezeState
```

### `RuntimeAllowance`

```text
allowanceId, ownerResourceKey, service, unit, grantedQuantity,
consumedQuantity, reservedMicrousd, expiresAt, revision
```

### `ControlState`

```text
accountId, baseState, reason, revision, transitionedAt,
projectedMicrousd, estimateComplete, coverageHealth,
activeOverrideLeaseId, residualLiabilityMicrousd
```

### `AuditEvent` / `OutboxEvent`

Append-only records containing actor, action, previous revision, new revision, reason,
request ID, and delivery state. Do not place secrets, raw prompts, request bodies, or
CloudTrail credentials in these tables or customer events.

## 19. Failure modes

| Failure | Required behavior |
|---|---|
| Duplicate/out-of-order event | Idempotent describe-and-reconcile; no duplicate transition |
| Missing or retention-gapped CloudTrail evidence | Inventory and billing reconciliation; mark historical evidence incomplete |
| Trail/logging/model-log disabled | Enter `UNSAFE`; deny new paid operations in strict mode |
| Queue backlog or inventory age exceeds policy | Alarm and fail closed to `THROTTLED`/`UNSAFE` |
| Pricing lookup unavailable | Use unexpired signed manifest plus reserve; otherwise `ESTIMATE_INCOMPLETE` |
| Unknown high-risk resource/path | Deny or freeze in strict mode; never price as zero |
| IAM propagation delay | Reserve residual liability and execute service-side shutdown |
| Accepted/in-flight work | Attempt safe cancellation; retain worst-case liability |
| Freeze adapter fails | Remain frozen, retry, surface failure, preserve DLQ record |
| Home Region unavailable | Preventive policy remains; deny new paid operations after bounded health window |
| Cognito/UI unavailable | Existing policy remains; use deployer-owned CLI recovery |
| Month rollover | Enter `RECONCILING`; keep freeze and prior exposure until release invariants pass |
| AWS billing amount decreases | Never auto-thaw solely because a delayed estimate changed |
| Cap reduced below committed exposure | Freeze and report minimum feasible floor |
| Override expires | Return to its base state, including `FROZEN` |
| Agent attempts controller mutation | Deny, freeze or alert by policy, and emit immutable tamper audit |

The product exposes `not_installed`, `coverage_incomplete`, and `degraded` readiness
separately from budget state. A working dashboard or Cognito pool is not evidence that
enforcement is installed.

## 20. Observability and audit

Emit structured metrics for:

- event age, queue depth, and DLQ count;
- reconciliation duration and adapter failures;
- discovered/unknown resource count;
- locally accrued, committed, projected, and AWS-reported spend;
- estimate completeness and uncertainty reserve;
- state transition count and time to freeze;
- remediation success/failure by adapter; and
- UI/API authorization failures and policy changes.

CloudWatch logs use explicit retention and redact request parameters that may contain
secrets. Control-plane CloudTrail events are routed to a high-priority guardrail rule.
Every owner mutation is stored in the append-only audit table.

## 21. Delivery phases

### Phase 0 — Design validation

- Record the requested 30-day audit and its 14-day retention limitation (Appendix A).
- Increase audit retention before using future history as readiness evidence.
- Validate event delivery, duplicates, Region distribution, and useful identifiers.
- Build the initial event catalog and resource adapter priority.
- Threat-model privilege escape from the current builder and custom-resource roles.

### Phase 1 — Observe-only compatibility

- Keep the existing `builder` profile explicitly non-strict.
- Multi-Region trail readiness, EventBridge forwarding, SQS/DLQ, dedupe, and inventory.
- Initial fixed-cost adapters and signed price manifest.
- Dashboard with AWS-reported and locally projected values plus coverage health.
- No hard guarantee, automatic permission change, or resource shutdown.

### Phase 2 — Reactive enforcement

- State machine, explicit frozen policy, role-session revocation.
- Email and custom EventBridge events.
- Idempotent freeze adapters for the initial resource catalog.
- Owner-driven freeze, override, and thaw.
- Delayed AWS billing backstops.

### Phase 3 — Preventive enforcement

- Controlled builder boundary and permanent guard policy.
- Synchronous approval for expensive CloudFormation change sets.
- Runtime Bedrock and public-traffic allowances.
- Deny or reserve unknown and commitment resources.

### Phase 4 — Hardening

- Expand adapter and event coverage from real deployments.
- Chaos tests for missed/duplicate events, IAM delay, queue failure, and partial freeze.
- Optional Organizations SCP integration.
- Formal maximum-unreserved-liability tests for strict mode.

## 22. Validation plan

### Unit tests

- deterministic price arithmetic and month boundaries;
- every event catalog entry maps to a known adapter or explicit ignore reason;
- duplicate and out-of-order event replay;
- resource state transitions, including stop-with-storage-still-billable;
- state-machine threshold and revision races;
- override expiration and cap reduction;
- redaction and event schema validation; and
- adapter freeze/thaw idempotency.

### Policy tests

- IAM Policy Simulator and integration fixtures verify the agent cannot alter the
  controller, guard, boundary, policy versions, trusts, instance profile, or trail.
- Verify it cannot create users/keys/unbounded roles, use alternate STS routes, pass
  protected roles, invoke controller custom resources, or create unapproved
  service-linked roles.
- Verify CloudFormation, Lambda, Step Functions, CodeBuild, ECS, Batch, Glue,
  SageMaker, and StackSets cannot delegate around the boundary.
- Verify frozen policies deny every covered paid Bedrock path, including Mantle, while
  the governor still cannot increase cap or self-authorize an override.
- Verify the API role cannot mutate workloads and only a stepped-up, session-current
  owner can raise cap, override, release, or approve destructive actions.
- Verify human/root recovery remains documented and explicitly outside agent trust.

### Integration tests

In a disposable account:

1. create, resize, stop, restart, and terminate representative resources;
2. prove events are reconciled across multiple Regions;
3. replay duplicate events and drop selected events to exercise inventory repair;
4. cross warning, throttle, and freeze thresholds using synthetic price fixtures;
5. verify the agent loses paid/write capabilities while reads still work;
6. verify active resources are frozen according to policy;
7. verify partial remediation retries and reaches the DLQ when exhausted;
8. exercise UI cap change, time-bounded override, and thaw; and
9. compare local estimates with AWS billing after publication delay.

Do not test by intentionally generating a large real bill. Price fixtures and low-cost
resources drive threshold behavior.

## 23. Decisions captured

- The controller runs in the same account as LowKey and protects against the
  controlled agent, not root or an independent same-account administrator.
- Existing `builder` remains observe-only; strict mode requires `controlled_builder`,
  an exclusive broker, or an external root of trust.
- CloudTrail events feed reconciliation but are not a synchronous enforcement boundary.
- SQS Standard plus idempotent state is preferred over assumed source ordering.
- Freeze uses explicit deny, not additive `ReadOnlyAccess`, and records residual liability.
- `FROZEN` is sticky across month rollover; `OVERRIDE` is an orthogonal lease.
- Mantle and external-provider paths are denied by default in strict mode until an
  exclusive metering/admission gateway covers them.
- Account-wide delayed billing remains an independent backstop.
- The control UI uses server-side authorization; a dedicated Cognito pool is the
  default, while eligible existing pools are presented rather than inferred.
- Unknown resources and unhealthy coverage fail visible and fail closed in strict mode.

## 24. Open questions

1. Is scope the whole account, one LowKey deployment, or a verified workload/tag set?
2. Does strict mode ship as `controlled_builder` or require the broker from day one?
3. Is protection against same-account administrators required, implying an SCP or
   separate security account?
4. Which destructive freeze actions are default versus owner opt-in?
5. What minimum reserve keeps the controller and retained data operational?
6. Are Mantle, LiteLLM, direct providers, standalone Codex, and Bedrock API keys
   prohibited or routed through separate gateways?
7. Which exact gross/unblended/amortized/net basis is contractual, and how are taxes,
   support, Marketplace, discounts, credits, and late adjustments displayed?
8. What manifest TTL, manual override process, and uncertainty reserve are acceptable?
9. How do multiple LowKey deployments share one account-level controller and cap?
10. During a home-Region outage, does strict mode only deny new work or also execute
    regional shutdown actions?
11. Is release always owner-driven, and which recent-MFA and recovery mechanisms are
    required for the authoritative identity model?

## Appendix A — 30-day CloudTrail findings

### A.1 Method and evidence boundary

A read-only subagent analyzed the requested closed UTC window
`2026-07-28T09:43:46Z` through `2026-08-27T09:43:46Z` using deterministic AWS MCP
scripts. It verified 17 enabled Regions:

`ap-northeast-1`, `ap-northeast-2`, `ap-northeast-3`, `ap-south-1`,
`ap-southeast-1`, `ap-southeast-2`, `ca-central-1`, `eu-central-1`, `eu-north-1`,
`eu-west-1`, `eu-west-2`, `eu-west-3`, `sa-east-1`, `us-east-1`, `us-east-2`,
`us-west-1`, and `us-west-2`.

Source priority and results:

1. **CloudTrail Lake:** no event data stores existed in the enabled Regions.
2. **CloudTrail-integrated CloudWatch Logs:** two deduplicated multi-Region trails
   included global events and were actively logging. The integrated log group
   `aws-controltower/CloudTrailLogs-yu0-dl0` in `us-east-1` retained only 14 days.
3. **Event History fallback:** `LookupEvents` returned a continuation token after the
   first 1,000 aggregated results and was not fully drained across all Regions. It
   would cover management events only, not data events.

The exact retained snapshot was collected approximately
`2026-08-27T10:19:34Z`–`10:19:45Z` and spans roughly
`2026-08-13T10:16:03Z`–`2026-08-27T09:43:14Z`. Records were expiring while queried.
Therefore the numbers below are exact for that retained snapshot, **not** exact for
the requested 30 days. The unavailable first approximately 16 days must not be
silently inferred. No AWS mutation was performed and no unnecessary principal or
account identifiers were retained.

### A.2 Retention-limited aggregate

| Classification | Exact retained count |
|---|---:|
| Successful mutating `AwsApiCall` management events (`readOnly=false`, no error) | 275,738 |
| Failed mutating `AwsApiCall` attempts | 1,223 |
| `AwsServiceEvent` records | 46,677 |
| Successful read-only management calls | 1,815,909 |
| Failed read-only management calls | 88,101 |
| `AwsMcpEvent` records | 343 |
| `AwsConsoleSignIn` records | 26 |
| Data events | 0 |
| **Total records matching the retained event-time predicate** | **2,228,017** |
| Distinct `eventSource` / `eventName` / Region tuples | 2,549 |
| Distinct `eventSource` / `eventName` pairs | 1,205 |

All retained records were management events. Zero data events reflects trail selector
coverage, not proof of zero data-plane activity. The volume also demonstrates why
`readOnly=false` cannot itself define a spend mutation.

### A.3 Observed P0 events

`O-R14` means observed in the retained slice. Counts are successful unless a failure
is stated.

| `eventSource` / `eventName` | Region and exact count | Design implication |
|---|---|---|
| `ec2.amazonaws.com` / `RunInstances` | `us-east-1`: 26 | Synchronous admission and liability reservation before acceptance |
| `cloudformation.amazonaws.com` / `CreateStack` | `us-east-1`: 12 | Pre-admission policy and estimate |
| `cloudformation.amazonaws.com` / `CreateChangeSet` | `us-east-1`: 20 | Inspect planned resources and reserve headroom |
| `cloudformation.amazonaws.com` / `ExecuteChangeSet` | `us-east-1`: 19 | Final reservation before execution |
| `dynamodb.amazonaws.com` / `CreateTable` | `us-east-1`: 1 | Capacity-mode admission and inventory |
| `elasticloadbalancing.amazonaws.com` / `CreateLoadBalancer` | `us-east-1`: 24; 1 failed `ValidationException` | Admission plus recurring/usage ledger |
| `lambda.amazonaws.com` / `PutFunctionConcurrency20171031` | `us-east-1`: 17 | Concurrency/capacity policy |
| `iam.amazonaws.com` / `CreateRole` | `us-east-1`: 100 | Boundary enforcement and immutable audit |
| `iam.amazonaws.com` / `AttachRolePolicy` | `us-east-1`: 120 | Guardrail-integrity policy |
| `iam.amazonaws.com` / `DetachRolePolicy` | `us-east-1`: 51 | Protect guard policies and alert |
| `iam.amazonaws.com` / `PutRolePolicy` | `us-east-1`: 114 | Validate privilege and delegation paths |
| `iam.amazonaws.com` / `DeleteRolePolicy` | `us-east-1`: 56 | Protect controller/guard identities |
| `iam.amazonaws.com` / `DeleteRole` | `us-east-1`: 40 | Protected-resource policy |
| `iam.amazonaws.com` / `CreatePolicy` | `us-east-1`: 7 | Policy validation and audit |
| `events.amazonaws.com` / `PutRule` | 210 failed `AccessDenied` attempts across 7 Regions | Integrity signal; no success observed |
| `events.amazonaws.com` / `PutTargets` | 210 failed `AccessDenied` attempts across the same Regions | Integrity signal; no success observed |

The EventBridge failures occurred in `ap-northeast-1`, `ap-south-1`,
`ap-southeast-1`, `ap-southeast-2`, `eu-central-1`, `eu-west-2`, and `eu-west-3`.
No retained mutation was observed for CloudTrail configuration, Service Quotas, or
Budgets. Absence in this slice is not proof that those operations cannot occur.

### A.4 Observed resource and usage priorities

| Family | Exact retained observations | Adapter implication |
|---|---|---|
| EC2/network/storage | `AllocateAddress=53`, `CreateVpc=10`, `CreateSubnet=19`, `CreateNetworkInterface=90`, `CreateSecurityGroup=57`, `CreateSnapshot=14`, `TerminateInstances=14`, `DeleteVolume=39` | EC2/network/storage inventory plus admission for unbounded resources |
| ELB | `CreateListener=24`, `CreateTargetGroup=24`, `CreateRule=21`, `RegisterTargets=30`, `DeleteLoadBalancer=8` | Load-balancer lifecycle ledger |
| Lambda | `CreateFunction20150331=134` across 13 Regions; `DeleteFunction20150331=54`; `UpdateFunctionCode20150331v2=2` | Multi-Region function and concurrency inventory |
| S3 | `CreateBucket=38`, `PutBucketVersioning=31`, `PutBucketLifecycle=7`, `PutBucketPolicy=9`, `DeleteBucket=1` | Storage/lifecycle and public-exposure ledger |
| CloudFront | `CreateDistribution=2`, `CreateDistributionWithTags=21`, `CreateVpcOrigin=7`, `UpdateDistribution=8`, `DeleteDistribution=6` | Edge recurring/traffic exposure |
| Secrets Manager | `CreateSecret=65`, `DeleteSecret=14`, `PutSecretValue=12` | Lifecycle audit; small recurring-cost adapter |
| SQS | `CreateQueue=9`, `DeleteQueue=7` | Queue inventory and retention limits |
| SSM commands/parameters | `PutParameter=1,045`, `DeleteParameter=42`, `SendCommand=77` plus 63 failed | Correlate provisioning activity; not direct cost truth |

High-volume `readOnly=false` records that must be P2 include
`ssm:UpdateInstanceInformation=116,144`,
`ssm:UpdateInstanceAssociationStatus=67,758`, `ssm:PutInventory=19,684`,
`ssm:PutComplianceItems=16,875`, `config:PutEvaluations=23,990`, and
`logs:CreateLogStream=25,998` successes across observed Regions.

Service-generated usage signals included
`bedrock.amazonaws.com:ConverseStream=42,044` and
`bedrock.amazonaws.com:InvokeModelWithResponseStream=1,678` in `us-east-1`.
They are useful for correlation, but CloudTrail does not provide a reliable token/cost
admission boundary. Model invocation logs, gateway reservations, pricing, and
billing/CUR reconciliation remain necessary.

### A.5 Consequences for the design

- First-wave adapters should prioritize EC2/network/EBS, IAM/CloudFormation,
  Lambda, ELB, S3/CloudFront, DynamoDB, and Bedrock runtime.
- Multi-Region deployment is required: function creation was observed in 13 Regions.
- EventBridge cannot stop P0 calls; it sees them after acceptance.
- Event payloads trigger authoritative describe/reconcile rather than direct billing
  deltas, and semantic classification must suppress telemetry noise.
- Trail/log retention must cover the evidence period. Strict mode treats retention or
  logging gaps as degraded coverage, not as zero activity.
- Runtime spend, data transfer, externally induced traffic, in-flight jobs, and
  service-linked-role activity need metrics, inventory, quotas, or admission controls.

## Appendix B — Baseline exact event catalog

This catalog is a coverage baseline, not a claim that CloudTrail alone enforces a
cap. `O-R14` is observed in the retained slice, `O-F14` is failed-only in that slice,
and `C` is coverage-driven. Rows group exact event names only when they share a
priority and adapter. EventBridge patterns are generated and fixture-tested from the
machine-readable implementation catalog.

| `eventSource` | Exact `eventName` values | Class | Priority | Evidence | Adapter/control |
|---|---|---|---|---|---|
| `ec2.amazonaws.com` | `RunInstances` | increase | P0 | O-R14 | Synchronous instance admission and reservation |
| `ec2.amazonaws.com` | `StartInstances`, `CreateFleet`, `RequestSpotInstances`, `RequestSpotFleet`, `CreateNatGateway` | increase | P0 | C | Admission, quota, maximum exposure |
| `autoscaling.amazonaws.com` | `CreateAutoScalingGroup`, `UpdateAutoScalingGroup`, `SetDesiredCapacity` | usage-gate | P0 | C | Maximum-capacity admission |
| `ecs.amazonaws.com` | `CreateService`, `UpdateService`, `RunTask`, `StartTask` | increase | P0 | C | Task/service lease admission |
| `eks.amazonaws.com` | `CreateCluster`, `CreateNodegroup`, `UpdateNodegroupConfig` | increase | P0 | C | Control-plane/node capacity admission |
| `rds.amazonaws.com` | `CreateDBInstance`, `CreateDBCluster`, `ModifyDBInstance`, `ModifyDBCluster`, `StartDBInstance`, `RestoreDBInstanceFromDBSnapshot`, `RestoreDBClusterFromSnapshot` | increase | P0 | C | Class/storage/runtime admission |
| `dynamodb.amazonaws.com` | `CreateTable` | increase | P0 | O-R14 | Capacity-mode admission |
| `dynamodb.amazonaws.com` | `UpdateTable`, `RestoreTableFromBackup`, `RestoreTableToPointInTime`, `CreateGlobalTable` | increase | P0 | C | Capacity/replication admission |
| `elasticache.amazonaws.com` | `CreateCacheCluster`, `CreateReplicationGroup`, `ModifyCacheCluster`, `ModifyReplicationGroup` | increase | P0 | C | Node/class admission |
| `redshift.amazonaws.com` | `CreateCluster`, `ResizeCluster`, `ResumeCluster` | increase | P0 | C | Capacity admission |
| `es.amazonaws.com` | `CreateDomain`, `UpdateDomainConfig` | increase | P0 | C | OpenSearch capacity admission |
| `lambda.amazonaws.com` | `PutFunctionConcurrency20171031` | usage-gate | P0 | O-R14 | Concurrency policy |
| `lambda.amazonaws.com` | `UpdateFunctionConfiguration`, `PutProvisionedConcurrencyConfig` | usage-gate | P0 | C | Memory/timeout/provisioned capacity admission |
| `bedrock.amazonaws.com` | `CreateProvisionedModelThroughput` | commitment | P0 | C | Provisioned-throughput admission |
| `elasticloadbalancing.amazonaws.com` | `CreateLoadBalancer` | increase | P0 | O-R14 | Load-balancer admission |
| `cloudformation.amazonaws.com` | `CreateStack`, `CreateChangeSet`, `ExecuteChangeSet` | increase | P0 | O-R14 | Plan inspection and final reservation |
| `cloudformation.amazonaws.com` | `UpdateStack`, `CreateStackSet`, `UpdateStackSet`, `CreateStackInstances`, `SetStackPolicy`, `UpdateTerminationProtection` | guardrail | P0 | C | Broker and protected-stack policy |
| `iam.amazonaws.com` | `CreateRole`, `DeleteRole`, `AttachRolePolicy`, `DetachRolePolicy`, `PutRolePolicy`, `DeleteRolePolicy`, `CreatePolicy` | guardrail | P0 | O-R14 | Boundary/policy integrity |
| `iam.amazonaws.com` | `CreateUser`, `CreateAccessKey`, `CreateLoginProfile`, `CreatePolicyVersion`, `SetDefaultPolicyVersion`, `UpdateAssumeRolePolicy`, `PutRolePermissionsBoundary`, `DeleteRolePermissionsBoundary`, `CreateServiceLinkedRole`, `AddRoleToInstanceProfile` | guardrail | P0 | C | Prevent alternate identities and delegation |
| `sts.amazonaws.com` | `AssumeRole`, `AssumeRoleWithSAML`, `AssumeRoleWithWebIdentity`, `GetFederationToken` | guardrail | P0 | C | Alternate-session audit and policy control |
| `cloudtrail.amazonaws.com` | `CreateTrail`, `UpdateTrail`, `DeleteTrail`, `StartLogging`, `StopLogging`, `PutEventSelectors`, `CreateEventDataStore`, `UpdateEventDataStore`, `DeleteEventDataStore` | guardrail | P0 | C | Prevent audit-path removal |
| `events.amazonaws.com` | `PutRule`, `PutTargets` | guardrail | P0 | O-F14 | Protected routing plus immediate alert |
| `events.amazonaws.com` | `DeleteRule`, `RemoveTargets`, `DisableRule`, `CreateEventBus`, `DeleteEventBus` | guardrail | P0 | C | Protected event plane |
| `servicequotas.amazonaws.com` | `RequestServiceQuotaIncrease` | usage-gate | P0 | C | Owner approval/quota policy |
| `budgets.amazonaws.com` | `CreateBudget`, `UpdateBudget`, `DeleteBudget` | guardrail | P0 | C | Billing-control integrity |
| `ce.amazonaws.com` | `CreateAnomalyMonitor`, `UpdateAnomalyMonitor`, `DeleteAnomalyMonitor`, `CreateAnomalySubscription`, `UpdateAnomalySubscription`, `DeleteAnomalySubscription` | guardrail | P0 | C | Anomaly-control integrity |
| `ec2.amazonaws.com` | `PurchaseReservedInstancesOffering` | commitment | P0 | C | Deny or owner-admit commitment |
| `rds.amazonaws.com` | `PurchaseReservedDBInstancesOffering` | commitment | P0 | C | Deny or owner-admit commitment |
| `savingsplans.amazonaws.com` | `CreateSavingsPlan` | commitment | P0 | C | Deny or owner-admit commitment |
| `route53domains.amazonaws.com` | `RegisterDomain`, `RenewDomain` | commitment | P0 | C | Renewal reservation/owner approval |
| `ec2.amazonaws.com` | `AllocateAddress`, `ReleaseAddress`, `CreateVpc`, `CreateSubnet`, `CreateNetworkInterface`, `CreateRouteTable`, `CreateInternetGateway`, `CreateRoute`, `CreateSecurityGroup`, `CreateSnapshot`, `DeleteSnapshot`, `DeleteVolume`, `TerminateInstances` | configuration | P1 | O-R14 | Network/storage/instance reconciliation |
| `ec2.amazonaws.com` | `CreateVolume`, `ModifyVolume`, `CreateVpcEndpoint`, `DeleteVpcEndpoints`, `CreateLaunchTemplate`, `CreateLaunchTemplateVersion`, `StopInstances`, `DeleteNatGateway` | configuration | P1 | C | Inventory and retained-liability ledger |
| `autoscaling.amazonaws.com` | `DeleteAutoScalingGroup`, `PutScalingPolicy`, `DeletePolicy`, `PutScheduledUpdateGroupAction`, `DeleteScheduledAction` | configuration | P1 | C | Capacity schedule reconciliation |
| `ecs.amazonaws.com` | `DeleteService`, `RegisterTaskDefinition`, `PutClusterCapacityProviders`, `UpdateCapacityProvider` | configuration | P1 | C | Service/capacity inventory |
| `eks.amazonaws.com` | `DeleteCluster`, `DeleteNodegroup`, `UpdateClusterConfig` | configuration | P1 | C | Cluster/node inventory |
| `rds.amazonaws.com` | `StopDBInstance`, `DeleteDBInstance`, `DeleteDBCluster`, `CreateDBSnapshot`, `DeleteDBSnapshot` | decrease | P1 | C | Runtime/storage reconciliation |
| `s3.amazonaws.com` | `CreateBucket`, `DeleteBucket`, `PutBucketLifecycle`, `PutBucketVersioning`, `PutBucketReplication`, `PutBucketPolicy`, `PutBucketPublicAccessBlock` | configuration | P1 | O-R14/C | Storage, replication, and exposure ledger |
| `lambda.amazonaws.com` | `CreateFunction20150331`, `DeleteFunction20150331`, `UpdateFunctionCode20150331v2`, `CreateEventSourceMapping20150331` | configuration | P1 | O-R14 | Function/trigger inventory |
| `states.amazonaws.com` | `CreateStateMachine`, `UpdateStateMachine`, `DeleteStateMachine`, `StartExecution`, `StartSyncExecution` | usage-gate | P1 | C | Workflow inventory and execution allowance |
| `apigateway.amazonaws.com` | `CreateApi`, `CreateRestApi`, `CreateStage`, `CreateDeployment`, `CreateIntegration`, `CreateRoute`, `DeleteRestApi`, `DeleteApi` | configuration | P1 | O-R14/C | API/public-traffic exposure |
| `cloudfront.amazonaws.com` | `CreateDistribution`, `CreateDistributionWithTags`, `CreateVpcOrigin`, `UpdateDistribution`, `DeleteDistribution` | configuration | P1 | O-R14 | Edge inventory and traffic exposure |
| `sqs.amazonaws.com` | `CreateQueue`, `DeleteQueue`, `SetQueueAttributes` | configuration | P1 | O-R14/C | Queue/retention inventory |
| `sns.amazonaws.com` | `CreateTopic`, `DeleteTopic`, `Subscribe`, `Unsubscribe`, `SetTopicAttributes` | configuration | P1 | C | Messaging inventory and public ingress |
| `kinesis.amazonaws.com` | `CreateStream`, `UpdateShardCount`, `DeleteStream` | usage-gate | P1 | C | Shard/capacity inventory |
| `firehose.amazonaws.com` | `CreateDeliveryStream`, `UpdateDestination`, `DeleteDeliveryStream` | configuration | P1 | C | Delivery and downstream-cost inventory |
| `logs.amazonaws.com` | `CreateLogGroup`, `PutRetentionPolicy`, `DeleteRetentionPolicy`, `DeleteLogGroup`, `PutSubscriptionFilter` | configuration | P1 | C | Retention/ingestion and egress ledger |
| `ecr.amazonaws.com` | `CreateRepository`, `DeleteRepository`, `PutLifecyclePolicy`, `DeleteLifecyclePolicy` | configuration | P1 | C | Image storage/lifecycle inventory |
| `sagemaker.amazonaws.com` | `CreateEndpoint`, `UpdateEndpoint`, `DeleteEndpoint`, `CreateTrainingJob`, `StopTrainingJob` | increase | P1 | C | Endpoint/job inventory and runtime controls |
| `glue.amazonaws.com` | `CreateJob`, `UpdateJob`, `StartJobRun`, `BatchStopJobRun`, `DeleteJob` | usage-gate | P1 | C | Job admission and reconciliation |
| `elasticmapreduce.amazonaws.com` | `RunJobFlow`, `AddInstanceFleet`, `ModifyInstanceFleet`, `TerminateJobFlows` | increase | P1 | C | Cluster/fleet inventory |
| `batch.amazonaws.com` | `CreateComputeEnvironment`, `UpdateComputeEnvironment`, `SubmitJob`, `TerminateJob` | usage-gate | P1 | C | Compute/job allowance |
| `elasticfilesystem.amazonaws.com` | `CreateFileSystem`, `PutLifecycleConfiguration`, `DeleteFileSystem` | configuration | P1 | C | Storage/lifecycle ledger |
| `fsx.amazonaws.com` | `CreateFileSystem`, `UpdateFileSystem`, `DeleteFileSystem` | configuration | P1 | C | Storage/capacity ledger |
| `ssm.amazonaws.com` | `UpdateInstanceInformation`, `UpdateInstanceAssociationStatus`, `PutInventory`, `PutComplianceItems`, `PutConfigurePackageResult` | telemetry | P2 | O-R14 | Fleet health only; suppress from admission queue |
| `config.amazonaws.com` | `PutEvaluations` | telemetry | P2 | O-R14 | Evaluation audit only |
| `logs.amazonaws.com` | `CreateLogStream` | telemetry | P2 | O-R14 | Use Logs metrics for volume/cost; not admission |
| `kms.amazonaws.com` | `CreateGrant`, `RetireGrant` | guardrail | P2 | O-R14 | Security audit; not direct spend admission |
| `bedrock.amazonaws.com` | `ConverseStream`, `InvokeModelWithResponseStream` | usage-signal | P2 | O-R14 | Correlate with model logs/gateway/CUR; never price by call count |
| `ecr.amazonaws.com` | `PolicyExecutionEvent` | service-event | P2 | O-R14 | Lifecycle correlation |

`iam:PassRole` is a permission check, not a standalone API call, so no CloudTrail
`eventName=PassRole` rule can close that escape path. Enforce it synchronously in IAM
and inspect the role parameters of target service calls. Likewise, EventBridge cannot
bound data-plane consumption, accepted asynchronous work, externally induced traffic,
or Mantle/direct-provider spend; those require service metrics, inventory, quotas,
or exclusive admission gateways.
