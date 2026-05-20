#!/usr/bin/env bash
#
# rabbit-assess.sh - GCP/BigQuery cost-savings assessment (Bash port).
#
# A dependency-light port of the Python `rabbit-assess` tool, for hosts that
# cannot run Python 3. It orchestrates tools that a GCP operator already has:
#   - gcloud   : project enumeration
#   - bq       : runs the INFORMATION_SCHEMA queries (CSV output)
#   - coreutils: awk, sed, sort, etc.
# No jq, no Python, no other packages.
#
# Requires: bash >= 4.2 (CentOS 7 ships 4.2).
#
# It enumerates projects under a scope, runs project-scoped queries across
# 6 cost categories, writes per-category CSVs, and produces a Markdown report.
# Anything the operator cannot read is skipped and recorded, never fatal.

# NOTE: deliberately no `set -u` - bash 4.2 errors on empty-array expansion
# under `set -u`. Unset variables are guarded with ${var:-} instead.
set -o pipefail

# --- bash version guard ----------------------------------------------------
if [ -z "${BASH_VERSINFO:-}" ] \
   || [ "${BASH_VERSINFO[0]}" -lt 4 ] \
   || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo "rabbit-assess: requires bash >= 4.2" >&2
  exit 1
fi

VERSION="0.1.0-bash"

ALL_CATEGORIES=(
  reservations
  capacity_commitments
  pricing_model_optimization
  storage_billing_model
  failed_jobs_capacity
  failed_jobs_general
  reservation_waste
)

# Human-readable titles for the report.
declare -A CATEGORY_TITLE=(
  [reservations]="BigQuery Reservations"
  [capacity_commitments]="Capacity Commitments"
  [pricing_model_optimization]="Job Pricing-Model Optimization"
  [storage_billing_model]="Storage Billing-Model Optimization"
  [failed_jobs_capacity]="Failed Jobs - Capacity-Related"
  [failed_jobs_general]="Failed Jobs - Cost Impact"
  [reservation_waste]="Reservation Utilization / Waste"
)

# --- defaults --------------------------------------------------------------
SCOPE=""
LOCATIONS=()
CATEGORIES=()
LOOKBACK_DAYS=30
OUTPUT_DIR="./rabbit-assessment-output"
CURRENCY="USD"
EXCHANGE_RATE="1.0"          # USD per 1 unit of CURRENCY
DEFAULT_STORAGE_MODEL="LOGICAL"
SLOT_HOUR_PRICE="0.06"
ONDEMAND_PRICE="6.25"
STORAGE_LOGICAL_ACTIVE="0.02"
STORAGE_LOGICAL_LT="0.01"
STORAGE_PHYSICAL_ACTIVE="0.04"
STORAGE_PHYSICAL_LT="0.02"
DRY_RUN=0
VERBOSE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Single source of truth: the Python tool's templates. A bundled copy placed
# next to this script (see bundle.sh) is preferred when present.
if [ -d "$SCRIPT_DIR/sql_templates" ]; then
  SQL_DIR="$SCRIPT_DIR/sql_templates"
else
  SQL_DIR="$SCRIPT_DIR/../src/rabbit_assessment/sql_templates"
fi
SQL_DIR="${RABBIT_SQL_DIR:-$SQL_DIR}"

# --- runtime state ---------------------------------------------------------
PROJECTS=()
RUN_DIR=""
RUN_TS_ISO=""
SUCCESS_COUNT=0
ERROR_COUNT=0
declare -A ROWCOUNT
declare -A ERR_BY_CAT

