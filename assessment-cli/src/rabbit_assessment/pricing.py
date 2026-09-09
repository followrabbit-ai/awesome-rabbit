"""Pricing config resolution and FX-rate derivation.

Costs are computed by the SQL using the resolved prices, which are expressed in
the operator's chosen currency (`--currency`). The report additionally shows
every figure in USD. Since negotiated prices are not reachable by API, the
local->USD rate is *derived* at run time from the Cloud Billing Catalog API by
pricing one BigQuery SKU in both currencies.
"""

from __future__ import annotations

import logging
import os
import tomllib
from dataclasses import dataclass
from pathlib import Path

from .config import PricingConfig
from .models import utc_now

log = logging.getLogger(__name__)

_ENV_PREFIX = "BQCOST_"
_CONFIG_FIELDS = tuple(PricingConfig.model_fields.keys())
# Fields that hold text rather than a numeric price.
_TEXT_FIELDS = frozenset({"default_storage_billing_model"})
_BIGQUERY_SERVICE = "BigQuery"


@dataclass
class FxRate:
    """A local-currency -> USD conversion: usd = local * rate_to_usd."""

    currency: str
    rate_to_usd: float
    source: str
    derived_at: str

    def to_usd(self, amount: float | None) -> float | None:
        if amount is None:
            return None
        return amount * self.rate_to_usd

    def as_dict(self) -> dict[str, object]:
        return {
            "currency": self.currency,
            "rate_to_usd": self.rate_to_usd,
            "source": self.source,
            "derived_at": self.derived_at,
        }


def _env_overrides() -> dict[str, float | str]:
    out: dict[str, float | str] = {}
    for field in _CONFIG_FIELDS:
        raw = os.environ.get(_ENV_PREFIX + field.upper())
        if raw is None:
            continue
        if field in _TEXT_FIELDS:
            out[field] = raw.strip()
        else:
            try:
                out[field] = float(raw)
            except ValueError:
                log.warning("Ignoring non-numeric %s%s=%r", _ENV_PREFIX, field.upper(), raw)
    return out


def resolve_pricing(
    config_path: Path | None,
    cli_overrides: dict[str, float | str | None],
    locations: list[str],
) -> dict[str, PricingConfig]:
    """Resolve per-location pricing and settings.

    Precedence (highest first): CLI flag > env var > config location override >
    config base > built-in default.
    """
    base: dict[str, float | str] = {}
    per_location: dict[str, dict] = {}
    if config_path is not None:
        data = tomllib.loads(config_path.read_text(encoding="utf-8"))
        pricing = dict(data.get("pricing", {}))
        per_location = dict(pricing.pop("locations", {}) or {})
        base = {k: v for k, v in pricing.items() if k in _CONFIG_FIELDS}

    env = _env_overrides()
    cli = {k: v for k, v in cli_overrides.items() if v is not None}

    resolved: dict[str, PricingConfig] = {}
    for loc in locations:
        merged: dict[str, float | str] = dict(base)
        loc_override = per_location.get(loc.lower(), {})
        merged.update({k: v for k, v in loc_override.items() if k in _CONFIG_FIELDS})
        merged.update(env)
        merged.update(cli)
        # pydantic validates/coerces each field; mypy can't see through **kwargs.
        resolved[loc] = PricingConfig(**merged)  # type: ignore[arg-type]
    return resolved


def _sku_price(sku: object) -> float | None:
    """First positive tiered unit price on a Catalog SKU, as a float."""
    for pricing_info in getattr(sku, "pricing_info", []):
        expression = getattr(pricing_info, "pricing_expression", None)
        for tier in getattr(expression, "tiered_rates", []):
            money = getattr(tier, "unit_price", None)
            if money is None:
                continue
            price = float(money.units) + money.nanos / 1e9
            if price > 0:
                return price
    return None


def derive_fx_rate(currency: str) -> FxRate:
    """Derive a local->USD rate from the Cloud Billing Catalog API.

    Falls back to a 1:1 USD identity rate (with a warning) if the currency is
    USD or the Catalog API cannot be reached.
    """
    currency = currency.strip().upper()
    if currency == "USD":
        return FxRate("USD", 1.0, "identity (currency is USD)", utc_now())

    try:
        from google.cloud import billing_v1

        client = billing_v1.CloudCatalogClient()
        service_name = None
        for service in client.list_services():
            if service.display_name == _BIGQUERY_SERVICE:
                service_name = service.name
                break
        if service_name is None:
            raise RuntimeError("BigQuery service not found in the Catalog API")

        usd_prices: dict[str, float] = {}
        for sku in client.list_skus(
            billing_v1.ListSkusRequest(parent=service_name, currency_code="USD")
        ):
            price = _sku_price(sku)
            if price:
                usd_prices[sku.sku_id] = price

        for sku in client.list_skus(
            billing_v1.ListSkusRequest(parent=service_name, currency_code=currency)
        ):
            local_price = _sku_price(sku)
            usd_price = usd_prices.get(sku.sku_id)
            if local_price and usd_price:
                rate = usd_price / local_price
                log.info(
                    "Derived FX rate 1 %s = %.6f USD from SKU %s",
                    currency, rate, sku.sku_id,
                )
                return FxRate(currency, rate, f"BigQuery Catalog SKU {sku.sku_id}", utc_now())
        raise RuntimeError("No SKU priced in both USD and " + currency)
    except Exception as exc:  # noqa: BLE001 - degrade gracefully to USD-only
        summary = str(exc).strip().replace("\n", " ")[:160]
        log.warning(
            "Could not derive an FX rate for %s (%s); report will be USD-only",
            currency, summary,
        )
        return FxRate(currency, 1.0, f"unavailable ({summary}); USD-only fallback", utc_now())
