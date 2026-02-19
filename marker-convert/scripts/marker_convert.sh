#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SETTINGS_FILE="${SCRIPT_DIR}/../config/marker_convert.env"

usage() {
  cat <<'EOF'
Usage:
  marker_convert.sh --input <path> [--output <path>] [options]

Options:
  --mode <auto|single|batch|chunk>   Conversion mode (default: auto)
  --input <path>                      Input PDF file or input folder
  --output <path>                     Output folder (required for chunk mode)
  --format <markdown|json|html>       Output format for single/batch (default: markdown)
  --page-range <range>                Example: 0,5-10,20
  --config-json <path>                Marker config JSON
  --disable-image-extraction          Disable extracted images
  --disable-multiprocessing           Disable multiprocessing
  --timeout <seconds>                 Wrapper timeout (0 disables)
  --use-llm                           Enable Marker --use_llm
  --llm-service <import.path.Class>   Marker --llm_service value
  --model-name <name>                 Marker --model_name value
  --service-timeout <seconds>         Marker service timeout via --timeout
  --claude-model-name <name>          Marker --claude_model_name
  --gemini-model-name <name>          Marker --gemini_model_name
  --settings <path>                   Load settings file (default shown below)
  --no-settings                        Do not load any settings file
  -h, --help                          Show this help
  --                                  Pass remaining args to marker command

Default settings file:
  ../config/marker_convert.env (relative to this script)

Examples:
  marker_convert.sh --mode single --input /tmp/paper.pdf --output /tmp/out --format markdown
  marker_convert.sh --mode batch --input /tmp/pdfs --output /tmp/out --format html
  marker_convert.sh --mode batch --input /tmp/pdfs --settings /tmp/marker_convert.env
EOF
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

init_defaults() {
  MODE="auto"
  INPUT_PATH=""
  OUTPUT_PATH=""
  OUTPUT_FORMAT="markdown"
  PAGE_RANGE=""
  CONFIG_JSON=""
  DISABLE_IMAGE_EXTRACTION=false
  DISABLE_MULTIPROCESSING=false

  MARKER_TIMEOUT=0
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
  MARKER_CMD=()
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
      MODE) MODE="${value}" ;;
      OUTPUT_FORMAT) OUTPUT_FORMAT="${value}" ;;
      PAGE_RANGE) PAGE_RANGE="${value}" ;;
      CONFIG_JSON) CONFIG_JSON="${value}" ;;
      DISABLE_IMAGE_EXTRACTION) DISABLE_IMAGE_EXTRACTION="${value}" ;;
      DISABLE_MULTIPROCESSING) DISABLE_MULTIPROCESSING="${value}" ;;
      MARKER_TIMEOUT) MARKER_TIMEOUT="${value}" ;;
      USE_LLM) USE_LLM="${value}" ;;
      LLM_SERVICE) LLM_SERVICE="${value}" ;;
      MODEL_NAME) MODEL_NAME="${value}" ;;
      SERVICE_TIMEOUT) SERVICE_TIMEOUT="${value}" ;;
      CLAUDE_MODEL_NAME) CLAUDE_MODEL_NAME="${value}" ;;
      GEMINI_MODEL_NAME) GEMINI_MODEL_NAME="${value}" ;;
      CLAUDE_API_KEY) CLAUDE_API_KEY="${value}" ;;
      OPENAI_API_KEY) OPENAI_API_KEY="${value}" ;;
      GOOGLE_API_KEY) GOOGLE_API_KEY="${value}" ;;
      NUM_DEVICES) NUM_DEVICES="${value}" ;;
      MARKER_BIN) MARKER_BIN="${value}" ;;
      MARKER_SINGLE_BIN) MARKER_SINGLE_BIN="${value}" ;;
      MARKER_CHUNK_BIN) MARKER_CHUNK_BIN="${value}" ;;
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
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
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

  if [[ -n "${CONFIG_JSON}" ]]; then
    check_file_readable_regular "${CONFIG_JSON}" "config JSON"
  fi
}

resolve_mode() {
  if [[ "${MODE}" == "auto" ]]; then
    if [[ -f "${INPUT_PATH}" ]]; then
      MODE="single"
    elif [[ -d "${INPUT_PATH}" ]]; then
      MODE="batch"
    else
      echo "Error: --input must be an existing file or directory for auto mode." >&2
      exit 1
    fi
  fi
}

