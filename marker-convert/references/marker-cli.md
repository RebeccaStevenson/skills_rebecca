# Marker CLI Notes

## Canonical Commands

Reference repository: <https://github.com/datalab-to/marker>

- Single PDF conversion:
  - `marker_single /path/to/file.pdf --output_dir /path/to/output --output_format markdown`
- Batch folder conversion:
  - `marker /path/to/input/folder --output_dir /path/to/output`
- Chunk conversion:
  - `marker_chunk_convert ...` (arguments vary by Marker version)
- Interactive extraction UI:
  - `marker_extract`

## Local Version Snapshot

Validate local behavior before advanced flag usage:

```bash
marker_single --help
marker --help
marker_chunk_convert --help
```

Observed in this environment:

- `marker_single` and `marker` support:
  - `--output_format [markdown|json|html]`
  - `--disable_image_extraction`
  - `--disable_multiprocessing`
  - `--use_llm`, `--llm_service`, `--model_name`
  - `--timeout`, `--claude_model_name`, `--gemini_model_name`
  - `--page_range`, `--config_json`
- `marker_chunk_convert` expects:
  - `marker_chunk_convert <in_folder> <out_folder>`
  - `NUM_DEVICES` must be set in this environment (example: `NUM_DEVICES=1`)

## Output Expectations

- Marker writes one output subfolder per input document.
- Markdown output references extracted images in an `images/` subdirectory by default.
- Disable extracted images with `--disable_image_extraction`.

## Folder Batch Workflow

For plain folder conversion, use:

```bash
bash ~/.codex/skills/marker-convert/scripts/batch_convert.sh \
  --input /path/to/pdf_folder \
  --output /path/to/output \
  --format markdown
```

## Wrapper Config File

Default file:
- `~/.codex/skills/marker-convert/config/marker_convert.env`

Wrapper scripts auto-load it and allow override:

```bash
bash ~/.codex/skills/marker-convert/scripts/marker_convert.sh \
  --settings /path/to/marker_convert.env \
  --mode batch \
  --input /path/to/pdf_folder
```

Core settings:
- `MARKER_TIMEOUT`: hard wrapper timeout in seconds (`0` disables)
- `USE_LLM`: enable Marker `--use_llm`
- `LLM_SERVICE`: value for `--llm_service`
- `MODEL_NAME`: value for `--model_name`
- `SERVICE_TIMEOUT`: value for Marker `--timeout`
- `CLAUDE_API_KEY`/`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`: provider credentials

When `USE_LLM=true`, the wrapper prints a short key-setup hint if no matching key is available.
Prefer environment variables for keys and avoid putting secrets on command lines. API key CLI flags are blocked.

## Smoke Test

```bash
bash ~/.codex/skills/marker-convert/scripts/smoke_test.sh \
  --pdf /path/to/sample.pdf
```
