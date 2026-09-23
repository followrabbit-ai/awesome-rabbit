"""Pricing resolution precedence and FX fallback."""

from rabbit_assessment.pricing import derive_fx_rate, resolve_pricing


def test_defaults_when_no_config():
    resolved = resolve_pricing(None, {}, ["US"])
    assert resolved["US"].slot_hour_price == 0.06
    assert resolved["US"].ondemand_price == 6.25
    assert resolved["US"].default_storage_billing_model == "LOGICAL"


def test_default_storage_billing_model_cli_override():
    resolved = resolve_pricing(None, {"default_storage_billing_model": "PHYSICAL"}, ["US"])
    assert resolved["US"].default_storage_billing_model == "PHYSICAL"


def test_default_storage_billing_model_from_config(tmp_path):
    config = tmp_path / "pricing.toml"
    config.write_text(
        "[pricing]\ndefault_storage_billing_model = 'PHYSICAL'\n", encoding="utf-8"
    )
    resolved = resolve_pricing(config, {}, ["US"])
    assert resolved["US"].default_storage_billing_model == "PHYSICAL"


def test_cli_override_wins():
    resolved = resolve_pricing(None, {"slot_hour_price": 0.03}, ["US"])
    assert resolved["US"].slot_hour_price == 0.03


def test_env_var_override(monkeypatch):
    monkeypatch.setenv("BQCOST_SLOT_HOUR_PRICE", "0.05")
    resolved = resolve_pricing(None, {}, ["US"])
    assert resolved["US"].slot_hour_price == 0.05


def test_cli_beats_env(monkeypatch):
    monkeypatch.setenv("BQCOST_SLOT_HOUR_PRICE", "0.05")
    resolved = resolve_pricing(None, {"slot_hour_price": 0.02}, ["US"])
    assert resolved["US"].slot_hour_price == 0.02


def test_config_file_and_location_override(tmp_path):
    config = tmp_path / "pricing.toml"
    config.write_text(
        "[pricing]\n"
        "slot_hour_price = 0.04\n"
        "ondemand_price = 5.0\n"
        "\n"
        "[pricing.locations.eu]\n"
        "slot_hour_price = 0.044\n",
        encoding="utf-8",
    )
    resolved = resolve_pricing(config, {}, ["US", "eu"])
    assert resolved["US"].slot_hour_price == 0.04
    assert resolved["US"].ondemand_price == 5.0
    assert resolved["eu"].slot_hour_price == 0.044  # location override applied
    assert resolved["eu"].ondemand_price == 5.0  # falls back to base


def test_fx_rate_usd_is_identity():
    rate = derive_fx_rate("USD")
    assert rate.rate_to_usd == 1.0
    assert rate.currency == "USD"
    assert rate.to_usd(100.0) == 100.0
