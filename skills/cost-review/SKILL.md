---
name: cost-review
description: >
  Perform a FollowRabbit cost review on the current repository.
  Use when the user wants to understand the cost impact of Terraform or SQL
  infrastructure, asks about cloud costs, or is working with *.tf or *.sql files.
version: 1.0.0
tools: Bash, Read
user-invocable: true
---

# FollowRabbit Cost Review Skill

## Overview

This skill guides you through performing a cost review using the `followrabbit` CLI. The CLI scans local Terraform and SQL files, sends the infrastructure context to the FollowRabbit API, and returns AI-powered cost optimization instructions.

## When to Use

- User asks to review infrastructure for cost impact
- User is working with Terraform (`.tf`) or SQL files and mentions cost, pricing, or optimization
- User says things like "is this expensive?", "check costs", "optimize spending", "review pricing"
- During a code review involving cloud infrastructure files

## Step 1: Ensure CLI Is Installed

Check if the `followrabbit` binary is available:

```bash
which followrabbit
```

If not found, install it automatically. Detect the best available method:

1. **Check for Homebrew** (preferred on macOS):

```bash
which brew
```

If available:

```bash
brew install followrabbit-ai/tap/followrabbit
```

2. **Check for npm** (cross-platform fallback):

```bash
which npm
```

If available:

```bash
npm install -g @followrabbit/cli
```

3. **Fall back to the shell installer** (works everywhere):

```bash
curl -fsSL https://raw.githubusercontent.com/followrabbit-ai/rabbit-agentic/main/cli/install.sh | sh
```

After installation, verify:

```bash
followrabbit version --json
```

## Step 2: Ensure Authentication

Check if the CLI is authenticated:

```bash
followrabbit auth status --json
```

If the output shows `"authenticated": false` or the command fails with exit code 2, the user needs an API key.

Tell the user:

> You need a FollowRabbit API key to run cost reviews.
>
> 1. Sign up at [followrabbit.ai](https://followrabbit.ai) to get your API key
> 2. Then authenticate:
>    ```
>    followrabbit auth login --key <YOUR_API_KEY>
>    ```

Wait for the user to complete authentication before continuing.

Also check quota from the auth status output. If the response includes quota information showing no remaining usage, inform the user their quota is exhausted and when it resets.

## Step 3: Run the Cost Review

Run the `costreview` command from the repository root (or the directory containing infrastructure files):

```bash
followrabbit costreview --json
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--dir <path>` | Current working directory | Directory to scan |
| `--types <list>` | `tf` | Comma-separated scan types: `tf`, `sql` |
| `--json` | Auto-enabled when piped | Output as JSON |

### Examples

Scan only Terraform files (default):

```bash
followrabbit costreview --json
```

Scan both Terraform and SQL files:

```bash
followrabbit costreview --types tf,sql --json
```

Scan a specific directory:

```bash
followrabbit costreview --dir ./infrastructure --json
```

## Step 4: Parse the Response

The JSON output uses this envelope structure:

```json
{
  "version": "1",
  "command": "costreview",
  "status": "success",
  "data": {
    "request_id": "eng_...",
    "mode": "context",
    "cost_usd": 0.01,
    "instructions": {
      "cost-impact": "<markdown instructions>",
      "partition-check": "<markdown instructions>",
      "best-practices": "<markdown instructions>"
    }
  }
}
```

The `data.instructions` object contains up to three skill areas:

| Key | What it covers |
|-----|---------------|
| `cost-impact` | Compute sizing, storage costs, database costs, networking costs |
| `partition-check` | BigQuery partitioning, clustering, and partition expiration |
| `best-practices` | Missing labels, lifecycle rules, autoscaling, HA over-provisioning, network tier, committed use discounts |

Each value is a markdown string with specific, actionable optimization instructions tailored to the scanned infrastructure.

If the API's primary engine is unavailable, the response will have `"mode": "fallback"` and `"cost_usd": 0.0` — the instructions are still valid (loaded from static skill files) but not personalized to the specific context.

## Step 5: Present Results and Offer to Help

1. **Present the instructions** to the user — show the optimization recommendations from each skill area that returned content.

2. **Offer to apply the suggestions** — ask the user if they'd like you to help implement any of the recommendations by editing the Terraform or SQL files directly.

3. **If the user agrees**, read the relevant infrastructure files and apply the suggested changes (e.g., adding labels, lifecycle rules, adjusting machine types, adding partitioning).

## Error Handling

| Exit Code | Meaning | What to Tell the User |
|-----------|---------|----------------------|
| 0 | Success | Show the instructions |
| 2 | Auth error | "Run `followrabbit auth login --key <KEY>` to authenticate. Get your key at followrabbit.ai" |
| 3 | Rate limit / quota exceeded | "API quota exhausted. Check `followrabbit status` for reset date" |
| 4 | Input error | "Invalid flags or arguments. Check the command syntax" |
| 5 | Processing error | "Failed to process the scan. Check that the directory contains valid .tf or .sql files" |
| 6 | Network error | "Cannot reach the FollowRabbit API. Check your internet connection" |

## Additional Commands

These commands are available for further investigation:

| Command | Purpose |
|---------|---------|
| `followrabbit context --json` | Local-only scan — outputs structured TF/SQL context without calling the API |
| `followrabbit recos list --json` | List cost optimization recommendations for the current repo |
| `followrabbit status --json` | Check API key usage, quota, and recent activity |

### `recos list` Flags

| Flag | Description |
|------|-------------|
| `--repo <url>` | Repository URL (auto-detected from git remote if omitted) |
| `--type <filter>` | Filter by type: `rightsizing`, `idle_resource`, `commitment` |
| `--status <filter>` | Filter by status: `open`, `applied`, `dismissed` |

## Example Interaction

**User**: "Can you check if there are any cost optimization opportunities in this Terraform code?"

**Agent**:
1. Checks `followrabbit` is installed — finds it at `/usr/local/bin/followrabbit`
2. Checks auth status — authenticated
3. Runs `followrabbit costreview --json`
4. Parses the response and presents:

> I ran a FollowRabbit cost review on your infrastructure. Here are the findings:
>
> **Cost Impact:**
> - Your `google_compute_instance.web_server` uses `n2-standard-8` — consider right-sizing to `n2-standard-4` if CPU utilization is low
> - `google_storage_bucket.logs` uses Standard storage class — consider Nearline or Coldline for infrequently accessed data
>
> **Best Practices:**
> - 3 resources are missing `cost_center` and `environment` labels
> - `google_storage_bucket.backups` has versioning enabled but no lifecycle rule to expire old versions
>
> **Partitioning:**
> - `google_bigquery_table.events` is missing time partitioning — this causes full table scans on every query
>
> Would you like me to apply any of these suggestions to your code?

**User**: "Yes, add the missing labels and the lifecycle rule"

**Agent**:
5. Reads the relevant `.tf` files
6. Adds labels and lifecycle rules
7. Shows the diff to the user
