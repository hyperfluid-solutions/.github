#!/bin/bash
# Build-layer guardrail: verify the runner's Xcode matches the project's pin.
# Source: Plan keep-mac-mini-runners-current — Layer B3.
#
# Reads a project's `.xcode-version` and ensures the self-hosted Mac mini runner
# will build against EXACTLY that Xcode — failing fast with an actionable
# message instead of letting a drifted toolchain produce a cryptic Swift
# compiler error. Optionally verifies a required iOS simulator runtime.
#
# Designed to run both in GitHub Actions (composite action wrapper) and locally
# for testing. Inputs come from environment variables so it is trivially
# unit-testable:
#   XCODE_VERSION_FILE   path to the pin file        (default: .xcode-version)
#   REQUIRE_SIM_RUNTIME  e.g. "iOS 26.5" to assert   (default: empty = skip)
#   AUTO_SELECT          select the pinned Xcode      (default: true)
#   MIN_FREE_GB          fail if less free disk       (default: 0 = skip)
#   GITHUB_ENV           if set, DEVELOPER_DIR is exported for later steps
#
# Beyond the version match, it guards the failure modes the deep-research
# (prompt 3) flagged as the real day-to-day killers on shared runners:
#   * a Command Line Tools dir selected instead of full Xcode,
#   * Xcode installed but first-launch not completed,
#   * the disk too full to finish a build (a ~40GB-Xcode fleet runs tight),
#   * the required simulator runtime missing.
set -uo pipefail

XCODE_VERSION_FILE="${XCODE_VERSION_FILE:-.xcode-version}"
REQUIRE_SIM_RUNTIME="${REQUIRE_SIM_RUNTIME:-}"
AUTO_SELECT="${AUTO_SELECT:-true}"
MIN_FREE_GB="${MIN_FREE_GB:-0}"

# Use GitHub's ::error:: annotation under Actions; a plain stderr line locally
# (echo never fails, so a `||` fallback would be dead code).
err() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::error::$*"; else echo "ERROR: $*" >&2; fi
}

# --- 1. Read the pin -------------------------------------------------------
if [[ ! -f "$XCODE_VERSION_FILE" ]]; then
  err "No $XCODE_VERSION_FILE found. Pin this project's Xcode by committing a \
.xcode-version file (e.g. echo 26.5 > .xcode-version) so builds are reproducible."
  exit 1
fi
pinned="$(tr -d '[:space:]' < "$XCODE_VERSION_FILE")"
if [[ -z "$pinned" ]]; then
  err "$XCODE_VERSION_FILE is empty — it must contain a version like 26.5"
  exit 1
fi
echo "Project pins Xcode $pinned (from $XCODE_VERSION_FILE)"

# --- 2. Locate the matching installed Xcode --------------------------------
# `xcodes` is the source of truth when present; fall back to scanning
# /Applications for side-by-side Xcode-<ver>.app bundles.
matching_dir=""
if command -v xcodes >/dev/null 2>&1; then
  matching_dir="$(xcodes installed 2>/dev/null \
    | awk -v v="$pinned" '$1 == v {print $NF}' | tr -d '()' | head -1)"
fi
if [[ -z "$matching_dir" ]]; then
  for app in /Applications/Xcode*.app; do
    [[ -d "$app" ]] || continue
    ver="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist" 2>/dev/null)"
    if [[ "$ver" == "$pinned" ]]; then matching_dir="$app"; break; fi
  done
fi

if [[ -z "$matching_dir" ]]; then
  installed="$(xcodes installed 2>/dev/null | awk '{print $1}' | paste -sd', ' - 2>/dev/null)"
  if [[ -z "$installed" ]]; then
    shopt -s nullglob
    xcode_apps=(/Applications/Xcode*.app)
    shopt -u nullglob
    installed="$(printf '%s, ' "${xcode_apps[@]}")"
    installed="${installed%, }"
  fi
  err "Runner does not have Xcode $pinned installed (has: ${installed:-none}). \
Route this job to an 'xcode-$pinned'-labeled runner, install it with \
'xcodes install $pinned', or update $XCODE_VERSION_FILE to a supported version."
  exit 1
fi
developer_dir="$matching_dir/Contents/Developer"
echo "Found matching Xcode at $matching_dir"

