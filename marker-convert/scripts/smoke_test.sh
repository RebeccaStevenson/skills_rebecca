#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  smoke_test.sh --pdf <path/to/sample.pdf> [--workdir /tmp/marker_smoke]

Runs lightweight checks:
1) single conversion (no LLM)
2) directory conversion continues after one bad PDF
3) resume behavior skips already processed PDFs
4) LLM missing-key fail-fast
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_WRAPPER="${SCRIPT_DIR}/marker_convert.sh"

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

echo "[1/4] Single conversion"
SINGLE_OUT="${WORKDIR}/single_out"
mkdir -p "${SINGLE_OUT}"
bash "${MARKER_WRAPPER}" \
  --input "${PDF_PATH}" \
  --output "${SINGLE_OUT}" \
  --page-range 0 \
  --disable-multiprocessing

SINGLE_MD_COUNT="$(find "${SINGLE_OUT}" -type f -name '*.md' | wc -l | tr -d ' ')"
if [[ "${SINGLE_MD_COUNT}" -lt 1 ]]; then
  echo "Error: single conversion produced no markdown files." >&2
  exit 1
fi

echo "[2/4] Directory conversion with one invalid PDF (continue on errors)"
SEQ_INPUT="${WORKDIR}/seq_input"
SEQ_OUT="${WORKDIR}/seq_out"
mkdir -p "${SEQ_INPUT}" "${SEQ_OUT}"
cp "${PDF_PATH}" "${SEQ_INPUT}/valid.pdf"
printf 'not a real pdf\n' > "${SEQ_INPUT}/invalid.pdf"

bash "${MARKER_WRAPPER}" \
  --input "${SEQ_INPUT}" \
  --output "${SEQ_OUT}" \
  --page-range 0 \
  --disable-multiprocessing

STATE_DIR="${SEQ_OUT}/state"
for required_file in processed_files.txt failed_conversions.txt conversion_log.txt error_details.txt; do
  if [[ ! -f "${STATE_DIR}/${required_file}" ]]; then
    echo "Error: missing state file: ${STATE_DIR}/${required_file}" >&2
    exit 1
  fi
done

if ! rg -q "valid.pdf" "${STATE_DIR}/processed_files.txt"; then
  echo "Error: valid PDF was not recorded as processed." >&2
  exit 1
fi
if ! rg -q "invalid.pdf" "${STATE_DIR}/failed_conversions.txt"; then
  echo "Error: invalid PDF failure was not recorded." >&2
  exit 1
fi

echo "[3/4] Resume behavior"
bash "${MARKER_WRAPPER}" \
  --input "${SEQ_INPUT}" \
  --output "${SEQ_OUT}" \
  --page-range 0 \
  --disable-multiprocessing

if ! rg -q "SKIPPED \(already processed\): .*valid.pdf" "${STATE_DIR}/conversion_log.txt"; then
  echo "Error: expected resume skip entry for valid.pdf in conversion_log.txt." >&2
  exit 1
fi

echo "[4/4] LLM missing-key guard"
LLM_ERR_FILE="${WORKDIR}/llm_missing_key.err"
set +e
env -u CLAUDE_API_KEY -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GOOGLE_API_KEY \
  bash "${MARKER_WRAPPER}" \
    --no-settings \
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

echo "Smoke test passed."
echo "Artifacts: ${WORKDIR}"
