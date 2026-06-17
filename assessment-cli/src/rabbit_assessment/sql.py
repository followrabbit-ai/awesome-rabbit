"""Load and safely render the bundled SQL templates.

Project ids and locations are substituted directly into table identifiers —
they cannot be passed as bound query parameters — so every substitution value
is validated before rendering. `string.Template` performs no escaping.
"""

from __future__ import annotations

import re
from importlib import resources
from string import Template

# GCP project id rules: 6-30 chars, lowercase letter first, letters/digits/'-',
# must not end with '-'.
_PROJECT_ID_RE = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")
# BigQuery locations: multi-region (us, eu) or regional (e.g. us-central1).
_LOCATION_RE = re.compile(r"^(us|eu|[a-z]{2,}-[a-z]+\d+)$")

_TEMPLATE_PACKAGE = "rabbit_assessment.sql_templates"
_TEMPLATE_CACHE: dict[str, str] = {}


class SqlRenderError(ValueError):
    """Raised when a template or a substitution value is invalid."""


def load_template(name: str) -> str:
    """Return the raw text of a bundled SQL template."""
    if name not in _TEMPLATE_CACHE:
        try:
            # resources.files() requires Python 3.9+; this package targets
            # Python >=3.11 (see pyproject.toml), so the 3.7-compat rule is a
            # false positive here.
            text = (
                resources.files(_TEMPLATE_PACKAGE)  # nosemgrep: python.lang.compatibility.python37.python37-compatibility-importlib2
                .joinpath(name)
                .read_text(encoding="utf-8")
            )
        except (FileNotFoundError, ModuleNotFoundError) as exc:
            raise SqlRenderError(f"Unknown SQL template: {name}") from exc
        _TEMPLATE_CACHE[name] = text
    return _TEMPLATE_CACHE[name]


def normalize_location(location: str) -> str:
    """Lower-case and validate a BigQuery location (e.g. 'US' -> 'us')."""
    norm = location.strip().lower()
    if not _LOCATION_RE.match(norm):
        raise SqlRenderError(f"Invalid BigQuery location: {location!r}")
    return norm


def validate_project_id(project_id: str) -> str:
    """Validate a GCP project id, returning it unchanged when valid."""
    if not _PROJECT_ID_RE.match(project_id):
        raise SqlRenderError(f"Invalid GCP project id: {project_id!r}")
    return project_id


def _format_number(key: str, value: object) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SqlRenderError(f"Parameter {key!r} must be numeric, got {value!r}")
    if isinstance(value, int):
        return str(value)
    return repr(float(value))


def render(
    name: str,
    *,
    project_id: str,
    location: str,
    numbers: dict[str, float | int] | None = None,
) -> str:
    """Render template `name`. Identifiers are validated; numbers are coerced.

    Raises SqlRenderError on any invalid input.
    """
    substitutions: dict[str, str] = {
        "project_id": validate_project_id(project_id),
        "region": normalize_location(location),
    }
    for key, value in (numbers or {}).items():
        substitutions[key] = _format_number(key, value)

    template = Template(load_template(name))
    try:
        return template.substitute(substitutions)
    except KeyError as exc:
        raise SqlRenderError(f"Template {name} is missing parameter {exc}") from exc
    except ValueError as exc:
        raise SqlRenderError(f"Template {name} is malformed: {exc}") from exc
