"""Orchestrate collection across projects x locations x units."""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from rich.progress import BarColumn, MofNCompleteColumn, Progress, TextColumn, TimeElapsedColumn

from .collector import collect
from .config import PricingConfig
from .models import CollectionError, CollectionResult

log = logging.getLogger(__name__)


def run_collection(
    client: Any,
    projects: list[str],
    locations: list[str],
    units: list[str],
    lookback_days: int,
    pricing_by_location: dict[str, PricingConfig],
    max_workers: int = 8,
) -> tuple[list[CollectionResult], list[CollectionError]]:
    """Collect every (project, location, unit) combination concurrently.

    A failure in one unit never aborts the others. The BigQuery client is
    thread-safe, so a single shared instance is used across the pool.
    """
    tasks = [
        (project, location, unit)
        for project in projects
        for location in locations
        for unit in units
    ]
    results: list[CollectionResult] = []
    errors: list[CollectionError] = []

    def _work(project_id: str, location: str, unit_name: str) -> CollectionResult | CollectionError:
        return collect(
            client,
            unit_name,
            project_id,
            location,
            lookback_days,
            pricing_by_location[location],
        )

    with Progress(
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        TimeElapsedColumn(),
    ) as progress:
        bar = progress.add_task("Collecting", total=len(tasks))
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            futures = [pool.submit(_work, *task) for task in tasks]
            for future in as_completed(futures):
                outcome = future.result()
                if isinstance(outcome, CollectionResult):
                    results.append(outcome)
                else:
                    errors.append(outcome)
                progress.update(bar, advance=1)

    log.info("Collection complete: %d succeeded, %d skipped", len(results), len(errors))
    return results, errors
