"""Generate the Markdown report and the rich console summary from a run dir.

Both outputs are built from the on-disk CSVs + manifest.json, so the `report`
command reproduces exactly what `run` produced, with no API calls.
"""

from __future__ import annotations

import csv
import json
import logging
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.table import Table

from .categories import UNITS

log = logging.getLogger(__name__)


def _read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def _to_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _slot_price(pricing: dict[str, Any], location: str | None) -> float:
    entry = pricing.get(location or "", {}) if isinstance(pricing, dict) else {}
    return _to_float(entry.get("slot_hour_price")) or 0.06


def _fmt(amount: float) -> str:
    return f"{amount:,.2f}"


class _Aggregates:
    """Headline numbers computed from a run directory."""

    def __init__(self, run_dir: Path, manifest: dict[str, Any]) -> None:
        currency = manifest.get("currency", "USD")
        fx = manifest.get("fx_rate", {})
        rate = _to_float(fx.get("rate_to_usd")) or 1.0
        pricing = manifest.get("pricing", {})
        self.currency = currency
        self.rate = rate

        job_rows = _read_csv(run_dir / "pricing_model_optimization.csv")
        self.job_saving = sum(_to_float(r.get("possible_saving")) for r in job_rows)

        storage_rows = _read_csv(run_dir / "storage_billing_model.csv")
        self.storage_saving = sum(
            _to_float(r.get("potential_monthly_saving"))
            for r in storage_rows
            if r.get("recommendation", "KEEP") != "KEEP"
            and _to_float(r.get("potential_monthly_saving")) > 0
        )

        failed_rows = _read_csv(run_dir / "failed_jobs_general.csv")
        self.failed_cost = sum(_to_float(r.get("cost")) for r in failed_rows)
        self.failed_slot_hours = sum(_to_float(r.get("slot_hours")) for r in failed_rows)

        capacity_rows = _read_csv(run_dir / "failed_jobs_capacity.csv")
        self.capacity_slot_hours = sum(_to_float(r.get("slot_hours")) for r in capacity_rows)
        self.capacity_cost = sum(
            _to_float(r.get("slot_hours")) * _slot_price(pricing, r.get("location"))
            for r in capacity_rows
        )

        waste_rows = _read_csv(run_dir / "reservation_waste.csv")
        self.reservation_count = len(waste_rows)
        billed = sum(_to_float(r.get("billed_slot_hours")) for r in waste_rows)
        utilized = sum(_to_float(r.get("utilized_slot_hours")) for r in waste_rows)
        self.wasted_slot_hours = max(billed - utilized, 0.0)
        self.waste_cost = sum(
            max(
                _to_float(r.get("billed_slot_hours"))
                - _to_float(r.get("utilized_slot_hours")),
                0.0,
            )
            * _slot_price(pricing, r.get("location"))
            for r in waste_rows
        )

    def usd(self, amount: float) -> float:
        return amount * self.rate

    @property
    def windowed_total(self) -> float:
        """Savings tied to the lookback window (excludes monthly storage)."""
        return self.job_saving + self.failed_cost + self.waste_cost


def _coverage(manifest: dict[str, Any], errors: list[dict[str, str]]) -> list[dict[str, Any]]:
    projects = manifest.get("projects", [])
    locations = manifest.get("locations", [])
    attempted = max(len(projects) * len(locations), 0)
    # Only the categories actually selected for this run were attempted.
    selected = set(manifest.get("units") or [u.name for u in UNITS])
    errors_by_unit: dict[str, list[dict[str, str]]] = defaultdict(list)
    for error in errors:
        errors_by_unit[error.get("category", "")].append(error)

    rows: list[dict[str, Any]] = []
    for unit in UNITS:
        if unit.name not in selected:
            continue
        unit_errors = errors_by_unit.get(unit.name, [])
        succeeded = attempted - len(unit_errors)
        reason = ""
        if unit_errors:
            classes = Counter(e.get("error_class", "?") for e in unit_errors)
            top_class, count = classes.most_common(1)[0]
            reason = f"{count} x {top_class}"
        rows.append(
            {
                "unit": unit,
                "succeeded": max(succeeded, 0),
                "attempted": attempted,
                "skipped": len(unit_errors),
                "reason": reason,
            }
        )
    return rows


