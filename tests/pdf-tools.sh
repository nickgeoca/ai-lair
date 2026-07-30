#!/usr/bin/env bash
set -euo pipefail

DOCKERFILE="$PWD/src/Dockerfile"
PYPROJECT="$PWD/src/pyproject.toml"
SKILL="$PWD/src/skills/productivity/ocr-and-documents/SKILL.md"

grep -Fq 'poppler-utils' "$DOCKERFILE"
grep -Fq -- '--extra documents' "$DOCKERFILE"
grep -Fq 'documents = ["pymupdf==1.28.0", "pymupdf4llm==1.28.0"]' "$PYPROJECT"
grep -Fq 'pdftotext -layout document.pdf -' "$SKILL"

echo "PDF extraction dependencies and skill guidance are wired"