# ===========================================================================
usage() {
  cat <<'EOF'
rabbit-assess.sh - GCP/BigQuery cost-savings assessment (Bash port)

USAGE:
  rabbit-assess.sh --scope <s> --location <loc> [options]

REQUIRED:
  --scope <s>            org:<id> | folder:<id> | project:<id>
  --location <loc>       BigQuery location, e.g. US (repeat for several)

OPTIONS:
  --lookback-days <n>            analysis window, 1-365 (default: 30)
  --output-dir <dir>             default: ./rabbit-assessment-output
  --currency <code>              report local-currency label (default: USD)
  --exchange-rate <f>            USD per 1 unit of --currency (default: 1.0)
  --default-storage-billing-model <LOGICAL|PHYSICAL>   (default: LOGICAL)
  --slot-hour-price <f>          (default: 0.06)
  --ondemand-price <f>           USD/TiB scanned (default: 6.25)
  --storage-logical-active-price <f>    (default: 0.02)
  --storage-logical-lt-price <f>        (default: 0.01)
  --storage-physical-active-price <f>   (default: 0.04)
  --storage-physical-lt-price <f>       (default: 0.02)
  --categories <a,b,...>         restrict to a subset (repeatable)
  --sql-dir <dir>                SQL template directory
  --dry-run                      render + print SQL, run no queries
  -v, --verbose                  verbose logging
  -h, --help                     this help

Requires: bash >= 4.2, gcloud, bq (Google Cloud SDK). No jq / Python needed.
EOF
}

log() {  # log LEVEL message...
  local level=$1; shift
  if [ "$level" = "DEBUG" ] && [ "$VERBOSE" -ne 1 ]; then return 0; fi
  echo "$(date -u +%H:%M:%S) [$level] $*" >&2
}

die() { echo "rabbit-assess: $*" >&2; exit 1; }

# --- argument parsing ------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)            SCOPE="${2:-}"; shift 2 ;;
      --location)         LOCATIONS+=("${2:-}"); shift 2 ;;
      --lookback-days)    LOOKBACK_DAYS="${2:-}"; shift 2 ;;
      --output-dir)       OUTPUT_DIR="${2:-}"; shift 2 ;;
      --currency)         CURRENCY="${2:-}"; shift 2 ;;
      --exchange-rate)    EXCHANGE_RATE="${2:-}"; shift 2 ;;
      --default-storage-billing-model)
                          DEFAULT_STORAGE_MODEL="$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
      --slot-hour-price)  SLOT_HOUR_PRICE="${2:-}"; shift 2 ;;
      --ondemand-price)   ONDEMAND_PRICE="${2:-}"; shift 2 ;;
      --storage-logical-active-price)  STORAGE_LOGICAL_ACTIVE="${2:-}"; shift 2 ;;
      --storage-logical-lt-price)      STORAGE_LOGICAL_LT="${2:-}"; shift 2 ;;
      --storage-physical-active-price) STORAGE_PHYSICAL_ACTIVE="${2:-}"; shift 2 ;;
      --storage-physical-lt-price)     STORAGE_PHYSICAL_LT="${2:-}"; shift 2 ;;
      --categories)
        local IFS=','
        for c in ${2:-}; do CATEGORIES+=("$c"); done
        shift 2 ;;
      --sql-dir)          SQL_DIR="${2:-}"; shift 2 ;;
      --dry-run)          DRY_RUN=1; shift ;;
      -v|--verbose)       VERBOSE=1; shift ;;
      -h|--help)          usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
}

