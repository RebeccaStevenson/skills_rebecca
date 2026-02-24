#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SETTINGS_FILE="${SCRIPT_DIR}/../config/marker_convert.env"

usage() {
  cat <<'USAGE'
Usage:
  marker_convert.sh --input <path> [--output <path>] [options]

Sequential conversion only. Each PDF is processed individually with marker_single.

Options:
  --input <path>                     Input PDF file or input folder (required)
  --output <path>                    Output folder (default: ./marker_output)
  --format <markdown|json|html>      Output format (default: markdown)
  --page-range <range>               Example: 0,5-10,20
  --config-json <path>               Marker config JSON
  --disable-image-extraction         Disable extracted images
  --disable-multiprocessing          Disable multiprocessing
  --timeout <seconds>                Per-PDF wrapper timeout (0 disables)
  --state-dir <path>                 State/log directory (default: <output>/state)
  --force                            Reprocess PDFs already listed in processed_files.txt
  --fail-fast                        Stop on first conversion failure
  --use-llm                          Enable Marker --use_llm
  --llm-service <import.path.Class>  Marker --llm_service value
  --model-name <name>                Marker --model_name value
  --service-timeout <seconds>        Marker service timeout via --timeout
  --claude-model-name <name>         Marker --claude_model_name
  --gemini-model-name <name>         Marker --gemini_model_name
  --settings <path>                  Load settings file (default shown below)
  --no-settings                      Do not load any settings file
  -h, --help                         Show this help
  --                                 Pass remaining args to marker_single

Default settings file:
  ../config/marker_convert.env (relative to this script)

Examples:
  marker_convert.sh --input /tmp/paper.pdf --output /tmp/out --format markdown
  marker_convert.sh --input /tmp/pdfs --output /tmp/out --timeout 300
USAGE
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_true() {
  case "$(to_lower "${1:-}")" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

check_file_readable_regular() {
  local file="$1"
  local label="$2"

  if [[ ! -e "${file}" ]]; then
    echo "Error: ${label} not found: ${file}" >&2
    exit 1
  fi
  if [[ ! -f "${file}" ]]; then
    echo "Error: ${label} must be a regular file: ${file}" >&2
    exit 1
  fi
  if [[ ! -r "${file}" ]]; then
    echo "Error: ${label} is not readable: ${file}" >&2
    exit 1
  fi
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

init_defaults() {
  INPUT_PATH=""
  OUTPUT_PATH=""
  OUTPUT_FORMAT="markdown"
  PAGE_RANGE=""
  CONFIG_JSON=""
  DISABLE_IMAGE_EXTRACTION=false
  DISABLE_MULTIPROCESSING=false

  MARKER_TIMEOUT=0
  STATE_DIR=""
  FORCE=false
  FAIL_FAST=false

  USE_LLM=false
  LLM_SERVICE=""
  MODEL_NAME=""
  SERVICE_TIMEOUT=""
  CLAUDE_MODEL_NAME=""
  GEMINI_MODEL_NAME=""
  CLAUDE_API_KEY="${CLAUDE_API_KEY:-${ANTHROPIC_API_KEY:-}}"
  OPENAI_API_KEY="${OPENAI_API_KEY:-}"
  GOOGLE_API_KEY="${GOOGLE_API_KEY:-}"

  SETTINGS_FILE="${DEFAULT_SETTINGS_FILE}"
  USE_SETTINGS=true
  SETTINGS_EXPLICIT=false
  EXTRA_ARGS=()

  PDF_FILES=()
  MARKER_BASE_ARGS=()

  PROCESSED_LIST=""
  FAILED_LOG=""
  FAILED_ARCHIVE=""
  CONVERSION_LOG=""
  ERROR_LOG=""
  SESSION_STARTED=""
}

parse_settings_file() {
  local file="$1"
  local raw_line=""
  local line=""
  local key=""
  local value=""

  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line="$(trim "${raw_line}")"
    [[ -z "${line}" ]] && continue
    [[ "${line}" == \#* ]] && continue
    [[ "${line}" != *=* ]] && continue

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    [[ -z "${key}" ]] && continue

    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi

    case "${key}" in
      OUTPUT_FORMAT) OUTPUT_FORMAT="${value}" ;;
      PAGE_RANGE) PAGE_RANGE="${value}" ;;
      CONFIG_JSON) CONFIG_JSON="${value}" ;;
      DISABLE_IMAGE_EXTRACTION) DISABLE_IMAGE_EXTRACTION="${value}" ;;
      DISABLE_MULTIPROCESSING) DISABLE_MULTIPROCESSING="${value}" ;;
      MARKER_TIMEOUT) MARKER_TIMEOUT="${value}" ;;
      STATE_DIR) STATE_DIR="${value}" ;;
      FORCE) FORCE="${value}" ;;
      FAIL_FAST) FAIL_FAST="${value}" ;;
      USE_LLM) USE_LLM="${value}" ;;
      LLM_SERVICE) LLM_SERVICE="${value}" ;;
      MODEL_NAME) MODEL_NAME="${value}" ;;
      SERVICE_TIMEOUT) SERVICE_TIMEOUT="${value}" ;;
      CLAUDE_MODEL_NAME) CLAUDE_MODEL_NAME="${value}" ;;
      GEMINI_MODEL_NAME) GEMINI_MODEL_NAME="${value}" ;;
      CLAUDE_API_KEY) CLAUDE_API_KEY="${value}" ;;
      OPENAI_API_KEY) OPENAI_API_KEY="${value}" ;;
      GOOGLE_API_KEY) GOOGLE_API_KEY="${value}" ;;
      MARKER_SINGLE_BIN) MARKER_SINGLE_BIN="${value}" ;;
    esac
  done < "${file}"
}

