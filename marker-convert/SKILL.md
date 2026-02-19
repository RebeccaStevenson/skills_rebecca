---
name: marker-convert
description: Convert PDFs to markdown, JSON, or HTML using the Marker CLI. This skill should be used when asked to run Marker conversions (`marker_single`, `marker`) for single files or folders of PDFs, including batch processing workflows.
---

# Marker Convert

Convert PDFs into markdown, extracted images, JSON, and HTML via the [Marker](https://github.com/datalab-to/marker) CLI.

## Workflow

1. Confirm `marker` and `marker_single` are available on `PATH`.
2. Determine the conversion mode: `single` for one PDF, `batch` for a folder.
3. Run the wrapper script rather than hand-writing raw Marker commands.
4. Verify outputs: content files (`.md`, `.json`, `.html`) and extracted images in each document's `images/` subdirectory.

## Quick Start

```bash
SKILL_DIR=~/.claude/skills/marker-convert/scripts

# Single PDF -> markdown + images
bash "$SKILL_DIR/marker_convert.sh" \
  --input /path/to/paper.pdf \
  --output /path/to/output \
  --format markdown

# Folder of PDFs -> markdown
bash "$SKILL_DIR/marker_convert.sh" \
  --input /path/to/pdf_folder \
  --output /path/to/output \
  --format markdown

# Convenience batch entrypoint (always runs --mode batch)
bash "$SKILL_DIR/batch_convert.sh" \
  --input /path/to/pdf_folder \
  --output /path/to/output
```

Auto-mode (the default) detects whether `--input` is a file or directory and selects single/batch accordingly.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/marker_convert.sh` | Primary wrapper — supports `--mode auto\|single\|batch` and all Marker flags |
| `scripts/batch_convert.sh` | Thin convenience wrapper that always runs batch mode |
| `scripts/smoke_test.sh` | Regression test: single conversion, missing-key guard, batch conversion |

## Configuration

The wrapper auto-loads `config/marker_convert.env` (relative to the scripts directory). Override with `--settings <path>` or disable with `--no-settings`. CLI flags always take precedence over settings-file values.

To enable LLM-enhanced conversion, set `USE_LLM=true` in the settings file or pass `--use-llm`. The wrapper validates that the required API key is present and exits with guidance if not.

Refer to `references/marker-cli.md` for the full list of CLI options, config keys, and supported Marker flags.

## Smoke Test

To validate the skill after edits:

```bash
bash ~/.claude/skills/marker-convert/scripts/smoke_test.sh \
  --pdf /path/to/sample.pdf
```

## References

- `references/marker-cli.md` — full CLI option reference, config key documentation, output format details, and version notes