# --- 3. Select it for this build -------------------------------------------
if [[ "$AUTO_SELECT" == "true" ]]; then
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "DEVELOPER_DIR=$developer_dir" >> "$GITHUB_ENV"
    echo "Exported DEVELOPER_DIR=$developer_dir for subsequent steps"
  fi
  export DEVELOPER_DIR="$developer_dir"
fi

# --- 4. Confirm the active toolchain actually reports the pin --------------
active="$(DEVELOPER_DIR="$developer_dir" xcodebuild -version 2>/dev/null \
  | awk '/^Xcode/ {print $2}')"
if [[ "$active" != "$pinned" ]]; then
  err "Active Xcode reports '$active' but project pins '$pinned'. \
DEVELOPER_DIR=$developer_dir did not resolve as expected."
  exit 1
fi
echo "Verified: active Xcode is $active"

# --- 4a. Guard against Command Line Tools instead of full Xcode -------------
# A CommandLineTools developer dir builds nothing iOS and fails cryptically
# ("requires Xcode, but active developer directory is a command line tools
# instance"). Catch it here.
active_dir="$(DEVELOPER_DIR="$developer_dir" xcode-select -p 2>/dev/null)"
if [[ "$active_dir" == *CommandLineTools* ]] \
   || ! DEVELOPER_DIR="$developer_dir" xcrun --find xcodebuild >/dev/null 2>&1; then
  err "Active developer dir is Command Line Tools, not a full Xcode ($active_dir). \
Point DEVELOPER_DIR at an Xcode.app."
  exit 1
fi

# --- 4b. Xcode installed but not first-launched ----------------------------
# A fresh install / new VM image that never ran first-launch will fail later
# with license / component prompts. Surface it now with the exact fix.
if ! DEVELOPER_DIR="$developer_dir" xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  err "Xcode $pinned is installed but first launch is incomplete on this runner. \
Run: sudo DEVELOPER_DIR=$developer_dir xcodebuild -runFirstLaunch"
  exit 1
fi

# --- 4c. Log the Swift toolchain (catches Swift drift within same Xcode) ----
swift_ver="$(DEVELOPER_DIR="$developer_dir" xcrun swift --version 2>/dev/null | head -1)"
echo "Swift toolchain: ${swift_ver:-unknown}"

# --- 4d. Disk-space gate ---------------------------------------------------
# Several side-by-side Xcodes + DerivedData + runtimes fill SSDs fast; a job
# that starts at 95% dies mid-build with an opaque error. Refuse early instead.
# Validate first: a non-numeric value (e.g. "30GB") makes the [[ -gt ]] test
# error out, which as an `if` condition would silently SKIP the gate.
if [[ -n "$MIN_FREE_GB" && ! "$MIN_FREE_GB" =~ ^[0-9]+$ ]]; then
  err "min-free-gb must be a whole number of GB (got '$MIN_FREE_GB')."
  exit 1
fi
if [[ "$MIN_FREE_GB" -gt 0 ]]; then
  free_gb="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$free_gb" && "$free_gb" -lt "$MIN_FREE_GB" ]]; then
    err "Only ${free_gb}GB free on / (< ${MIN_FREE_GB}GB required). Aborting before a \
full-disk mid-build failure; groom the runner (groom-disk-macos.sh) or free space."
    exit 1
  fi
  echo "Disk OK: ${free_gb:-?}GB free (>= ${MIN_FREE_GB}GB)"
fi

# --- 5. Optional simulator runtime check -----------------------------------
if [[ -n "$REQUIRE_SIM_RUNTIME" ]]; then
  echo "Checking for simulator runtime: $REQUIRE_SIM_RUNTIME"
  if ! DEVELOPER_DIR="$developer_dir" xcrun simctl list runtimes 2>/dev/null \
       | grep -qF "$REQUIRE_SIM_RUNTIME"; then
    err "Required simulator runtime '$REQUIRE_SIM_RUNTIME' is not installed. \
Install it with 'xcodes runtimes install \"$REQUIRE_SIM_RUNTIME\"' or adjust \
the workflow's destination string."
    exit 1
  fi
  echo "Verified: simulator runtime '$REQUIRE_SIM_RUNTIME' present"
fi

echo "Xcode version guardrail passed."
