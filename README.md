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

Two engines ship. `crispy bench` reproduces all of this on your own hardware.

| Noise @ 0dB SNR | RNNoise | **DeepFilterNet3** |
|---|---|---|
| white | +28.1 dB | **+42.5 dB** |
| pink | +15.8 dB | **+36.6 dB** |
| **babble (other voices)** | +4.2 dB | +4.5 dB |
| real-time factor | 0.014 | 0.048 |

DFN3 is the default for recorded audio — 14 dB better on steady noise, still 20x
real time. **Live denoise is always RNNoise**, because `deep-filter` is
file-to-file with no streaming mode.

### The honest gap: background voices

Neither engine cancels background *voices*, and DFN3 does not rescue it. Measured
as word-error-rate on the target talker in babble at 0 dB SNR:

| | WER |
|---|---|
| untouched | 19% |
| RNNoise | 19% |
| DFN3 | 31% |
| DFN3 + `--pf` post-filter | 50% |

DFN3's large dB number on babble is **over-attenuation eating the talker** — which
is why the post-filter is not shipped. Both engines separate voice from non-voice;
babble is voice. Cancelling it needs target-speaker extraction — deciding which
voice is yours — a different model class, not available as a drop-in local binary.
Commercial "background voice cancellation" is genuinely better at this.

**Do not demo this against a coffee shop.** Fans, traffic, keyboards, HVAC: handled
very well.

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

## Live virtual microphone — working

`crispy live start` puts a denoised microphone in front of Zoom/Teams/Meet: select
the loopback device it names as your mic.

```
crispy live status     # what it found
crispy live start      # mic -> RNNoise -> loopback
crispy live stop
```

It needs a *loopback* CoreAudio device — one presenting both an output and an
input. A dedicated one (BlackHole) needs an administrator password, **but most
machines already have a loopback installed by a conferencing app**, and `crispy
live` uses whichever is present. On this machine that meant nothing to install.

Two implementation notes, both learned the hard way:

- **Two ffmpeg processes, not one.** Piping an avfoundation capture straight into
  the audiotoolbox output device gives audio at a plausible level that is not
  intelligible: `mic -> file` transcribes perfectly, the same chain `mic -> device`
  yields `[BLANK_AUDIO]`. A file-like input to audiotoolbox works, so a wav pipe
  between two processes decouples the capture clock from the playback clock.
- **No `-fflags nobuffer` / `-flags low_delay`.** Measured against this exact
  chain they cost 12 dB at the far end (-26.9 dB vs -14.2 dB captured) by dropping
  samples, which reads as silence.

## Still not built

**Far-end audio capture** — recording the *other* people needs a loopback wired the
other way (system output into a capture source). Without it your side is captured
well and the room only through your microphone. This is the remaining functional
gap versus a cloud meeting assistant.

**Accent conversion** — no local model. Not attempted.

---

## Config

Environment variables, all optional:

| Var | Default | Meaning |
|---|---|---|
| `CRISPY_HOME` | `~/.rappcrispy` | state directory |
| `CRISPY_MIC` | auto | avfoundation input index; auto-pick prefers real hardware over virtual devices |
| `CRISPY_DICT` | `~/.rappvoice/dictionary.txt` | personal dictionary |
| `ENGINE` | `auto` | `dfn` / `rnnoise` / `auto` (DFN3 when present) |
| `RNN_MODEL` | `cb` | RNNoise model: `bd cb sh mp lq` |
| `SINK_NAME` | auto | pin `crispy live`'s loopback device by name |
| `ASR_PORT` | `8765` | local whisper-server port |
| `CHUNK_SECONDS` | `300` | transcription chunk size |

Auto mic selection deliberately skips virtual devices. On a machine with the
incumbent installed, its virtual mic is often input `[0]` — capturing through it
would mean measuring *their* denoiser instead of ours.

---

## Tests

```bash
./tools/dryrun.sh      # everything
./tools/parity.sh      # just the no-duplicated-facts checks
./tools/setversion.sh 1.2.1   # the ONLY way to change the version
```

24 assertions, no microphone and no keyboard needed. Deterministic behaviour is
asserted (denoise floors, RTF, dictionary enforcement, notes structure, that the
capture device is real hardware). Recogniser output is **measured and printed,
not asserted** — a suite that asserts on model output goes red for the wrong
reason.

## Running as a service

`crispy` works fine ad hoc, but the ASR server and the hatched twin die on logout.
`install.sh --service` installs two user-level launchd agents — no sudo, no system
directories:

| Agent | What |
|---|---|
| `com.rapp.whisper-server` | the local ASR on 127.0.0.1:8765 (shared with RAPP Voice) |
| `com.rapp.crispy-twin` | the hatched rapplication on :7090 |

```bash
launchctl list | grep com.rapp.           # status
launchctl bootout gui/$(id -u)/com.rapp.crispy-twin   # stop one
rm ~/Library/LaunchAgents/com.rapp.*.plist            # uninstall entirely
```

The live virtual microphone is deliberately **not** a service — it holds the
microphone open, so you start it when you want it.

## Keeping it from rotting

Every real bug in this project came from **one fact living in two places**: the
version pinned in three files, the dictionary path defaulting differently in the
CLI and the agent, loopback detection narrower in the agent than in the CLI, and a
capability fact asserted in `soul.md` that the tool contradicted.

Two things guard that now, and they are different cures:

- **`tools/setversion.sh` is a generator.** The store spec needs `version` in three
  files; one command writes all three and rebuilds the egg. Never edit a version by
  hand.
- **`tools/parity.sh` is a detector**, for what a generator cannot cover: the twin
  agent must be byte-identical to the singleton, the egg must carry the shipped
  agent, the CLI and agent must resolve the same defaults, and **prose must never
  assert a fact a tool can compute** — that last rule is why the persona now defers
  to `live_status` instead of claiming a driver is required.

`dryrun.sh` runs both, so the rule is enforced by the same command that proves the
product works.

MIT.
