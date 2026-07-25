#!/bin/bash
# RAPP Crispy notes hook.
#   $1 = path to transcript.txt
#   stdout = markdown meeting notes
#
# Swap the body for a fully offline model, e.g.:
#   ollama run llama3.1 "$(cat prompt)"
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

transcript="$(cat "$1")"
[ -n "$transcript" ] || exit 1

claude -p "You are writing meeting notes from a raw, unpunctuated local transcript. It may contain ASR errors; do not invent content you cannot support from the text.

Output ONLY markdown, in exactly this structure:

## Summary
Three sentences maximum.

## Decisions
Bullet list. Only decisions actually reached. Write 'None recorded.' if there are none.

## Action items
Bullet list as '- [ ] owner — task'. Use 'unassigned' when no owner is named. Write 'None recorded.' if there are none.

## Open questions
Bullet list, or 'None recorded.'

Transcript:
$transcript"
