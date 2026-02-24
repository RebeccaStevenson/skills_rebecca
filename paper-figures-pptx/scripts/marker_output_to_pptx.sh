#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  marker_output_to_pptx.sh [--marker-output <path>] [options]

Generate PowerPoint deck(s) from Marker conversion output.
If --pdf-input is provided, this wrapper runs marker_single conversion first.

Options:
  --marker-output <path>         Marker output directory
  --pdf-input <path>             Input PDF file/folder for conversion pre-step
  --paper <name-or-path>         Paper folder path, exact folder name, or partial match
  --all                          Generate decks for all detected paper folders
  --output, -o <path>            Output .pptx path (single paper only)
  --output-dir <path>            Output directory for generated decks
  --marker-bin <path>            marker_single binary (default: marker_single)
  --marker-timeout <seconds>     Per-PDF conversion timeout (default: 1000, 0 disables)
  --marker-state-dir <path>      Conversion state/log directory (default: <output>/state)
  --marker-force                 Reprocess PDFs already listed in processed_files.txt
  --marker-fail-fast             Stop conversion on first conversion failure
  --marker-use-llm               Pass --use_llm to marker_single
  --marker-service-timeout <s>   Pass --timeout to marker_single when using LLM
  --marker-extra-arg <arg>       Extra marker_single arg (repeatable)
  --experimental-figure-captions Include extracted figure captions on figure slides (experimental)
  --with-captions                Alias for --experimental-figure-captions
  --skip-tables                  Omit table slides
  --skip-equations               Omit equation slides
  --python <python-bin>          Python executable (default: python in conda, else python3)
  -h, --help                     Show this help

Examples:
  # Existing marker output
  marker_output_to_pptx.sh \
    --marker-output /tmp/marker_out \
    --output /tmp/paper_figures.pptx

  # Raw PDFs -> convert -> generate all decks
  marker_output_to_pptx.sh \
    --pdf-input /tmp/pdfs \
    --marker-output /tmp/marker_out \
    --all \
    --output-dir /tmp/pptx_out
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PPTX_SCRIPT="${SCRIPT_DIR}/generate_paper_pptx.py"

MARKER_OUTPUT=""
PDF_INPUT=""
PAPER_SELECTOR=""
CONVERT_ALL=false
OUTPUT_FILE=""
OUTPUT_DIR=""
MARKER_SINGLE_BIN="${MARKER_SINGLE_BIN:-marker_single}"
MARKER_TIMEOUT=1000
MARKER_STATE_DIR=""
MARKER_FORCE=false
MARKER_FAIL_FAST=false
MARKER_USE_LLM=false
MARKER_SERVICE_TIMEOUT=""
MARKER_EXTRA_ARGS=()
EXPERIMENTAL_FIGURE_CAPTIONS=false
SKIP_TABLES=false
SKIP_EQUATIONS=false
if [[ -n "${CONDA_PREFIX:-}" ]] && command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  PYTHON_BIN="python3"
fi

CANDIDATES=()
SELECTED=()
PDF_FILES=()

PROCESSED_LIST=""
FAILED_LOG=""
FAILED_ARCHIVE=""
CONVERSION_LOG=""
ERROR_LOG=""

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

find_primary_md() {
  local folder="$1"
  find "${folder}" -maxdepth 1 -type f -name '*.md' \
    ! -name '*_citation.md' ! -name '*_no_refs.md' -print -quit
}

collect_candidates() {
  local root="$1"
  local subdir=""

  CANDIDATES=()

  if [[ -n "$(find_primary_md "${root}" || true)" ]]; then
    CANDIDATES+=("${root}")
  fi

  while IFS= read -r subdir; do
    if [[ -n "$(find_primary_md "${subdir}" || true)" ]]; then
      CANDIDATES+=("${subdir}")
    fi
  done < <(find "${root}" -mindepth 1 -maxdepth 1 -type d | sort)
}

