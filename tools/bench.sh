#!/bin/bash
# RAPP Crispy bench: mix speech with noise at a known SNR, denoise, and score.
#   noise floor reduction  = how much quieter the non-speech gaps get (what you hear)
#   speech retention       = how much of the talker survives (guards against muting everything)
#   RTF                    = processed seconds per second of audio; must be < 1 to run live
set -uo pipefail
FF=/opt/homebrew/bin/ffmpeg
FIX=/tmp/crispy/fixtures
M=/tmp/crispy
LEAD_T=1.4          # lead-in silence region
SPEECH_SS=1.6       # speech region
SPEECH_T=2.5

vol() { # vol <file> <ss> <t>  -> mean dB
  $FF -hide_banner -ss "$2" -t "$3" -i "$1" -af volumedetect -f null - 2>&1 \
    | grep mean_volume | sed 's/.*mean_volume: //;s/ dB//'
}

speech_rms=$(vol "$FIX/clean.wav" $SPEECH_SS $SPEECH_T)

mix() { # mix <noisefile> <target_snr_db> <out>
  local nrms; nrms=$(vol "$1" 0 5)
  # gain so that during speech, speech_rms - noise_rms == target SNR
  local gain; gain=$(python3 -c "print(f'{($speech_rms - $2) - ($nrms):.2f}')")
  $FF -hide_banner -loglevel error -i "$FIX/clean.wav" -i "$1" \
    -filter_complex "[1:a]volume=${gain}dB,atrim=0:8[n];[0:a][n]amix=inputs=2:duration=first:normalize=0" \
    -ar 48000 -ac 1 -c:a pcm_s16le -y "$3"
}

printf '%-9s %-7s %-6s  %8s %8s  %9s %9s  %7s\n' \
  NOISE SNRin MODEL "gap_in" "gap_out" "REDUCED" "speech_d" "RTF"
for noise in white pink babble; do
  for snr in 0 5; do
    noisy="$M/noisy_${noise}_${snr}.wav"
    mix "$FIX/n_${noise}.wav" "$snr" "$noisy"
    gap_in=$(vol "$noisy" 0 $LEAD_T)
    sp_in=$(vol "$noisy" $SPEECH_SS $SPEECH_T)
    for model in bd sh mp cb lq; do
      out="$M/den_${noise}_${snr}_${model}.wav"
      t0=$(python3 -c 'import time;print(time.time())')
      $FF -hide_banner -loglevel error -i "$noisy" -af "arnndn=m=$M/${model}.rnnn" \
        -ar 48000 -ac 1 -c:a pcm_s16le -y "$out" 2>/dev/null
      t1=$(python3 -c 'import time;print(time.time())')
      dur=$(python3 -c "import wave;w=wave.open('$noisy');print(w.getnframes()/w.getframerate())")
      rtf=$(python3 -c "print(f'{($t1-$t0)/$dur:.3f}')")
      gap_out=$(vol "$out" 0 $LEAD_T)
      sp_out=$(vol "$out" $SPEECH_SS $SPEECH_T)
      red=$(python3 -c "print(f'{$gap_in - ($gap_out):+.1f}')")
      spd=$(python3 -c "print(f'{($sp_out) - ($sp_in):+.1f}')")
      printf '%-9s %-7s %-6s  %8s %8s  %9s %9s  %7s\n' \
        "$noise" "${snr}dB" "$model" "$gap_in" "$gap_out" "$red" "$spd" "$rtf"
    done
  done
done
