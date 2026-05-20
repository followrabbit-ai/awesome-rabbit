"""Write CSVs, errors.csv, manifest.json, rendered SQL, and run logging."""

from __future__ import annotations

import csv
import json
import logging
from pathlib import Path
from typing import Any

from .categories import UNITS
from .models import CollectionError, CollectionResult

log = logging.getLogger(__name__)

_ERROR_COLUMNS = ["project_id", "location", "category", "error_class", "message", "occurred_at"]
_LEAD_COLUMNS = ["project_id", "location", "collected_at"]


def setup_run_logging(out_dir: Path, verbose: bool) -> None:
    """Send logs to run.log (always) and to the console (only when verbose)."""
    handlers: list[logging.Handler] = [
        logging.FileHandler(out_dir / "run.log", encoding="utf-8")
    ]
    if verbose:
        handlers.append(logging.StreamHandler())
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=handlers,
        force=True,
    )


def _flatten(value: Any, prefix: str = "") -> dict[str, Any]:
    """Flatten nested dicts (BigQuery STRUCTs) to dotted keys; lists -> JSON."""
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, val in value.items():
            out.update(_flatten(val, f"{prefix}{key}."))
        return out
    key = prefix.rstrip(".") or "value"
    if isinstance(value, list):
        return {key: json.dumps(value, default=str)}
    return {key: value}


def _write_rows(path: Path, rows: list[dict[str, Any]], lead: list[str]) -> None:
    fieldnames = list(lead)
    for row in rows:
        for key in row:
            if key not in fieldnames:
                fieldnames.append(key)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def write_category_csvs(out_dir: Path, results: list[CollectionResult]) -> dict[str, int]:
    """Write one CSV per unit. Returns a {unit: row_count} map."""
    by_unit: dict[str, list[CollectionResult]] = {}
    for result in results:
        by_unit.setdefault(result.template, []).append(result)

    row_counts: dict[str, int] = {}
    for unit in UNITS:
        rows: list[dict[str, Any]] = []
        for result in by_unit.get(unit.name, []):
            for raw in result.rows:
                rows.append(
                    {
                        "project_id": result.project_id,
                        "location": result.location,
                        "collected_at": result.collected_at,
                        **_flatten(raw),
                    }
                )
        _write_rows(out_dir / f"{unit.name}.csv", rows, _LEAD_COLUMNS)
        row_counts[unit.name] = len(rows)
    return row_counts


def write_errors_csv(out_dir: Path, errors: list[CollectionError]) -> None:
    rows = [
        {
            "project_id": error.project_id,
            "location": error.location,
            "category": error.template,
            "error_class": error.error_class,
            "message": error.message,
            "occurred_at": error.occurred_at,
        }
        for error in errors
    ]
    _write_rows(out_dir / "errors.csv", rows, _ERROR_COLUMNS)


def write_rendered_sql(out_dir: Path, results: list[CollectionResult]) -> None:
    """Persist one rendered SQL sample per unit so customers can audit it."""
    sql_dir = out_dir / "rendered_sql"
    sql_dir.mkdir(exist_ok=True)
    seen: set[str] = set()
    for result in results:
        if result.template in seen:
            continue
        seen.add(result.template)
        (sql_dir / f"{result.template}.sql").write_text(result.rendered_sql, encoding="utf-8")


def write_manifest(out_dir: Path, manifest: dict[str, Any]) -> None:
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, default=str), encoding="utf-8"
    )
