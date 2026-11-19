#!/usr/bin/env bash
# force_git_symlinks and repair_symlinks (lib/common.sh) against a user git config with
# core.symlinks=false, which writes symlinks as text files and breaks QEMU's build. No network.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# A private git config for every git command here: nothing from the caller's.
export GIT_CONFIG_GLOBAL=$tmp/gitconfig GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main

# The origin: one file and one symlink to it.
git -c core.symlinks=true init -q "$tmp/origin"
printf 'header\n' > "$tmp/origin/real.h"
ln -s real.h "$tmp/origin/link.h"
git -C "$tmp/origin" add real.h link.h
git -C "$tmp/origin" commit -qm origin

git config --global core.symlinks false
git clone -q "$tmp/origin" "$tmp/broken"
git clone -q "$tmp/origin" "$tmp/edited"
if [ -L "$tmp/broken/link.h" ] || [ ! -f "$tmp/broken/link.h" ]; then
  fail "the fixture did not reproduce core.symlinks=false (link.h is a symlink)"
fi
printf 'my own edit\n' > "$tmp/edited/link.h"

(
  # shellcheck disable=SC1091  # this checkout's own lib/common.sh
  source "$root/lib/common.sh"
  force_git_symlinks 2>/dev/null
  [ "$VSETUP_GIT_SYMLINKS_FORCED" = 1 ] || fail "core.symlinks=false was not detected"
  [ "${GIT_CONFIG_COUNT:-}" = 1 ] || fail "GIT_CONFIG_COUNT is '${GIT_CONFIG_COUNT:-}', not 1"

  # A new clone under the override: a real symlink.
  git clone -q "$tmp/origin" "$tmp/fresh"
  [ -L "$tmp/fresh/link.h" ] || fail "a clone after force_git_symlinks has no symlink"

  # A second call (a child script sourcing common.sh again) adds nothing.
  force_git_symlinks 2>/dev/null
  [ "$GIT_CONFIG_COUNT" = 1 ] || fail "a second force_git_symlinks changed GIT_CONFIG_COUNT"

  # The older clone is repaired, and keeps symlinks on in its own config.
  repair_symlinks "$tmp/broken" >/dev/null
  [ -L "$tmp/broken/link.h" ] || fail "repair_symlinks left link.h as a text file"
  [ "$(readlink "$tmp/broken/link.h")" = real.h ] || fail "the repaired link points elsewhere"
  [ "$(git -C "$tmp/broken" config --local core.symlinks)" = true ] ||
    fail "repair_symlinks did not set core.symlinks in the checkout"
  [ -z "$(git -C "$tmp/broken" status --porcelain)" ] || fail "the repaired checkout is not clean"

  # A file whose text is not the link target (a local edit) is left alone.
  repair_symlinks "$tmp/edited" >/dev/null
  if [ -L "$tmp/edited/link.h" ] || [ "$(cat "$tmp/edited/link.h")" != 'my own edit' ]; then
    fail "repair_symlinks replaced an edited file"
  fi
)

# With symlinks on (the default), force_git_symlinks changes nothing.
git config --global --unset core.symlinks
(
  # shellcheck disable=SC1091
  source "$root/lib/common.sh"
  force_git_symlinks
  [ "$VSETUP_GIT_SYMLINKS_FORCED" = 0 ] || fail "force_git_symlinks acted with symlinks on"
  [ -z "${GIT_CONFIG_COUNT:-}" ] || fail "force_git_symlinks set GIT_CONFIG_COUNT with symlinks on"
)
printf 'OK: core.symlinks=false is overridden for setup and old checkouts are repaired\n'
