#!/bin/bash
# RAPP Crispy installer — idempotent. Safe to re-run.
set -euo pipefail

# Homebrew prefix differs by architecture (/opt/homebrew on Apple Silicon,
# /usr/local on Intel). Resolve rather than hardcode, or this file is a no-op
# on half the Macs it targets.
brewbin() { for p in "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
    [ -x "$p" ] && { echo "$p"; return; }; done
  command -v "$1" 2>/dev/null || echo "/opt/homebrew/bin/$1"; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CH="$HOME/.rappcrispy"
RNNOISE_COMMIT="3eee541a283fd3b8f81b85b1748e3b9ccbefa04d"
MODELS_URL="https://raw.githubusercontent.com/GregorR/rnnoise-models/$RNNOISE_COMMIT"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[33m!\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31mfatal:\033[0m %s\n' "$*" >&2; exit 1; }
sha256(){ /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }
verify_file(){
  local path="$1" bytes="$2" expected="$3"
  [ -f "$path" ] && [ ! -L "$path" ] && [ "$(stat -f%z "$path")" = "$bytes" ] \
    && [ "$(sha256 "$path")" = "$expected" ]
}
download_verified(){
  local url="$1" destination="$2" bytes="$3" digest="$4" label="$5"
  local partial="$destination.part"
  rm -f "$partial"
  curl -sL --fail -o "$partial" "$url" || { rm -f "$partial"; return 1; }
  verify_file "$partial" "$bytes" "$digest" \
    || { rm -f "$partial"; return 1; }
  mv "$partial" "$destination"
  ok "$label verified"
}

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
for m in \
  "bd|beguiling-drafter-2018-08-30|299693|ae3f7411e1e6a884f839a4a145c394408398f09854dbc1216ee02faafc98a17b" \
  "cb|conjoined-burgers-2018-08-28|299741|f1357c4e5be9dee8467bead486dfced2d75b640c26ad0b594fa7f102322371d9" \
  "sh|somnolent-hogwash-2018-09-01|297646|70bb6685eb0c2a1d18e2918dca3fbfbd39317010b1802eb1b6ea73a92f3fdec0" \
  "mp|marathon-prescription-2018-08-29|296861|4e84a448a4baf937992aaf4d10c8258007ec5d24219b6647dfd5fb4b563ad231" \
  "lq|leavened-quisling-2018-08-31|297041|1957528b752799fddf06270bc5469af7cf54c3badc358544ae2abed730943ff9"; do
  IFS='|' read -r n d bytes digest <<< "$m"
  destination="$CH/models/$n.rnnn"
  if [ -e "$destination" ]; then
    verify_file "$destination" "$bytes" "$digest" \
      && ok "$n.rnnn verified" \
      || die "$n.rnnn already exists but does not match its pinned bytes; preserved unchanged at $destination"
  elif ! download_verified "$MODELS_URL/$d/$n.rnnn" "$destination" "$bytes" "$digest" "$n.rnnn"; then
    warn "failed to download and verify $n.rnnn; other verified models remain usable"
  fi
done

say "DeepFilterNet3 (offline denoise engine)"
DF="$CH/bin/deep-filter"
mkdir -p "$CH/bin"
ARCH=$(uname -m)
case "$ARCH" in
  arm64)
    T=aarch64-apple-darwin
    DF_BYTES=27877081
    DF_SHA=4601e7f4e4c03e59a4c5b5000216ef3add3e808799cfccd95e14e83ea4611081
    ;;
  x86_64)
    T=x86_64-apple-darwin
    DF_BYTES=29933512
    DF_SHA=d3be84003acb7c23e738ad7f70a158ec779a8d233a82e7fa3e717d112eb5b50f
    ;;
  *) die "unsupported architecture for the pinned DeepFilterNet binary: $ARCH" ;;
esac
if [ -e "$DF" ]; then
  verify_file "$DF" "$DF_BYTES" "$DF_SHA" \
    || die "existing deep-filter does not match its pinned bytes; preserved unchanged at $DF"
  chmod 700 "$DF"
  ok "deep-filter 0.5.6 ($T) verified"
else
  if download_verified \
    "https://github.com/Rikorose/DeepFilterNet/releases/download/v0.5.6/deep-filter-0.5.6-$T" \
    "$DF" "$DF_BYTES" "$DF_SHA" "deep-filter 0.5.6 ($T)"; then
    chmod 700 "$DF"
    ok "normal macOS quarantine/Gatekeeper behavior was preserved"
  else
    warn "deep-filter download failed verification; RNNoise remains available"
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

 Everything stays in ~/.rappcrispy/meetings/ unless you explicitly authorize
 a notes provider with CRISPY_NOTES_CONSENT=1. The example notes hook calls
 'claude -p' and sends transcripts to Anthropic. Notes are disabled by default.
 The native .app does not need this developer/CLI installer.
============================================================
PERMS
