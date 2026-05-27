#!/bin/bash
# SessionStart hook: install apm dependencies declared in apm.yml.
#
# Scope: Claude Code on the web only (CLAUDE_CODE_REMOTE=true).
# Failure policy: never block session startup. If apm is missing or
# `apm install` fails, log a warning to stderr and exit 0.

set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

log() {
  printf '[session-start] %s\n' "$*" >&2
}

if ! command -v apm >/dev/null 2>&1; then
  log "WARNING: apm CLI not found in PATH; skipping 'apm install'."
  log "         To bootstrap: 'pip install apm-cli' or see https://microsoft.github.io/apm/"
  exit 0
fi

log "Running 'apm install --frozen'..."
if ! apm install --frozen; then
  log "WARNING: 'apm install --frozen' failed (likely lockfile drift or missing apm.lock.yaml); continuing without blocking session startup."
  log "         If apm.lock.yaml is missing, run 'apm install' locally once and commit the lockfile."
  exit 0
fi

log "apm install --frozen completed."
exit 0
