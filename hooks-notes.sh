#!/bin/bash
# RAPP Crispy notes hook.
#   $1 = path to transcript.txt
#   stdout = markdown meeting notes
#
# Swap the body for a fully offline model, e.g.:
#   ollama run llama3.1 < "$1"
set -euo pipefail

if [ "${CRISPY_NOTES_CONSENT:-0}" != 1 ] && [ "${2:-}" != "--rappcrispy-explicit-consent" ]; then
  printf '%s\n' "Notes disabled: this hook sends transcripts to Anthropic via claude -p. Review the provider and explicitly consent in RAPP Crispy Settings, or set CRISPY_NOTES_CONSENT=1 for this CLI invocation." >&2
  exit 3
fi

# Homebrew prefix differs by architecture (/opt/homebrew on Apple Silicon,
# /usr/local on Intel). Resolve rather than hardcode, or this file is a no-op
# on half the Macs it targets.
brewbin() { for p in "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
    [ -x "$p" ] && { echo "$p"; return; }; done
  command -v "$1" 2>/dev/null || echo "/opt/homebrew/bin/$1"; }

# APPEND rather than replace. Hard-resetting PATH silently overrode a user who
# had put a local-model shim named `claude` earlier on their PATH — precisely
# the person trying to keep the transcript off the network.
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

[ -s "$1" ] || exit 1

exec claude -p "You are writing meeting notes from the raw, unpunctuated local transcript supplied on standard input. It may contain ASR errors; do not invent content you cannot support from the text.

Output ONLY markdown, in exactly this structure:

## Summary
Three sentences maximum.

## Decisions
Bullet list. Only decisions actually reached. Write 'None recorded.' if there are none.

## Action items
Bullet list as '- [ ] owner — task'. Use 'unassigned' when no owner is named. Write 'None recorded.' if there are none.

## Open questions
Bullet list, or 'None recorded.'" < "$1"
