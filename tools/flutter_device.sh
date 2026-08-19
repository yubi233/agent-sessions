#!/usr/bin/env bash
# Resolve a physical Android Flutter target without starting, stopping, or
# changing any connected device. This is used by restart.sh's `--flutter device`.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/flutter_device.sh {list|resolve [adb-serial]}

list                  Print online physical Android devices.
resolve [adb-serial] Print one selected online physical Android serial.
                      Without a serial, exactly one device must be connected.

ADB_BIN overrides ADB discovery. Otherwise ANDROID_SDK_ROOT, ANDROID_HOME,
and ~/Library/Android/sdk are checked in that order.
EOF
}

find_adb() {
  if [[ -n "${ADB_BIN:-}" ]]; then
    [[ -x "$ADB_BIN" ]] || { echo "flutter_device.sh: ADB_BIN is not executable: $ADB_BIN" >&2; return 1; }
    printf '%s\n' "$ADB_BIN"
    return 0
  fi

  local root candidate
  for root in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Library/Android/sdk"; do
    [[ -n "$root" ]] || continue
    candidate="$root/platform-tools/adb"
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "flutter_device.sh: adb not found; set ADB_BIN, ANDROID_SDK_ROOT, or ANDROID_HOME" >&2
  return 1
}

list_devices() {
  local adb="$1" output line serial state details
  if ! output="$("$adb" devices -l)"; then
    echo "flutter_device.sh: adb devices failed" >&2
    return 1
  fi
  while IFS= read -r line; do
    [[ "$line" == "List of devices attached" || -z "$line" ]] && continue
    serial="${line%%[[:space:]]*}"
    line="${line#"$serial"}"
    line="${line#${line%%[![:space:]]*}}"
    state="${line%%[[:space:]]*}"
    details="${line#"$state"}"
    details="${details#${details%%[![:space:]]*}}"
    [[ "$state" == "device" && "$serial" != emulator-* ]] || continue
    printf '%s\t%s\n' "$serial" "$details"
  done <<< "$output"
}

resolve_device() {
  local requested="${1:-}" adb selected=() row serial
  adb="$(find_adb)"
  while IFS= read -r row; do
    [[ -n "$row" ]] && selected+=("$row")
  done < <(list_devices "$adb")

  if [[ -n "$requested" ]]; then
    for row in "${selected[@]}"; do
      serial="${row%%$'\t'*}"
      if [[ "$serial" == "$requested" ]]; then
        printf '%s\n' "$serial"
        return 0
      fi
    done
    echo "flutter_device.sh: requested physical Android device is not online: $requested" >&2
    return 1
  fi

  case "${#selected[@]}" in
    0)
      echo "flutter_device.sh: no online physical Android device found" >&2
      return 1
      ;;
    1)
      printf '%s\n' "${selected[0]%%$'\t'*}"
      ;;
    *)
      echo "flutter_device.sh: multiple physical Android devices found; pass --flutter-device <adb-serial>" >&2
      list_devices "$adb" >&2
      return 1
      ;;
  esac
}

main() {
  local action="${1:-}"
  case "$action" in
    list)
      [[ $# -eq 1 ]] || { usage >&2; return 2; }
      list_devices "$(find_adb)"
      ;;
    resolve)
      [[ $# -le 2 ]] || { usage >&2; return 2; }
      resolve_device "${2:-}"
      ;;
    -h|--help|help) usage ;;
    *) usage >&2; return 2 ;;
  esac
}

main "$@"
