# Rabbit BQ Proxy

**Rabbit BQ Proxy** is a lightweight reverse proxy that sits between your BigQuery clients and the Google BigQuery API. It transparently forwards all traffic while selectively optimizing job submissions to reduce your BigQuery costs — with zero changes to your existing queries, tools, or workflows.

## How It Works

```
┌──────────────┐         ┌──────────────┐         ┌──────────────────────┐
│  Your Tools  │         │   BQ Proxy   │         │  BigQuery API        │
│  (Looker,    │──req──▶ │              │──req──▶ │  bigquery.googleapis │
│   dbt, etc.) │◀─res──  │  Cloud Run   │◀─res──  │  .com                │
└──────────────┘         └──────┬───────┘         └──────────────────────┘
                                │
                         ┌──────▼───────┐
                         │  Rabbit API  │
                         │  (Optimizer) │
                         └──────────────┘
```

1. **Your BigQuery clients** send requests to the proxy instead of directly to `bigquery.googleapis.com`.
2. **The proxy forwards everything transparently** — reads, metadata calls, and results stream through unchanged.
3. **For job submissions** (`jobs.insert`, `jobs.query`), the proxy consults Rabbit's optimization API to determine the most cost-effective execution strategy (e.g., routing to reservations vs. on-demand pricing).
4. **The optimized request** is forwarded to BigQuery. If anything goes wrong during optimization, the **original request is forwarded unchanged** (fail-open design).

### Key Properties

- **Zero client changes** — point your BigQuery endpoint to the proxy URL and everything works.
- **Fail-open** — if the optimizer is unreachable or returns an error, the original query runs as-is. Your workloads are never blocked.
- **Streaming** — responses are streamed, not buffered. Even large result sets pass through without extra memory overhead.
- **No credential handling** — OAuth tokens from your clients pass through to BigQuery untouched. The proxy does not store or inspect credentials.

## Prerequisites

Before deploying, ensure you have:

1. **A GCP project** with the following APIs enabled:
  - Cloud Run API (`run.googleapis.com`)
  - BigQuery API (`bigquery.googleapis.com`)
  - Artifact Registry API (`artifactregistry.googleapis.com`)
