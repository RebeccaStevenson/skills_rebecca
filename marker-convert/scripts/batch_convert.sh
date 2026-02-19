#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  batch_convert.sh --input <pdf_folder> [options]

Compatibility wrapper that always runs:
  marker_convert.sh --mode batch ...

Examples:
  batch_convert.sh --input /tmp/pdfs --output /tmp/out --format markdown
  batch_convert.sh --input /tmp/pdfs -- --workers 2
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_WRAPPER="${SCRIPT_DIR}/marker_convert.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

exec bash "${MARKER_WRAPPER}" --mode batch "$@"
