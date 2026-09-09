# Rabbit BQ Reverse Proxy

**Rabbit BQ Reverse Proxy** is a lightweight, transparent reverse proxy that sits between your BigQuery clients and the Google BigQuery API. It forwards all traffic unchanged while selectively optimizing job submissions to reduce your BigQuery costs — with zero changes to your existing queries, tools, or workflows.

> This package deploys the current generation of the proxy (service name `bq-reverse-proxy`). It replaces the earlier `bq-proxy` service; if you are running the old proxy, see [Migrating from the old BQ Proxy](#migrating-from-the-old-bq-proxy).

## How It Works

```
┌──────────────┐         ┌──────────────────┐         ┌──────────────────────┐
│  Your Tools  │         │ BQ Reverse Proxy │         │  BigQuery API        │
│  (Looker,    │──req──▶ │                  │──req──▶ │  bigquery.googleapis │
│   dbt, etc.) │◀─res──  │    Cloud Run     │◀─res──  │  .com                │
└──────────────┘         └────────┬─────────┘         └──────────────────────┘
                                  │
                          ┌───────▼───────┐
                          │  Rabbit API   │
                          │  (Optimizer)  │
                          └───────────────┘
```

1. **Your BigQuery clients** send requests to the proxy instead of directly to `bigquery.googleapis.com`.
2. **The proxy forwards everything transparently** — reads, metadata calls, and results stream through unchanged. Only two endpoints are ever intercepted: `jobs.insert` and `jobs.query` (job submissions).
3. **For job submissions**, the proxy consults Rabbit's BQ Job Optimizer to determine the most cost-effective execution strategy (e.g., routing to reservations vs. on-demand pricing). All optimization behavior — pricing mode, reservations, enabled optimizations — is configured on the Rabbit side, keyed by your API key. There is nothing to tune in the proxy itself.
4. **The optimized request** is forwarded to BigQuery. If anything goes wrong during optimization — timeout, error, oversized body — the **original request is forwarded unchanged** (fail-open design).

### Key Properties

- **Zero client changes** — point your BigQuery endpoint to the proxy URL and everything works.
- **Fail-open** — if the optimizer is unreachable or returns an error, the original query runs as-is. Your workloads are never blocked.
- **Streaming** — responses are streamed, not buffered. Even large result sets pass through without extra memory overhead.
- **No credential handling** — OAuth tokens from your clients pass through to BigQuery untouched. The proxy does not store, inspect, or refresh credentials, and its service account needs no BigQuery permissions.
- **Stateless & single-tenant** — one deployment per organization. No datastore, no cache, no query logging.

### Limitations

- Only the global BigQuery endpoint (`https://bigquery.googleapis.com`) is supported. Regional endpoints (`bigquery.<region>.rep.googleapis.com`) are not supported yet.

## Prerequisites

Before deploying, ensure you have:

1. **A GCP project** with the following APIs enabled:
  - Service Usage API (`serviceusage.googleapis.com`) — required to enable and manage the other APIs. On a brand-new project this is often disabled; enable it first (Console: [enable here](https://console.developers.google.com/apis/api/serviceusage.googleapis.com/overview), or `gcloud services enable serviceusage.googleapis.com --project YOUR_PROJECT`).
  - Cloud Run API (`run.googleapis.com`)
  - IAM API (`iam.googleapis.com`) — Terraform creates a runtime service account for the proxy
  - BigQuery API (`bigquery.googleapis.com`)

  Enable them all in one command:

  ```bash
  gcloud services enable \
    serviceusage.googleapis.com \
    run.googleapis.com \
    iam.googleapis.com \
    bigquery.googleapis.com \
    --project YOUR_PROJECT
  ```

  If you store the Rabbit API key in Secret Manager (recommended — see [Storing the API Keys in Secret Manager](#storing-the-api-keys-in-secret-manager)), also enable `secretmanager.googleapis.com`.
2. **Terraform** >= 1.6 installed locally ([install guide](https://developer.hashicorp.com/terraform/install)), with the **Google provider >= 7.7.0** (the release that promoted `default_uri_disabled` to GA — the module pins `>= 7.7.0, < 8.0`). If you are upgrading from an older pin, run `terraform init -upgrade`.
3. **gcloud CLI** authenticated with a principal that has permissions to create Cloud Run services, service accounts, and IAM bindings. You need **two** logins:
  - `gcloud auth login` — for gcloud CLI commands
  - `gcloud auth application-default login` — Terraform's Google provider authenticates via [Application Default Credentials](https://cloud.google.com/docs/authentication/application-default-credentials) (ADC), which is separate from your gcloud CLI login. Without ADC, `terraform plan`/`apply` fails with a credentials error.
4. **A Rabbit API key** — create one yourself in the Rabbit UI at [app.followrabbit.ai/api-keys](https://app.followrabbit.ai/api-keys) (no need to contact Rabbit support). Without it the proxy runs in pass-through mode (no optimization).

## Container Images

The proxy image is published to Rabbit's central Artifact Registry and replicated to three regional mirrors. **Choose the one closest to the region where you deploy the proxy** to minimize image pull time:


| Region           | Image registry                                                          |
| ---------------- | ----------------------------------------------------------------------- |
| **Americas**     | `us-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy`     |
| **Europe**       | `europe-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy` |
| **Asia-Pacific** | `asia-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy`   |


These are the same image — only the registry location differs. Any authenticated GCP identity can pull these images (the repositories grant `roles/artifactregistry.reader` to `allAuthenticatedUsers`), so the Cloud Run service agent in your project can pull them with no extra IAM setup. Images are versioned with semver tags (e.g. `v0.1.0`) plus a `latest` tag pointing at the newest release. The Terraform in this package deploys `latest` by default; set the `image_tag` variable to a release tag to pin the version (recommended if you want explicit control over upgrades).

## Deployment with Terraform

The [terraform/](terraform/) directory contains the official deployment module for the proxy — the same code Rabbit uses for its own environments and integration tests. You can run it directly as shown below, or consume it as a Terraform module from your own configuration:

```hcl
module "bq_reverse_proxy" {
  source = "git::https://github.com/followrabbit-ai/awesome-rabbit.git//bq-reverse-proxy/terraform"

  project_id      = "my-gcp-project"
  region          = "europe-west3"
  api_keys = { default = var.rabbit_api_key }
}
```

> **Pin the module for production.** The `source` above tracks the default
> branch, so `terraform init` picks up module changes as they land. Note this
> is the opposite of how the image behaves: `image_tag = "latest"` is resolved
> to a digest when a revision is created and will **not** move on its own,
> whereas the module is re-resolved on every `init`.
>
> If you manage change explicitly, pin the module to a commit and bump it
> deliberately — the same discipline as pinning `image_tag` to a release tag
> rather than `latest`:
>
> ```hcl
> source = "git::https://github.com/followrabbit-ai/awesome-rabbit.git//bq-reverse-proxy/terraform?ref=<commit-sha>"
> ```

### Step 1: Configure Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
project_id      = "my-gcp-project"
region          = "europe-west3"
api_keys = { default = "your-rabbit-api-key" }

allow_unauthenticated = true
ingress               = "INGRESS_TRAFFIC_ALL" # or INGRESS_TRAFFIC_INTERNAL_ONLY, see below
```

See [Choosing an Access Model](#choosing-an-access-model) and the [Configuration Reference](#configuration-reference) below. `api_keys` as a plain variable is the quickest start, but it ends up as a plain-text env var on the service — for production, use the Secret Manager-backed setup instead (see [Storing the API Keys in Secret Manager](#storing-the-api-keys-in-secret-manager)).

### Step 2: Initialize and Deploy

```bash
terraform init
terraform plan
terraform apply
```

After deployment, Terraform outputs the proxy URL:

```
service_url = "https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app"
```

### Step 3: Verify

```bash
curl https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app/readyz
# Expected: {"ready":true,...}
```

> Use `/readyz` for external health checks. (`/healthz` also exists but is used by Cloud Run's liveness probe and may be intercepted by the platform.) The proxy also exposes Prometheus metrics on `/metrics`.

## Storing the API Keys in Secret Manager

Setting `api_keys` injects the keys as plain-text env vars: they are stored in the Cloud Run revision spec and visible in the console to anyone with `run.services.get`. The module supports sourcing the whole key map from a **single** Secret Manager secret instead — Cloud Run then resolves it at instance startup, and the console/revision spec only ever show the secret *reference* (e.g. `bq-reverse-proxy-api-keys:latest`), never the keys. Reading the value requires `secretmanager.versions.access` on the secret, which is separately granted and audited.

The secret value is the exact string `api_keys` renders to — `alias=key` pairs, comma-separated, with the reserved alias `default` carrying the fallback key:

```
default=rabbit-key-root,dbt=rabbit-key-dbt,looker=rabbit-key-looker
```

A single-key deployment's secret is just `default=rabbit-key-root`. Alias rules (single path segment, no reserved segments — see [Using Multiple API Keys](#using-multiple-api-keys-with-one-deployment)) still apply; with the secret path they are enforced by the proxy at startup rather than by Terraform.

Prerequisites: `secretmanager.googleapis.com` enabled in the project (see [Prerequisites](#prerequisites)), and proxy image **v0.2.0 or newer** (the first release that understands the `default` alias — older images would treat it as a routable path and start without a fallback key).

### Option A: Module-managed secret

```hcl
# instead of api_keys = { ... }
create_api_keys_secret = true
```

The module creates a secret named `<service_name>-api-keys` and grants the proxy's runtime service account `roles/secretmanager.secretAccessor` on it. The secret is created **empty** — the keys never pass through Terraform, so they appear in neither the Terraform state nor the revision spec. You add them as a secret version out-of-band, and the Cloud Run rollout only succeeds once a version exists, so deploy in two steps:

```bash
# 1. Create the secret first (prefix the address with module.<name>. if you
#    consume this as a module):
terraform apply -target='google_secret_manager_secret.api_keys'

# 2. Add the keys as a secret version:
printf '%s' 'default=YOUR_RABBIT_API_KEY' | gcloud secrets versions add \
  bq-reverse-proxy-api-keys --data-file=- --project YOUR_PROJECT

# 3. Deploy everything else:
terraform apply
```

To rotate keys later, add a new version with the same `gcloud secrets versions add` command (the full mapping each time — versions are immutable snapshots). With the default `api_keys_secret_version = "latest"` the new version takes effect on the next revision rollout (any `terraform apply` that touches the service, or `gcloud run services update <service> --region <region>`); running instances keep the value they resolved at startup.

### Option B: Bring your own secret

If the keys already live in a secret you manage elsewhere (possibly in another project), in the same `default=key0,alias1=key1` format:

```hcl
api_keys_secret         = "my-rabbit-api-keys"                   # short id: secret in project_id
# api_keys_secret       = "projects/other-proj/secrets/my-keys"  # full name: secret in another project
api_keys_secret_version = "latest"                               # or pin a version, e.g. "3"
```

The module does not manage IAM on secrets it doesn't own — grant the proxy's runtime service account access yourself:

```bash
gcloud secrets add-iam-policy-binding my-rabbit-api-keys \
  --member "serviceAccount:bq-reverse-proxy-sa@YOUR_PROJECT.iam.gserviceaccount.com" \
  --role roles/secretmanager.secretAccessor \
  --project PROJECT_OF_THE_SECRET
```

(The runtime service account email is available as the `service_account_email` Terraform output.)

### Permissions needed by whoever runs Terraform

- **Option A** additionally requires permission to create secrets and set IAM policy on them — `roles/secretmanager.admin` on the project covers both.
- **Option B** requires no Secret Manager permission for the Terraform principal at all: the module only writes the secret *reference* into the service config and never reads the secret. Only the runtime service account needs `secretAccessor`, granted by the secret's owner as shown above.

`api_keys`, `create_api_keys_secret`, `api_keys_secret`, and the deprecated `default_api_key`/`api_key_routes` pair are mutually exclusive ways to configure the keys — Terraform fails the plan if more than one is set.

### Pinning secrets to a region

By default Secret Manager replicates a secret automatically across regions (Google-managed, global). If your organization requires secrets to stay in named locations, set `secret_locations`:

```hcl
create_api_keys_secret = true
secret_locations       = ["europe-west3"]   # or [var.region], or several regions
```

This is module-wide rather than per-secret: it applies to every secret the module creates, so residency is configured once. It does **not** apply to a secret you bring yourself via `api_keys_secret` — that one is replicated however you created it.

> **Replication is immutable.** Adding, changing, or removing `secret_locations` on an existing module-managed secret makes Terraform **destroy and recreate** it, which deletes all of its versions. Check the plan, and re-add the keys (`gcloud secrets versions add …`) after the apply.

## Per-Workload Optimizer Configuration

Optimization behavior (pricing mode, reservations, statement-level routing) is normally configured on the Rabbit side per API key. `optimizer_configs` overrides it from your own deployment — self-service, no Rabbit UI involvement — keyed by the same aliases as `api_keys`, with `default` covering root traffic and any alias without its own entry:

```hcl
optimizer_configs = {
  default = { statementLevelOverride = true }
  dbt     = { reservationIds = ["my-project:EU.my-reservation"] }
}
```

Each config object is passed to the optimizer as JSON **verbatim** (camelCase field names, the optimizer's contract), so new optimizer capabilities work without a module update. Currently accepted fields, all optional — absent means "derived by the optimizer": `reservationIds` (list of `project:location.name` or full reservation resource names) and `statementLevelOverride` (bool). The pricing mode is always derived per job project by the optimizer; `defaultPricingModeOverride` is rejected at plan time (and by the optimizer) from this path. Other field-level validation happens per request in the optimizer: an invalid config is logged on both sides and the query fails open (runs unoptimized, never blocked).

How it works: the proxy forwards the matching alias's config with each job submission (the `x-rabbit-optimizer-config` header), where it takes precedence over the API key's server-side configuration. The config is not secret and is deliberately visible: it appears as a plain env var on the service, in the proxy's startup log, and on every optimizer request log line (`configSource: header`) — so "why did this query route on-demand?" is always answerable from the logs. Requires proxy image **v0.2.0 or newer**; against older Rabbit optimizer deployments the header is ignored and the server-side config applies.

## Choosing an Access Model

The proxy forwards your clients' BigQuery OAuth tokens as-is, so a request without a valid BigQuery credential can never read your data. However, the standard BigQuery client SDKs send OAuth access tokens scoped to BigQuery — **not** ID tokens audience-bound to the proxy URL — so they **cannot pass a Cloud Run IAM invoker gate**. Setting `allow_unauthenticated = false` for SDK/tool traffic results in HTML `401` responses from Cloud Run before requests ever reach the proxy.

Protect the endpoint at the network layer instead:


| Model | Settings | When to use |
| ----- | -------- | ----------- |
| **Internal (recommended)** | `allow_unauthenticated = true`, `ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"` | All clients run inside your GCP project / VPC / VPC-SC perimeter (Composer, in-VPC Airflow, dbt on GCE). The URL is unreachable from the internet. |
| **Internal + Load Balancer** | `allow_unauthenticated = true`, `ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"` | You want to front the proxy with your own Google Cloud Load Balancer (custom domain, Cloud Armor allowlists). |
| **Public** | `allow_unauthenticated = true`, `ingress = "INGRESS_TRAFFIC_ALL"` | You use SaaS clients that connect from outside your network (Looker, dbt Cloud). |

Orthogonal to all three: `default_uri_disabled = true` turns off public resolution of the built-in `*.run.app` hostname, so the service is only reachable through an entry point you control. `ingress` decides *where traffic may come from*; this decides *whether the default hostname exists at all*. Pair it with the load-balancer model when policy forbids a Google-assigned public hostname. The `service_url` output still reports that URI, but it will no longer resolve — point clients at your own endpoint.

For the **public** model, note what exposure actually means: the proxy is stateless and holds no data — an anonymous caller without a valid BigQuery OAuth token gets errors from BigQuery, exactly as if they hit `bigquery.googleapis.com` directly. If you want to additionally restrict which networks can reach a public endpoint, put it behind a load balancer with [Cloud Armor](https://cloud.google.com/armor) IP allowlists.

## Using Multiple API Keys with One Deployment

Optimization behavior (pricing mode, reservations, enabled optimizations) is configured on the Rabbit side **per API key**. If all your traffic should use the same settings, `api_keys = { default = "..." }` is all you need — skip this section.

To give different workloads different settings (e.g. dbt production on a reservation, Looker dashboards on-demand), create one API key per workload in the [Rabbit UI](https://app.followrabbit.ai/api-keys) and route each workload to its key. The proxy resolves the key for each request in this order:

1. **`rabbit-api-key` request header** (optional) — for custom code using the BigQuery SDKs, where you can inject HTTP headers (Java's `FixedHeaderProvider`, a custom `http.Client` in Go). Standard tools (Looker, dbt, Airflow, `bq` CLI, JDBC/ODBC drivers) **cannot** send custom headers — see the [capability summary](#client-capability-summary).
2. **Path alias** — the mechanism for everything else. Configure aliases in Terraform:

   ```hcl
   api_keys = {
     default = "rabbit-key-fallback"
     dbt     = "rabbit-key-for-dbt"
     looker  = "rabbit-key-for-looker"
   }
   ```

   This puts the keys in a plain-text env var; to keep them out of the Cloud Run console, source the mapping from Secret Manager instead via `create_api_keys_secret` or `api_keys_secret` — see [Storing the API Keys in Secret Manager](#storing-the-api-keys-in-secret-manager).

   Then point each workload's BigQuery endpoint at `https://<proxy-url>/<alias>`:

   ```
   dbt    →  https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app/dbt
   Looker →  https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app/looker
   ```

   Every client appends the standard `/bigquery/v2/...` path to the endpoint it is given, so requests arrive as `/<alias>/bigquery/v2/...`; the proxy strips the alias, uses that alias's API key, and forwards the canonical path to BigQuery. The API key itself never appears in URLs or request logs — only the alias does.
3. **The `default` key** (`api_keys` entry `default`) — fallback for requests that match neither.

Aliases are single path segments of your choosing (they cannot be `bigquery`, `upload`, `batch`, `discovery`, `healthz`, `readyz`, or `metrics`). Adding, removing, or rotating a routed key is a `terraform apply` (in-place revision, no downtime). Requests with an unknown first path segment are forwarded to BigQuery unchanged, which returns a normal 404.

All client integration guides below work identically with an alias URL — wherever a guide says to use the proxy URL, append `/<alias>`.

### Client Capability Summary

How each supported client points at the proxy, and which options it has for supplying a dedicated API key. Every client can always fall back to the `default` key (no key configuration on the client at all). The `rabbit-api-key` header is always optional — where it is supported it is simply an alternative to a path alias.

| Client | Endpoint configuration | `rabbit-api-key` header | Path alias |
|---|---|---|---|
| Python (`google-cloud-bigquery`) | `client_options.api_endpoint` or `BIGQUERY_EMULATOR_HOST` | ❌ | ✅ |
| Java (`google-cloud-bigquery`) | `BigQueryOptions.setHost(...)` | ✅ `FixedHeaderProvider` | ✅ |
| Node.js (`@google-cloud/bigquery`) | `apiEndpoint` constructor option | ❌ | ✅ |
| Go (`cloud.google.com/go/bigquery`) | `option.WithEndpoint(.../bigquery/v2/)` | ✅ custom `http.Client` | ✅ |
| C# / .NET (`Google.Cloud.BigQuery.V2`) | `BigQueryClientBuilder.BaseUri` | ❌ | ✅ |
| dbt Core | `BIGQUERY_EMULATOR_HOST` env var | ❌ | ✅ |
| dbt Cloud | Extended Attributes `api_endpoint` | ❌ | ✅ |
| Airflow / Cloud Composer / Astronomer | `BIGQUERY_EMULATOR_HOST` env var | ❌ | ✅ |
| Dagster / Mage / Prefect | `BIGQUERY_EMULATOR_HOST` env var | ❌ | ✅ |
| Looker | JDBC `rootUrl` via user attribute | ❌ | ✅ |
| Metabase | **Alternate hostname** field | ❌ | ✅ |
| Lightdash | **BigQuery URL override** field | ❌ | ✅ |
| `bq` CLI | `--api` flag | ❌ | ✅ |
| JDBC (Simba driver) | connection URL / `rootUrl` property | ❌ | ✅ |

Only custom code using the Java or Go SDK can send the header; every standard tool relies on a path alias for a dedicated key, or on the `default` key.

## Connecting Your Clients to the Proxy

Once deployed, configure your BigQuery clients to send requests to the proxy URL instead of the default `bigquery.googleapis.com` endpoint. Below are integration guides for common tools.

> **Multiple workloads?** Each example below uses the bare proxy URL, which resolves to the `default` key. To route a client to a specific API key, use `https://<proxy-url>/<alias>` instead — see [Using Multiple API Keys with One Deployment](#using-multiple-api-keys-with-one-deployment).

### Python (google-cloud-bigquery)

Use the `client_options` parameter to override the API endpoint:

```python
from google.api_core.client_options import ClientOptions
from google.cloud import bigquery

client = bigquery.Client(
    project="my-gcp-project",
    client_options=ClientOptions(
        api_endpoint="https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app"
    ),
)

results = client.query("SELECT 1").result()
for row in results:
    print(row)
```

All queries and job submissions made through this client will be routed through the proxy. Authentication (OAuth tokens) continues to work as before — the proxy passes them through to BigQuery unchanged.

**Alternative: environment variable**

You can also set the `BIGQUERY_EMULATOR_HOST` environment variable. The `google-cloud-bigquery` Python library reads this variable and routes all API traffic to the specified host:

```bash
export BIGQUERY_EMULATOR_HOST=https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

With this set, any `bigquery.Client()` created in the same shell session will automatically route through the proxy — no code changes required.

### dbt Core

dbt Core uses the `google-cloud-bigquery` Python library under the hood. Set the `BIGQUERY_EMULATOR_HOST` environment variable before running dbt:

```bash
export BIGQUERY_EMULATOR_HOST=https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
dbt run
```

This applies to all dbt commands (`dbt run`, `dbt test`, `dbt build`, etc.) in the same shell session. No changes to `profiles.yml` are needed.

### dbt Cloud

In dbt Cloud, you can route BigQuery traffic through the proxy using **Extended Attributes** on your environment:

1. Navigate to **Environments** in your dbt Cloud project.
2. Select the environment you want to configure and open its **Settings**.
3. In the **Extended Attributes** section, add the following YAML:

```yaml
api_endpoint: https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

4. Click **Save**.

All dbt jobs running in that environment will now route their BigQuery API calls through the proxy. You can configure this per-environment, so you can test with a staging environment first before applying to production.

> dbt Cloud connects from outside your network, so this requires the **public** access model.

**A few things that are easy to miss:**

- **Your BigQuery credential still does the authentication.** The proxy only changes *where* the API calls go — it forwards your connection's existing credential (service-account key, OAuth, or WIF) to BigQuery untouched. It does not authenticate on your behalf, and it needs no BigQuery permissions of its own. If your connection's credential is missing or invalid, jobs fail with a normal BigQuery auth error, not a proxy error.
- **Extended Attributes are set per environment.** Each environment you want routed — every deployment environment *and* the development (IDE) environment — needs its own `api_endpoint`. In dbt Cloud they are stored as a separate object attached to the environment, so be careful editing an environment through the API: an update that omits the extended-attributes reference will detach it and silently send traffic straight to BigQuery again.
- **Include the full path if the proxy is behind a load balancer.** The example URL is a bare Cloud Run hostname, which is correct for the public access model. If you front the proxy with a load balancer on a path prefix (e.g. `https://api.example.com/bq-reverse-proxy`), set `api_endpoint` to that full URL including the prefix.

To confirm traffic is actually flowing through the proxy, run a model and check that the proxy's `/metrics` counters (e.g. `bq_proxy_requests_total`) increase, or look at its logs for the forwarded job submissions.

### Apache Airflow

For Airflow deployments running BigQuery operators (e.g. `BigQueryInsertJobOperator`), set the `BIGQUERY_EMULATOR_HOST` environment variable on your Airflow workers:

```bash
export BIGQUERY_EMULATOR_HOST=https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

All BigQuery API calls made by Airflow operators in that worker process will be routed through the proxy.

### Google Cloud Composer

For Cloud Composer environments, set the `BIGQUERY_EMULATOR_HOST` environment variable through the Composer configuration. See the [Composer environment variables documentation](https://docs.cloud.google.com/composer/docs/composer-3/set-environment-variables#gcloud) for all available methods (Console, gcloud, API, Terraform).

**gcloud CLI:**

```bash
gcloud composer environments update ENVIRONMENT_NAME \
  --location LOCATION \
  --update-env-variables=BIGQUERY_EMULATOR_HOST=https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

**Terraform:**

```hcl
resource "google_composer_environment" "test" {
  name   = "mycomposer"
  region = "us-central1"

  config {
    software_config {
      env_variables = {
        BIGQUERY_EMULATOR_HOST = "https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app"
      }
    }
  }
}
```

All DAGs running in the Composer environment will automatically route their BigQuery API calls through the proxy.

### Astronomer

Astronomer-hosted Airflow works the same way as self-managed Airflow: set `BIGQUERY_EMULATOR_HOST=https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app` as a deployment environment variable (Deployment → Variables in the Astronomer UI, or via `astro deployment variable create`). See the [Astronomer environment variables documentation](https://www.astronomer.io/docs/astro/environment-variables).

> Astronomer deployments connect from outside your network, so this requires the **public** access model.

### Dagster / Mage / Prefect

These orchestrators all use the `google-cloud-bigquery` Python library under the hood, so the same environment variable works — set it on the workers/agents that execute your pipelines (Docker, Kubernetes, etc.):

```bash
export BIGQUERY_EMULATOR_HOST=https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

### Looker

Looker connects to BigQuery via JDBC. You can route Looker's BigQuery traffic through the proxy by overriding the JDBC `rootUrl` parameter using a **user attribute**. This approach lets you roll out the change gradually — starting with a few test users before enabling it for everyone.

> Looker (hosted) connects from outside your network, so this requires the **public** access model.

#### Step 1: Create a User Attribute

1. In Looker, navigate to **Admin > User Attributes** ([docs](https://docs.cloud.google.com/looker/docs/admin-panel-users-user-attributes)).
2. Click **Create User Attribute** and configure it as follows:


| Setting           | Value                             |
| ----------------- | --------------------------------- |
| **Name**          | `rabbit_bq_proxy_url`             |
| **Label**         | Rabbit BQ Proxy URL               |
| **Data Type**     | String                            |
| **User Access**   | None                              |
| **Default Value** | `https://bigquery.googleapis.com` |


The default value points to the standard BigQuery API, so all users continue working normally until you explicitly override it.

#### Step 2: Override the Value for Test Users or Groups

1. On the same User Attribute page, click the **Group Values** tab (or **User Values** for individual users).
2. Click **+ Add Group** and select the group you want to test with (e.g. a "BQ Proxy Pilot" group). See the [Groups documentation](https://docs.cloud.google.com/looker/docs/admin-panel-users-groups) for managing groups.
3. Set the **Value** to your proxy Cloud Run URL:

```
https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

4. Click **Save**. Only users in this group will have their traffic routed through the proxy.

#### Step 3: Configure the BigQuery Connection

1. Navigate to **Admin > Connections** and click **Edit** on your BigQuery connection.
2. In the **Additional Settings** section, find the **Additional JDBC parameters** field.
3. Add the following parameter:

```
rootUrl={{ _user_attributes['rabbit_bq_proxy_url'] }}
```

4. Click **Save**.

This uses Looker's [Liquid templating](https://docs.cloud.google.com/looker/docs/admin-panel-users-user-attributes#database_connections) to dynamically inject the proxy URL from the user attribute. Users with the default value will continue connecting directly to BigQuery; users with the override will go through the proxy.

#### Step 4: Reauthenticate the Connection

For the JDBC parameter change to take effect, you must **reauthenticate** the connection. On the connection edit page, reauthenticate and test the connection to confirm it works through the proxy.

#### Step 5: Roll Out to All Users

Once you've validated that the proxy works correctly with your test users/groups:

1. Go back to **Admin > User Attributes** and select `rabbit_bq_proxy_url`.
2. Change the **Default Value** to your proxy URL:

```
https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

3. Remove any group-level overrides that are no longer needed.

All Looker users will now have their BigQuery traffic routed through the proxy. To revert at any time, change the default value back to `https://bigquery.googleapis.com`.

### Metabase

1. Navigate to **Admin → Databases** and select your BigQuery database.
2. Expand the advanced options and set the **Alternate hostname** field to the proxy URL:

```
https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

3. Save. All Metabase queries against that database now route through the proxy.

> Metabase Cloud connects from outside your network, so this requires the **public** access model. Self-hosted Metabase inside your VPC can use the internal model.

### Lightdash

In your project's connection settings, find the **BigQuery URL override** section and set it to the proxy URL:

```
https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

> Lightdash Cloud connects from outside your network, so this requires the **public** access model.

### bq CLI

```bash
bq --api https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app query "SELECT 1"
```

### JDBC (Simba driver)

```
jdbc:bigquery://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app:443;ProjectId=my-project;OAuthType=...
```

### Java (google-cloud-bigquery)

```java
BigQuery bigquery = BigQueryOptions.newBuilder()
    .setProjectId("my-gcp-project")
    .setHost("https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app")
    .build()
    .getService();
```

Java is also one of the few clients that can send the `rabbit-api-key` header directly — an alternative to path aliases for per-workload keys:

```java
import com.google.api.gax.rpc.FixedHeaderProvider;

BigQuery bigquery = BigQueryOptions.newBuilder()
    .setProjectId("my-gcp-project")
    .setHost("https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app")
    .setHeaderProvider(FixedHeaderProvider.create("rabbit-api-key", System.getenv("RABBIT_API_KEY")))
    .build()
    .getService();
```

### Node.js (@google-cloud/bigquery)

```js
const { BigQuery } = require("@google-cloud/bigquery");

const bigquery = new BigQuery({
  projectId: "my-gcp-project",
  apiEndpoint: "https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app",
});
```

### Go (cloud.google.com/go/bigquery)

The Go client takes the full API base URL including the `/bigquery/v2/` path:

```go
client, err := bigquery.NewClient(ctx, "my-gcp-project",
    option.WithEndpoint("https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app/bigquery/v2/"))
```

For per-workload keys, either use a path alias (`.../myalias/bigquery/v2/`) or inject the `rabbit-api-key` header with a custom `http.Client` via `option.WithHTTPClient`.

### C# / .NET (Google.Cloud.BigQuery.V2)

The .NET client takes the full API base URL including the `/bigquery/v2/` path:

```csharp
var client = new BigQueryClientBuilder
{
    ProjectId = "my-gcp-project",
    BaseUri = "https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app/bigquery/v2/",
}.Build();
```

### Clients that cannot be routed

These tools offer no BigQuery API endpoint override, so they cannot use the proxy (or any BigQuery proxy):

- Google Looker Studio (Data Studio)
- Google Connected Sheets
- GCP-managed Dataform
- BigQuery console UI

## Configuration Reference

### Terraform Variables


| Variable | Required | Default | Description |
|---|---|---|---|
| `project_id` | **Yes** | — | GCP project ID for deployment |
| `region` | **Yes** | — | GCP region for the Cloud Run service |
| `bq_job_optimizer_url` | No | `https://api.followrabbit.ai/bq-job-optimizer` | Rabbit BQ Job Optimizer URL. The default is the global public endpoint — right for everyone. `""` = pass-through mode |
| `api_keys` | No | `{}` | Alias → Rabbit API key map as a plain env var; the reserved alias `default` is the fallback key (see [Using Multiple API Keys](#using-multiple-api-keys-with-one-deployment)). Prefer the Secret Manager variants below (see [Storing the API Keys in Secret Manager](#storing-the-api-keys-in-secret-manager)) |
| `create_api_keys_secret` | No | `false` | Create a Secret Manager secret for the whole key map; you add the keys (`default=key0,alias1=key1`) as a secret version out-of-band. Needs image ≥ v0.2.0 |
| `api_keys_secret` | No | `null` | Existing Secret Manager secret holding the key map (short id, or `projects/*/secrets/*` for cross-project). Needs image ≥ v0.2.0 |
| `api_keys_secret_version` | No | `latest` | Secret version to pin when the keys come from Secret Manager |
| `secret_locations` | No | `[]` (automatic/global) | Regions every module-created secret is replicated to (see [Pinning secrets to a region](#pinning-secrets-to-a-region)). Changing it recreates the secret |
| `optimizer_configs` | No | `{}` | Per-workload optimizer config keyed by `api_keys` alias (see [Per-Workload Optimizer Configuration](#per-workload-optimizer-configuration)) |
| `default_api_key` | No | `null` | **Deprecated** — use `api_keys = { default = "..." }`. Still works |
| `api_key_routes` | No | `{}` | **Deprecated** — use `api_keys` with non-`default` aliases. Still works |
| `image_registry` | No | `europe-docker.pkg.dev/.../bq-reverse-proxy` | Registry path without tag (see [Container Images](#container-images)) |
| `image_tag` | No | `latest` | Image version to deploy. Set a release tag (e.g. `v0.1.0`) to pin |
| `allow_unauthenticated` | No | `false` | Grant `run.invoker` to `allUsers` (see [Choosing an Access Model](#choosing-an-access-model)) |
| `ingress` | No | `INGRESS_TRAFFIC_ALL` | `..._ALL`, `..._INTERNAL_ONLY`, or `..._INTERNAL_LOAD_BALANCER` |
| `default_uri_disabled` | No | `false` | Disable public resolution of the default `*.run.app` URI (see [Choosing an Access Model](#choosing-an-access-model)). Needs google provider ≥ 7.7.0 |
| `invoker_members` | No | `[]` | IAM principals granted `run.invoker` (only when `allow_unauthenticated = false`) |
| `service_name` | No | `bq-reverse-proxy` | Cloud Run service name |
| `service_account_email` | No | `null` (created) | Bring your own runtime service account |
| `min_instances` | No | `1` | Minimum instances (1+ avoids cold starts) |
| `max_instances` | No | `50` | Maximum instances |
| `cpu` | No | `1` | vCPUs per instance |
| `memory` | No | `512Mi` | Memory per instance |
| `log_level` | No | `info` | `debug`, `info`, `warn`, `error` |
| `bq_api_target_url` | No | `https://bigquery.googleapis.com` | Upstream BigQuery API URL |
| `request_timeout` | No | `10m` | Upstream request timeout (Go duration) |
| `bq_job_optimizer_timeout` | No | `2s` | Optimizer call timeout (Go duration); fail-open on expiry |
| `max_body_bytes` | No | `1048576` | Max body size buffered for optimization; larger bodies pass through untouched |
| `enable_pool_reroute` | No | `false` | Move jobs the optimizer places in an on-demand pool project, and resolve the client's job-scoped calls to wherever the job ran. Requires `bq_job_optimizer_url` + a **configured** API key (see below), and proxy image >= `v0.3.0` |
| `vpc_connector` | No | `null` | VPC access connector ID. Mutually exclusive with `vpc_network` |
| `vpc_network` | No | `null` | Direct VPC egress network, `projects/<host>/global/networks/<name>`. No connector instances needed |
| `vpc_subnetwork` | No | `null` | Direct VPC egress subnetwork, `projects/<host>/regions/<region>/subnetworks/<name>`. Region must match the service. Required with `vpc_network` |
| `vpc_egress` | No | `PRIVATE_RANGES_ONLY` | VPC egress mode. Use `ALL_TRAFFIC` to route googleapis calls through the VPC |
| `labels` | No | `{}` | Labels for created resources |
| `extra_env` | No | `{}` | Extra container environment variables |

Note that pricing mode and reservation configuration are no longer proxy settings — Rabbit manages optimization behavior server-side, keyed by your API key. Contact your Rabbit representative to change them.

### Environment Variables (Advanced)

These are the environment variables the proxy container reads. The Terraform configuration sets all of them from the variables above. If you deploy without Terraform (e.g. `gcloud run deploy`), set these directly on the container.

| Variable | Default | Terraform Variable | Description |
|---|---|---|---|
| `PORT` | `8080` | — (managed by Cloud Run) | HTTP listen port |
| `BQ_API_TARGET_URL` | `https://bigquery.googleapis.com` | `bq_api_target_url` | Upstream BigQuery API URL |
| `BQ_JOB_OPTIMIZER_URL` | _(empty = pass-through)_ | `bq_job_optimizer_url` | Rabbit optimizer base URL. The Terraform default is `https://api.followrabbit.ai/bq-job-optimizer` |
| `BQ_JOB_OPTIMIZER_TIMEOUT` | `2s` | `bq_job_optimizer_timeout` | Optimizer call timeout |
| `DEFAULT_API_KEY` | _(unset)_ | `api_keys` entry `default` | Fallback Rabbit API key |
| `API_KEY_ROUTES` | _(unset)_ | `api_keys` (non-`default` aliases) | Path alias → key map, `alias1=key1,alias2=key2` |
| `REQUEST_TIMEOUT` | `10m` | `request_timeout` | Upstream request timeout |
| `MAX_BODY_BYTES` | `1048576` | `max_body_bytes` | Max buffered body size |
| `LOG_LEVEL` | `info` | `log_level` | Log verbosity |
| `ENABLE_POOL_REROUTE` | _(unset = off)_ | `enable_pool_reroute` | On-demand pool rerouting. Pool projects are read from the optimizer, not configured here |

### Pool rerouting needs a key of its own

Turning on `enable_pool_reroute` requires an API key the proxy can use **on its
own behalf**, because it reads the pool project list from the optimizer on a
background refresh — not on the back of a client request.

This catches out a deployment where every client sends its own `rabbit-api-key`
header. That works fine for per-request optimization, so it can look like the
proxy "has" a key. The background refresh has no incoming request to take one
from, so with the flag on and nothing configured the proxy refuses to start:

```
failed to load config: ENABLE_POOL_REROUTE=true requires an API key (DEFAULT_API_KEY or API_KEY_ROUTES)
```

Supply one through `api_keys` (a `default` alias, or any route alias) or the
Secret Manager options.

> **A secret that exists but is empty passes the plan.** The module's
> precondition checks that a key mechanism is *configured*; Terraform cannot
> read the secret's value. An empty secret therefore plans cleanly and fails
> when the container starts — the revision never becomes ready, and traffic
> stays on the previous one.

The pool list is **per-tenant**: use a key belonging to the tenant whose pool
the jobs should land in, since the proxy allowlists only that tenant's pool
projects.


## Updating the Proxy

> **Note (empty API keys).** An API key given as an empty string is now treated
> as *no key*, the same as omitting it — previously it rendered `DEFAULT_API_KEY`
> as an empty environment variable, which looked configured but could not be
> used. Blank-valued entries in `api_keys` / `api_key_routes` are dropped for the
> same reason. If you were passing an empty value (easy to do when wiring a key
> from a CI secret that is not set — GitHub Actions substitutes `""`), your next
> `terraform apply` will create a new revision that simply omits the variable.
> Behaviour is unchanged; the proxy treated both as no key. What does change:
> `enable_pool_reroute = true` with only blank keys now fails at plan time with
> a clear message instead of producing a revision that cannot start.


By default this package deploys the `latest` release tag. Because the tag itself doesn't change between releases, a plain `terraform apply` sees no diff — force a new revision to pull the newest image:

```bash
terraform apply -replace="google_cloud_run_v2_service.proxy"
```

> **Public deployments:** replacing the service destroys and recreates it, which wipes its IAM policy — including the `allUsers` invoker binding from `allow_unauthenticated = true`. The service will return `403` until the binding is re-applied. Replace the invoker binding in the **same** apply so it's recreated alongside the service:
>
> ```bash
> terraform apply \
>   -replace="google_cloud_run_v2_service.proxy" \
>   -replace='google_cloud_run_v2_service_iam_member.public_invoker[0]'
> ```
>
> Pinning `image_tag` (below) avoids this entirely — it updates the service in place without recreation.

**Pinning versions instead (recommended for production change management):** set the `image_tag` variable to a release tag and bump it deliberately — each change is a normal, reviewable Terraform diff:

```hcl
image_tag = "v0.1.0"
```

Running deployments are never changed automatically either way — Cloud Run resolves the image when a revision is created, so a new release only reaches you when you apply.

## Removing the Proxy

```bash
terraform destroy
```

This removes the Cloud Run service, service account, and IAM bindings. Your BigQuery data and configurations are unaffected. Remember to point your clients back to `https://bigquery.googleapis.com`.

## Performance Testing

The [perftest/](perftest/) directory contains a standalone Go CLI tool for benchmarking the proxy against direct BigQuery API calls. Use it to verify that the proxy adds negligible overhead in your environment.

```bash
cd perftest
go build -o perftest main.go
./perftest --project-id=YOUR_PROJECT --proxy-url=https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app
```

The tool runs four scenario categories — small queries (latency overhead), medium queries (throughput), large queries (streaming & memory), and concurrent load (scale). See the [perftest README](perftest/README.md) for full documentation, flags, and usage examples. In Rabbit's own testing the proxy adds ~10–50ms at p50 for small queries and streams multi-MB result sets with kilobyte-range memory overhead.

## Migrating from the old BQ Proxy

If you deployed the previous `bq-proxy` package from this repository:

1. Deploy the new proxy alongside the old one (this package uses the service name `bq-reverse-proxy`, so no conflicts).
2. Note the config changes: `rabbit_api_key` → `api_keys` entry `default`, `rabbit_api_base_url` → `bq_job_optimizer_url` (defaults to the global public endpoint — normally nothing to set), and `default_pricing_mode` / `reservation_ids` are gone (managed server-side by Rabbit).
3. Switch your clients' endpoint to the new proxy URL.
4. `terraform destroy` the old deployment.

## Troubleshooting


| Symptom                              | Likely Cause               | Fix                                                                                                                                       |
| ------------------------------------ | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Image pull fails on deploy           | Artifact Registry access   | The registry allows all authenticated GCP identities to pull. Make sure the Cloud Run service agent exists (deploy once) and the region prefix in `image_registry` is valid |
| HTML `401` on every request          | Cloud Run IAM gate         | You set `allow_unauthenticated = false` with SDK clients. Use `allow_unauthenticated = true` + network-level protection (see [Choosing an Access Model](#choosing-an-access-model)) |
| `404` / connection refused           | Ingress setting            | `INGRESS_TRAFFIC_INTERNAL_ONLY` blocks traffic from outside your VPC — SaaS clients (Looker, dbt Cloud) need `INGRESS_TRAFFIC_ALL`             |
| Health check passes but queries fail | BigQuery API not enabled   | Enable `bigquery.googleapis.com` on your project                                                                                          |
| Queries succeed but no optimization  | Missing or invalid API key | Verify the `default` API key is set correctly and `bq_job_optimizer_url` was not overridden. Check logs: `gcloud run services logs read bq-reverse-proxy --region=REGION` |
| High latency on first request        | Cold start                 | Increase `min_instances` to 1 or higher                                                                                                   |


## Support

Create your API key yourself in the Rabbit UI at [app.followrabbit.ai/api-keys](https://app.followrabbit.ai/api-keys). For any other issues with the proxy, contact your Rabbit representative or reach out to [support@followrabbit.ai](mailto:support@followrabbit.ai).
