"""Runner orchestration and error isolation.

The core requirement: one failing (project, location, category) must never
abort the others.
"""

from google.api_core.exceptions import Forbidden

from rabbit_assessment.models import CollectionError, CollectionResult
from rabbit_assessment.pricing import resolve_pricing
from rabbit_assessment.runner import run_collection


class _FakeJob:
    def __init__(self, rows):
        self._rows = rows

    def result(self):
        return self._rows


class _FakeClient:
    """Stand-in BigQuery client; raises Forbidden when the SQL mentions a
    project listed in `fail_substrings`."""

    def __init__(self, fail_substrings):
        self.fail_substrings = fail_substrings

    def query(self, sql, location):  # noqa: ARG002 - signature parity
        for needle in self.fail_substrings:
            if needle in sql:
                raise Forbidden("caller lacks bigquery.jobs.listAll")
        return _FakeJob([{"ok": 1}])


def test_runner_isolates_failures():
    client = _FakeClient(fail_substrings=["denied-project-x"])
    pricing = resolve_pricing(None, {}, ["US"])

    results, errors = run_collection(
        client,
        projects=["good-project-1", "denied-project-x"],
        locations=["US"],
        units=["reservations", "capacity_commitments"],
        lookback_days=30,
        pricing_by_location=pricing,
        max_workers=4,
    )

    assert len(results) + len(errors) == 4  # 2 projects x 1 location x 2 units
    assert len(results) == 2  # good project, both units
    assert len(errors) == 2  # denied project, both units
    assert all(isinstance(r, CollectionResult) for r in results)
    assert all(isinstance(e, CollectionError) for e in errors)
    assert {e.error_class for e in errors} == {"Forbidden"}
    assert {e.project_id for e in errors} == {"denied-project-x"}


def test_runner_records_render_errors_without_crashing():
    client = _FakeClient(fail_substrings=[])
    pricing = resolve_pricing(None, {}, ["US"])

    results, errors = run_collection(
        client,
        projects=["BadProject"],  # invalid id -> SqlRenderError
        locations=["US"],
        units=["reservations"],
        lookback_days=30,
        pricing_by_location=pricing,
        max_workers=2,
    )

    assert results == []
    assert len(errors) == 1
    assert errors[0].error_class == "SqlRenderError"


def test_runner_successful_results_carry_rows():
    client = _FakeClient(fail_substrings=[])
    pricing = resolve_pricing(None, {}, ["US"])

    results, errors = run_collection(
        client,
        projects=["good-project-1"],
        locations=["US"],
        units=["reservations"],
        lookback_days=30,
        pricing_by_location=pricing,
        max_workers=2,
    )

    assert errors == []
    assert len(results) == 1
    assert results[0].rows == [{"ok": 1}]
    assert results[0].project_id == "good-project-1"
