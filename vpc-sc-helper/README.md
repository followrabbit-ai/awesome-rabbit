# Rabbit VPC Service Controls helper

If your organization uses [VPC Service Controls](https://cloud.google.com/vpc-service-controls/docs/overview),
your perimeters may block the API calls Rabbit's dedicated service account makes
while loading cost and usage metadata. When that happens, Rabbit reports one or
more **violation identifiers** (`vpcServiceControlsUniqueIdentifier` values) like:

```
VPC Service Controls: Request is prohibited by organization's policy.
vpcServiceControlsUniqueIdentifier: D8SdsrmBFJTz1i6JrSXtjaRXRe0r04aq...
```

Rabbit cannot see your perimeter configuration, so it cannot tell you *which*
perimeter needs *which* rule. **This script can — because it runs on your side,
with your visibility.** Given the violation id(s), it:

1. finds the matching entry in your `cloudaudit.googleapis.com/policy` audit logs,
2. identifies the exact perimeter and access policy that produced the denial,
3. prints the minimal ingress or egress rule needed — scoped to the single
   Rabbit service account and the single blocked service,
4. prints the exact `gcloud` commands to apply it, dry-run first.

## Safety properties

- **Read-only.** The script only reads logs and perimeter configuration. It
  never modifies anything — you review the printed YAML and run the apply
  commands yourself.
- **Single file, plain bash.** Audit every line before running it.
- **Rabbit-scoped.** It only generates rules for principals matching Rabbit's
  service account pattern (`rabbit-<code>-sa@rbt-*-cust-<code>.iam.gserviceaccount.com`);
  it refuses to build rules for any other identity, so it cannot be used to
  open your perimeter for anything else.
- The generated rules gate access on the **identity** of Rabbit's per-customer
  service account, whose IAM role on your organization is read-only metadata
  (no `bigquery.tables.getData`, no write permissions).

## Prerequisites

- `gcloud` (authenticated) and `jq`
- Roles for the user running the script:
  - `roles/logging.viewer` on the organization (or on the project named in the
    error, using `--project`)
  - `roles/accesscontextmanager.policyReader` on the organization
- The violation must be at most 30 days old (default retention of the
  `_Default` log bucket that receives policy-denial audit logs).

## Usage

```bash
./rabbit-vpcsc-helper.sh --org YOUR_ORG_ID VIOLATION_ID [VIOLATION_ID ...]

# If you only have log visibility on a single project:
./rabbit-vpcsc-helper.sh --project PROJECT_ID VIOLATION_ID
```

Example output:

```
===================================================================
Violation: Wkaesblvho8FaOZDZ_fws8Eivy...
  perimeter : data_perimeter   (policy: accessPolicies/197319183691, dry-run event: true)
  service   : bigquery.googleapis.com (bigquery.jobs.listAll)
  principal : rabbit-xxxxxxxxxx-sa@rbt-prod-cust-xxxxxxxxxx.iam.gserviceaccount.com
  reason    : NO_MATCHING_ACCESS_LEVEL
  direction : INGRESS (into projects/408514850123)

  --- Add this INGRESS rule to perimeter 'data_perimeter' ---
- ingressFrom:
    identities:
    - serviceAccount:rabbit-xxxxxxxxxx-sa@rbt-prod-cust-xxxxxxxxxx.iam.gserviceaccount.com
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: bigquery.googleapis.com
      methodSelectors:
      - method: '*'
    resources:
    - '*'

  --- How to apply ---
  gcloud access-context-manager perimeters dry-run update data_perimeter ...
```

## Why the ingress rule uses "Any source"

VPC-SC `resource:` sources match on the **originating VPC network** of a
request, not on the project a workload belongs to. Rabbit's data loaders run on
serverless Google Cloud infrastructure (Cloud Run and similar) whose requests
cannot be attributed to a source project or network — so an ingress rule
restricted to project sources will keep failing with `NO_MATCHING_ACCESS_LEVEL`
or `NETWORK_NOT_IN_SAME_SERVICE_PERIMETER` no matter which projects are listed.
The effective and tightly-scoped gate is the identity: the rule admits exactly
one dedicated, read-only service account, and only to the specific service(s)
Rabbit needs.

Two rules may be needed for BigQuery: Rabbit's query jobs run in Rabbit's
tenant project while your data stays in your perimeter, so the read is
evaluated as **ingress** and the movement of query results into the tenant
project as **egress**. The script detects the direction from the violation and
prints the right rule.

## Applying safely

The printed workflow is dry-run first:

1. `perimeters describe` — export your current rules so you append, never replace.
2. `perimeters dry-run update` — apply the new rule to the dry-run config and
   confirm in the policy audit log that the violations stop.
3. `perimeters dry-run enforce` — promote to the enforced config.
