#!/bin/bash
# RAPP Crispy test suite. No microphone and no keyboard needed: speech is
# synthesised with `say`, mixed with noise at a known SNR, and pushed through the
# real pipeline.
#
# Deterministic behaviour is ASSERTED. Recogniser output is stochastic, so ASR
# quality is MEASURED and printed rather than asserted — a suite that asserts on
# model output is a suite that goes red for the wrong reason.
set -uo pipefail


# Homebrew prefix differs by architecture (/opt/homebrew on Apple Silicon,
# /usr/local on Intel). Resolve rather than hardcode, or this file is a no-op
# on half the Macs it targets.
brewbin() { for p in "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
    [ -x "$p" ] && { echo "$p"; return; }; done
  command -v "$1" 2>/dev/null || echo "/opt/homebrew/bin/$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRISPY="$HERE/../crispy"
FF=$(brewbin ffmpeg)
W=/tmp/crispy-test
FIX="$W/fixtures"
ASR_PORT="${ASR_PORT:-8765}"
mkdir -p "$FIX"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
info() { printf '       %s\n' "$*"; }
head_(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }

vol() { $FF -hide_banner -ss "$2" -t "$3" -i "$1" -af volumedetect -f null - 2>&1 \
        | grep mean_volume | sed 's/.*mean_volume: //;s/ dB//'; }

# ------------------------------------------------------------------ fixtures
head_ "Fixtures"
if [ ! -f "$FIX/clean.wav" ]; then
  say -r 175 -o "$FIX/sp.aiff" "the quick brown fox jumps over the lazy dog and then keeps running toward the river"
  $FF -hide_banner -loglevel error -i "$FIX/sp.aiff" -ar 48000 -ac 1 -c:a pcm_s16le -y "$FIX/sp.wav"
  $FF -hide_banner -loglevel error -f lavfi -i anullsrc=r=48000:cl=mono -t 1.5 -c:a pcm_s16le -y "$FIX/sil.wav"
  $FF -hide_banner -loglevel error -i "$FIX/sil.wav" -i "$FIX/sp.wav" -i "$FIX/sil.wav" \
    -filter_complex '[0:a][1:a][2:a]concat=n=3:v=0:a=1' -ar 48000 -ac 1 -c:a pcm_s16le -y "$FIX/clean.wav"
fi
for kind in white pink; do
  [ -f "$FIX/n_$kind.wav" ] || $FF -hide_banner -loglevel error \
    -f lavfi -i "anoisesrc=r=48000:c=$kind:a=0.5:d=12" -ac 1 -c:a pcm_s16le -y "$FIX/n_$kind.wav"
done
if [ ! -f "$FIX/n_babble.wav" ]; then
  for i in 1 2 3 4; do
    say -v Samantha -r $((150+i*20)) -o "$FIX/b$i.aiff" "background chatter about quarterly numbers and lunch plans"
  done
  $FF -hide_banner -loglevel error -i "$FIX/b1.aiff" -i "$FIX/b2.aiff" -i "$FIX/b3.aiff" -i "$FIX/b4.aiff" \
    -filter_complex '[0][1][2][3]amix=inputs=4:duration=longest,volume=3' \
    -ar 48000 -ac 1 -c:a pcm_s16le -y "$FIX/n_babble.wav"
fi
speech_rms=$(vol "$FIX/clean.wav" 1.6 2.5)
info "clean speech $(printf '%.1f' "$speech_rms") dB; noise beds: white pink babble"
[ -n "$speech_rms" ] && ok "fixtures built" || bad "fixture build failed"

mix() { # mix <noise> <snr> <out>
  local nrms gain; nrms=$(vol "$1" 0 5)
  gain=$(python3 -c "print(f'{($speech_rms - $2) - ($nrms):.2f}')")
  $FF -hide_banner -loglevel error -i "$FIX/clean.wav" -i "$1" \
    -filter_complex "[1:a]volume=${gain}dB,atrim=0:8[n];[0:a][n]amix=inputs=2:duration=first:normalize=0" \
    -ar 48000 -ac 1 -c:a pcm_s16le -y "$3"
}

# -------------------------------------------------------------------- doctor
head_ "0. Environment"
doc=$("$CRISPY" doctor 2>&1)
case "$doc" in *"arnndn filter present"*) ok "arnndn detected" ;; *) bad "arnndn not detected" ;; esac
case "$doc" in
  *[Kk]risp*|*[Bb]lack[Hh]ole*|*[Ll]oopback*) bad "capture device is virtual — would measure another denoiser" ;;
  *"capture device"*) ok "capture device is real hardware, not a virtual device" ;;
  *) bad "no capture device found" ;;
esac

