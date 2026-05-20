"""Resolve an org / folder / project scope to a list of project ids."""

from __future__ import annotations

import logging
from typing import Any

log = logging.getLogger(__name__)

_VALID_KINDS = ("org", "folder", "project")


class ScopeError(ValueError):
    """Raised when the --scope string is malformed."""


def parse_scope(scope: str) -> tuple[str, str]:
    """'project:foo' -> ('project', 'foo'). Validates the prefix and id."""
    if ":" not in scope:
        raise ScopeError("Scope must be 'org:<id>', 'folder:<id>' or 'project:<id>'")
    kind, _, value = scope.partition(":")
    kind = kind.strip().lower()
    value = value.strip()
    if kind not in _VALID_KINDS or not value:
        raise ScopeError(f"Unsupported scope {scope!r}; expected one of {_VALID_KINDS}")
    return kind, value


def list_projects(scope: str, credentials: Any) -> list[str]:
    """Enumerate active project ids visible to the caller under `scope`.

    A 'project:' scope makes no API call. For 'org:'/'folder:' the resource
    hierarchy is walked breadth-first; a parent the caller cannot read is
    logged and skipped so enumeration always returns partial results rather
    than failing.
    """
    kind, value = parse_scope(scope)
    if kind == "project":
        return [value]

    from google.cloud import resourcemanager_v3

    projects_client = resourcemanager_v3.ProjectsClient(credentials=credentials)
    folders_client = resourcemanager_v3.FoldersClient(credentials=credentials)

    root = f"organizations/{value}" if kind == "org" else f"folders/{value}"
    found: set[str] = set()
    seen: set[str] = set()
    queue: list[str] = [root]

    while queue:
        parent = queue.pop()
        if parent in seen:
            continue
        seen.add(parent)
        try:
            for project in projects_client.search_projects(query=f"parent:{parent}"):
                if project.state.name == "ACTIVE":
                    found.add(project.project_id)
        except Exception as exc:  # noqa: BLE001 - skip unreadable parents
            log.warning("Cannot list projects under %s: %s", parent, exc)
        try:
            for folder in folders_client.list_folders(parent=parent):
                if folder.state.name == "ACTIVE":
                    queue.append(folder.name)
        except Exception as exc:  # noqa: BLE001 - skip unreadable folders
            log.warning("Cannot list sub-folders under %s: %s", parent, exc)

    return sorted(found)
