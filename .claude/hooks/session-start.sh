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

log "Running 'apm install'..."
if ! apm install; then
  log "WARNING: 'apm install' failed; continuing without blocking session startup."
  exit 0
fi

log "apm install completed."
exit 0
