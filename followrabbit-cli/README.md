# `followrabbit` CLI Reference

Reference for the `followrabbit` command-line tool — the entrypoint for Rabbit cost-optimization workflows that run from a terminal, a CI pipeline, or an AI coding agent.

Everything below was verified against the shipped binary **v0.1.3** by running the commands. For usage from inside an AI coding agent (Claude Code / Cursor / OpenAI Codex), see the [plugin section of the main README](../README.md#coding-agent-plugins) — the plugin skills shell out to this CLI.

---

## Install

The CLI is a single static Go binary. Pick one:

```bash
# Homebrew (macOS / Linux)
brew trust followrabbit-ai/tap        # required on Homebrew 6.x+
brew install followrabbit-ai/tap/followrabbit

# npm (cross-platform)
npm install -g @followrabbit/cli

# Universal shell installer
curl -fsSL https://followrabbit-ai.github.io/homebrew-tap/install.sh | sh
```

On Homebrew 6.x and later, `brew install` refuses formulae from untrusted third-party taps, so the `brew trust` step is required once per machine. In non-interactive CI, skipping it is a hard failure.

Verify the install:

```bash
followrabbit version
```

Upgrade later with the matching tool: `brew upgrade followrabbit-ai/tap/followrabbit`, `npm update -g @followrabbit/cli`, or re-run the curl installer.

---

## Authenticate

You need a Rabbit API key. Get one at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai).

```bash
followrabbit auth login --key <YOUR_API_KEY>
followrabbit auth status
```

`auth status` reports `authenticated: true` once the key is stored. There is no browser-based login: `auth login` without `--key` exits 4 with `browser-based login is not yet supported; use --key to provide an API key`.

| Command | Purpose |
|---|---|
| `followrabbit auth login --key <KEY>` | Store an API key in the user config. |
| `followrabbit auth status` | Check whether the CLI is authenticated; prints the signup URL when not. |
| `followrabbit auth logout` | Remove stored credentials. |
| `followrabbit auth token` | Print the current API key to stdout, for scripts that need to relay it. |

Keys are stored at `~/.config/followrabbit/credentials.json` (mode `0600`) and travel only in the `X-Rabbit-Api-Key` request header.

---

## Global flags

These work with every command:

| Flag | Description |
|---|---|
| `--json` | Emit JSON wrapped in a `{version, command, status, data, error}` envelope. **Auto-enabled whenever stdout is not a TTY** — anything piping or capturing CLI output gets JSON without asking for it. |
| `--api-key <key>` | Override the stored API key for one invocation. |
| `--api-url <url>` | Override the API base URL (default: `https://api.agentic.followrabbit.ai`). |
| `--quiet` | Suppress non-essential output. |

## Environment variables

| Variable | Description |
|---|---|
| `FOLLOWRABBIT_API_KEY` | API key override, used instead of stored credentials. Credential-bearing — treat like any secret in CI. |
| `RABBIT_API_URL` | API base URL override, same effect as `--api-url`. |
| `RABBIT_CONFIG_DIR` | Override the default config directory (`~/.config/followrabbit/`). |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | OK |
| `2` | Auth — invalid or missing API key. |
| `3` | Quota exhausted / rate limited. |
| `4` | Input — invalid flags or arguments (also the no-browser-login case above). |
| `5` | Non-2xx response from the API. |
| `6` | Network error. |

---

## Commands

### `version`

Print build and runtime info.

```bash
followrabbit version
```

### `status`

Show API key info, quota usage for the current period, and recent activity.

```bash
followrabbit status
```

### `costreview`

Scan local Terraform / SQL files and call the Rabbit API for AI-powered cost-optimization recommendations.

```bash
followrabbit costreview                          # scan Terraform in the current directory
followrabbit costreview --dir ./infra --types tf,sql
followrabbit costreview --filter sql --skills sql-antipatterns
```

| Flag | Default | Description |
|---|---|---|
| `--dir <path>` | current directory | Directory to scan. |
| `--types <list>` | `tf` | Comma-separated scan types: `tf`, `sql`. |
| `--filter <name>` | — | Convenience alias for `--types`: `sql`, `infra`, or `all`. Overrides `--types` when set. |
| `--skills <list>` | `cost-impact,partition-check,best-practices` | Skill IDs to run. **Replaces** the default set rather than adding to it — to add one, list the defaults too. |
| `--model <name>` | API default | LLM override (e.g. `gemini-2.5-pro`). |

The response groups instructions by skill — each is markdown that an agent or human can act on directly. See the [data-flow disclosure](../README.md#data-sent-to-the-followrabbit-api) for exactly what is uploaded.

### `context`

Local-only structured Terraform/SQL scan. No API call — useful for piping into other tools or giving an agent repo context.

```bash
followrabbit context --dir ./infra --types tf,sql --json
```

Same `--dir` and `--types` flags as `costreview`.

### `recos list`

List saved cost-optimization recommendations for a repository.

```bash
followrabbit recos list                                 # repo auto-detected from git remote
followrabbit recos list --repo https://github.com/acme/infra
followrabbit recos list --type rightsizing --status open
```

| Flag | Description |
|---|---|
| `--repo <url>` | Repository URL (defaults to the git `origin` remote). |
| `--type <filter>` | `rightsizing`, `idle_resource`, `commitment`. |
| `--status <filter>` | `open`, `applied`, `dismissed`. |

### `completion <shell>`

Generate a shell-completion script for `bash`, `zsh`, `fish`, or `powershell`.

```bash
followrabbit completion zsh
```

Run `followrabbit completion --help` for per-shell load instructions.

---

## Troubleshooting

**`AUTH_ERROR` / exit 2** — the stored key is missing or the server rejected it. Run `followrabbit auth status` to see which; re-login with `followrabbit auth login --key <KEY>`.

**Exit 3** — your key's quota for the period is exhausted or you are rate limited. Check usage with `followrabbit status`; quota is managed at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai).

**`400 INVALID_REQUEST` from `costreview` on large repos** — the server caps uploaded context at 500,000 characters. SQL files are capped at 100 KiB each but there is no aggregate client-side cap, so a repo with roughly six or more large SQL files can exceed the ceiling. Narrow the scan with `--dir`, or split the review.

**Corporate proxy / TLS interception** — the CLI talks HTTPS to `api.agentic.followrabbit.ai`. If your proxy re-signs TLS, the request fails with a certificate error (exit 6); have the proxy's CA in the system trust store or allowlist the API host.

**Getting JSON when you expected text** — output is auto-JSON whenever stdout is piped or captured (see global flags). Run in a terminal, or embrace the JSON envelope in scripts.

---

## Related

- [Coding-agent plugins](../README.md#coding-agent-plugins) — the Claude Code / Cursor / Codex surface for this CLI.
- [`cost-review`](../skills/cost-review/) skill — the agent skill that drives `costreview`.
- [assessment-cli](../assessment-cli/) — pre-sales assessment of a GCP/BigQuery environment; separate Python tool, no API key needed.
