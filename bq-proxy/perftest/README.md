# BQ Proxy Performance Test

A standalone Go CLI tool for benchmarking the BQ Proxy against direct BigQuery API calls. It measures latency overhead, streaming throughput, memory usage, and concurrent load handling — giving you confidence that the proxy adds negligible overhead to your workloads.

## What It Does

The perftest tool sends real BigQuery queries through two paths and compares the results:

```
                ┌─────────────────┐
 Direct path:   │  BigQuery API   │  ← baseline measurement
                └─────────────────┘

                ┌──────────┐      ┌─────────────────┐
 Proxy path:    │ BQ Proxy │  ──▶ │  BigQuery API   │  ← proxy measurement
                └──────────┘      └─────────────────┘
```

For each scenario it reports percentile latencies (p50/p95/p99), the overhead delta, transfer sizes, memory allocation, and error rates.

## Prerequisites

- **Go 1.21+** installed
- **GCP credentials** — either Application Default Credentials (ADC) or one or more service account JSON key files
- **A GCP project** with BigQuery API enabled (the tool runs queries against public datasets, so no private data is needed)
- **A running BQ Proxy** — either locally or deployed to Cloud Run

## Build

```bash
go build -o perftest main.go
```

> **Note:** The perftest depends on `golang.org/x/oauth2` and `golang.org/x/oauth2/google`. If building outside the bq-proxy module, initialize a Go module first:
>
> ```bash
> go mod init perftest
> go mod tidy
> go build -o perftest main.go
> ```

## Usage

```bash
./perftest --project-id=YOUR_PROJECT --proxy-url=http://localhost:8080
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--project-id` | *(required)* | GCP project ID for query billing |
| `--proxy-url` | `http://localhost:8080` | URL of the BQ Proxy to test |
| `--direct-url` | `https://bigquery.googleapis.com` | Direct BigQuery API URL (baseline) |
| `--keys-dir` | *(empty — uses ADC)* | Directory containing `*.json` service account key files. Keys are used in round-robin to spread load across multiple identities and avoid per-user quota limits. |
| `--concurrency` | `10` | Number of concurrent workers for load tests |
| `--duration` | `30s` | Duration for concurrent load tests |
| `--scenario` | `all` | Which scenario to run: `small`, `medium`, `large`, `concurrent`, or `all` |
| `--proxy-only` | `false` | Skip direct BigQuery calls; only measure the proxy path |

## Test Scenarios

### Small — Proxy Latency Overhead

Runs 20 iterations (+ 1 warmup) of minimal queries to isolate the proxy's added latency:

- `SELECT 1` — absolute minimum query
- `SELECT * FROM UNNEST(GENERATE_ARRAY(1, 100))` — slightly larger payload

### Medium — Throughput Measurement

Runs 20 iterations of queries returning moderate result sets:

- Shakespeare dataset, 1,000 rows — representative of typical BI/dashboard queries

### Large — Streaming and Memory Resilience

Runs 3 iterations of large result sets to verify the proxy streams responses without buffering:

- Full Shakespeare table (~17.8 MB)
- Natality dataset, 100K rows (~14.3 MB)

Reports transfer time, response size, and peak memory allocation to confirm the proxy doesn't buffer responses in memory.

### Concurrent — Scale Testing

Runs sustained concurrent load at configurable concurrency levels (default: 10, 50, and 100 workers) for the configured duration. Reports throughput (req/s), percentile latencies, and error rates.

## Authentication

**Application Default Credentials (default):** If `--keys-dir` is not set, the tool uses ADC from your environment (`gcloud auth application-default login` or `GOOGLE_APPLICATION_CREDENTIALS`).

**Multiple service account keys:** For concurrent tests, a single identity may hit BigQuery's per-user rate limits (100 req/s). Place multiple `*.json` service account key files in a directory and pass `--keys-dir=./keys`. The tool rotates through them round-robin.

```bash
mkdir keys
cp sa-1.json sa-2.json sa-3.json keys/
./perftest --project-id=my-project --proxy-url=https://bq-proxy-xxx.a.run.app --keys-dir=./keys --scenario=concurrent
```

## Examples

Run all scenarios against a local proxy:

```bash
./perftest --project-id=my-project --proxy-url=http://localhost:8080
```

Run only the small scenario against a Cloud Run deployment (proxy only, no direct comparison):

```bash
./perftest --project-id=my-project --proxy-url=https://bq-proxy-xxx.a.run.app --scenario=small --proxy-only
```

Run a 60-second concurrent load test with 50 workers:

```bash
./perftest --project-id=my-project --proxy-url=https://bq-proxy-xxx.a.run.app --scenario=concurrent --concurrency=50 --duration=60s
```

## Reading the Output

```
--- Scenario: select_1 (small) [1 warmup + N measured runs] ---
  Direct BQ:  p50=377ms  p95=521ms  p99=521ms  errors=0/20
  Via Proxy:  p50=421ms  p95=494ms  p99=494ms  errors=0/20
  Overhead:   p50=+44ms  p95=-27ms  p99=-27ms
```

- **Direct BQ** — baseline latency hitting BigQuery directly
- **Via Proxy** — latency going through the BQ Proxy
- **Overhead** — the difference (positive = proxy is slower, negative = proxy is faster due to connection reuse or other effects)

For streaming tests, `peak_alloc` shows the memory high-water mark — it should stay in the KB range regardless of result set size, confirming streaming works correctly.
