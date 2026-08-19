#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "devices" ]]; then
  printf '%s\n' "${FAKE_FLUTTER_DEVICES_JSON:-[{\"id\":\"macos\",\"name\":\"macOS\"}]}"
  exit 0
fi

if [[ "${1:-}" == "run" ]]; then
  printf 'fake flutter run %s\n' "$*"
  trap 'exit 0' TERM INT
  while :; do sleep 1; done
fi

printf 'fake flutter: unsupported command %s\n' "${1:-}" >&2
exit 2
