"""Application Default Credentials resolution."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import google.auth
from google.auth.exceptions import DefaultCredentialsError

log = logging.getLogger(__name__)

_SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]


@dataclass
class AuthContext:
    """Resolved credentials plus the project that quota/jobs are billed to."""

    credentials: Any
    quota_project: str | None
    principal: str


def resolve_auth(quota_project: str | None) -> AuthContext:
    """Resolve ADC. Exits with guidance if no credentials are available."""
    try:
        credentials, default_project = google.auth.default(scopes=_SCOPES)
    except DefaultCredentialsError as exc:
        raise SystemExit(
            "No Application Default Credentials found.\n"
            "Run:  gcloud auth application-default login"
        ) from exc

    principal = _principal(credentials)
    resolved_quota = (
        quota_project
        or getattr(credentials, "quota_project_id", None)
        or default_project
    )
    log.info("Authenticated as %s (quota project: %s)", principal, resolved_quota)
    return AuthContext(credentials, resolved_quota, principal)


def _principal(credentials: Any) -> str:
    for attr in ("service_account_email", "signer_email", "_account"):
        value = getattr(credentials, attr, None)
        if value:
            return str(value)
    return "user credentials (ADC)"
