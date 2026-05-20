"""Typer CLI for the Rabbit GCP/BigQuery cost-savings assessment."""

from __future__ import annotations

import logging
from datetime import UTC, datetime
from pathlib import Path

import typer
from rich.console import Console

from . import __version__, report, writers
from .auth import resolve_auth
from .categories import UNITS, build_numbers
from .config import PricingConfig
from .models import utc_now
from .pricing import derive_fx_rate, resolve_pricing
from .runner import run_collection
from .scope import ScopeError, list_projects, parse_scope
from .sql import SqlRenderError, normalize_location, render

app = typer.Typer(
    add_completion=False,
    help="Assess a GCP/BigQuery environment for cost-saving opportunities with Rabbit.",
)
console = Console()
log = logging.getLogger(__name__)

_ALL_UNITS = [unit.name for unit in UNITS]


def _fail(message: str) -> None:
    console.print(f"[red]Error:[/red] {message}")
    raise typer.Exit(code=1)


def _resolve_units(categories: list[str]) -> list[str]:
    if not categories:
        return list(_ALL_UNITS)
    unknown = [c for c in categories if c not in _ALL_UNITS]
    if unknown:
        _fail(f"Unknown categories {unknown}. Valid: {_ALL_UNITS}")
    return [c for c in _ALL_UNITS if c in categories]


def _validate_locations(locations: list[str]) -> list[str]:
    for loc in locations:
        try:
            normalize_location(loc)
        except SqlRenderError as exc:
            _fail(str(exc))
    return locations


@app.command()
def run(
    scope: str = typer.Option(
        ..., "--scope", help="org:<id> | folder:<id> | project:<id>"
    ),
    location: list[str] = typer.Option(
        ..., "--location", help="BigQuery location, e.g. US (repeatable)"
    ),
    lookback_days: int = typer.Option(30, "--lookback-days", min=1, max=365),
    output_dir: Path = typer.Option(Path("./rabbit-assessment-output"), "--output-dir"),
    config: Path | None = typer.Option(
        None, "--config", exists=True, dir_okay=False, help="TOML pricing config"
    ),
    currency: str = typer.Option("USD", "--currency", help="ISO 4217 currency code"),
    slot_hour_price: float | None = typer.Option(None, "--slot-hour-price"),
    ondemand_price: float | None = typer.Option(None, "--ondemand-price"),
    max_workers: int = typer.Option(8, "--max-workers", min=1, max=32),
    categories: list[str] = typer.Option(
        [], "--categories", help="Restrict to a subset of categories (repeatable)"
    ),
    quota_project: str | None = typer.Option(
        None, "--quota-project", help="Project that BigQuery jobs are billed to"
    ),
    dry_run: bool = typer.Option(False, "--dry-run", help="Render SQL only; no queries"),
    verbose: bool = typer.Option(False, "-v", "--verbose"),
) -> None:
    """Collect cost data across a scope and produce CSVs + a savings report."""
    try:
        parse_scope(scope)
    except ScopeError as exc:
        _fail(str(exc))

    locations = _validate_locations(location)
    units = _resolve_units(categories)
    cli_overrides = {"slot_hour_price": slot_hour_price, "ondemand_price": ondemand_price}

    auth_ctx = resolve_auth(quota_project)
    console.print(
        f"Authenticated as [cyan]{auth_ctx.principal}[/cyan] "
        f"(quota project: {auth_ctx.quota_project})"
    )

    pricing_by_location = resolve_pricing(config, cli_overrides, locations)
    if currency.upper() != "USD" and not (config or slot_hour_price or ondemand_price):
        console.print(
            "[yellow]Note:[/yellow] --currency is set but prices are USD list-price "
            "defaults. Supply local-currency prices via --config for accurate figures."
        )

    if dry_run:
        _dry_run(scope, auth_ctx, locations, units, lookback_days, pricing_by_location)
        return

    run_dir = output_dir / datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    run_dir.mkdir(parents=True, exist_ok=True)
    writers.setup_run_logging(run_dir, verbose)
    started = utc_now()
    log.info("Run started: scope=%s locations=%s lookback=%d", scope, locations, lookback_days)

    console.print(f"Resolving projects under [cyan]{scope}[/cyan] ...")
    projects = list_projects(scope, auth_ctx.credentials)
    if not projects:
        _fail(f"No accessible projects found under {scope}")
    console.print(f"Found [green]{len(projects)}[/green] accessible project(s).")

    fx_rate = derive_fx_rate(currency)

    from google.cloud import bigquery

    client = bigquery.Client(
        project=auth_ctx.quota_project, credentials=auth_ctx.credentials
    )

    results, errors = run_collection(
        client, projects, locations, units, lookback_days, pricing_by_location, max_workers
    )

    row_counts = writers.write_category_csvs(run_dir, results)
    writers.write_errors_csv(run_dir, errors)
    writers.write_rendered_sql(run_dir, results)
    writers.write_manifest(
        run_dir,
        {
            "tool_version": __version__,
            "scope": scope,
            "locations": locations,
            "lookback_days": lookback_days,
            "currency": currency.upper(),
            "fx_rate": fx_rate.as_dict(),
            "pricing": {loc: pc.model_dump() for loc, pc in pricing_by_location.items()},
            "projects": projects,
            "units": units,
            "max_workers": max_workers,
            "principal": auth_ctx.principal,
            "quota_project": auth_ctx.quota_project,
            "started_at": started,
            "generated_at": utc_now(),
            "row_counts": row_counts,
            "counts": {"succeeded": len(results), "skipped": len(errors)},
        },
    )

    report.generate_report(run_dir)
    console.print()
    report.print_console_summary(run_dir, console)


@app.command("report")
def report_command(
    run_dir: Path = typer.Option(
        ..., "--run-dir", exists=True, file_okay=False, help="An existing run directory"
    ),
) -> None:
    """Regenerate report.md from an existing run directory (no API calls)."""
    if not (run_dir / "manifest.json").exists():
        _fail(f"{run_dir} is not a run directory (no manifest.json)")
    report.generate_report(run_dir)
    console.print()
    report.print_console_summary(run_dir, console)


@app.command()
def version() -> None:
    """Print the tool version."""
    console.print(f"rabbit-assessment {__version__}")


def _dry_run(
    scope: str,
    auth_ctx: object,
    locations: list[str],
    units: list[str],
    lookback_days: int,
    pricing_by_location: dict[str, PricingConfig],
) -> None:
    """Print the rendered SQL and the project x location matrix; no queries."""
    projects = list_projects(scope, getattr(auth_ctx, "credentials", None))
    console.print(f"[bold]Dry run[/bold] — {len(projects)} project(s), "
                  f"{len(locations)} location(s), {len(units)} categories")
    console.print(f"Projects: {projects or '(none accessible)'}")
    sample_project = projects[0] if projects else "sample-project-id"
    sample_location = locations[0]
    pricing = pricing_by_location[sample_location]
    for unit_name in units:
        console.rule(f"{unit_name}.sql  [{sample_project} / {sample_location}]")
        try:
            rendered = render(
                f"{unit_name}.sql",
                project_id=sample_project,
                location=sample_location,
                numbers=build_numbers(unit_name, lookback_days, pricing),
            )
            console.print(rendered)
        except SqlRenderError as exc:
            console.print(f"[red]{exc}[/red]")


if __name__ == "__main__":
    app()
