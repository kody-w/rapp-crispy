# RAPP Crispy

A local-first meeting stack for macOS. Record a meeting, clean up the audio,
transcribe it, and get notes with decisions and action items — **entirely on your
own machine.** No account, no upload, no retention policy to read.

The files land in `~/.rappcrispy/meetings/<timestamp>/` and stay there.

```
mic (real hardware)  ──►  RNNoise denoise      (ffmpeg arnndn, on-device)
screen (optional)    ──►  screen.mov           (screencapture, on-device)
                     ──►  whisper.cpp ASR      (localhost, on-device)
                     ──►  notes hook           (claude -p or Ollama, your choice)
                     ──►  ~/.rappcrispy/meetings/<ts>/
```

---

## Why this exists

The incumbent in this category processes **noise cancellation on-device** — that
part is genuinely local and good. But its meeting assistant is not: recordings
and transcripts are stored server-side in AWS, and audio is transmitted to the
vendor's cloud for transcription.

So the audio filtering was never the thing you didn't own. **Your meeting content
was.** RAPP Crispy takes that half back first, because that is the half that
leaves your machine.

---

## Install

```bash
git clone https://github.com/kody-w/rapp-crispy.git
cd rapp-crispy
./install.sh
```

Needs `ffmpeg` (for `arnndn`) and a local whisper.cpp server. If you already run
[RAPP Voice](https://github.com/kody-w/rapp-voice), you already have the ASR
server and the personal dictionary — Crispy reuses both.

---

## Use

```bash
crispy doctor                        # environment check
crispy run --seconds 900 --name standup   # record, denoise, transcribe, notes
crispy run --screen --name demo           # ...and capture the screen
crispy record                        # open-ended; ENTER stops it
crispy notes ~/.rappcrispy/meetings/<ts>  # (re)generate notes for a meeting
crispy list                          # what you have on disk
crispy bench                         # measured denoise quality, all 5 models
```

`crispy run` with no `--seconds` records until you press ENTER.

Output per meeting:

| File | What |
|---|---|
| `mic.wav` | raw capture, 48kHz mono |
| `mic.denoised.wav` | after RNNoise |
| `screen.mov` | screen video, only with `--screen` |
| `transcript.txt` | local ASR, personal dictionary applied |
| `notes.md` | Summary / Decisions / Action items / Open questions |
| `device.txt` | which microphone it actually used |

---

## Measured denoise performance

Not claims — `crispy bench` reproduces this. Fixtures are synthesised speech
mixed with noise at a known SNR; the score is how much quieter the non-speech
gaps get, and how much of the talker survives.

| Noise @ 0dB SNR | Noise floor reduction | Speech cost |
|---|---|---|
| white | **+26 to +28 dB** | −3.9 dB |
| pink | +15 to +16 dB | −3.9 dB |
| **babble (other voices)** | **+3.2 dB** | −5 to −13 dB |

**RTF 0.014** — 70× faster than real time on an M4, so compute is not the
constraint for live use.

### The honest gap

RNNoise is built to separate *voice from non-voice*. Babble is voice, so it
barely moves — and what little it removes costs more speech than noise. The
incumbent's "Background Voice Cancellation" is a different model class
(documented at 32kHz, no voice enrollment) and it is genuinely better at this.

If you need babble suppression, the path is DeepFilterNet3, which needs a Rust
toolchain to build (`deepfilterlib` has no wheel for Python 3.14). That is not
wired up here. **Do not demo this against a coffee-shop background and expect to
win.** Stationary noise — fans, traffic, keyboards, HVAC — it handles well.

---

## Personal dictionary

If `~/.rappvoice/dictionary.txt` exists, Crispy uses it two ways:

1. **Bias** — every term is fed to the recogniser as a weighted decoding prompt
   (each term twice, which is what makes invented words survive).
2. **Enforcement** — canonical spelling is applied to the transcript afterwards,
   including `heard => Term` rewrite lines.

Measured effect on "Kody owns the OpenRappter transcript":

```
no dictionary        Cody owns the OpenRaptor transcript.
bias + enforcement   Kody owns the OpenRapter transcript.
```

`Kody` lands reliably. A word that is a **homophone of a real word** may still
need a rewrite rule per mis-hearing you observe — and the mis-hearing shifts with
prompt context, so one rule is not always enough. There is deliberately no fuzzy
matching: it would corrupt genuine uses of the real word.

Point Crispy at a different dictionary with `CRISPY_DICT=/path/to/dict.txt`.

---

## Notes hook

`~/.rappcrispy/hooks/notes.sh` takes a transcript path as `$1` and prints
markdown. The shipped hook uses `claude -p`. For fully offline notes:

```bash
#!/bin/bash
ollama run llama3.1 "Write meeting notes with Summary, Decisions, Action items,
Open questions. Only what the transcript supports: $(cat "$1")"
```

The prompt tells the model not to invent content the transcript cannot support —
worth keeping, since ASR errors otherwise become confident fiction.

---

## What is NOT built (and why)

**Live virtual microphone** — denoising *inside* Zoom/Teams/Meet needs a
CoreAudio driver presenting a virtual input device, so apps can select it. The
incumbent ships `KrispAudio.driver` for exactly this. Compute is not the blocker
(RTF 0.014); the blocker is that installing an audio driver is a consequential,
sudo-level change to your system's audio routing. The route is BlackHole as the
loopback transport, mic → `arnndn` → BlackHole → app.

**Far-end audio capture** — recording the *other* people needs the same loopback
device. `screencapture -G` captures an *input* device, not system output, so
today Crispy records your side well and the room's side only through your mic.
This is the single biggest functional gap versus a cloud meeting assistant.

**Accent conversion** — no local model. Not attempted.

---

## Config

Environment variables, all optional:

| Var | Default | Meaning |
|---|---|---|
| `CRISPY_HOME` | `~/.rappcrispy` | state directory |
| `CRISPY_MIC` | auto | avfoundation input index; auto-pick prefers real hardware over virtual devices |
| `CRISPY_DICT` | `~/.rappvoice/dictionary.txt` | personal dictionary |
| `RNN_MODEL` | `cb` | one of `bd cb sh mp lq` — see `crispy bench` |
| `ASR_PORT` | `8765` | local whisper-server port |
| `CHUNK_SECONDS` | `300` | transcription chunk size |

Auto mic selection deliberately skips virtual devices. On a machine with the
incumbent installed, its virtual mic is often input `[0]` — capturing through it
would mean measuring *their* denoiser instead of ours.

---

## Tests

```bash
./tools/dryrun.sh
```

24 assertions, no microphone and no keyboard needed. Deterministic behaviour is
asserted (denoise floors, RTF, dictionary enforcement, notes structure, that the
capture device is real hardware). Recogniser output is **measured and printed,
not asserted** — a suite that asserts on model output goes red for the wrong
reason.

MIT.