preparse_settings_selection() {
  local args=("$@")
  local idx=0
  local arg=""
  local next_idx=0

  while [[ ${idx} -lt ${#args[@]} ]]; do
    arg="${args[$idx]}"
    case "${arg}" in
      --settings)
        next_idx=$((idx + 1))
        if [[ ${next_idx} -ge ${#args[@]} ]]; then
          echo "Error: --settings requires a path." >&2
          exit 1
        fi
        SETTINGS_FILE="${args[$next_idx]}"
        SETTINGS_EXPLICIT=true
        idx=$((idx + 2))
        ;;
      --no-settings)
        USE_SETTINGS=false
        idx=$((idx + 1))
        ;;
      --)
        break
        ;;
      *)
        idx=$((idx + 1))
        ;;
    esac
  done
}

load_settings_if_needed() {
  if [[ "${USE_SETTINGS}" == true && -f "${SETTINGS_FILE}" ]]; then
    check_file_readable_regular "${SETTINGS_FILE}" "settings file"
    parse_settings_file "${SETTINGS_FILE}"
  elif [[ "${USE_SETTINGS}" == true && "${SETTINGS_EXPLICIT}" == true ]]; then
    echo "Error: settings file not found: ${SETTINGS_FILE}" >&2
    exit 1
  fi
}

parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input)
        INPUT_PATH="${2:-}"
        shift 2
        ;;
      --output)
        OUTPUT_PATH="${2:-}"
        shift 2
        ;;
      --format)
        OUTPUT_FORMAT="${2:-}"
        shift 2
        ;;
      --page-range)
        PAGE_RANGE="${2:-}"
        shift 2
        ;;
      --config-json)
        CONFIG_JSON="${2:-}"
        shift 2
        ;;
      --disable-image-extraction)
        DISABLE_IMAGE_EXTRACTION=true
        shift
        ;;
      --disable-multiprocessing)
        DISABLE_MULTIPROCESSING=true
        shift
        ;;
      --timeout)
        MARKER_TIMEOUT="${2:-}"
        shift 2
        ;;
      --state-dir)
        STATE_DIR="${2:-}"
        shift 2
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --fail-fast)
        FAIL_FAST=true
        shift
        ;;
      --use-llm)
        USE_LLM=true
        shift
        ;;
      --llm-service)
        LLM_SERVICE="${2:-}"
        shift 2
        ;;
      --model-name)
        MODEL_NAME="${2:-}"
        shift 2
        ;;
      --service-timeout)
        SERVICE_TIMEOUT="${2:-}"
        shift 2
        ;;
      --claude-model-name)
        CLAUDE_MODEL_NAME="${2:-}"
        shift 2
        ;;
      --gemini-model-name)
        GEMINI_MODEL_NAME="${2:-}"
        shift 2
        ;;
      --claude-api-key)
        echo "Error: passing API keys on CLI is disabled for security." >&2
        echo "Set CLAUDE_API_KEY (or ANTHROPIC_API_KEY) in env or settings file." >&2
        exit 1
        ;;
      --openai-api-key)
        echo "Error: passing API keys on CLI is disabled for security." >&2
        echo "Set OPENAI_API_KEY in env or settings file." >&2
        exit 1
        ;;
      --google-api-key)
        echo "Error: passing API keys on CLI is disabled for security." >&2
        echo "Set GOOGLE_API_KEY in env or settings file." >&2
        exit 1
        ;;
      --settings)
        SETTINGS_FILE="${2:-}"
        SETTINGS_EXPLICIT=true
        shift 2
        ;;
      --no-settings)
        USE_SETTINGS=false
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        EXTRA_ARGS=("$@")
        break
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

