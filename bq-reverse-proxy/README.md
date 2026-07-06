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
  - Cloud Run API (`run.googleapis.com`)
  - BigQuery API (`bigquery.googleapis.com`)
2. **Terraform** >= 1.6 installed locally ([install guide](https://developer.hashicorp.com/terraform/install))
3. **gcloud CLI** authenticated with a principal that has permissions to create Cloud Run services, service accounts, and IAM bindings
4. **A Rabbit API key** from your Rabbit representative — without it the proxy runs in pass-through mode (no optimization)

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
  default_api_key = var.rabbit_api_key
}
```

### Step 1: Configure Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
project_id      = "my-gcp-project"
region          = "europe-west3"
default_api_key = "your-rabbit-api-key"

allow_unauthenticated = true
ingress               = "INGRESS_TRAFFIC_ALL" # or INGRESS_TRAFFIC_INTERNAL, see below
```

See [Choosing an Access Model](#choosing-an-access-model) and the [Configuration Reference](#configuration-reference) below.

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

## Choosing an Access Model

The proxy forwards your clients' BigQuery OAuth tokens as-is, so a request without a valid BigQuery credential can never read your data. However, the standard BigQuery client SDKs send OAuth access tokens scoped to BigQuery — **not** ID tokens audience-bound to the proxy URL — so they **cannot pass a Cloud Run IAM invoker gate**. Setting `allow_unauthenticated = false` for SDK/tool traffic results in HTML `401` responses from Cloud Run before requests ever reach the proxy.

Protect the endpoint at the network layer instead:


| Model | Settings | When to use |
| ----- | -------- | ----------- |
| **Internal (recommended)** | `allow_unauthenticated = true`, `ingress = "INGRESS_TRAFFIC_INTERNAL"` | All clients run inside your GCP project / VPC / VPC-SC perimeter (Composer, in-VPC Airflow, dbt on GCE). The URL is unreachable from the internet. |
| **Internal + Load Balancer** | `allow_unauthenticated = true`, `ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"` | You want to front the proxy with your own Google Cloud Load Balancer (custom domain, Cloud Armor allowlists). |
| **Public** | `allow_unauthenticated = true`, `ingress = "INGRESS_TRAFFIC_ALL"` | You use SaaS clients that connect from outside your network (Looker, dbt Cloud). |

For the **public** model, note what exposure actually means: the proxy is stateless and holds no data — an anonymous caller without a valid BigQuery OAuth token gets errors from BigQuery, exactly as if they hit `bigquery.googleapis.com` directly. If you want to additionally restrict which networks can reach a public endpoint, put it behind a load balancer with [Cloud Armor](https://cloud.google.com/armor) IP allowlists.

## Connecting Your Clients to the Proxy

Once deployed, configure your BigQuery clients to send requests to the proxy URL instead of the default `bigquery.googleapis.com` endpoint. Below are integration guides for common tools.

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

### bq CLI

```bash
bq --api https://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app query "SELECT 1"
```

### JDBC (Simba driver)

```
jdbc:bigquery://bq-reverse-proxy-xxxxxxxxxx-ey.a.run.app:443;ProjectId=my-project;OAuthType=...
```

## Configuration Reference

### Terraform Variables


| Variable | Required | Default | Description |
|---|---|---|---|
| `project_id` | **Yes** | — | GCP project ID for deployment |
| `region` | **Yes** | — | GCP region for the Cloud Run service |
| `bq_job_optimizer_url` | No | `https://api.followrabbit.ai/bq-job-optimizer` | Rabbit BQ Job Optimizer URL. The default is the global public endpoint — right for everyone. `""` = pass-through mode |
| `default_api_key` | No | `null` | Rabbit API key used for requests without a `rabbit-api-key` header. In practice: set it (standard BQ tools can't send custom headers) |
| `image_registry` | No | `europe-docker.pkg.dev/.../bq-reverse-proxy` | Registry path without tag (see [Container Images](#container-images)) |
| `image_tag` | No | `latest` | Image version to deploy. Set a release tag (e.g. `v0.1.0`) to pin |
| `allow_unauthenticated` | No | `false` | Grant `run.invoker` to `allUsers` (see [Choosing an Access Model](#choosing-an-access-model)) |
| `ingress` | No | `INGRESS_TRAFFIC_ALL` | `..._ALL`, `..._INTERNAL`, or `..._INTERNAL_LOAD_BALANCER` |
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
| `vpc_connector` | No | `null` | VPC access connector ID |
| `vpc_egress` | No | `PRIVATE_RANGES_ONLY` | VPC egress mode (only with `vpc_connector`) |
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
| `DEFAULT_API_KEY` | _(unset)_ | `default_api_key` | Fallback Rabbit API key |
| `REQUEST_TIMEOUT` | `10m` | `request_timeout` | Upstream request timeout |
| `MAX_BODY_BYTES` | `1048576` | `max_body_bytes` | Max buffered body size |
| `LOG_LEVEL` | `info` | `log_level` | Log verbosity |


## Updating the Proxy

By default this package deploys the `latest` release tag. Because the tag itself doesn't change between releases, a plain `terraform apply` sees no diff — force a new revision to pull the newest image:

```bash
terraform apply -replace="google_cloud_run_v2_service.proxy"
```

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
2. Note the config changes: `rabbit_api_key` → `default_api_key`, `rabbit_api_base_url` → `bq_job_optimizer_url` (defaults to the global public endpoint — normally nothing to set), and `default_pricing_mode` / `reservation_ids` are gone (managed server-side by Rabbit).
3. Switch your clients' endpoint to the new proxy URL.
4. `terraform destroy` the old deployment.

## Troubleshooting


| Symptom                              | Likely Cause               | Fix                                                                                                                                       |
| ------------------------------------ | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Image pull fails on deploy           | Artifact Registry access   | The registry allows all authenticated GCP identities to pull. Make sure the Cloud Run service agent exists (deploy once) and the region prefix in `image_registry` is valid |
| HTML `401` on every request          | Cloud Run IAM gate         | You set `allow_unauthenticated = false` with SDK clients. Use `allow_unauthenticated = true` + network-level protection (see [Choosing an Access Model](#choosing-an-access-model)) |
| `404` / connection refused           | Ingress setting            | `INGRESS_TRAFFIC_INTERNAL` blocks traffic from outside your VPC — SaaS clients (Looker, dbt Cloud) need `INGRESS_TRAFFIC_ALL`             |
| Health check passes but queries fail | BigQuery API not enabled   | Enable `bigquery.googleapis.com` on your project                                                                                          |
| Queries succeed but no optimization  | Missing or invalid API key | Verify `default_api_key` is set correctly and `bq_job_optimizer_url` was not overridden. Check logs: `gcloud run services logs read bq-reverse-proxy --region=REGION` |
| High latency on first request        | Cold start                 | Increase `min_instances` to 1 or higher                                                                                                   |


## Support

For issues with the proxy or to obtain an API key, contact your Rabbit representative or reach out to [support@followrabbit.ai](mailto:support@followrabbit.ai).
