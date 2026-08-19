#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "resolve" ]]; then
  echo "fake flutter device helper: expected resolve" >&2
  exit 2
fi
requested="${2:-physical-123}"
if [[ "$requested" != "physical-123" ]]; then
  echo "fake flutter device helper: device not found: $requested" >&2
  exit 1
fi
printf '%s\n' "$requested"