normalize_boolean_flags() {
  if is_true "${DISABLE_IMAGE_EXTRACTION}"; then
    DISABLE_IMAGE_EXTRACTION=true
  else
    DISABLE_IMAGE_EXTRACTION=false
  fi

  if is_true "${DISABLE_MULTIPROCESSING}"; then
    DISABLE_MULTIPROCESSING=true
  else
    DISABLE_MULTIPROCESSING=false
  fi

  if is_true "${FORCE}"; then
    FORCE=true
  else
    FORCE=false
  fi

  if is_true "${FAIL_FAST}"; then
    FAIL_FAST=true
  else
    FAIL_FAST=false
  fi

  if is_true "${USE_LLM}"; then
    USE_LLM=true
  else
    USE_LLM=false
  fi
}

validate_numeric_flags() {
  if ! [[ "${MARKER_TIMEOUT}" =~ ^[0-9]+$ ]]; then
    echo "Error: --timeout must be a non-negative integer." >&2
    exit 1
  fi

  if [[ -n "${SERVICE_TIMEOUT}" ]] && ! [[ "${SERVICE_TIMEOUT}" =~ ^[0-9]+$ ]]; then
    echo "Error: --service-timeout must be a non-negative integer." >&2
    exit 1
  fi
}

validate_inputs() {
  if [[ -z "${INPUT_PATH}" ]]; then
    echo "Error: --input is required." >&2
    usage
    exit 1
  fi

  if [[ ! -f "${INPUT_PATH}" && ! -d "${INPUT_PATH}" ]]; then
    echo "Error: --input must be an existing file or directory: ${INPUT_PATH}" >&2
    exit 1
  fi

  if [[ -n "${CONFIG_JSON}" ]]; then
    check_file_readable_regular "${CONFIG_JSON}" "config JSON"
  fi

  case "${OUTPUT_FORMAT}" in
    markdown|json|html)
      ;;
    *)
      echo "Error: --format must be one of: markdown, json, html" >&2
      exit 1
      ;;
  esac
}

resolve_default_output_path() {
  if [[ -z "${OUTPUT_PATH}" ]]; then
    OUTPUT_PATH="$(pwd)/marker_output"
  fi
}

resolve_state_dir() {
  if [[ -z "${STATE_DIR}" ]]; then
    STATE_DIR="${OUTPUT_PATH}/state"
  fi
}

validate_extra_args() {
  local arg=""

  for arg in "${EXTRA_ARGS[@]:-}"; do
    case "${arg}" in
      --ClaudeService_claude_api_key|--OpenAIService_openai_api_key|--GoogleGeminiService_gemini_api_key|--google_api_key)
        echo "Error: API key arguments are blocked in pass-through mode for security." >&2
        echo "Use environment variables or settings-file key fields instead." >&2
        exit 1
        ;;
    esac
  done
}