def generate_report(run_dir: Path) -> Path:
    """Build report.md from the run directory's CSVs and manifest."""
    manifest = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))
    errors = _read_csv(run_dir / "errors.csv")
    agg = _Aggregates(run_dir, manifest)
    cur = agg.currency
    lookback = manifest.get("lookback_days", 30)
    row_counts = manifest.get("row_counts", {})

    lines: list[str] = []
    lines.append("# Rabbit GCP/BigQuery Cost-Savings Assessment\n")
    lines.append(f"- **Scope:** `{manifest.get('scope', '?')}`")
    lines.append(f"- **Locations:** {', '.join(manifest.get('locations', []))}")
    lines.append(f"- **Lookback window:** {lookback} days")
    lines.append(f"- **Projects discovered:** {len(manifest.get('projects', []))}")
    lines.append(f"- **Generated at:** {manifest.get('generated_at', '?')}")
    fx = manifest.get("fx_rate", {})
    lines.append(
        f"- **Currency:** {cur} — FX 1 {cur} = {agg.rate:.6f} USD "
        f"(source: {fx.get('source', '?')})"
    )
    lines.append("")

    # --- Coverage --------------------------------------------------------
    lines.append("## Coverage\n")
    lines.append("What was collected vs. skipped. Skips (missing access, disabled "
                 "APIs) are expected with limited visibility — the run continues regardless.\n")
    lines.append("| Category | Collected | Skipped | Rows | Most common skip |")
    lines.append("|---|---|---|---|---|")
    for cov in _coverage(manifest, errors):
        unit = cov["unit"]
        lines.append(
            f"| {unit.title} | {cov['succeeded']}/{cov['attempted']} "
            f"| {cov['skipped']} | {row_counts.get(unit.name, 0)} | {cov['reason'] or '-'} |"
        )
    lines.append("")
    if errors:
        lines.append(
            f"{len(errors)} unit(s) skipped. Short index: `errors.csv`. "
            "Full error text and the failing SQL for each: `query-errors.log`. "
            "Run log: `run.log`.\n"
        )

    # --- Savings summary -------------------------------------------------
    # When the currency is USD the local and USD columns are identical, so a
    # single column is shown; otherwise both are shown.
    dual = cur != "USD"

    def cost_cells(amount: float, bold: bool = False) -> str:
        usd = _fmt(agg.usd(amount))
        local = _fmt(amount)
        if bold:
            usd, local = f"**{usd}**", f"**{local}**"
        return f"{local} | {usd}" if dual else usd

    lines.append("## Estimated Savings Opportunities\n")
    if dual:
        lines.append(f"| Opportunity | Period | Saving ({cur}) | Saving (USD) |")
        lines.append("|---|---|---|---|")
    else:
        lines.append("| Opportunity | Period | Saving (USD) |")
        lines.append("|---|---|---|")
    lines.append(
        f"| Job pricing-model optimization | {lookback}d | {cost_cells(agg.job_saving)} |"
    )
    lines.append(
        f"| Storage billing-model optimization | monthly "
        f"| {cost_cells(agg.storage_saving)} |"
    )
    lines.append(
        f"| Failed-job slot cost (all failed jobs) | {lookback}d "
        f"| {cost_cells(agg.failed_cost)} |"
    )
    lines.append(
        f"| Reservation waste ({_fmt(agg.wasted_slot_hours)} idle slot-hours) | {lookback}d "
        f"| {cost_cells(agg.waste_cost)} |"
    )
    lines.append(
        f"| **Total ({lookback}-day, excl. monthly storage)** | {lookback}d "
        f"| {cost_cells(agg.windowed_total, bold=True)} |"
    )
    lines.append("")
    lines.append(
        "> Failed-job slots over the window — capacity-related failures are a "
        "**subset** of all failed jobs (not additional):"
    )
    lines.append(f"> - all failed jobs: {_fmt(agg.failed_slot_hours)} slot-hours")
    lines.append(
        f"> - of which capacity/resource-related: {_fmt(agg.capacity_slot_hours)} "
        f"slot-hours ({cur} {_fmt(agg.capacity_cost)} / "
        f"USD {_fmt(agg.usd(agg.capacity_cost))})\n"
    )

    # --- Per-category detail --------------------------------------------
    pricing = manifest.get("pricing", {})
    storage_default = next(
        (p.get("default_storage_billing_model", "LOGICAL") for p in pricing.values()),
        "LOGICAL",
    )
    lines.append("## Collected Data\n")
    for unit in UNITS:
        lines.append(f"### {unit.title}\n")
        if unit.name == "storage_billing_model":
            lines.append(
                f"_Datasets with no explicit `storage_billing_model` option are "
                f"assumed **{storage_default}**._\n"
            )
        rows = _read_csv(run_dir / f"{unit.name}.csv")
        if not rows:
            lines.append("_No rows collected._\n")
            continue
        lines.extend(_markdown_table(rows, limit=10))
        if len(rows) > 10:
            lines.append(f"\n_Showing 10 of {len(rows)} rows — see `{unit.name}.csv`._\n")
        else:
            lines.append("")

    # --- Limitations -----------------------------------------------------
    lines.append("## Limitations\n")
    lines.append(
        "- **SKU-level GCP billing is out of scope.** Actual spend is not "
        "retrievable via API without a BigQuery billing export; figures here "
        "are estimates derived from `INFORMATION_SCHEMA` usage and the supplied prices."
    )
    lines.append(
        "- **Reservation utilization may be undercounted.** Category 7 reads each "
        "project's own jobs only, so a reservation serving multiple projects shows "
        "less utilization (more apparent waste) than reality."
    )
    lines.append(
        "- **Prices are list prices unless overridden.** Supply negotiated rates "
        "via `--config` for accurate numbers."
    )
    lines.append(
        f"- **FX rate** is derived from the Cloud Billing Catalog API "
        f"({fx.get('source', '?')})."
    )
    lines.append("")

    report_path = run_dir / "report.md"
    report_path.write_text("\n".join(lines), encoding="utf-8")
    log.info("Report written to %s", report_path)
    return report_path


