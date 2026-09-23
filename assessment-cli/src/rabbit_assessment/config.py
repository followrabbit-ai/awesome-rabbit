"""Typed pricing configuration."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class PricingConfig(BaseModel):
    """Prices used to estimate BigQuery cost. Values are per the configured
    currency (USD by default). BigQuery list prices are the built-in defaults;
    supply negotiated rates via the TOML config or CLI overrides."""

    model_config = ConfigDict(extra="forbid")

    # Enterprise-edition slot-hour list price.
    slot_hour_price: float = Field(default=0.06, gt=0)
    # On-demand analysis price, per TiB scanned.
    ondemand_price: float = Field(default=6.25, gt=0)
    # Storage list prices, per GiB-month.
    storage_logical_active_price: float = Field(default=0.02, gt=0)
    storage_logical_lt_price: float = Field(default=0.01, gt=0)
    storage_physical_active_price: float = Field(default=0.04, gt=0)
    storage_physical_lt_price: float = Field(default=0.02, gt=0)

    # Billing model assumed for datasets that have no explicit
    # storage_billing_model option set. BigQuery's own default is LOGICAL.
    default_storage_billing_model: Literal["LOGICAL", "PHYSICAL"] = "LOGICAL"
