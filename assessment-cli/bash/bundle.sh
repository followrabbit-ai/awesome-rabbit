#!/usr/bin/env bash
#
# bundle.sh - pack the Bash assessment tool + its SQL templates into a single
# tarball, for shipping to a host that cannot clone this repo.
#
# The SQL templates live with the Python tool (single source of truth); this
# copies them next to the script so the bundle is self-contained. rabbit-assess.sh
# prefers a co-located sql_templates/ directory when present.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_SRC="$SCRIPT_DIR/../src/rabbit_assessment/sql_templates"
DIST="${1:-$SCRIPT_DIR/dist}"
STAGE="$DIST/rabbit-assess-bash"

[ -d "$SQL_SRC" ] || { echo "bundle: SQL templates not found at $SQL_SRC" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/sql_templates"
cp "$SCRIPT_DIR/rabbit-assess.sh" "$STAGE/"
[ -f "$SCRIPT_DIR/README.md" ] && cp "$SCRIPT_DIR/README.md" "$STAGE/"
cp "$SQL_SRC"/*.sql "$STAGE/sql_templates/"
chmod +x "$STAGE/rabbit-assess.sh"

TARBALL="$DIST/rabbit-assess-bash.tar.gz"
tar -czf "$TARBALL" -C "$DIST" rabbit-assess-bash

echo "Created: $TARBALL"
echo
echo "On the target host:"
echo "  tar -xzf rabbit-assess-bash.tar.gz"
echo "  cd rabbit-assess-bash"
echo "  ./rabbit-assess.sh --scope folder:<id> --location US"
