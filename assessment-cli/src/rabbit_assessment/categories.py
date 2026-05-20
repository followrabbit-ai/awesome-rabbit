"""Registry of collection units. Each unit maps 1:1 to a SQL template and a CSV."""

from __future__ import annotations

from dataclasses import dataclass

from .config import PricingConfig


@dataclass(frozen=True)
class Unit:
    """One collection unit: a SQL template, its CSV stem, and report metadata."""

    name: str  # template stem and CSV stem
    title: str  # human-readable label for the report
    monetary: bool  # output carries cost columns that get converted to USD


UNITS: tuple[Unit, ...] = (
    Unit("reservations", "BigQuery Reservations", False),
    Unit("capacity_commitments", "Capacity Commitments", False),
    Unit("pricing_model_optimization", "Job Pricing-Model Optimization", True),
    Unit("storage_billing_model", "Storage Billing-Model Optimization", True),
    Unit("failed_jobs_capacity", "Failed Jobs - Capacity-Related", False),
    Unit("failed_jobs_general", "Failed Jobs - Cost Impact", True),
    Unit("reservation_waste", "Reservation Utilization / Waste", False),
)

UNITS_BY_NAME: dict[str, Unit] = {u.name: u for u in UNITS}


def build_numbers(
    unit_name: str, lookback_days: int, pricing: PricingConfig
) -> dict[str, float | int]:
    """The numeric template parameters a given template needs."""
    if unit_name == "pricing_model_optimization":
        return {
            "lookback_days": lookback_days,
            "slot_hour_price": pricing.slot_hour_price,
            "ondemand_price": pricing.ondemand_price,
        }
    if unit_name == "storage_billing_model":
        return {
            "storage_logical_active_price": pricing.storage_logical_active_price,
            "storage_logical_lt_price": pricing.storage_logical_lt_price,
            "storage_physical_active_price": pricing.storage_physical_active_price,
            "storage_physical_lt_price": pricing.storage_physical_lt_price,
        }
    if unit_name == "failed_jobs_general":
        return {"lookback_days": lookback_days, "slot_hour_price": pricing.slot_hour_price}
    if unit_name in ("failed_jobs_capacity", "reservation_waste"):
        return {"lookback_days": lookback_days}
    if unit_name in ("reservations", "capacity_commitments"):
        return {}
    raise KeyError(f"Unknown collection unit: {unit_name}")