print_candidates() {
  local c=""
  for c in "${CANDIDATES[@]}"; do
    printf '  - %s\n' "${c}"
  done
}

resolve_selector() {
  local selector="$1"
  local root="$2"
  local c=""
  local selector_lc=""
  local base_lc=""
  local root_candidate="${root}/${selector}"
  local matches=()

  if [[ -d "${selector}" && -n "$(find_primary_md "${selector}" || true)" ]]; then
    SELECTED=("${selector}")
    return 0
  fi

  if [[ -d "${root_candidate}" && -n "$(find_primary_md "${root_candidate}" || true)" ]]; then
    SELECTED=("${root_candidate}")
    return 0
  fi

  selector_lc="$(to_lower "${selector}")"
  for c in "${CANDIDATES[@]}"; do
    base_lc="$(to_lower "$(basename "${c}")")"
    if [[ "${base_lc}" == *"${selector_lc}"* ]]; then
      matches+=("${c}")
    fi
  done

  if [[ ${#matches[@]} -eq 1 ]]; then
    SELECTED=("${matches[0]}")
    return 0
  fi
  if [[ ${#matches[@]} -gt 1 ]]; then
    echo "Error: --paper selector matched multiple folders." >&2
    for c in "${matches[@]}"; do
      printf '  - %s\n' "${c}" >&2
    done
    echo "Use a more specific --paper value or pass a full folder path." >&2
    exit 1
  fi

  echo "Error: --paper did not match any Marker-converted paper folder: ${selector}" >&2
  exit 1
}

run_with_timeout() {
  local timeout_s="$1"
  shift

  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${timeout_s}" "$@"
    return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_s}" "$@"
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${timeout_s}" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
cmd = sys.argv[2:]

try:
    result = subprocess.run(cmd, timeout=timeout_seconds, check=False)
    raise SystemExit(result.returncode)
except subprocess.TimeoutExpired:
    print(f"Command timed out after {timeout_seconds} seconds", file=sys.stderr)
    raise SystemExit(124)
PY
    return $?
  fi

  echo "Error: timeout requested but no timeout utility is available." >&2
  return 1
}

append_unique_line() {
  local file="$1"
  local value="$2"

  if ! grep -F -x -q -- "${value}" "${file}"; then
    printf '%s\n' "${value}" >> "${file}"
  fi
}

collect_pdf_inputs() {
  local file=""
  PDF_FILES=()

  if [[ -f "${PDF_INPUT}" ]]; then
    PDF_FILES=("${PDF_INPUT}")
    return
  fi

  while IFS= read -r file; do
    PDF_FILES+=("${file}")
  done < <(find "${PDF_INPUT}" -type f -iname '*.pdf' | sort)

  if [[ ${#PDF_FILES[@]} -eq 0 ]]; then
    echo "Error: no PDF files found under --pdf-input: ${PDF_INPUT}" >&2
    exit 1
  fi
}

prepare_conversion_state() {
  local session_started=""
  mkdir -p "${MARKER_OUTPUT}" "${MARKER_STATE_DIR}"

  PROCESSED_LIST="${MARKER_STATE_DIR}/processed_files.txt"
  FAILED_LOG="${MARKER_STATE_DIR}/failed_conversions.txt"
  FAILED_ARCHIVE="${MARKER_STATE_DIR}/failed_conversions_archive.txt"
  CONVERSION_LOG="${MARKER_STATE_DIR}/conversion_log.txt"
  ERROR_LOG="${MARKER_STATE_DIR}/error_details.txt"

  touch "${PROCESSED_LIST}" "${FAILED_LOG}" "${FAILED_ARCHIVE}" "${CONVERSION_LOG}" "${ERROR_LOG}"

  if [[ -s "${FAILED_LOG}" ]]; then
    {
      printf '\n=== Archived at %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
      cat "${FAILED_LOG}"
    } >> "${FAILED_ARCHIVE}"
    : > "${FAILED_LOG}"
  fi

  session_started="$(date '+%Y-%m-%d %H:%M:%S')"
  {
    printf '\n=== Conversion session started at %s ===\n' "${session_started}"
    printf 'Input: %s\n' "${PDF_INPUT}"
    printf 'Output: %s\n' "${MARKER_OUTPUT}"
    printf 'State dir: %s\n\n' "${MARKER_STATE_DIR}"
  } >> "${CONVERSION_LOG}"
}

run_marker_conversion_if_requested() {
  local marker_base_args=()
  local cmd=()
  local pdf_path=""
  local total=0
  local current=0
  local succeeded=0
  local failed=0
  local skipped=0
  local final_exit=0
  local exit_code=0
  local temp_error_file=""
  local fail_ts=""

  if [[ -z "${PDF_INPUT}" ]]; then
    return
  fi

  if ! command -v "${MARKER_SINGLE_BIN}" >/dev/null 2>&1; then
    echo "Error: marker_single command not found: ${MARKER_SINGLE_BIN}" >&2
    exit 1
  fi

  collect_pdf_inputs
  prepare_conversion_state

  marker_base_args=(--output_dir "${MARKER_OUTPUT}" --output_format markdown)
  if [[ "${MARKER_USE_LLM}" == true ]]; then
    marker_base_args+=(--use_llm)
    if [[ -n "${MARKER_SERVICE_TIMEOUT}" ]]; then
      marker_base_args+=(--timeout "${MARKER_SERVICE_TIMEOUT}")
    fi
  fi
  if [[ ${#MARKER_EXTRA_ARGS[@]} -gt 0 ]]; then
    marker_base_args+=("${MARKER_EXTRA_ARGS[@]}")
  fi

  total="${#PDF_FILES[@]}"
  printf 'Found %s PDF(s) for conversion.\n' "${total}"
  printf 'Output directory: %s\n' "${MARKER_OUTPUT}"
  printf 'State directory: %s\n\n' "${MARKER_STATE_DIR}"

  for pdf_path in "${PDF_FILES[@]}"; do
    current=$((current + 1))

    if [[ "${MARKER_FORCE}" != true ]] && grep -F -x -q -- "${pdf_path}" "${PROCESSED_LIST}"; then
      printf '[%s/%s] Skipped (already processed): %s\n' "${current}" "${total}" "${pdf_path}"
      printf 'SKIPPED (already processed): %s\n' "${pdf_path}" >> "${CONVERSION_LOG}"
      skipped=$((skipped + 1))
      continue
    fi

    cmd=("${MARKER_SINGLE_BIN}" "${pdf_path}" "${marker_base_args[@]}")
    temp_error_file="$(mktemp "${MARKER_STATE_DIR}/marker_error.XXXXXX")"
    printf '[%s/%s] Converting: %s\n' "${current}" "${total}" "${pdf_path}"

    set +e
    if [[ "${MARKER_TIMEOUT}" -gt 0 ]]; then
      run_with_timeout "${MARKER_TIMEOUT}" "${cmd[@]}" > "${temp_error_file}" 2>&1
      exit_code=$?
    else
      "${cmd[@]}" > "${temp_error_file}" 2>&1
      exit_code=$?
    fi
    set -e

    if [[ "${exit_code}" -eq 0 ]]; then
      append_unique_line "${PROCESSED_LIST}" "${pdf_path}"
      printf 'SUCCESS: %s\n' "${pdf_path}" >> "${CONVERSION_LOG}"
      rm -f "${temp_error_file}"
      succeeded=$((succeeded + 1))
      printf '  OK\n'
      continue
    fi

    failed=$((failed + 1))
    fail_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "${exit_code}" -eq 124 ]]; then
      printf '[%s] TIMEOUT: %s\n' "${fail_ts}" "${pdf_path}" >> "${FAILED_LOG}"
      printf 'TIMEOUT: %s\n' "${pdf_path}" >> "${CONVERSION_LOG}"
    else
      printf '[%s] FAILED (exit code %s): %s\n' "${fail_ts}" "${exit_code}" "${pdf_path}" >> "${FAILED_LOG}"
      printf 'FAILED (exit code %s): %s\n' "${exit_code}" "${pdf_path}" >> "${CONVERSION_LOG}"
    fi
    {
      printf '=== Error for: %s (%s) ===\n' "${pdf_path}" "${fail_ts}"
      cat "${temp_error_file}"
      printf '\n'
    } >> "${ERROR_LOG}"
    rm -f "${temp_error_file}"
    printf '  FAILED (exit code %s)\n' "${exit_code}"

    if [[ "${MARKER_FAIL_FAST}" == true ]]; then
      final_exit=1
      break
    fi
  done

  {
    printf '\nSession completed at %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Attempted: %s\n' "${current}"
    printf 'Succeeded: %s\n' "${succeeded}"
    printf 'Failed: %s\n' "${failed}"
    printf 'Skipped: %s\n' "${skipped}"
  } >> "${CONVERSION_LOG}"

  {
    printf '\n--- Session %s ---\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Attempted: %s | Succeeded: %s | Failed: %s | Skipped: %s\n' "${current}" "${succeeded}" "${failed}" "${skipped}"
  } >> "${FAILED_LOG}"

  printf '\n=== Conversion Session Complete ===\n'
  printf 'Attempted: %s\n' "${current}"
  printf 'Succeeded: %s\n' "${succeeded}"
  printf 'Failed: %s\n' "${failed}"
  printf 'Skipped: %s\n' "${skipped}"
  printf 'Conversion log: %s\n' "${CONVERSION_LOG}"
  printf 'Failed log: %s\n' "${FAILED_LOG}"
  printf 'Error details: %s\n' "${ERROR_LOG}"
  printf 'Processed list: %s\n\n' "${PROCESSED_LIST}"

  if [[ "${final_exit}" -ne 0 ]]; then
    exit "${final_exit}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --marker-output)
      MARKER_OUTPUT="${2:-}"
      shift 2
      ;;
    --pdf-input)
      PDF_INPUT="${2:-}"
      shift 2
      ;;
    --paper)
      PAPER_SELECTOR="${2:-}"
      shift 2
      ;;
    --all)
      CONVERT_ALL=true
      shift
      ;;
    --output|-o)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --marker-bin)
      MARKER_SINGLE_BIN="${2:-}"
      shift 2
      ;;
    --marker-timeout)
      MARKER_TIMEOUT="${2:-}"
      shift 2
      ;;
    --marker-state-dir)
      MARKER_STATE_DIR="${2:-}"
      shift 2
      ;;
    --marker-force)
      MARKER_FORCE=true
      shift
      ;;
    --marker-fail-fast)
      MARKER_FAIL_FAST=true
      shift
      ;;
    --marker-use-llm)
      MARKER_USE_LLM=true
      shift
      ;;
    --marker-service-timeout)
      MARKER_SERVICE_TIMEOUT="${2:-}"
      shift 2
      ;;
    --marker-extra-arg)
      MARKER_EXTRA_ARGS+=("${2:-}")
      shift 2
      ;;
    --experimental-figure-captions|--with-captions)
      EXPERIMENTAL_FIGURE_CAPTIONS=true
      shift
      ;;
    --skip-tables)
      SKIP_TABLES=true
      shift
      ;;
    --skip-equations)
      SKIP_EQUATIONS=true
      shift
      ;;
    --python)
      PYTHON_BIN="${2:-}"
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

