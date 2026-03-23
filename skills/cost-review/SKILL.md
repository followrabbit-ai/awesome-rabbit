---
name: cost-review
description: >
  Perform a FollowRabbit cost review on the current repository.
  Use when the user wants to understand the cost impact of Terraform or SQL
  infrastructure, asks about cloud costs, or is working with *.tf or *.sql files.
version: 1.1.0
tools: Bash, Read, AskUserQuestion
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

## Step 1: Ensure CLI Is Installed and Up to Date

Check if the `followrabbit` binary is available:

```bash
which followrabbit
```

### If not found — ask before installing

Use the `AskUserQuestion` tool to ask the user:

> The `followrabbit` CLI is not installed. Would you like me to install it?

Options:
- **Yes, install it** — detect the best available method and install
- **No, I'll install it myself** — stop and let the user handle it

**If the user agrees**, detect the best available method:

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
curl -fsSL https://followrabbit-ai.github.io/homebrew-tap/install.sh | sh
```

After install, verify:

```bash
followrabbit version --json
```

### If already installed — check for updates

```bash
followrabbit version --json
```

The `data` object contains:

| Field | Example |
|-------|---------|
| `version` | `"1.2.0"` |
| `commit` | `"abc1234"` |
| `build_date` | `"2026-03-01T12:00:00Z"` |
| `go_version` | `"go1.23.0"` |
| `os` | `"darwin"` |
| `arch` | `"arm64"` |

Compare the `data.version` field against the latest release tag:

```bash
curl -fsSL "https://api.github.com/repos/followrabbit-ai/homebrew-tap/releases?per_page=1" | grep -m1 '"tag_name"'
```

**If the installed version is behind**, use the `AskUserQuestion` tool to ask:

> A newer version of the `followrabbit` CLI is available (installed: X, latest: Y). Would you like me to upgrade it?

Options:
- **Yes, upgrade now** — run the appropriate upgrade command
- **No, continue with current version** — proceed without upgrading

If the user agrees to upgrade:

- **Homebrew**: `brew upgrade followrabbit-ai/tap/followrabbit`
- **npm**: `npm update -g @followrabbit/cli`
- **Otherwise**: re-run `curl -fsSL https://followrabbit-ai.github.io/homebrew-tap/install.sh | sh`

After update, verify:

```bash
followrabbit version --json
```

## Step 2: Ensure Authentication

Check if the CLI is authenticated:

```bash
followrabbit auth status --json
```

If the output shows `"authenticated": false` or the command fails with exit code 2, use the `AskUserQuestion` tool to ask:

> The CLI is not authenticated. You need a FollowRabbit API key — get one at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai). How would you like to authenticate?

Options:
- **I'll paste the key — run the login for me** — wait for the user to provide the key, then run `followrabbit auth login --key <KEY>`
- **I'll handle it myself** — stop and wait for the user to authenticate on their own

If the user chooses to paste the key, run:

```bash
followrabbit auth login --key <KEY_PROVIDED_BY_USER>
```

Verify authentication succeeded:

```bash
followrabbit auth status --json
```

### Other Auth Subcommands

| Command | Purpose |
|---------|---------|
| `followrabbit auth status --json` | Check if CLI is authenticated |
| `followrabbit auth login --key <KEY>` | Store an API key |
| `followrabbit auth logout` | Remove stored credentials |
| `followrabbit auth token` | Print the current API key to stdout (useful for scripts) |

Then check quota:

```bash
followrabbit status --json
```

