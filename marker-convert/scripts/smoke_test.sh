#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  smoke_test.sh --pdf <path/to/sample.pdf> [--workdir /tmp/marker_smoke]

Runs lightweight checks:
1) single conversion (no LLM)
2) LLM missing-key fail-fast
3) batch conversion
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_WRAPPER="${SCRIPT_DIR}/marker_convert.sh"
BATCH_WRAPPER="${SCRIPT_DIR}/batch_convert.sh"

PDF_PATH=""
WORKDIR="/tmp/marker_convert_smoke_$$"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pdf)
      PDF_PATH="${2:-}"
      shift 2
      ;;
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${PDF_PATH}" ]]; then
  echo "Error: --pdf is required." >&2
  usage
  exit 1
fi
if [[ ! -f "${PDF_PATH}" ]]; then
  echo "Error: sample PDF not found: ${PDF_PATH}" >&2
  exit 1
fi

mkdir -p "${WORKDIR}"

echo "[1/3] Single conversion"
SINGLE_OUT="${WORKDIR}/single_out"
mkdir -p "${SINGLE_OUT}"
bash "${MARKER_WRAPPER}" \
  --mode single \
  --input "${PDF_PATH}" \
  --output "${SINGLE_OUT}" \
  --page-range 0 \
  --disable-multiprocessing

SINGLE_MD_COUNT="$(find "${SINGLE_OUT}" -type f -name '*.md' | wc -l | tr -d ' ')"
if [[ "${SINGLE_MD_COUNT}" -lt 1 ]]; then
  echo "Error: single conversion produced no markdown files." >&2
  exit 1
fi

echo "[2/3] LLM missing-key guard"
LLM_ERR_FILE="${WORKDIR}/llm_missing_key.err"
set +e
env -u CLAUDE_API_KEY -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GOOGLE_API_KEY \
  bash "${MARKER_WRAPPER}" \
    --no-settings \
    --mode single \
    --input "${PDF_PATH}" \
    --output "${WORKDIR}/llm_missing_key_out" \
    --page-range 0 \
    --disable-multiprocessing \
    --use-llm \
    --llm-service marker.services.claude.ClaudeService \
    > /dev/null 2> "${LLM_ERR_FILE}"
LLM_EXIT=$?
set -e

if [[ "${LLM_EXIT}" -eq 0 ]]; then
  echo "Error: expected missing-key check to fail, but command succeeded." >&2
  exit 1
fi
if ! rg -q "API key" "${LLM_ERR_FILE}"; then
  echo "Error: missing-key failure did not include expected API key guidance." >&2
  cat "${LLM_ERR_FILE}" >&2
  exit 1
fi

echo "[3/3] Batch conversion"
BATCH_INPUT="${WORKDIR}/batch_input"
BATCH_OUT="${WORKDIR}/batch_out"
mkdir -p "${BATCH_INPUT}" "${BATCH_OUT}"
cp "${PDF_PATH}" "${BATCH_INPUT}/sample.pdf"
bash "${BATCH_WRAPPER}" \
  --input "${BATCH_INPUT}" \
  --output "${BATCH_OUT}" \
  --page-range 0 \
  --disable-multiprocessing

BATCH_MD_COUNT="$(find "${BATCH_OUT}" -type f -name '*.md' | wc -l | tr -d ' ')"
if [[ "${BATCH_MD_COUNT}" -lt 1 ]]; then
  echo "Error: batch conversion produced no markdown files." >&2
  exit 1
fi

echo "Smoke test passed."
echo "Artifacts: ${WORKDIR}"
