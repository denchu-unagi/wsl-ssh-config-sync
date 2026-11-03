#!/bin/sh
# Tests for bin/wsl-ssh-config-sync. Run from this directory: sh test.sh
# Uses temporary files only; never touches the real ~/.ssh or /mnt/c.
set -u

script=$(cd "$(dirname "$0")/.." && pwd)/bin/wsl-ssh-config-sync
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

# Fresh HOME, source, target and state paths for each case.
setup() {
  rm -rf "$work/case"
  mkdir -p "$work/case/home" "$work/case/win"
  src="$work/case/home/config"
  dst="$work/case/win/config"
  state="$work/case/state/last-synced"
  printf 'Host a\n  HostName 192.0.2.1\n' > "$src"
}

run() {
  env HOME="$work/case/home" \
    WSL_SSH_CONFIG_SYNC_SOURCE="$src" \
    WSL_SSH_CONFIG_SYNC_TARGET="$dst" \
    WSL_SSH_CONFIG_SYNC_STATE="$state" \
    "$script" 2>/dev/null
}

# A missing target setting must stop with exit 2 instead of guessing a path.
setup
env -u WSL_SSH_CONFIG_SYNC_TARGET HOME="$work/case/home" WSL_SSH_CONFIG_SYNC_SOURCE="$src" \
  WSL_SSH_CONFIG_SYNC_STATE="$state" "$script" 2>/dev/null
[ $? -eq 2 ] || fail "unset target should exit 2"
[ ! -e "$state" ] || fail "unset target should not write state"

# First run: no sync record and the Windows file differs, so it must not be overwritten.
setup
printf 'Host windows-only\n' > "$dst"
run
[ $? -eq 1 ] || fail "first run with differing target should exit 1"
[ "$(cat "$dst")" = "Host windows-only" ] || fail "first run overwrote the Windows file"
[ ! -e "$state" ] || fail "refused run should not write state"

# Already identical: succeeds and records state so later saves can sync.
setup
cp "$src" "$dst"
run
[ $? -eq 0 ] || fail "identical files should exit 0"
cmp -s "$src" "$state" || fail "identical files should record state"

# Normal sync: the target still matches the last sync, so the new source is copied.
setup
printf 'old\n' > "$dst"
mkdir -p "$(dirname "$state")"
printf 'old\n' > "$state"
run
[ $? -eq 0 ] || fail "normal sync should exit 0"
cmp -s "$src" "$dst" || fail "normal sync did not copy source to target"
cmp -s "$src" "$state" || fail "normal sync did not update state"

# The Windows file was edited after the last sync: keep the edit and exit 1.
setup
mkdir -p "$(dirname "$state")"
printf 'old\n' > "$state"
printf 'old\nHost edited-on-windows\n' > "$dst"
run
[ $? -eq 1 ] || fail "edited target should exit 1"
[ "$(tail -n 1 "$dst")" = "Host edited-on-windows" ] || fail "edited target was overwritten"
[ "$(cat "$state")" = "old" ] || fail "refused run changed state"

# No Windows file yet: nothing can be lost, so create it (and the state directory).
setup
run
[ $? -eq 0 ] || fail "missing target should exit 0"
cmp -s "$src" "$dst" || fail "missing target was not created from source"
cmp -s "$src" "$state" || fail "missing target run did not record state"

if [ "$failures" -eq 0 ]; then
  echo "all tests passed"
else
  echo "$failures test(s) failed" >&2
  exit 1
fi