# ------------------------------------------------------------------- denoise
head_ "1. Denoise quality (asserted floors, measured values)"
for spec in "white 0 20" "pink 0 5"; do
  read -r kind snr floor <<< "$spec"
  mix "$FIX/n_$kind.wav" "$snr" "$W/noisy_$kind.wav"
  gin=$(vol "$W/noisy_$kind.wav" 0 1.4)
  out=$("$CRISPY" denoise "$W/noisy_$kind.wav" "$W/den_$kind.wav" 2>/dev/null | tail -1)
  gout=$(vol "$W/den_$kind.wav" 0 1.4)
  red=$(python3 -c "print(f'{$gin - ($gout):.1f}')")
  spd=$(python3 -c "print(f'{$(vol "$W/den_$kind.wav" 1.6 2.5) - ($(vol "$W/noisy_$kind.wav" 1.6 2.5)):+.1f}')")
  info "$kind @ ${snr}dB SNR: noise floor $red dB quieter, speech $spd dB"
  python3 -c "import sys; sys.exit(0 if $red >= $floor else 1)" \
    && ok "$kind noise reduced >= ${floor}dB (got $red)" || bad "$kind reduced only $red dB (floor ${floor})"
done
# Babble is RNNoise's known weakness. Measure it, print it, do not claim it.
mix "$FIX/n_babble.wav" 0 "$W/noisy_babble.wav"
gin=$(vol "$W/noisy_babble.wav" 0 1.4)
"$CRISPY" denoise "$W/noisy_babble.wav" "$W/den_babble.wav" >/dev/null 2>&1
gout=$(vol "$W/den_babble.wav" 0 1.4)
bred=$(python3 -c "print(f'{$gin - ($gout):.1f}')")
info "babble @ 0dB SNR: $bred dB — KNOWN LIMITATION, RNNoise targets non-voice noise"
python3 -c "import sys; sys.exit(0 if $bred >= 0 else 1)" \
  && ok "babble does not make things worse ($bred dB)" || bad "babble path degraded the signal ($bred dB)"

head_ "1b. DeepFilterNet3 (offline engine)"
DF="$HOME/.rappcrispy/bin/deep-filter"
if [ -x "$DF" ]; then
  ok "deep-filter present"
  eng=$("$CRISPY" denoise "$W/noisy_white.wav" "$W/dfn_white.wav" 2>/dev/null | grep -o 'engine=[a-z]*' | cut -d= -f2)
  [ "$eng" = dfn ] && ok "auto-selects DFN3 when present" || bad "selected engine=$eng"
  gin=$(vol "$W/noisy_white.wav" 0 1.4); gout=$(vol "$W/dfn_white.wav" 0 1.4)
  red=$(python3 -c "print(f'{$gin - ($gout):.1f}')")
  info "DFN3 white @0dB: $red dB (RNNoise got ~28)"
  python3 -c "import sys; sys.exit(0 if $red >= 35 else 1)" \
    && ok "DFN3 beats RNNoise on steady noise ($red dB >= 35)" || bad "DFN3 only $red dB"
  eng=$(ENGINE=rnnoise "$CRISPY" denoise "$W/noisy_white.wav" "$W/forced.wav" 2>/dev/null | grep -o 'engine=[a-z]*' | cut -d= -f2)
  [ "$eng" = rnnoise ] && ok "ENGINE=rnnoise forces the old engine" || bad "override gave engine=$eng"
else
  info "SKIP: deep-filter not installed (install.sh fetches it)"
fi

head_ "1c. Babble is NOT solved by either engine (guards against overclaiming)"
# Asserting the LIMIT keeps a future change from silently claiming babble works.
mix "$FIX/n_babble.wav" 0 "$W/nb.wav"
gin=$(vol "$W/nb.wav" 0 1.4)
"$CRISPY" denoise "$W/nb.wav" "$W/nb_out.wav" >/dev/null 2>&1
red=$(python3 -c "print(f'{$gin - ($(vol "$W/nb_out.wav" 0 1.4)):.1f}')")
info "babble @0dB: $red dB — target-speaker extraction is what would fix this"
python3 -c "import sys; sys.exit(0 if $red < 15 else 1)" \
  && ok "babble still unsolved ($red dB) — README claim matches reality" \
  || bad "babble now $red dB: the README understates the product, update it"

head_ "2. Real-time capability"
rtf=$("$CRISPY" denoise "$W/noisy_white.wav" "$W/rtf.wav" 2>/dev/null | grep -o 'RTF=[0-9.]*' | cut -d= -f2)
info "RTF $rtf (processed seconds per second of audio)"
python3 -c "import sys; sys.exit(0 if $rtf < 0.1 else 1)" \
  && ok "RTF $rtf < 0.1 — comfortably real-time" || bad "RTF $rtf too slow for live use"

# ---------------------------------------------------------------- dictionary
head_ "3. Dictionary enforcement (deterministic — asserted)"
FIXER="$HERE/dictfix.py"
printf 'OpenRappter\nKody Wildflower\nC++\nF#\nGPT-4\nOpen Raptor => OpenRappter\n' > "$W/dict.txt"
d() { printf '%s' "$1" | python3 "$FIXER" "$W/dict.txt"; }
r=$(d "openrappter is shipping");         [ "$r" = "OpenRappter is shipping" ] && ok "canonical casing: $r" || bad "got: $r"
r=$(d "we use open raptor daily");        [ "$r" = "we use OpenRappter daily" ] && ok "homophone rewrite: $r" || bad "got: $r"
r=$(d "i write c++ and f# and gpt-4");    [ "$r" = "i write C++ and F# and GPT-4" ] && ok "punctuation/digit terms: $r" || bad "got: $r"
r=$(d "a velociraptor is not a term");    [ "$r" = "a velociraptor is not a term" ] && ok "no match inside a larger word" || bad "false positive: $r"
r=$(printf 'unchanged text' | python3 "$FIXER" /nonexistent-dict); [ "$r" = "unchanged text" ] && ok "missing dictionary passes text through" || bad "got: $r"

