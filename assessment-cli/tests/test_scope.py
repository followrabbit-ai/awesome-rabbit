"""Scope-string parsing."""

import pytest

from rabbit_assessment.scope import ScopeError, list_projects, parse_scope


@pytest.mark.parametrize(
    ("scope", "expected"),
    [
        ("project:my-project", ("project", "my-project")),
        ("org:123456789", ("org", "123456789")),
        ("folder:987654321", ("folder", "987654321")),
        ("  project:trimmed  ", ("project", "trimmed")),
    ],
)
def test_parse_scope_valid(scope, expected):
    assert parse_scope(scope) == expected


@pytest.mark.parametrize("scope", ["nocolon", "bogus:123", "project:", ":value", ""])
def test_parse_scope_invalid(scope):
    with pytest.raises(ScopeError):
        parse_scope(scope)


def test_list_projects_project_scope_makes_no_api_call():
    # A 'project:' scope must resolve without touching any API (credentials=None).
    assert list_projects("project:my-project", credentials=None) == ["my-project"]
