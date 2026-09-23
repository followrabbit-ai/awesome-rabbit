"""SQL template rendering and identifier-injection rejection."""

import pytest

from rabbit_assessment.categories import UNITS, build_literals, build_numbers
from rabbit_assessment.config import PricingConfig
from rabbit_assessment.sql import (
    SqlRenderError,
    normalize_location,
    render,
    validate_project_id,
)


def test_every_unit_template_renders():
    pricing = PricingConfig()
    for unit in UNITS:
        sql = render(
            f"{unit.name}.sql",
            project_id="my-project-123",
            location="US",
            numbers=build_numbers(unit.name, 30, pricing),
            literals=build_literals(unit.name, pricing),
        )
        assert "my-project-123" in sql
        assert "region-us" in sql
        assert "${" not in sql  # all placeholders substituted


def test_storage_template_uses_configured_default_model():
    # Default is LOGICAL.
    sql = render(
        "storage_billing_model.sql",
        project_id="my-project-123",
        location="US",
        numbers=build_numbers("storage_billing_model", 30, PricingConfig()),
        literals=build_literals("storage_billing_model", PricingConfig()),
    )
    assert "COALESCE(m.storage_billing_model, 'LOGICAL')" in sql

    # Configurable to PHYSICAL.
    physical = PricingConfig(default_storage_billing_model="PHYSICAL")
    sql = render(
        "storage_billing_model.sql",
        project_id="my-project-123",
        location="US",
        numbers=build_numbers("storage_billing_model", 30, physical),
        literals=build_literals("storage_billing_model", physical),
    )
    assert "COALESCE(m.storage_billing_model, 'PHYSICAL')" in sql


def test_render_rejects_invalid_literal():
    with pytest.raises(SqlRenderError):
        render(
            "storage_billing_model.sql",
            project_id="my-project-123",
            location="US",
            numbers=build_numbers("storage_billing_model", 30, PricingConfig()),
            literals={"default_storage_billing_model": "LOGICAL'; DROP TABLE x;--"},
        )


def test_normalize_location():
    assert normalize_location("US") == "us"
    assert normalize_location("us-central1") == "us-central1"
    with pytest.raises(SqlRenderError):
        normalize_location("US; DROP TABLE")
    with pytest.raises(SqlRenderError):
        normalize_location("../etc")


@pytest.mark.parametrize(
    "bad_id",
    [
        "Foo",  # uppercase
        "ab",  # too short
        "proj`id",  # backtick injection
        "proj id",  # space
        "proj-",  # trailing hyphen
        "1project",  # leading digit
        "p;drop",  # semicolon
    ],
)
def test_validate_project_id_rejects_injection(bad_id):
    with pytest.raises(SqlRenderError):
        validate_project_id(bad_id)


def test_render_rejects_bad_project_id():
    with pytest.raises(SqlRenderError):
        render("reservations.sql", project_id="bad`id", location="US")


def test_render_rejects_non_numeric_parameter():
    with pytest.raises(SqlRenderError):
        render(
            "failed_jobs_general.sql",
            project_id="my-project-123",
            location="US",
            numbers={"lookback_days": 30, "slot_hour_price": "oops"},  # type: ignore[dict-item]
        )


def test_render_missing_parameter_raises():
    with pytest.raises(SqlRenderError):
        render("failed_jobs_general.sql", project_id="my-project-123", location="US")


def test_unknown_template_raises():
    with pytest.raises(SqlRenderError):
        render("does_not_exist.sql", project_id="my-project-123", location="US")