2. **Terraform** >= 1.3 installed locally ([install guide](https://developer.hashicorp.com/terraform/install))
3. **gcloud CLI** authenticated with a principal that has permissions to create Cloud Run services, service accounts, and IAM bindings
4. **A Rabbit API key** — contact your Rabbit representative to obtain one. Without a key, the proxy runs in pass-through mode (no optimization).

## Container Images

The BQ Proxy image is published to three regional Artifact Registry repositories. **Choose the one closest to the GCP region where your BigQuery datasets and reservations reside** to minimize latency:


| Region           | Image                                                                |
| ---------------- | -------------------------------------------------------------------- |
| **Americas**     | `us-docker.pkg.dev/rbt-prod-app-eu/rbt-bq-proxy/bq-proxy:latest`     |
| **Europe**       | `europe-docker.pkg.dev/rbt-prod-app-eu/rbt-bq-proxy/bq-proxy:latest` |
| **Asia-Pacific** | `asia-docker.pkg.dev/rbt-prod-app-eu/rbt-bq-proxy/bq-proxy:latest`   |


These are the same image built from the same source — only the registry location differs. Pulling from a regional registry avoids cross-region transfer costs and reduces image pull time on Cloud Run.

## Deployment with Terraform

The `[terraform/](terraform/)` directory contains a ready-to-use Terraform configuration that deploys the BQ Proxy to Cloud Run.

### Files


| File                                 | Description                                                     |
| ------------------------------------ | --------------------------------------------------------------- |
| `terraform/main.tf`                  | Cloud Run service, service account, and IAM configuration       |
| `terraform/variables.tf`             | All configurable input variables with descriptions and defaults |
| `terraform/outputs.tf`               | Service URL, name, and service account email                    |
| `terraform/terraform.tfvars.example` | Example variable values — copy and customize                    |


### Step 1: Configure Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
project_id     = "my-gcp-project"
region         = "us-central1"
rabbit_api_key = "your-rabbit-api-key"
image          = "us-docker.pkg.dev/rbt-prod-app-eu/rbt-bq-proxy/bq-proxy:latest"
```

See the [Configuration Reference](#configuration-reference) below for all available options.

### Step 2: Initialize and Deploy

```bash
terraform init
terraform plan
terraform apply
```

After deployment, Terraform outputs the proxy URL:

```
service_url = "https://bq-proxy-xxxxxxxxxx-uc.a.run.app"
```

### Step 3: Verify

```bash
curl https://bq-proxy-xxxxxxxxxx-uc.a.run.app/healthz
# Expected: {"status":"ok"}
```

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
        api_endpoint="https://bq-proxy-xxxxxxxxxx-uc.a.run.app"
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
export BIGQUERY_EMULATOR_HOST=https://bq-proxy-xxxxxxxxxx-uc.a.run.app
```

With this set, any `bigquery.Client()` created in the same shell session will automatically route through the proxy — no code changes required.

### dbt Core

dbt Core uses the `google-cloud-bigquery` Python library under the hood. Set the `BIGQUERY_EMULATOR_HOST` environment variable before running dbt:

```bash
export BIGQUERY_EMULATOR_HOST=https://bq-proxy-xxxxxxxxxx-uc.a.run.app
dbt run
```

This applies to all dbt commands (`dbt run`, `dbt test`, `dbt build`, etc.) in the same shell session. No changes to `profiles.yml` are needed.

### dbt Cloud

In dbt Cloud, you can route BigQuery traffic through the proxy using **Extended Attributes** on your environment:

1. Navigate to **Environments** in your dbt Cloud project.
2. Select the environment you want to configure and open its **Settings**.
3. In the **Extended Attributes** section, add the following YAML:

```yaml
api_endpoint: https://bq-proxy-xxxxxxxxxx-uc.a.run.app
```

4. Click **Save**.

All dbt jobs running in that environment will now route their BigQuery API calls through the proxy. You can configure this per-environment, so you can test with a staging environment first before applying to production.

### Apache Airflow

For Airflow deployments running BigQuery operators (e.g. `BigQueryInsertJobOperator`), set the `BIGQUERY_EMULATOR_HOST` environment variable on your Airflow workers:

```bash
export BIGQUERY_EMULATOR_HOST=https://bq-proxy-xxxxxxxxxx-uc.a.run.app
```

All BigQuery API calls made by Airflow operators in that worker process will be routed through the proxy.

### Google Cloud Composer

For Cloud Composer environments, set the `BIGQUERY_EMULATOR_HOST` environment variable through the Composer configuration. See the [Composer environment variables documentation](https://docs.cloud.google.com/composer/docs/composer-3/set-environment-variables#gcloud) for all available methods (Console, gcloud, API, Terraform).

**gcloud CLI:**

```bash
gcloud composer environments update ENVIRONMENT_NAME \
  --location LOCATION \
  --update-env-variables=BIGQUERY_EMULATOR_HOST=https://bq-proxy-xxxxxxxxxx-uc.a.run.app
```

**Terraform:**

```hcl
resource "google_composer_environment" "test" {
  name   = "mycomposer"
  region = "us-central1"

  config {
    software_config {
      env_variables = {
        BIGQUERY_EMULATOR_HOST = "https://bq-proxy-xxxxxxxxxx-uc.a.run.app"
      }
    }
  }
}
```

All DAGs running in the Composer environment will automatically route their BigQuery API calls through the proxy.

### Looker

Looker connects to BigQuery via JDBC. You can route Looker's BigQuery traffic through the proxy by overriding the JDBC `rootUrl` parameter using a **user attribute**. This approach lets you roll out the change gradually — starting with a few test users before enabling it for everyone.

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
3. Set the **Value** to your BQ Proxy Cloud Run URL:

```
https://bq-proxy-xxxxxxxxxx-uc.a.run.app
```

1. Click **Save**. Only users in this group will have their traffic routed through the proxy.

#### Step 3: Configure the BigQuery Connection

1. Navigate to **Admin > Connections** and click **Edit** on your BigQuery connection.
2. In the **Additional Settings** section, find the **Additional JDBC parameters** field.
3. Add the following parameter:

```
rootUrl={{ _user_attributes['rabbit_bq_proxy_url'] }}
```

1. Click **Save**.

This uses Looker's [Liquid templating](https://docs.cloud.google.com/looker/docs/admin-panel-users-user-attributes#database_connections) to dynamically inject the proxy URL from the user attribute. Users with the default value will continue connecting directly to BigQuery; users with the override will go through the proxy.

#### Step 4: Reauthenticate the Connection

For the JDBC parameter change to take effect, you must **reauthenticate** the connection. On the connection edit page, reauthenticate and test the connection to confirm it works through the proxy.

#### Step 5: Roll Out to All Users

Once you've validated that the proxy works correctly with your test users/groups:

1. Go back to **Admin > User Attributes** and select `rabbit_bq_proxy_url`.
2. Change the **Default Value** to your BQ Proxy URL:

```
https://bq-proxy-xxxxxxxxxx-uc.a.run.app
```

1. Remove any group-level overrides that are no longer needed.

All Looker users will now have their BigQuery traffic routed through the proxy. To revert at any time, change the default value back to `https://bigquery.googleapis.com`.

### bq CLI

```bash
bq --api https://bq-proxy-xxxxxxxxxx-uc.a.run.app query "SELECT 1"
```

### JDBC (Simba driver)

```
jdbc:bigquery://bq-proxy-xxxxxxxxxx-uc.a.run.app:443;ProjectId=my-project;OAuthType=...
```

## Configuration Reference

### Terraform Variables


| Variable | Required | Default | Description |
|---|---|---|---|
| `project_id` | **Yes** | — | GCP project ID for deployment |
| `region` | **Yes** | — | GCP region for the Cloud Run service |
| `rabbit_api_key` | No | `""` | Rabbit API key for optimization. Empty = pass-through mode |
| `image` | No | `us-docker.pkg.dev/.../bq-proxy:latest` | Container image (see [Container Images](#container-images)) |
| `default_pricing_mode` | No | `on_demand` | `on_demand` or `slot_based` |
| `reservation_ids` | No | `[]` | BigQuery reservation IDs for optimization |
| `service_name` | No | `bq-proxy` | Cloud Run service name |
| `min_instances` | No | `1` | Minimum instances (1+ avoids cold starts) |
| `max_instances` | No | `20` | Maximum instances |
| `cpu` | No | `2` | vCPUs per instance |
| `memory` | No | `512Mi` | Memory per instance |
| `log_level` | No | `info` | `debug`, `info`, `warn`, `error` |
| `port` | No | `8080` | HTTP listen port |
| `bq_target_url` | No | `https://bigquery.googleapis.com` | Upstream BigQuery API URL |
| `request_timeout` | No | `600` | Per-request timeout in seconds |
| `rabbit_api_base_url` | No | `https://api.followrabbit.ai/bq-job-optimizer` | Rabbit optimizer endpoint |
| `rabbit_api_timeout` | No | `5` | Timeout (seconds) for Rabbit API calls |

### Environment Variables (Advanced)

These are the environment variables the proxy container reads. The Terraform configuration sets all of them from the variables above. If you deploy without Terraform, you can set these directly on the container.

| Variable | Default | Terraform Variable | Description |
|---|---|---|---|
| `PORT` | `8080` | `port` | HTTP listen port |
| `BQ_TARGET_URL` | `https://bigquery.googleapis.com` | `bq_target_url` | Upstream BigQuery API URL |
| `REQUEST_TIMEOUT` | `600` | `request_timeout` | Request timeout in seconds |
| `LOG_LEVEL` | `info` | `log_level` | Log verbosity |
| `RABBIT_API_KEY` | _(empty)_ | `rabbit_api_key` | Rabbit API key |
| `RABBIT_API_BASE_URL` | `https://api.followrabbit.ai/bq-job-optimizer` | `rabbit_api_base_url` | Rabbit optimizer endpoint |
| `RABBIT_API_TIMEOUT` | `5` | `rabbit_api_timeout` | Timeout (seconds) for Rabbit API calls |
| `DEFAULT_PRICING_MODE` | `on_demand` | `default_pricing_mode` | Default pricing mode |
| `RESERVATION_IDS` | _(empty)_ | `reservation_ids` | Comma-separated reservation IDs |


## Understanding Pricing Modes


| Mode         | When to Use                                                                                                                                                           |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `on_demand`  | You primarily use on-demand BigQuery pricing and want Rabbit to optimize by routing eligible jobs to available reservations when cost-effective. This is the default. |
| `slot_based` | You primarily use BigQuery editions (slot-based) reservations and want Rabbit to optimize job placement across your reservations.                                     |


## Updating the Proxy

To update to the latest version:

```bash
# Re-apply to pull the :latest image
terraform apply -replace="google_cloud_run_v2_service.bq_proxy"
```

Or pin to a specific version tag by changing the `image` variable.

## Removing the Proxy

```bash
terraform destroy
```

This removes the Cloud Run service, service account, and IAM bindings. Your BigQuery data and configurations are unaffected.

## Performance Testing

The `[perftest/](perftest/)` directory contains a standalone Go CLI tool for benchmarking the BQ Proxy against direct BigQuery API calls. Use it to verify that the proxy adds negligible overhead in your environment.

```bash
cd perftest
go build -o perftest main.go
./perftest --project-id=YOUR_PROJECT --proxy-url=https://bq-proxy-xxxxxxxxxx-uc.a.run.app
```

The tool runs four scenario categories — small queries (latency overhead), medium queries (throughput), large queries (streaming & memory), and concurrent load (scale). See the [perftest README](perftest/README.md) for full documentation, flags, and usage examples.

### Reference Benchmark Results

All benchmarks run against Cloud Run (`europe-west3`), 5 service accounts, 1 warmup run excluded per scenario.

**Latency — small queries** (20 iterations each):


| Scenario         | Path         | p50       | p95       | p99       |
| ---------------- | ------------ | --------- | --------- | --------- |
| `SELECT 1`       | Direct BQ    | 377ms     | 521ms     | 521ms     |
|                  | Via Proxy    | 421ms     | 494ms     | 494ms     |
|                  | **Overhead** | **+44ms** | **-27ms** | **-27ms** |
| `GENERATE_ARRAY` | Direct BQ    | 395ms     | 639ms     | 639ms     |
|                  | Via Proxy    | 410ms     | 646ms     | 646ms     |
|                  | **Overhead** | **+15ms** | **+7ms**  | **+7ms**  |


**Latency — medium queries** (20 iterations):


| Scenario            | Path         | p50       | p95        | p99        |
| ------------------- | ------------ | --------- | ---------- | ---------- |
| Shakespeare 1K rows | Direct BQ    | 584ms     | 1.461s     | 1.461s     |
|                     | Via Proxy    | 568ms     | 800ms      | 800ms      |
|                     | **Overhead** | **-16ms** | **-661ms** | **-661ms** |


**Streaming — large queries** (3 iterations):


| Scenario           | Path      | Transfer time | Response size | Peak alloc |
| ------------------ | --------- | ------------- | ------------- | ---------- |
| Shakespeare full   | Direct BQ | 5.421s        | 17.8MB        | 520.1KB    |
|                    | Via Proxy | 3.694s        | 17.8MB        | 582.2KB    |
| Natality 100K rows | Direct BQ | 3.964s        | 14.3MB        | 411.8KB    |
|                    | Via Proxy | 2.977s        | 14.3MB        | 641.0KB    |


**Concurrent load** (100 concurrency, 10 min, `SELECT 1`):


| Path         | p50       | p95       | p99       | Throughput  | Errors   |
| ------------ | --------- | --------- | --------- | ----------- | -------- |
| Direct BQ    | 354ms     | 528ms     | 726ms     | 266.3 req/s | 0/159766 |
| Via Proxy    | 364ms     | 550ms     | 768ms     | 258.0 req/s | 0/154797 |
| **Overhead** | **+10ms** | **+21ms** | **+42ms** | **-3.1%**   | —        |


> The proxy adds ~10-44ms latency at p50 for small queries, with zero errors under sustained 100-concurrency load. Memory allocation stays in the KB range even for 17MB+ result sets, confirming true streaming with no response buffering.

## Troubleshooting


| Symptom                              | Likely Cause               | Fix                                                                                                                                                      |
| ------------------------------------ | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `403` when pulling the image         | Artifact Registry access   | Ensure the Cloud Run service agent can read from the Artifact Registry. Run: `gcloud auth configure-docker us-docker.pkg.dev` (replace region as needed) |
| `403` when invoking the proxy        | Cloud Run ingress settings | The endpoint is publicly accessible by default. Check that your Cloud Run ingress is set to "All" in the GCP console                                     |
| Health check passes but queries fail | BigQuery API not enabled   | Enable `bigquery.googleapis.com` on your project                                                                                                         |
| Queries succeed but no optimization  | Missing or invalid API key | Verify `rabbit_api_key` is set correctly. Check logs: `gcloud run services logs read bq-proxy --region=REGION`                                           |
| High latency on first request        | Cold start                 | Increase `min_instances` to 1 or higher                                                                                                                  |


## Support

For issues with the BQ Proxy or to obtain an API key, contact your Rabbit representative or reach out to [support@followrabbit.ai](mailto:support@followrabbit.ai).