infer_llm_provider() {
  local llm_service_lower
  llm_service_lower="$(to_lower "${LLM_SERVICE}")"

  if [[ "${llm_service_lower}" == *"ollama"* ]]; then
    printf '%s' "ollama"
    return
  fi
  if [[ "${llm_service_lower}" == *"claude"* ]]; then
    printf '%s' "claude"
    return
  fi
  if [[ "${llm_service_lower}" == *"openai"* ]]; then
    printf '%s' "openai"
    return
  fi
  if [[ "${llm_service_lower}" == *"gemini"* ]] || [[ "${llm_service_lower}" == *"google"* ]] || [[ "${llm_service_lower}" == *"vertex"* ]]; then
    printf '%s' "gemini"
    return
  fi
  if [[ -n "${CLAUDE_API_KEY}" ]]; then
    printf '%s' "claude"
    return
  fi
  if [[ -n "${OPENAI_API_KEY}" ]]; then
    printf '%s' "openai"
    return
  fi
  if [[ -n "${GOOGLE_API_KEY}" ]]; then
    printf '%s' "gemini"
    return
  fi

  printf '%s' "unknown"
}

validate_llm_keys() {
  local llm_provider=""

  if [[ "${USE_LLM}" != true ]]; then
    return
  fi

  llm_provider="$(infer_llm_provider)"
  case "${llm_provider}" in
    claude)
      if [[ -z "${CLAUDE_API_KEY}" ]]; then
        echo "Error: LLM is enabled but Claude API key is missing." >&2
        echo "Set CLAUDE_API_KEY (or ANTHROPIC_API_KEY) in env or marker_convert.env." >&2
        exit 1
      fi
      ;;
    openai)
      if [[ -z "${OPENAI_API_KEY}" ]]; then
        echo "Error: LLM is enabled but OpenAI API key is missing." >&2
        echo "Set OPENAI_API_KEY in env or marker_convert.env." >&2
        exit 1
      fi
      ;;
    gemini)
      if [[ -z "${GOOGLE_API_KEY}" ]]; then
        echo "Error: LLM is enabled but Google API key is missing." >&2
        echo "Set GOOGLE_API_KEY in env or marker_convert.env." >&2
        exit 1
      fi
      ;;
    ollama)
      ;;
    *)
      if [[ -z "${CLAUDE_API_KEY}" && -z "${OPENAI_API_KEY}" && -z "${GOOGLE_API_KEY}" ]]; then
        echo "Error: LLM is enabled but no API key was found." >&2
        echo "Set one of: CLAUDE_API_KEY (or ANTHROPIC_API_KEY), OPENAI_API_KEY, GOOGLE_API_KEY in marker_convert.env." >&2
        exit 1
      fi
      ;;
  esac
}

export_api_keys() {
  if [[ -n "${CLAUDE_API_KEY}" ]]; then
    export CLAUDE_API_KEY
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${CLAUDE_API_KEY}}"
  fi
  if [[ -n "${OPENAI_API_KEY}" ]]; then
    export OPENAI_API_KEY
  fi
  if [[ -n "${GOOGLE_API_KEY}" ]]; then
    export GOOGLE_API_KEY
  fi
}

collect_pdf_files() {
  local found_any=false

  if [[ -f "${INPUT_PATH}" ]]; then
    PDF_FILES=("${INPUT_PATH}")
    return
  fi

  while IFS= read -r -d '' file; do
    PDF_FILES+=("${file}")
    found_any=true
  done < <(find "${INPUT_PATH}" -type f -iname '*.pdf' -print0)

  if [[ "${found_any}" == true ]]; then
    IFS=$'\n' PDF_FILES=($(printf '%s\n' "${PDF_FILES[@]}" | sort))
    unset IFS
  fi
}