If the quota usage shows no remaining budget, inform the user their quota is exhausted and when it resets.

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
| `--skills <list>` | `cost-impact,partition-check,best-practices` | Comma-separated skill IDs to request |
| `--model <name>` | API default | LLM model override (e.g., `gemini-2.5-pro`) |
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
    "skills": [
      {
        "id": "cost-impact",
        "name": "Cost Impact Analysis",
        "instructions": "<markdown instructions>"
      },
      {
        "id": "partition-check",
        "name": "Partition Check",
        "instructions": "<markdown instructions>"
      },
      {
        "id": "best-practices",
        "name": "Best Practices",
        "instructions": "<markdown instructions>"
      }
    ]
  }
}
```

The `data.skills` array contains up to three skill areas:

| Skill ID | What it covers |
|----------|---------------|
| `cost-impact` | Compute sizing, storage costs, database costs, networking costs |
| `partition-check` | BigQuery partitioning, clustering, and partition expiration |
| `best-practices` | Missing labels, lifecycle rules, autoscaling, HA over-provisioning, network tier, committed use discounts |

Each entry has an `id`, `name`, and `instructions` field. The `instructions` value is a markdown string with specific, actionable optimization instructions tailored to the scanned infrastructure.

If the API's primary engine is unavailable, the response will have `"mode": "fallback"` and `"cost_usd": 0.0` — the instructions are still valid (loaded from static skill files) but not personalized to the specific context.

## Step 5: Present Results and Offer to Help

1. **Present the instructions** to the user — show the optimization recommendations from each skill area that returned content.

2. **Offer to apply the suggestions** — ask the user if they'd like you to help implement any of the recommendations by editing the Terraform or SQL files directly.

3. **If the user agrees**, read the relevant infrastructure files and apply the suggested changes (e.g., adding labels, lifecycle rules, adjusting machine types, adding partitioning).

## Error Handling

| Exit Code | Meaning | What to Tell the User |
|-----------|---------|----------------------|
| 0 | Success | Show the instructions |
| 2 | Auth error | "Run `followrabbit auth login --key <KEY>` to authenticate. Get your key at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai)" |
| 3 | Rate limit / quota exceeded | "API quota exhausted. Check `followrabbit status` for reset date" |
| 4 | Input error | "Invalid flags or arguments. Check the command syntax" |
| 5 | Processing error | "Failed to process the scan. Check that the directory contains valid .tf or .sql files" |
| 6 | Network error | "Cannot reach the FollowRabbit API. Check your internet connection" |

## Global Flags

These flags work with any `followrabbit` command:

| Flag | Description |
|------|-------------|
| `--json` | Output as JSON (auto-enabled when stdout is piped) |
| `--api-key <key>` | Override the stored API key for this invocation |
| `--api-url <url>` | Override the API base URL (default: `https://api.agentic.followrabbit.ai`) |
| `--quiet` | Suppress non-essential output |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `FOLLOWRABBIT_API_KEY` | API key override (used instead of stored credentials) |
| `RABBIT_CONFIG_DIR` | Override the default config directory (`~/.config/followrabbit/`) |

## Additional Commands

These commands are available for further investigation:

| Command | Purpose |
|---------|---------|
| `followrabbit context --json` | Local-only scan — outputs structured TF/SQL context without calling the API |
| `followrabbit recos list --json` | List cost optimization recommendations for the current repo |
| `followrabbit status --json` | Check API key usage, quota, and recent activity |
| `followrabbit completion <shell>` | Generate shell completions (bash, zsh, fish, powershell) |

### `context` Flags

The `context` command supports the same scan flags as `costreview`:

| Flag | Default | Description |
|------|---------|-------------|
| `--dir <path>` | Current working directory | Directory to scan |
| `--types <list>` | `tf` | Comma-separated scan types: `tf`, `sql` |

Example — scan a subdirectory for both Terraform and SQL files (local only, no API call):

```bash
followrabbit context --dir ./infrastructure --types tf,sql --json
```

### `recos list` Flags

| Flag | Description |
|------|-------------|
| `--repo <url>` | Repository URL (auto-detected from git remote if omitted) |
| `--type <filter>` | Filter by type: `rightsizing`, `idle_resource`, `commitment` |
| `--status <filter>` | Filter by status: `open`, `applied`, `dismissed` |

## Example Interaction

**User**: "Can you check if there are any cost optimization opportunities in this Terraform code?"

**Agent**:
1. Runs `which followrabbit` — not found
2. Uses `AskUserQuestion`: "The `followrabbit` CLI is not installed. Would you like me to install it?"
3. User selects "Yes, install it"
4. Detects Homebrew, runs `brew install followrabbit-ai/tap/followrabbit`
5. Runs `followrabbit auth status --json` — not authenticated
6. Uses `AskUserQuestion`: "The CLI is not authenticated. You need a FollowRabbit API key — get one at subscriptions.agentic.followrabbit.ai. How would you like to authenticate?"
7. User selects "I'll paste the key — run the login for me" and provides the key
8. Runs `followrabbit auth login --key <KEY>` — success
9. Runs `followrabbit costreview --json`
10. Parses the response and presents:

> Here are the findings from the FollowRabbit cost review:
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
11. Reads the relevant `.tf` files
12. Adds labels and lifecycle rules
13. Shows the diff to the user
