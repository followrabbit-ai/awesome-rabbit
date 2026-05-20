"""Run one collection unit against one (project, location).

Every unit is wrapped so that any failure becomes a CollectionError rather than
aborting the run — skip-and-continue is a core requirement.
"""

from __future__ import annotations

import logging
from typing import Any

from google.api_core import exceptions as gexc
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from . import sql
from .categories import build_numbers
from .config import PricingConfig
from .models import CollectionError, CollectionResult, utc_now

log = logging.getLogger(__name__)

# Transient server-side failures worth retrying.
_RETRYABLE = (
    gexc.ServiceUnavailable,
    gexc.InternalServerError,
    gexc.TooManyRequests,
    gexc.GatewayTimeout,
)


@retry(
    retry=retry_if_exception_type(_RETRYABLE),
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=2, min=2, max=30),
    reraise=True,
)
def _run_query(client: Any, rendered_sql: str, location: str) -> list[dict[str, Any]]:
    job = client.query(rendered_sql, location=location)
    return [dict(row) for row in job.result()]


def collect(
    client: Any,
    unit_name: str,
    project_id: str,
    location: str,
    lookback_days: int,
    pricing: PricingConfig,
) -> CollectionResult | CollectionError:
    """Render and run one unit. Never raises — returns a result or an error."""
    try:
        rendered = sql.render(
            f"{unit_name}.sql",
            project_id=project_id,
            location=location,
            numbers=build_numbers(unit_name, lookback_days, pricing),
        )
    except (sql.SqlRenderError, KeyError) as exc:
        return CollectionError(
            project_id, location, unit_name, type(exc).__name__, str(exc), utc_now()
        )

    try:
        rows = _run_query(client, rendered, location)
    except Exception as exc:  # noqa: BLE001 - skip-and-continue is the core requirement
        message = str(exc).strip().replace("\n", " ")[:500]
        log.debug("Collection failed: %s/%s/%s: %s", project_id, location, unit_name, message)
        return CollectionError(
            project_id, location, unit_name, type(exc).__name__, message, utc_now()
        )

    return CollectionResult(project_id, location, unit_name, rows, rendered, utc_now())