is_number() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
valid_project_id() { [[ "$1" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; }
valid_location()   { [[ "${1,,}" =~ ^(us|eu|[a-z]+-[a-z]+[0-9]+)$ ]]; }

validate() {
  command -v gcloud >/dev/null 2>&1 || die "gcloud not found on PATH"
  command -v bq     >/dev/null 2>&1 || die "bq not found on PATH"

  [ -n "$SCOPE" ] || die "--scope is required"
  [[ "$SCOPE" =~ ^(org|folder|project):[A-Za-z0-9_-]+$ ]] \
    || die "--scope must be org:<id>, folder:<id> or project:<id>"

  [ "${#LOCATIONS[@]}" -gt 0 ] || die "at least one --location is required"
  local loc
  for loc in "${LOCATIONS[@]}"; do
    valid_location "$loc" || die "invalid BigQuery location: $loc"
  done

  [[ "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] && [ "$LOOKBACK_DAYS" -ge 1 ] \
    && [ "$LOOKBACK_DAYS" -le 365 ] || die "--lookback-days must be 1-365"

  case "$DEFAULT_STORAGE_MODEL" in
    LOGICAL|PHYSICAL) ;;
    *) die "--default-storage-billing-model must be LOGICAL or PHYSICAL" ;;
  esac

  local n
  for n in "$EXCHANGE_RATE" "$SLOT_HOUR_PRICE" "$ONDEMAND_PRICE" \
           "$STORAGE_LOGICAL_ACTIVE" "$STORAGE_LOGICAL_LT" \
           "$STORAGE_PHYSICAL_ACTIVE" "$STORAGE_PHYSICAL_LT"; do
    is_number "$n" || die "expected a number, got: $n"
  done

  [ -d "$SQL_DIR" ] || die "SQL template directory not found: $SQL_DIR"

  if [ "${#CATEGORIES[@]}" -eq 0 ]; then
    CATEGORIES=("${ALL_CATEGORIES[@]}")
  else
    local c known
    for c in "${CATEGORIES[@]}"; do
      known=0
      local k
      for k in "${ALL_CATEGORIES[@]}"; do [ "$c" = "$k" ] && known=1; done
      [ "$known" -eq 1 ] || die "unknown category: $c"
    done
  fi
}

# --- SQL rendering ---------------------------------------------------------
# Identifiers are validated before reaching here; values contain no sed
# metacharacters, so plain substitution is safe.
render_sql() {  # render_sql CATEGORY PROJECT_ID REGION
  local cat=$1 pid=$2 region=$3
  local tmpl="$SQL_DIR/$cat.sql"
  [ -f "$tmpl" ] || return 1
  sed \
    -e "s|\${project_id}|$pid|g" \
    -e "s|\${region}|$region|g" \
    -e "s|\${lookback_days}|$LOOKBACK_DAYS|g" \
    -e "s|\${slot_hour_price}|$SLOT_HOUR_PRICE|g" \
    -e "s|\${ondemand_price}|$ONDEMAND_PRICE|g" \
    -e "s|\${storage_logical_active_price}|$STORAGE_LOGICAL_ACTIVE|g" \
    -e "s|\${storage_logical_lt_price}|$STORAGE_LOGICAL_LT|g" \
    -e "s|\${storage_physical_active_price}|$STORAGE_PHYSICAL_ACTIVE|g" \
    -e "s|\${storage_physical_lt_price}|$STORAGE_PHYSICAL_LT|g" \
    -e "s|\${default_storage_billing_model}|$DEFAULT_STORAGE_MODEL|g" \
    "$tmpl"
}

# --- project enumeration ---------------------------------------------------
enumerate_projects() {
  local kind=${SCOPE%%:*} value=${SCOPE#*:}
  PROJECTS=()
  if [ "$kind" = "project" ]; then
    PROJECTS=("$value")
    return 0
  fi

  local -a queue
  local -A seen found
  if [ "$kind" = "org" ]; then queue=("organizations/$value"); else queue=("folders/$value"); fi

  while [ "${#queue[@]}" -gt 0 ]; do
    local parent=${queue[0]}
    queue=("${queue[@]:1}")
    [ -n "${seen[$parent]:-}" ] && continue
    seen[$parent]=1

    local ptype=${parent%%/*} pid=${parent#*/} gtype
    case "$ptype" in
      organizations) gtype=organization ;;
      folders)       gtype=folder ;;
    esac

    local plist p
    if plist=$(gcloud projects list \
                 --filter="parent.id=$pid AND parent.type=$gtype" \
                 --format="value(projectId)" 2>/dev/null); then
      while IFS= read -r p; do [ -n "$p" ] && found[$p]=1; done <<<"$plist"
    else
      log WARN "cannot list projects under $parent (skipped)"
    fi

    local flist f
    if flist=$(gcloud resource-manager folders list \
                 "--$gtype=$pid" --format="value(name)" 2>/dev/null); then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        [[ "$f" == folders/* ]] || f="folders/$f"
        queue+=("$f")
      done <<<"$flist"
    else
      log DEBUG "cannot list sub-folders under $parent (skipped)"
    fi
  done

  if [ "${#found[@]}" -gt 0 ]; then
    while IFS= read -r p; do PROJECTS+=("$p"); done \
      < <(printf '%s\n' "${!found[@]}" | sort)
  fi
}

# --- collection ------------------------------------------------------------
record_error() {  # record_error PROJECT LOCATION CATEGORY CLASS MESSAGE
  local msg=${5//\"/\"\"}
  printf '%s,%s,%s,%s,"%s",%s\n' \
    "$1" "$2" "$3" "$4" "$msg" "$RUN_TS_ISO" >>"$RUN_DIR/errors.csv"
  ERROR_COUNT=$((ERROR_COUNT + 1))
  ERR_BY_CAT[$3]=$(( ${ERR_BY_CAT[$3]:-0} + 1 ))
}

append_result() {  # append_result CATEGORY PROJECT LOCATION CSV_FILE
  local cat=$1 pid=$2 loc=$3 file=$4
  local dest="$RUN_DIR/$cat.csv"
  SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  # bq emits no output at all for a 0-row result.
  if [ ! -s "$file" ]; then
    [ -f "$dest" ] || : >"$dest"
    return
  fi
  # Write the header once (dest may exist but be empty from a prior 0-row run).
  if [ ! -s "$dest" ]; then
    printf 'project_id,location,collected_at,%s\n' "$(head -1 "$file")" >"$dest"
  fi
  local line
  while IFS= read -r line; do
    printf '%s,%s,%s,%s\n' "$pid" "$loc" "$RUN_TS_ISO" "$line" >>"$dest"
  done < <(tail -n +2 "$file")
  local n=$(( $(wc -l <"$file") - 1 ))
  [ "$n" -lt 0 ] && n=0
  ROWCOUNT[$cat]=$(( ${ROWCOUNT[$cat]:-0} + n ))
}

collect_one() {  # collect_one CATEGORY PROJECT LOCATION REGION
  local cat=$1 pid=$2 loc=$3 region=$4
  local sql out err
  if ! sql=$(render_sql "$cat" "$pid" "$region"); then
    record_error "$pid" "$loc" "$cat" "RenderError" "missing template $cat.sql"
    return
  fi
  out=$(mktemp); err=$(mktemp)
  if printf '%s\n' "$sql" | bq --quiet --format=csv query \
        --use_legacy_sql=false --project_id="$pid" --location="$loc" \
        --max_rows=1000000 >"$out" 2>"$err"; then
    append_result "$cat" "$pid" "$loc" "$out"
  else
    # bq writes BigQuery errors to stderr but CSV-formatting errors to stdout,
    # so scan both.
    local msg
    msg=$(cat "$err" "$out" | tr -d '\r' | grep -v -e '^Waiting' -e '^$' \
          | head -2 | tr '\n' ' ')
    record_error "$pid" "$loc" "$cat" "QueryError" "${msg:-bq query failed}"
  fi
  rm -f "$out" "$err"
}

# --- report helpers --------------------------------------------------------
# Sum a numeric column found by header name. Optionally exclude rows where
# another column equals a value. Safe for our queries: no commas appear in
# fields left of the summed column.
csv_sum() {  # csv_sum FILE SUMCOL [FILTERCOL EXCLUDEVAL]
  [ -f "$1" ] || { echo "0.00"; return; }
  awk -F, -v sc="$2" -v fc="${3:-}" -v xv="${4:-}" '
    NR==1 { for (i=1;i<=NF;i++){ if($i==sc) s=i; if(fc!=""&&$i==fc) f=i } next }
    s     { if (fc=="" || $f!=xv) tot += $s + 0 }
    END   { printf "%.2f", tot + 0 }
  ' "$1"
}

# Sum the last column (used where earlier free-text fields may contain commas).
csv_sum_lastcol() {  # csv_sum_lastcol FILE
  [ -f "$1" ] || { echo "0.00"; return; }
  awk -F, 'NR>1 { tot += $NF + 0 } END { printf "%.2f", tot + 0 }' "$1"
}

mul() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", (a+0)*(b+0) }'; }
fmt() { awk -v a="$1" 'BEGIN { printf "%.2f", a+0 }'; }

# Render USD-only or dual-currency cells for a Markdown table.
cost_cells() {  # cost_cells AMOUNT
  local usd; usd=$(mul "$1" "$EXCHANGE_RATE")
  if [ "$CURRENCY" = "USD" ]; then echo "$usd"; else echo "$(fmt "$1") | $usd"; fi
}

generate_report() {
  local report="$RUN_DIR/report.md"
  local total_pl=$(( ${#PROJECTS[@]} * ${#LOCATIONS[@]} ))

  local job_saving storage_saving failed_cost billed utilized waste_cost cap_hours
  job_saving=$(csv_sum "$RUN_DIR/pricing_model_optimization.csv" possible_saving)
  storage_saving=$(csv_sum "$RUN_DIR/storage_billing_model.csv" potential_monthly_saving recommendation KEEP)
  failed_cost=$(csv_sum "$RUN_DIR/failed_jobs_general.csv" cost)
  billed=$(csv_sum "$RUN_DIR/reservation_waste.csv" billed_slot_hours)
  utilized=$(csv_sum "$RUN_DIR/reservation_waste.csv" utilized_slot_hours)
  cap_hours=$(csv_sum_lastcol "$RUN_DIR/failed_jobs_capacity.csv")
  waste_cost=$(awk -v b="$billed" -v u="$utilized" -v p="$SLOT_HOUR_PRICE" \
    'BEGIN { d=b-u; if(d<0)d=0; printf "%.2f", d*p }')
  local windowed
  windowed=$(awk -v a="$job_saving" -v b="$failed_cost" -v c="$waste_cost" \
    'BEGIN { printf "%.2f", a+b+c }')

  local cur_hdr sep
  if [ "$CURRENCY" = "USD" ]; then
    cur_hdr="Saving (USD)"; sep="|---|---|---|"
  else
    cur_hdr="Saving ($CURRENCY) | Saving (USD)"; sep="|---|---|---|---|"
  fi

  {
    echo "# Rabbit GCP/BigQuery Cost-Savings Assessment"
    echo
    echo "- **Scope:** \`$SCOPE\`"
    echo "- **Locations:** ${LOCATIONS[*]}"
    echo "- **Lookback window:** $LOOKBACK_DAYS days"
    echo "- **Projects discovered:** ${#PROJECTS[@]}"
    echo "- **Generated at:** $RUN_TS_ISO"
    echo "- **Currency:** $CURRENCY (FX: 1 $CURRENCY = $EXCHANGE_RATE USD)"
    echo "- **Storage default model:** $DEFAULT_STORAGE_MODEL"
    echo
    echo "## Coverage"
    echo
    echo "What was collected vs. skipped. Skips (missing access, disabled APIs)"
    echo "are expected with limited visibility - the run continues regardless."
    echo
    echo "| Category | Collected | Skipped | Rows | Most common skip |"
    echo "|---|---|---|---|---|"
    local cat
    for cat in "${ALL_CATEGORIES[@]}"; do
      local errs=${ERR_BY_CAT[$cat]:-0}
      local ok=$(( total_pl - errs ))
      [ "$ok" -lt 0 ] && ok=0
      local reason="-"
      if [ "$errs" -gt 0 ] && [ -f "$RUN_DIR/errors.csv" ]; then
        reason=$(awk -F, -v c="$cat" 'NR>1 && $3==c {print $4}' "$RUN_DIR/errors.csv" \
                 | sort | uniq -c | sort -rn | head -1 | awk '{print $1" x "$2}')
        [ -z "$reason" ] && reason="-"
      fi
      echo "| ${CATEGORY_TITLE[$cat]} | $ok/$total_pl | $errs | ${ROWCOUNT[$cat]:-0} | $reason |"
    done
    echo
    echo "## Estimated Savings Opportunities"
    echo
    echo "| Opportunity | Period | $cur_hdr |"
    echo "$sep"
    echo "| Job pricing-model optimization | ${LOOKBACK_DAYS}d | $(cost_cells "$job_saving") |"
    echo "| Storage billing-model optimization | monthly | $(cost_cells "$storage_saving") |"
    echo "| Failed-job slot cost (all failed jobs) | ${LOOKBACK_DAYS}d | $(cost_cells "$failed_cost") |"
    echo "| Reservation waste ($(fmt "$(awk -v b="$billed" -v u="$utilized" 'BEGIN{d=b-u;if(d<0)d=0;print d}')") idle slot-hours) | ${LOOKBACK_DAYS}d | $(cost_cells "$waste_cost") |"
    echo "| **Total (${LOOKBACK_DAYS}-day, excl. monthly storage)** | ${LOOKBACK_DAYS}d | $(cost_cells "$windowed") |"
    echo
    echo "> Capacity-related failed jobs additionally burned $cap_hours slot-hours."
    echo
    echo "## Collected Data"
    echo
    for cat in "${ALL_CATEGORIES[@]}"; do
      echo "### ${CATEGORY_TITLE[$cat]}"
      echo
      if [ "$cat" = "storage_billing_model" ]; then
        echo "_Datasets with no explicit \`storage_billing_model\` option are assumed **$DEFAULT_STORAGE_MODEL**._"
        echo
      fi
      local f="$RUN_DIR/$cat.csv"
      if [ -f "$f" ] && [ "$(wc -l <"$f")" -gt 1 ]; then
        echo "First rows of \`$cat.csv\` (${ROWCOUNT[$cat]:-0} rows total):"
        echo
        echo '```'
        head -6 "$f"
        echo '```'
      else
        echo "_No rows collected._"
      fi
      echo
    done
    echo "## Limitations"
    echo
    echo "- SKU-level GCP billing is out of scope; figures are estimates derived"
    echo "  from INFORMATION_SCHEMA usage and the supplied prices."
    echo "- Reservation utilization counts each project's own jobs only, so a"
    echo "  reservation serving multiple projects shows more apparent waste."
    echo "- Prices are list prices unless overridden. The local->USD rate is the"
    echo "  --exchange-rate value (no auto-derivation in the Bash port)."
  } >"$report"
  log INFO "report written: $report"
}

console_summary() {
  local job storage failed billed utilized waste windowed
  job=$(csv_sum "$RUN_DIR/pricing_model_optimization.csv" possible_saving)
  storage=$(csv_sum "$RUN_DIR/storage_billing_model.csv" potential_monthly_saving recommendation KEEP)
  failed=$(csv_sum "$RUN_DIR/failed_jobs_general.csv" cost)
  billed=$(csv_sum "$RUN_DIR/reservation_waste.csv" billed_slot_hours)
  utilized=$(csv_sum "$RUN_DIR/reservation_waste.csv" utilized_slot_hours)
  waste=$(awk -v b="$billed" -v u="$utilized" -v p="$SLOT_HOUR_PRICE" \
    'BEGIN { d=b-u; if(d<0)d=0; printf "%.2f", d*p }')
  windowed=$(awk -v a="$job" -v b="$failed" -v c="$waste" 'BEGIN { printf "%.2f", a+b+c }')

  local total=$(( ${#PROJECTS[@]} * ${#LOCATIONS[@]} * ${#CATEGORIES[@]} ))
  echo
  if [ "$CURRENCY" = "USD" ]; then
    echo "  Estimated Savings Opportunities (USD)"
  else
    echo "  Estimated Savings Opportunities ($CURRENCY; FX 1 $CURRENCY = $EXCHANGE_RATE USD)"
  fi
  echo "  -----------------------------------------------------------"
  summary_row() {  # summary_row LABEL AMOUNT
    if [ "$CURRENCY" = "USD" ]; then
      printf "  %-34s %14s\n" "$1" "$(mul "$2" "$EXCHANGE_RATE")"
    else
      printf "  %-34s %14s %14s\n" "$1" "$2" "$(mul "$2" "$EXCHANGE_RATE")"
    fi
  }
  if [ "$CURRENCY" = "USD" ]; then
    printf "  %-34s %14s\n" "Opportunity" "USD"
  else
    printf "  %-34s %14s %14s\n" "Opportunity" "$CURRENCY" "USD"
  fi
  summary_row "Job pricing-model optimization" "$job"
  summary_row "Storage billing-model (monthly)" "$storage"
  summary_row "Failed-job slot cost" "$failed"
  summary_row "Reservation waste" "$waste"
  summary_row "Total (windowed)" "$windowed"
  echo "  -----------------------------------------------------------"
  echo "  $SUCCESS_COUNT/$total collection units succeeded ($ERROR_COUNT skipped - see errors.csv)"
  echo "  Report: $RUN_DIR/report.md"
}

write_manifest() {
  {
    echo "tool_version=$VERSION"
    echo "scope=$SCOPE"
    echo "locations=${LOCATIONS[*]}"
    echo "lookback_days=$LOOKBACK_DAYS"
    echo "currency=$CURRENCY"
    echo "exchange_rate=$EXCHANGE_RATE"
    echo "default_storage_billing_model=$DEFAULT_STORAGE_MODEL"
    echo "slot_hour_price=$SLOT_HOUR_PRICE"
    echo "ondemand_price=$ONDEMAND_PRICE"
    echo "projects=${PROJECTS[*]}"
    echo "categories=${CATEGORIES[*]}"
    echo "generated_at=$RUN_TS_ISO"
    echo "units_succeeded=$SUCCESS_COUNT"
    echo "units_skipped=$ERROR_COUNT"
  } >"$RUN_DIR/manifest.txt"
}

# --- dry run ---------------------------------------------------------------
do_dry_run() {
  enumerate_projects
  echo "Dry run - ${#PROJECTS[@]} project(s), ${#LOCATIONS[@]} location(s), ${#CATEGORIES[@]} categories"
  if [ "${#PROJECTS[@]}" -gt 0 ]; then
    printf 'Projects: %s\n' "${PROJECTS[*]}"
  else
    echo "Projects: (none accessible)"
  fi
  local sample_project="sample-project-id"
  [ "${#PROJECTS[@]}" -gt 0 ] && sample_project="${PROJECTS[0]}"
  local sample_loc="${LOCATIONS[0]}"
  local cat
  for cat in "${CATEGORIES[@]}"; do
    echo
    echo "----- $cat.sql  [$sample_project / $sample_loc] -----"
    render_sql "$cat" "$sample_project" "${sample_loc,,}" || echo "(missing template)"
  done
}

# ===========================================================================
main() {
  parse_args "$@"
  validate

  if [ "$DRY_RUN" -eq 1 ]; then
    do_dry_run
    exit 0
  fi

  RUN_TS_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  RUN_DIR="$OUTPUT_DIR/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$RUN_DIR" || die "cannot create output directory $RUN_DIR"
  echo "project_id,location,category,error_class,message,occurred_at" >"$RUN_DIR/errors.csv"

  local c
  for c in "${ALL_CATEGORIES[@]}"; do ROWCOUNT[$c]=0; ERR_BY_CAT[$c]=0; done

  log INFO "scope=$SCOPE locations=${LOCATIONS[*]} lookback=${LOOKBACK_DAYS}d"
  echo "Resolving projects under $SCOPE ..."
  enumerate_projects
  [ "${#PROJECTS[@]}" -gt 0 ] || die "no accessible projects found under $SCOPE"
  echo "Found ${#PROJECTS[@]} accessible project(s)."

  local total=$(( ${#PROJECTS[@]} * ${#LOCATIONS[@]} * ${#CATEGORIES[@]} ))
  local done=0 pid loc cat region
  for pid in "${PROJECTS[@]}"; do
    if ! valid_project_id "$pid"; then
      for loc in "${LOCATIONS[@]}"; do
        for cat in "${CATEGORIES[@]}"; do
          record_error "$pid" "$loc" "$cat" "InvalidProjectId" "rejected by validation"
          done=$((done + 1))
        done
      done
      continue
    fi
    for loc in "${LOCATIONS[@]}"; do
      region="${loc,,}"
      for cat in "${CATEGORIES[@]}"; do
        done=$((done + 1))
        printf '\r  [%d/%d] %-48s' "$done" "$total" "$pid/$loc/$cat" >&2
        collect_one "$cat" "$pid" "$loc" "$region"
      done
    done
  done
  printf '\r%*s\r' 72 '' >&2

  # Ensure an (empty) CSV exists for every category that was attempted.
  for cat in "${CATEGORIES[@]}"; do
    [ -f "$RUN_DIR/$cat.csv" ] || : >"$RUN_DIR/$cat.csv"
  done

  write_manifest
  generate_report
  console_summary
}

main "$@"