prepare_state_files() {
  mkdir -p "${OUTPUT_PATH}" "${STATE_DIR}"

  PROCESSED_LIST="${STATE_DIR}/processed_files.txt"
  FAILED_LOG="${STATE_DIR}/failed_conversions.txt"
  FAILED_ARCHIVE="${STATE_DIR}/failed_conversions_archive.txt"
  CONVERSION_LOG="${STATE_DIR}/conversion_log.txt"
  ERROR_LOG="${STATE_DIR}/error_details.txt"

  touch "${PROCESSED_LIST}" "${FAILED_LOG}" "${FAILED_ARCHIVE}" "${CONVERSION_LOG}" "${ERROR_LOG}"

  if [[ -s "${FAILED_LOG}" ]]; then
    {
      printf '\n=== Archived at %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
      cat "${FAILED_LOG}"
    } >> "${FAILED_ARCHIVE}"
    : > "${FAILED_LOG}"
  fi

  SESSION_STARTED="$(date '+%Y-%m-%d %H:%M:%S')"
  {
    printf '\n=== Conversion session started at %s ===\n' "${SESSION_STARTED}"
    printf 'Input: %s\n' "${INPUT_PATH}"
    printf 'Output: %s\n' "${OUTPUT_PATH}"
    printf 'State dir: %s\n\n' "${STATE_DIR}"
  } >> "${CONVERSION_LOG}"
}

build_marker_base_args() {
  MARKER_BASE_ARGS=("--output_dir" "${OUTPUT_PATH}" "--output_format" "${OUTPUT_FORMAT}")

  if [[ -n "${PAGE_RANGE}" ]]; then
    MARKER_BASE_ARGS+=("--page_range" "${PAGE_RANGE}")
  fi
  if [[ -n "${CONFIG_JSON}" ]]; then
    MARKER_BASE_ARGS+=("--config_json" "${CONFIG_JSON}")
  fi
  if [[ "${DISABLE_IMAGE_EXTRACTION}" == true ]]; then
    MARKER_BASE_ARGS+=("--disable_image_extraction")
  fi
  if [[ "${DISABLE_MULTIPROCESSING}" == true ]]; then
    MARKER_BASE_ARGS+=("--disable_multiprocessing")
  fi
  if [[ "${USE_LLM}" == true ]]; then
    MARKER_BASE_ARGS+=("--use_llm")
    if [[ -n "${LLM_SERVICE}" ]]; then
      MARKER_BASE_ARGS+=("--llm_service" "${LLM_SERVICE}")
    fi
    if [[ -n "${MODEL_NAME}" ]]; then
      MARKER_BASE_ARGS+=("--model_name" "${MODEL_NAME}")
    fi
    if [[ -n "${SERVICE_TIMEOUT}" ]]; then
      MARKER_BASE_ARGS+=("--timeout" "${SERVICE_TIMEOUT}")
    fi
    if [[ -n "${CLAUDE_MODEL_NAME}" ]]; then
      MARKER_BASE_ARGS+=("--claude_model_name" "${CLAUDE_MODEL_NAME}")
    fi
    if [[ -n "${GEMINI_MODEL_NAME}" ]]; then
      MARKER_BASE_ARGS+=("--gemini_model_name" "${GEMINI_MODEL_NAME}")
    fi
  fi

  if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    MARKER_BASE_ARGS+=("${EXTRA_ARGS[@]}")
  fi
}

run_one_pdf() {
  local pdf_path="$1"
  local attempt_idx="$2"
  local total="$3"
  local temp_error_file=""
  local exit_code=0
  local fail_ts=""
  local cmd=()

  cmd=("${MARKER_SINGLE_BIN:-marker_single}" "${pdf_path}" "${MARKER_BASE_ARGS[@]}")

  temp_error_file="$(mktemp "${STATE_DIR}/marker_error.XXXXXX")"

  printf '[%s/%s] Processing: %s\n' "${attempt_idx}" "${total}" "${pdf_path}"

  set +e
  if [[ "${MARKER_TIMEOUT}" -gt 0 ]]; then
    run_with_timeout "${MARKER_TIMEOUT}" "${cmd[@]}" > "${temp_error_file}" 2>&1
  else
    "${cmd[@]}" > "${temp_error_file}" 2>&1
  fi
  exit_code=$?
  set -e

  if [[ ${exit_code} -eq 0 ]]; then
    append_unique_line "${PROCESSED_LIST}" "${pdf_path}"
    printf 'SUCCESS: %s\n' "${pdf_path}" >> "${CONVERSION_LOG}"
    rm -f "${temp_error_file}"
    return 0
  fi

  fail_ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ ${exit_code} -eq 124 ]]; then
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
  return "${exit_code}"
}