resolve_default_output_path() {
  if [[ -z "${OUTPUT_PATH}" && "${MODE}" != "chunk" ]]; then
    OUTPUT_PATH="$(pwd)/marker_output"
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

  if [[ "${USE_LLM}" != true || "${MODE}" == "chunk" ]]; then
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

build_marker_command() {
  case "${MODE}" in
    single)
      if [[ ! -f "${INPUT_PATH}" ]]; then
        echo "Error: single mode requires a file input." >&2
        exit 1
      fi
      MARKER_CMD=("${MARKER_SINGLE_BIN:-marker_single}" "${INPUT_PATH}" "--output_dir" "${OUTPUT_PATH}" "--output_format" "${OUTPUT_FORMAT}")
      ;;
    batch)
      if [[ ! -d "${INPUT_PATH}" ]]; then
        echo "Error: batch mode requires a directory input." >&2
        exit 1
      fi
      MARKER_CMD=("${MARKER_BIN:-marker}" "${INPUT_PATH}" "--output_dir" "${OUTPUT_PATH}" "--output_format" "${OUTPUT_FORMAT}")
      ;;
    chunk)
      if [[ ! -d "${INPUT_PATH}" ]]; then
        echo "Error: chunk mode requires a directory input." >&2
        exit 1
      fi
      if [[ -z "${OUTPUT_PATH}" ]]; then
        echo "Error: chunk mode requires --output." >&2
        exit 1
      fi
      if [[ -z "${NUM_DEVICES:-}" ]]; then
        echo "Error: chunk mode requires NUM_DEVICES to be set (example: NUM_DEVICES=1)." >&2
        exit 1
      fi
      export NUM_DEVICES
      MARKER_CMD=("${MARKER_CHUNK_BIN:-marker_chunk_convert}" "${INPUT_PATH}" "${OUTPUT_PATH}")
      ;;
    *)
      echo "Error: unsupported mode '${MODE}'." >&2
      usage
      exit 1
      ;;
  esac
}

append_non_chunk_marker_flags() {
  if [[ "${MODE}" == "chunk" ]]; then
    return
  fi

  if [[ -n "${PAGE_RANGE}" ]]; then
    MARKER_CMD+=("--page_range" "${PAGE_RANGE}")
  fi
  if [[ -n "${CONFIG_JSON}" ]]; then
    MARKER_CMD+=("--config_json" "${CONFIG_JSON}")
  fi
  if [[ "${DISABLE_IMAGE_EXTRACTION}" == true ]]; then
    MARKER_CMD+=("--disable_image_extraction")
  fi
  if [[ "${DISABLE_MULTIPROCESSING}" == true ]]; then
    MARKER_CMD+=("--disable_multiprocessing")
  fi
  if [[ "${USE_LLM}" == true ]]; then
    MARKER_CMD+=("--use_llm")
    if [[ -n "${LLM_SERVICE}" ]]; then
      MARKER_CMD+=("--llm_service" "${LLM_SERVICE}")
    fi
    if [[ -n "${MODEL_NAME}" ]]; then
      MARKER_CMD+=("--model_name" "${MODEL_NAME}")
    fi
    if [[ -n "${SERVICE_TIMEOUT}" ]]; then
      MARKER_CMD+=("--timeout" "${SERVICE_TIMEOUT}")
    fi
    if [[ -n "${CLAUDE_MODEL_NAME}" ]]; then
      MARKER_CMD+=("--claude_model_name" "${CLAUDE_MODEL_NAME}")
    fi
    if [[ -n "${GEMINI_MODEL_NAME}" ]]; then
      MARKER_CMD+=("--gemini_model_name" "${GEMINI_MODEL_NAME}")
    fi
  fi
}

append_extra_marker_flags() {
  if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    MARKER_CMD+=("${EXTRA_ARGS[@]}")
  fi
}

run_marker_command() {
  if ! command -v "${MARKER_CMD[0]}" >/dev/null 2>&1; then
    echo "Error: command not found: ${MARKER_CMD[0]}" >&2
    exit 1
  fi

  echo "Running: ${MARKER_CMD[0]} (${MODE} mode)" >&2

  if [[ "${MARKER_TIMEOUT}" -gt 0 ]]; then
    run_with_timeout "${MARKER_TIMEOUT}" "${MARKER_CMD[@]}"
  else
    "${MARKER_CMD[@]}"
  fi
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
  resolve_mode
  resolve_default_output_path
  validate_extra_args
  validate_llm_keys
  export_api_keys
  build_marker_command
  append_non_chunk_marker_flags
  append_extra_marker_flags
  run_marker_command
}

main "$@"
