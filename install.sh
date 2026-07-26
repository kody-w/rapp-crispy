#!/bin/bash
# RAPP Crispy installer — idempotent. Safe to re-run.
set -uo pipefail

# Homebrew prefix differs by architecture (/opt/homebrew on Apple Silicon,
# /usr/local on Intel). Resolve rather than hardcode, or this file is a no-op
# on half the Macs it targets.
brewbin() { for p in "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
    [ -x "$p" ] && { echo "$p"; return; }; done
  command -v "$1" 2>/dev/null || echo "/opt/homebrew/bin/$1"; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CH="$HOME/.rappcrispy"
MODELS_URL="https://raw.githubusercontent.com/GregorR/rnnoise-models/master"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[33m!\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31mfatal:\033[0m %s\n' "$*" >&2; exit 1; }

command -v brew >/dev/null || die "Homebrew required: https://brew.sh"
say "Dependencies"
if brew list --versions ffmpeg >/dev/null 2>&1; then ok "ffmpeg $(brew list --versions ffmpeg | awk '{print $2}')"
else say "installing ffmpeg"; brew install ffmpeg || die "brew install ffmpeg failed"; fi
filters=$($(brewbin ffmpeg) -hide_banner -filters 2>/dev/null)
case "$filters" in *arnndn*) ok "arnndn filter available" ;; *) die "this ffmpeg lacks arnndn" ;; esac
if brew list --versions whisper-cpp >/dev/null 2>&1; then ok "whisper-cpp $(brew list --versions whisper-cpp | awk '{print $2}')"
else say "installing whisper-cpp"; brew install whisper-cpp || die "brew install whisper-cpp failed"; fi

say "Directories"
mkdir -p "$CH"/{models,meetings,hooks,logs}
ok "$CH/{models,meetings,hooks,logs}"

say "Denoise models"
for m in bd:beguiling-drafter-2018-08-30 cb:conjoined-burgers-2018-08-28 sh:somnolent-hogwash-2018-09-01 mp:marathon-prescription-2018-08-29 lq:leavened-quisling-2018-08-31; do
  n=${m%%:*}; d=${m##*:}
  if [ -s "$CH/models/$n.rnnn" ]; then ok "$n.rnnn present"
  else curl -sL --fail -o "$CH/models/$n.rnnn" "$MODELS_URL/$d/$n.rnnn" \
       && ok "$n.rnnn $(stat -f%z "$CH/models/$n.rnnn") bytes" || warn "failed to fetch $n.rnnn"; fi
done

say "DeepFilterNet3 (offline denoise engine)"
DF="$CH/bin/deep-filter"
mkdir -p "$CH/bin"
if [ -x "$DF" ]; then ok "deep-filter present"
else
  ARCH=$(uname -m); case "$ARCH" in arm64) T=aarch64-apple-darwin ;; *) T=x86_64-apple-darwin ;; esac
  if curl -sL --fail -o "$DF" "https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-$T"; then
    chmod +x "$DF"; xattr -d com.apple.quarantine "$DF" 2>/dev/null || true
    ok "deep-filter installed ($(du -h "$DF" | cut -f1), $T)"
  else
    warn "could not fetch deep-filter — RNNoise still works, ~14dB weaker on steady noise"
  fi
fi

say "Notes hook"
if [ -f "$CH/hooks/notes.sh" ]; then ok "hooks/notes.sh kept (yours)"
else cp "$SRC/hooks-notes.sh" "$CH/hooks/notes.sh"; ok "hooks/notes.sh installed"; fi
chmod +x "$CH/hooks/notes.sh"

say "Speech server"
PORT=8765
MODEL="$HOME/.rappvoice/models/ggml-small.en.bin"
[ -f "$MODEL" ] || MODEL="$CH/models/ggml-small.en.bin"
if pgrep -f "whisper-server .*--port $PORT" >/dev/null; then ok "whisper-server already on $PORT"
elif [ -f "$MODEL" ]; then
  nohup $(brewbin whisper-server) -m "$MODEL" --host 127.0.0.1 --port "$PORT" -l en -t 4 \
    >> "$CH/logs/whisper-server.log" 2>&1 &
  for _ in $(seq 1 60); do sleep 0.5
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)
    [ "${code:-000}" != "000" ] && break; done
  [ "${code:-000}" != "000" ] && ok "whisper-server up on $PORT" || warn "server did not answer"
else
  warn "no whisper model found. Install RAPP Voice, or:"
  echo "      curl -L -o $CH/models/ggml-small.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
fi

say "CLI"
mkdir -p "$HOME/.local/bin"
ln -sfn "$SRC/crispy" "$HOME/.local/bin/crispy"
ok "$HOME/.local/bin/crispy -> $SRC/crispy"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "add ~/.local/bin to PATH" ;; esac

cat <<'PERMS'

============================================================
 RAPP Crispy installed.
============================================================
 PERMISSIONS
  Microphone      — first `crispy record` prompts your terminal. Approve it.
  Screen Recording — only needed for `--screen`. System Settings >
                     Privacy & Security > Screen Recording.

 TRY IT
  crispy doctor
  crispy run --seconds 30 --name test
  crispy list

 Everything stays in ~/.rappcrispy/meetings/. One exception: the default
 notes hook (~/.rappcrispy/hooks/notes.sh) calls 'claude -p', which sends the
 transcript to Anthropic. Replace or delete it to keep everything offline.
============================================================
PERMS