run_sequential_conversion() {
  local total="${#PDF_FILES[@]}"
  local current=0
  local success_count=0
  local failed_count=0
  local skipped_count=0
  local final_exit=0
  local pdf_path=""
  local run_exit=0

  if [[ "${total}" -eq 0 ]]; then
    echo "No PDF files found under input: ${INPUT_PATH}"
    return 0
  fi

  printf 'Found %s PDF(s).\n' "${total}"
  printf 'Output directory: %s\n' "${OUTPUT_PATH}"
  printf 'State directory: %s\n\n' "${STATE_DIR}"

  for pdf_path in "${PDF_FILES[@]}"; do
    current=$((current + 1))

    if [[ "${FORCE}" != true ]] && grep -F -x -q -- "${pdf_path}" "${PROCESSED_LIST}"; then
      printf '[%s/%s] Skipped (already processed): %s\n' "${current}" "${total}" "${pdf_path}"
      printf 'SKIPPED (already processed): %s\n' "${pdf_path}" >> "${CONVERSION_LOG}"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    run_exit=0
    run_one_pdf "${pdf_path}" "${current}" "${total}" || run_exit=$?

    if [[ ${run_exit} -eq 0 ]]; then
      success_count=$((success_count + 1))
      printf '  OK\n'
    else
      failed_count=$((failed_count + 1))
      printf '  FAILED (exit code %s)\n' "${run_exit}"
      if [[ "${FAIL_FAST}" == true ]]; then
        final_exit=1
        break
      fi
    fi
  done

  {
    printf '\nSession completed at %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Attempted: %s\n' "${current}"
    printf 'Succeeded: %s\n' "${success_count}"
    printf 'Failed: %s\n' "${failed_count}"
    printf 'Skipped: %s\n' "${skipped_count}"
  } >> "${CONVERSION_LOG}"

  {
    printf '\n--- Session %s ---\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Attempted: %s | Succeeded: %s | Failed: %s | Skipped: %s\n' "${current}" "${success_count}" "${failed_count}" "${skipped_count}"
  } >> "${FAILED_LOG}"

  printf '\n=== Conversion Session Complete ===\n'
  printf 'Attempted: %s\n' "${current}"
  printf 'Succeeded: %s\n' "${success_count}"
  printf 'Failed: %s\n' "${failed_count}"
  printf 'Skipped: %s\n' "${skipped_count}"
  printf 'Conversion log: %s\n' "${CONVERSION_LOG}"
  printf 'Failed log: %s\n' "${FAILED_LOG}"
  printf 'Error details: %s\n' "${ERROR_LOG}"
  printf 'Processed list: %s\n' "${PROCESSED_LIST}"

  return "${final_exit}"
}

main() {
  local args=("$@")

  init_defaults
  preparse_settings_selection "${args[@]}"
  load_settings_if_needed
  parse_cli_args "${args[@]}"
  normalize_boolean_flags
  validate_numeric_flags
  validate_inputs
  resolve_default_output_path
  resolve_state_dir
  validate_extra_args
  validate_llm_keys
  export_api_keys
  collect_pdf_files
  prepare_state_files
  build_marker_base_args

  if ! command -v "${MARKER_SINGLE_BIN:-marker_single}" >/dev/null 2>&1; then
    echo "Error: command not found: ${MARKER_SINGLE_BIN:-marker_single}" >&2
    exit 1
  fi

  run_sequential_conversion
}

main "$@"
