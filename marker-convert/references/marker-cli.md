# Marker CLI Reference

Upstream repository: <https://github.com/datalab-to/marker>

Citation: `datalab-to. Marker (software). GitHub repository: https://github.com/datalab-to/marker`

## Canonical Marker Commands

- Single PDF conversion:
  `marker_single /path/to/file.pdf --output_dir /path/to/output --output_format markdown`
- Interactive extraction UI:
  `marker_extract`

## Wrapper CLI Options

`scripts/marker_convert.sh` accepts the following flags. CLI flags always override settings-file values.

| Flag | Description |
|---|---|
| `--input <path>` | Input PDF file or folder (required). Folder inputs are processed sequentially, one PDF at a time |
| `--output <path>` | Output folder (default: `./marker_output`) |
| `--format markdown\|json\|html` | Output format (default: `markdown`) |
| `--page-range <range>` | Page range, e.g. `0,5-10,20` |
| `--config-json <path>` | Marker config JSON file |
| `--disable-image-extraction` | Skip image extraction |
| `--disable-multiprocessing` | Disable multiprocessing |
| `--timeout <seconds>` | Per-PDF wrapper timeout (`0` disables) |
| `--state-dir <path>` | State/log directory (default: `<output>/state`) |
| `--force` | Reprocess already successful files from `processed_files.txt` |
| `--fail-fast` | Stop on first conversion failure (default behavior is continue-on-error) |
| `--use-llm` | Enable Marker `--use_llm` |
| `--llm-service <import.path.Class>` | Marker `--llm_service` value |
| `--model-name <name>` | Marker `--model_name` value |
| `--service-timeout <seconds>` | Marker service timeout via `--timeout` |
| `--claude-model-name <name>` | Marker `--claude_model_name` |
| `--gemini-model-name <name>` | Marker `--gemini_model_name` |
| `--settings <path>` | Load a custom settings file |
| `--no-settings` | Do not load any settings file |
| `-- <extra args>` | Pass remaining arguments directly to Marker |

API key CLI flags (`--claude-api-key`, `--openai-api-key`, `--google-api-key`) are blocked for security. Set keys via environment variables or the settings file.

## Settings File

Default location: `config/marker_convert.env` (relative to the scripts directory).

| Key | Description |
|---|---|
| `OUTPUT_FORMAT` | Default output format |
| `PAGE_RANGE` | Default page range |
| `CONFIG_JSON` | Path to Marker config JSON |
| `DISABLE_IMAGE_EXTRACTION` | `true`/`false` |
| `DISABLE_MULTIPROCESSING` | `true`/`false` |
| `MARKER_TIMEOUT` | Per-PDF wrapper timeout in seconds (`0` disables) |
| `STATE_DIR` | State/log directory override |
| `FORCE` | Reprocess PDFs already marked successful |
| `FAIL_FAST` | Stop on first failure instead of continuing |
| `USE_LLM` | Enable Marker LLM mode |
| `LLM_SERVICE` | Marker `--llm_service` value |
| `MODEL_NAME` | Marker `--model_name` value |
| `SERVICE_TIMEOUT` | Marker `--timeout` value |
| `CLAUDE_MODEL_NAME` | Marker `--claude_model_name` |
| `GEMINI_MODEL_NAME` | Marker `--gemini_model_name` |
| `CLAUDE_API_KEY` / `ANTHROPIC_API_KEY` | Claude/Anthropic API key |
| `OPENAI_API_KEY` | OpenAI API key |
| `GOOGLE_API_KEY` | Google API key |
| `MARKER_SINGLE_BIN` | Override for the `marker_single` command |

When `USE_LLM=true`, the wrapper infers the LLM provider from `LLM_SERVICE` or available keys and exits with a clear message if the required key is missing.

## Output Expectations

- Marker writes one output subfolder per input document.
- Markdown output references extracted images in an `images/` subdirectory.
- Disable image extraction with `--disable_image_extraction` (raw Marker) or `--disable-image-extraction` (wrapper).
- Persistent state/log files are written under `<output>/state` by default:
  - `processed_files.txt`
  - `conversion_log.txt`
  - `failed_conversions.txt`
  - `error_details.txt`

## Version Notes

Marker CLI behavior varies by installed version. To validate current flags:

```bash
marker_single --help
```

Observed supported flags in this environment:
- `--output_format [markdown|json|html]`
- `--disable_image_extraction`
- `--disable_multiprocessing`
- `--use_llm`, `--llm_service`, `--model_name`
- `--timeout`, `--claude_model_name`, `--gemini_model_name`
- `--page_range`, `--config_json`