if [[ -z "${MARKER_OUTPUT}" ]]; then
  if [[ -n "${PDF_INPUT}" ]]; then
    MARKER_OUTPUT="$(pwd)/marker_output"
    echo "No --marker-output provided. Using default: ${MARKER_OUTPUT}"
  else
    echo "Error: --marker-output is required when --pdf-input is not provided." >&2
    usage
    exit 1
  fi
fi
if [[ -n "${PAPER_SELECTOR}" && "${CONVERT_ALL}" == true ]]; then
  echo "Error: --paper and --all cannot be used together." >&2
  exit 1
fi
if [[ -n "${OUTPUT_FILE}" && -n "${OUTPUT_DIR}" ]]; then
  echo "Error: --output and --output-dir cannot be used together." >&2
  exit 1
fi
if ! [[ "${MARKER_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  echo "Error: --marker-timeout must be a non-negative integer." >&2
  exit 1
fi
if [[ -n "${MARKER_SERVICE_TIMEOUT}" ]] && ! [[ "${MARKER_SERVICE_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  echo "Error: --marker-service-timeout must be a non-negative integer." >&2
  exit 1
fi
if [[ -n "${PDF_INPUT}" && ! -f "${PDF_INPUT}" && ! -d "${PDF_INPUT}" ]]; then
  echo "Error: --pdf-input must be an existing file or directory: ${PDF_INPUT}" >&2
  exit 1
fi
if [[ ! -f "${PPTX_SCRIPT}" ]]; then
  echo "Error: generator script not found: ${PPTX_SCRIPT}" >&2
  exit 1
fi

if [[ -z "${MARKER_STATE_DIR}" ]]; then
  MARKER_STATE_DIR="${MARKER_OUTPUT}/state"
fi

run_marker_conversion_if_requested

if [[ ! -d "${MARKER_OUTPUT}" ]]; then
  echo "Error: marker output directory not found: ${MARKER_OUTPUT}" >&2
  exit 1
fi
if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "Error: python executable not found: ${PYTHON_BIN}" >&2
  exit 1
fi
if ! "${PYTHON_BIN}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
  echo "Error: Python 3.10+ is required by generate_paper_pptx.py (selected: ${PYTHON_BIN})." >&2
  exit 1
fi

collect_candidates "${MARKER_OUTPUT}"
if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "Error: no Marker-converted paper folders found under ${MARKER_OUTPUT}" >&2
  exit 1
fi

if [[ -n "${OUTPUT_FILE}" && "${CONVERT_ALL}" == true ]]; then
  echo "Error: --output cannot be used with --all." >&2
  exit 1
fi

if [[ -n "${PAPER_SELECTOR}" ]]; then
  resolve_selector "${PAPER_SELECTOR}" "${MARKER_OUTPUT}"
elif [[ "${CONVERT_ALL}" == true ]]; then
  SELECTED=("${CANDIDATES[@]}")
elif [[ ${#CANDIDATES[@]} -eq 1 ]]; then
  SELECTED=("${CANDIDATES[0]}")
else
  echo "Error: multiple paper folders found. Use --paper <name-or-path> or --all." >&2
  print_candidates >&2
  exit 1
fi

if [[ ${#SELECTED[@]} -gt 1 && -n "${OUTPUT_FILE}" ]]; then
  echo "Error: --output is only valid when one paper is selected." >&2
  exit 1
fi

if [[ -n "${OUTPUT_DIR}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
fi

echo "Detected ${#SELECTED[@]} paper folder(s)."

for paper_folder in "${SELECTED[@]}"; do
  cmd=("${PYTHON_BIN}" "${PPTX_SCRIPT}" "${paper_folder}")

  if [[ -n "${OUTPUT_FILE}" ]]; then
    cmd+=(--output "${OUTPUT_FILE}")
  elif [[ -n "${OUTPUT_DIR}" ]]; then
    cmd+=(--output "${OUTPUT_DIR}/$(basename "${paper_folder}")_figures.pptx")
  fi

  if [[ "${SKIP_TABLES}" == true ]]; then
    cmd+=(--skip-tables)
  fi
  if [[ "${SKIP_EQUATIONS}" == true ]]; then
    cmd+=(--skip-equations)
  fi
  if [[ "${EXPERIMENTAL_FIGURE_CAPTIONS}" == true ]]; then
    cmd+=(--experimental-figure-captions)
  fi

  echo "Generating PPTX for: ${paper_folder}"
  "${cmd[@]}"
done

echo "Done."
