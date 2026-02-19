---
name: marker-convert
description: Convert PDFs with Marker into markdown, extracted images, JSON, and HTML. Use when asked to run Marker CLI workflows (`marker_single`, `marker`) for single files or folders.
---

# Marker Convert

Upstream Marker project:
- https://github.com/datalab-to/marker

Citation (upstream Marker):
- `datalab-to. Marker (software). GitHub repository: https://github.com/datalab-to/marker`

## Overview
Run reliable Marker conversions for single PDFs and PDF folders. Prefer packaged wrappers in `scripts/` to keep commands consistent and version-aware.

## Configuration

Default config file:
- `~/.codex/skills/marker-convert/config/marker_convert.env`

The wrapper auto-loads this file. Override with:
- `--settings /path/to/marker_convert.env`
- `--no-settings`

Important config keys:
- `MARKER_TIMEOUT` wrapper timeout in seconds
- `USE_LLM` enable Marker `--use_llm`
- `LLM_SERVICE` set Marker `--llm_service`
- `MODEL_NAME` set Marker `--model_name`
- `SERVICE_TIMEOUT` set Marker `--timeout`
- `CLAUDE_MODEL_NAME` and `GEMINI_MODEL_NAME`
- `CLAUDE_API_KEY` or `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `GOOGLE_API_KEY`

If `USE_LLM=true` and no key is found, the wrapper exits with a brief message telling which key to set.
Prefer environment variables for secrets instead of CLI key flags. API key CLI flags are blocked.

## Quick Start

Use the generic wrapper for most requests:

```bash
SKILL_DIR=~/.codex/skills/marker-convert/scripts

# Single PDF -> markdown + images
bash "$SKILL_DIR/marker_convert.sh" \
  --mode single \
  --input /path/to/paper.pdf \
  --output /path/to/output \
  --format markdown

# Folder of PDFs -> HTML outputs
bash "$SKILL_DIR/marker_convert.sh" \
  --mode batch \
  --input /path/to/pdf_folder \
  --output /path/to/output \
  --format html

# Convenience batch entrypoint for folder-of-PDF jobs
bash "$SKILL_DIR/batch_convert.sh" \
  --input /path/to/pdf_folder \
  --output /path/to/output \
  --format markdown
```

## Workflow

1. Confirm tools are available: `marker`, `marker_single`.
2. Select mode:
- `single`: one PDF file.
- `batch`: a folder of PDFs.
3. Run wrapper scripts from `scripts/` instead of hand-writing long commands.
4. Verify outputs:
- content files (`.md`, `.json`, `.html`) in output subfolders.
- extracted images in each document's `images/` directory (unless disabled).

## Scripts

### `scripts/marker_convert.sh`
Use for single/batch conversions with a stable argument shape.

Supported options:
- `--mode auto|single|batch`
- `--input <path>`
- `--output <path>`
- `--format markdown|json|html` (single/batch modes)
- `--page-range <range>` (single/batch modes)
- `--config-json <path>` (single/batch modes)
- `--disable-image-extraction`
- `--disable-multiprocessing`
- `--timeout <seconds>`
- `--use-llm`
- `--llm-service <import.path.Class>`
- `--model-name <name>`
- `--service-timeout <seconds>`
- `--settings <path>`, `--no-settings`
- `-- <extra marker args>`

Examples:

```bash
# Auto-mode (file => single, directory => batch)
bash ~/.codex/skills/marker-convert/scripts/marker_convert.sh \
  --input /path/to/file_or_folder \
  --output /path/to/output \
  --format markdown

# Explicit batch mode (folder -> folder)
bash ~/.codex/skills/marker-convert/scripts/marker_convert.sh \
  --mode batch \
  --input /path/to/pdf_folder \
  --output /path/to/output
```

### `scripts/batch_convert.sh`
Use when the request is simply "convert this folder of PDFs".

```bash
bash ~/.codex/skills/marker-convert/scripts/batch_convert.sh \
  --input /path/to/pdf_folder \
  --output /path/to/output \
  --format markdown
```

### `scripts/smoke_test.sh`
Run a quick regression test after edits:

```bash
bash ~/.codex/skills/marker-convert/scripts/smoke_test.sh \
  --pdf /path/to/sample.pdf
```

## Version Check

Marker CLI behavior varies by installed version. Validate current flags before passing advanced options:

```bash
marker_single --help
marker --help
```

See `references/marker-cli.md` for command mapping and output notes.