def _markdown_table(rows: list[dict[str, str]], limit: int) -> list[str]:
    columns = list(rows[0].keys())[:10]
    out = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    for row in rows[:limit]:
        cells = [str(row.get(col, "")).replace("|", "\\|")[:120] for col in columns]
        out.append("| " + " | ".join(cells) + " |")
    return out


def print_console_summary(run_dir: Path, console: Console) -> None:
    """Print the headline numbers + coverage line after a run."""
    manifest = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))
    errors = _read_csv(run_dir / "errors.csv")
    agg = _Aggregates(run_dir, manifest)
    cur = agg.currency

    dual = cur != "USD"
    table = Table(title="Estimated Savings Opportunities", show_lines=False)
    table.add_column("Opportunity")
    if dual:
        table.add_column(cur, justify="right")
    table.add_column("USD", justify="right")

    def _row(label: str, amount: float, bold: bool = False) -> None:
        cells = [label]
        if dual:
            cells.append(_fmt(amount))
        cells.append(_fmt(agg.usd(amount)))
        if bold:
            cells = [f"[bold]{c}[/bold]" for c in cells]
        table.add_row(*cells)

    _row("Job pricing-model optimization", agg.job_saving)
    _row("Storage billing-model (monthly)", agg.storage_saving)
    _row("Failed-job slot cost", agg.failed_cost)
    _row("Reservation waste", agg.waste_cost)
    _row("Total (windowed)", agg.windowed_total, bold=True)
    console.print(table)

    attempted = len(manifest.get("projects", [])) * len(manifest.get("locations", []))
    selected_units = manifest.get("units") or [u.name for u in UNITS]
    total_units = attempted * len(selected_units)
    skipped = len(errors)
    succeeded = total_units - skipped
    style = "green" if skipped == 0 else "yellow"
    console.print(
        f"[{style}]{succeeded}/{total_units} collection units succeeded "
        f"({skipped} skipped — see errors.csv)[/{style}]"
    )
    console.print(f"Report: {run_dir / 'report.md'}")
