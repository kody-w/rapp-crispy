# RAPP Crispy

A local-first meeting stack, packaged as a rapplication. Record a meeting, strip
the background noise, transcribe it, and get notes — **entirely on the machine the
brainstem runs on.**

Recordings, transcripts and notes are plain files under
`~/.rappcrispy/meetings/<timestamp>/`. Recording, denoising and transcription
never leave this machine. Note-writing goes through `~/.rappcrispy/hooks/notes.sh`,
and the hook shipped as the default calls `claude -p` — so the transcript is sent
to Anthropic unless you repoint that hook at a local model.

```
mic (real hardware)  ──►  RNNoise denoise   ffmpeg arnndn, on-device
screen (optional)    ──►  screen.mov        screencapture, on-device
                     ──►  whisper.cpp       127.0.0.1, on-device
                     ──►  notes hook        any local model you point it at
                     ──►  ~/.rappcrispy/meetings/<ts>/
```

## Why local matters here

Commercial tools in this category already run their **noise cancellation**
on-device — that part was never the problem. What leaves your machine is the
*meeting content*: recordings and transcripts stored server-side, audio
transmitted out for transcription. RAPP Crispy takes that half back, which is the
half that determines whether you can point it at a conversation you are not
permitted to send to a vendor.

## Actions

| Action | What it does |
|---|---|
| `doctor` | environment check — ffmpeg, arnndn, mic, ASR, models, hook |
| `run` | record → denoise → transcribe → notes (needs `seconds`) |
| `record` | capture only (needs `seconds`; add `screen: true` for video) |
| `denoise` | RNNoise a wav at `path` |
| `transcribe` | local ASR on a wav at `path` |
| `notes` | transcript + summary for a `meeting` id |
| `list` | meetings on disk, as JSON |
| `read` | notes and transcript for a `meeting` |
| `bench` | reproduce the denoise numbers on your own hardware |
| `live_status` | live virtual microphone state and what it needs |

Headless use requires `seconds` — there is no keypress to stop a recording.

```json
{ "action": "run", "seconds": 600, "name": "standup" }
```

## Requirements

- **ffmpeg** with the `arnndn` filter (`brew install ffmpeg`)
- **a local whisper.cpp server** on `127.0.0.1:8765`:
  `whisper-server -m ggml-small.en.bin --host 127.0.0.1 --port 8765 -l en`
- **RNNoise model files** in `~/.rappcrispy/models/*.rnnn`
- optional: a notes hook at `~/.rappcrispy/hooks/notes.sh` taking a transcript
  path as `$1` and printing markdown. Without it you still get transcripts.

## Measured denoise performance

Reproduce with `action: "bench"`. Do not take these on faith.

| Noise @ 0dB SNR | Noise floor reduction | Speech cost |
|---|---|---|
| white | **−26 to −28 dB** | −3.9 dB |
| pink | −15 dB | −3.9 dB |
| **babble (other voices)** | **−3.2 dB** | −5 to −13 dB |

**Real-time factor 0.014** on an Apple M4 — 70× faster than real time.

### The honest gap

RNNoise separates *voice from non-voice*. Babble is voice, so it barely moves —
and what little it removes costs more speech than noise. **Do not demo this
against a café background.** Fans, traffic, keyboards and HVAC it handles well.
Beating babble needs a different model class (DeepFilterNet-style), which is not
wired up here.

## Not built

- **Live denoise inside a call.** Needs a loopback CoreAudio device so meeting
  apps can select it as their microphone. Installing an audio driver changes
  system audio routing and requires an administrator password, so it is never
  automated. Compute is not the blocker — RTF is 0.014.
- **Far-end audio capture.** Needs the same loopback device. Without it, your side
  is captured well and the room only through your microphone. This is the biggest
  functional gap versus a cloud meeting assistant.
- **Accent conversion.** No local model. Not attempted.

## Personal vocabulary (optional)

`~/.rappcrispy/dictionary.txt`, one term per line. Terms are fed to the recogniser
as a weighted decoding prompt (each term twice, which is what makes invented words
survive) and the canonical spelling is enforced on the transcript afterwards.

```
Kubernetes
PostgreSQL
# for an invented word that is a homophone of a real one:
whatever it heard => What you meant
```

Biasing alone will not fix a true homophone, and the mis-hearing shifts with
context — so a rewrite line is per-mis-hearing. There is deliberately no fuzzy
matching: it would corrupt genuine uses of the real word.

MIT.
