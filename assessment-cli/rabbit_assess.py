#!/usr/bin/env python3
"""Launcher for rabbit-assess.

Lets the tool run straight from a `pip install -r requirements.txt` with no
editable install and no build backend (poetry/uv/hatchling not required).

Usage:
    python rabbit_assess.py run --scope project:my-project --location US
"""

import sys
from pathlib import Path

# Put the src/ layout on the import path so `rabbit_assessment` resolves
# without the package being installed.
sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from rabbit_assessment.cli import app  # noqa: E402

if __name__ == "__main__":
    app()
