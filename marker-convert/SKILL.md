---
name: marker-convert
description: Convert PDFs to markdown, JSON, or HTML using the Marker CLI. This skill should be used when asked to run Marker conversions (`marker_single`) for single files or folders of PDFs, including resumable sequential workflows.
---

# Marker Convert

Convert PDFs into markdown, extracted images, JSON, and HTML via the [Marker](https://github.com/datalab-to/marker) CLI.

## Workflow

1. Confirm `marker_single` is available on `PATH`.
2. Run the wrapper script (it always processes one PDF at a time, sequentially).
3. For folder inputs, monitor progress and state logs under `<output>/state`.
4. Verify outputs: content files (`.md`, `.json`, `.html`) and extracted images in each document's `images/` subdirectory.

## Quick Start

```bash
SKILL_DIR=~/.codex/skills/marker-convert/scripts

# Single PDF -> markdown + images
bash "$SKILL_DIR/marker_convert.sh" \
  --input /path/to/paper.pdf \
  --output /path/to/output \
  --format markdown

# Folder of PDFs -> sequential markdown conversion (one PDF at a time)
bash "$SKILL_DIR/marker_convert.sh" \
  --input /path/to/pdf_folder \
  --output /path/to/output \
  --format markdown
```

State files are written to `<output>/state` by default (`processed_files.txt`, `conversion_log.txt`, `failed_conversions.txt`, `error_details.txt`), so re-runs skip already processed PDFs unless `--force` is set.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/marker_convert.sh` | Primary wrapper — sequential conversion with persistent state/logging and continue-on-error |
| `scripts/smoke_test.sh` | Regression test: single conversion, resume skip behavior, continue-on-error, missing-key guard |

## Configuration

The wrapper auto-loads `config/marker_convert.env` (relative to the scripts directory). Override with `--settings <path>` or disable with `--no-settings`. CLI flags always take precedence over settings-file values.

To enable LLM-enhanced conversion, set `USE_LLM=true` in the settings file or pass `--use-llm`. The wrapper validates that the required API key is present and exits with guidance if not.

Refer to `references/marker-cli.md` for the full list of CLI options, config keys, and supported Marker flags.

## Smoke Test

To validate the skill after edits:

```bash
bash ~/.codex/skills/marker-convert/scripts/smoke_test.sh \
  --pdf /path/to/sample.pdf
```

## References

- `references/marker-cli.md` — full CLI option reference, config key documentation, output format details, and version notes