# ---------------------------------------------------------------- transcribe
head_ "4. Local transcription (measured)"
code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$ASR_PORT/" 2>/dev/null)
if [ "${code:-000}" = "000" ]; then
  bad "no ASR on :$ASR_PORT — cannot test transcription"
else
  ok "local ASR answering on :$ASR_PORT"
  txt=$("$CRISPY" transcribe "$W/den_white.wav" 2>/dev/null)
  info "transcript: \"$(echo "$txt" | tr -d '\n' | cut -c1-72)\""
  case "$(echo "$txt" | tr 'A-Z' 'a-z')" in
    *"quick brown fox"*) ok "recovered the reference phrase from noisy audio" ;;
    *) bad "reference phrase not recovered" ;;
  esac
fi

# --------------------------------------------------------------------- notes
head_ "5. Notes hook"
HOOK="$HOME/.rappcrispy/hooks/notes.sh"
if [ -x "$HOOK" ] && { command -v claude >/dev/null || [ -x "$HOME/.local/bin/claude" ]; }; then
  cat > "$W/transcript.txt" <<'T'
okay so the decision is we ship the offline path first and gate the audio driver
action item claude will write the test suite before we push
open question do we need speaker labels for multi party calls
T
  if "$HOOK" "$W/transcript.txt" > "$W/notes.md" 2>"$W/notes.err"; then
    ok "hook produced notes.md"
    for h in "## Summary" "## Decisions" "## Action items" "## Open questions"; do
      grep -q "$h" "$W/notes.md" && ok "section present: $h" || bad "missing section: $h"
    done
    grep -qi 'test suite' "$W/notes.md" && ok "action item carried through" || bad "action item lost"
  else
    bad "notes hook failed: $(head -1 "$W/notes.err")"
  fi
else
  info "SKIP: no notes hook or no claude CLI"
fi

# ------------------------------------------------------------ meeting layout
head_ "5c. Live virtual microphone"
lv=$("$CRISPY" live status 2>&1)
case "$lv" in
  *"loopback sink available"*) ok "found a loopback device without installing anything" ;;
  *"no loopback device"*) info "SKIP: no loopback device on this machine" ;;
  *) bad "live status unexpected" ;;
esac
case "$("$CRISPY" live install 2>&1)" in
  *"nothing to install"*)        ok "live install reports nothing to do" ;;
  *"administrator password"*)    ok "live install explains the driver route without running it" ;;
  *) bad "live install output unexpected" ;;
esac
# the chain must be two processes joined by a pipe — one process is the bug
grep -q 'f wav -c:a pcm_s16le - \\' "$CRISPY" && ok "live chain is a two-process pipe" \
  || bad "live chain is not piped — single-process yields unintelligible audio"
# match the FLAG, not the comment that explains why it was removed
grep -vE '^\s*#' "$CRISPY" | grep -q -- '-flags low_delay' \
  && bad "low_delay flag is back in the chain (cost 12dB)" \
  || ok "no low_delay flag in the live chain"

head_ "6. Meeting on disk (ownership)"
MEET="$HOME/.rappcrispy/meetings"
latest=$(ls -td "$MEET"/*/ 2>/dev/null | head -1)
if [ -n "$latest" ]; then
  ok "meetings stored locally under $MEET"
  for f in mic.wav device.txt; do
    [ -f "$latest$f" ] && ok "$f present in $(basename "$latest")" || bad "$f missing"
  done
  dev=$(cat "$latest/device.txt" 2>/dev/null)
  case "$dev" in *[Kk]risp*|*[Bb]lack[Hh]ole*) bad "recorded through a virtual device: $dev" ;; *) ok "recorded from $dev" ;; esac
else
  info "SKIP: no meetings recorded yet (crispy run --seconds 16)"
fi

head_ "7. Parity — no fact stated twice and differing"
if bash "$HERE/parity.sh" >/tmp/crispy-parity.out 2>&1; then
  while IFS= read -r l; do case "$l" in *PASS*) ok "${l#*PASS }" ;; esac; done < /tmp/crispy-parity.out
else
  while IFS= read -r l; do case "$l" in *FAIL*) bad "${l#*FAIL }" ;; esac; done < /tmp/crispy-parity.out
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
cat <<'GATED'

NOT covered here — needs a consequential step you must approve:
  live virtual microphone (denoise inside Zoom/Teams/Meet) requires installing a
  CoreAudio driver, and far-end audio capture requires the same. See README.
GATED
[ "$fail" -eq 0 ]
