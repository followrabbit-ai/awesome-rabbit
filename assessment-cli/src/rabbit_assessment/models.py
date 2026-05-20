"""Dataclasses shared across the assessment pipeline."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any


def utc_now() -> str:
    """Current UTC time as a second-precision ISO-8601 string."""
    return datetime.now(UTC).isoformat(timespec="seconds")


@dataclass
class CollectionResult:
    """A query that ran successfully against one (project, location)."""

    project_id: str
    location: str
    template: str
    rows: list[dict[str, Any]]
    rendered_sql: str
    collected_at: str


@dataclass
class CollectionError:
    """A collection unit that failed or was skipped. The run continues anyway.

    `message` is the short form for errors.csv; `detail` and `rendered_sql`
    are the full, untruncated context written to query-errors.log.
    """

    project_id: str
    location: str
    template: str
    error_class: str
    message: str
    occurred_at: str
    detail: str = ""
    rendered_sql: str = ""
