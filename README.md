# RAPP Crispy

A local-first meeting stack for macOS, now with a **native macOS 14+ SwiftUI/
AppKit app** alongside the preserved CLI and agent workflows. Record, enhance,
transcribe, browse meeting history and play local audio without Terminal,
Homebrew or Hammerspoon. See [the native app guide](native/README.md) for setup,
supported capabilities, exact runtime dependencies and release/build gates.

**Recording, enhancement and transcription stay on this Mac. Notes are disabled
by default.** The example `~/.rappcrispy/hooks/notes.sh` calls `claude -p`, which
**sends the transcript to Anthropic**. Native provider approval is bound to the
chosen executable/destination and can be revoked. Legacy CLI/agent hooks now
require explicit `CRISPY_NOTES_CONSENT=1`; `--no-notes` / `notes=false` still
override it. Missing consent or a provider never prevents local recording or
transcription.

The files land in `~/.rappcrispy/meetings/<timestamp>/` and stay there.

The preserved **developer/CLI pipeline** is:

```
mic (real hardware)  ──►  RNNoise denoise      (ffmpeg arnndn, on-device)
screen (optional)    ──►  screen.mov           (screencapture, on-device)
                     ──►  whisper.cpp ASR      (localhost, on-device)
                     ──►  notes hook           (disabled until explicit consent)
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

### Native app

**[RAPP Crispy 1.5.0 is available](https://github.com/kody-w/rapp-crispy/releases/tag/v1.5.0)**
for macOS 14.0 or later. These architecture-specific ZIPs contain the
Developer ID signed, notarized/stapled native application and its bundled
local CPU Whisper runtime—not a terminal launcher or a Python installer.

| Mac | Download | Exact bytes | SHA-256 |
|---|---|---:|---|
| Apple Silicon (`arm64`) | [RAPP Crispy 1.5.0 ZIP](https://github.com/kody-w/rapp-crispy/releases/download/v1.5.0/rapp_crispy-1.5.0-arm64.zip) | 1,678,209 | `1462693b958fa170f178d01a3e531b8eaee544f6dd7813df46ab9d3698ea5e35` |
| Intel (`x86_64`) | [RAPP Crispy 1.5.0 ZIP](https://github.com/kody-w/rapp-crispy/releases/download/v1.5.0/rapp_crispy-1.5.0-x86_64.zip) | 1,908,949 | `80b4650ad805ac9735fc48a6e4163ea50b6e684266e81b1c120967faf3cd7dfe` |

Publisher release reports:
[Apple Silicon](https://github.com/kody-w/rapp-crispy/releases/download/v1.5.0/rapp_crispy-1.5.0-arm64.zip.evidence.2fcc4bd0806156f06cdfaf2bbe485753a73840e5befac564415459074b3ab7a9.json) ·
[Intel](https://github.com/kody-w/rapp-crispy/releases/download/v1.5.0/rapp_crispy-1.5.0-x86_64.zip.evidence.142cbda70a2fb49bb05fb97cc30353e6b5de805ecc9eac8cc1121a3b9075941d.json).
The content-addressed report suffix hashes the report bytes, not the ZIP.
Reports describe checks on the enclosed application; ZIP containers are not
themselves stapled. Public references and byte hashes are inspectable, but
publisher reports are not independent Apple certification or RAPP/1 acceptance
by the Store.

1. Download the ZIP for your Mac, double-click it in Finder, and drag
   `RAPPCrispy.app` to Applications.
2. Launch RAPP Crispy normally from Applications. Let macOS/Gatekeeper perform
   its checks; no protection bypass is required. Nothing records on launch.
3. In Settings, select/download a verified English speech model. The model
   host receives a model download request, not meeting content.
4. Choose a microphone and enhancement mode, then click **Record**. Grant
   Microphone permission to the app only when prompted. **Stop & process**
   and **Cancel job** are visible, and existing meeting files are preserved.
5. Screen video requires a separate explicit display/window selection and
   permission. It is silent video—not system or far-end audio capture.
6. Notes remain optional and disabled until you approve and request a provider.

Default native enhancement is **Apple AVFoundation voice processing**, not
RNNoise/DeepFilterNet; no legacy CLI benchmark score applies to it. Advanced
DeepFilterNet/RNNoise executables and models are **not bundled**. An existing
compatible loopback is optional for legacy live routing only; the native app
does not install a driver or implement a live virtual microphone.

Native source:
[`656537dacb605d0298a9552ffc882936cec41cc3`](https://github.com/kody-w/rapp-crispy/commit/656537dacb605d0298a9552ffc882936cec41cc3).
[Successful same-source CI](https://github.com/kody-w/rapp-crispy/actions/runs/34735277189).
The later manifest/integration metadata commit is distinct from this immutable
native-build commit. See [the native guide](native/README.md) for capabilities,
storage, developer builds and per-build verification requirements.

### Developer/CLI compatibility

The following installer is for existing CLI workflows, **not a prerequisite for
the native app**:

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

Two advanced **CLI engine paths** are retained. `crispy bench` reproduces the
original measurements on your own configured hardware. The native Apple engine
is different and is **not represented in this table**; advanced binaries are
optional and are not redistributed by the native source implementation.

| Noise @ 0dB SNR | RNNoise | **DeepFilterNet3** |
|---|---|---|
| white | +28.1 dB | **+42.5 dB** |
| pink | +15.8 dB | **+36.6 dB** |
| **babble (other voices)** | +4.2 dB | +4.5 dB |
| real-time factor | 0.014 | 0.048 |

DFN3 is the CLI default for recorded audio when installed — 14 dB better on steady noise, still 20x
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
markdown. The example uses `claude -p` but is disabled until explicit approval.
For a reviewed legacy provider, `CRISPY_NOTES_CONSENT=1 crispy notes <meeting>`
authorizes that invocation; native approval happens in Settings instead.
For a provider you have verified stays local, a hook might use:

```bash
#!/bin/bash
{
  printf '%s\n' "Write meeting notes with Summary, Decisions, Action items,
Open questions. Only what the transcript supports:"
  cat "$1"
} | ollama run llama3.1
```

The shipped Claude hook likewise sends transcript content over standard input,
not in process arguments. The first hook argument remains the local transcript
file path for compatibility.

The prompt tells the model not to invent content the transcript cannot support —
worth keeping, since ASR errors otherwise become confident fiction.

---

## Legacy live virtual microphone — optional existing loopback

`crispy live start` puts a denoised microphone in front of Zoom/Teams/Meet: select
the loopback device it names as your mic.

```
crispy live status     # what it found
crispy live start      # mic -> RNNoise -> loopback
crispy live stop
```

It needs a **compatible, separately configured loopback** CoreAudio device.
Some machines already have one; names and duplex channels alone do not prove
that routing works. The native app reports candidate devices and explicitly says
that native live routing is not implemented. It does not install a driver,
change routing or claim remote-participant audio capture.

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
./tools/dryrun.sh --safe  # generated data, no devices/cloud/user meetings
./tools/parity.sh        # source adapters, native version and catalog parity
```

Native `swift test -j 2` / `swift build -j 2` commands and workspace isolation
are documented in [native/README.md](native/README.md). Native source versioning
is separate from the parent-owned public catalog; do not use the historical
egg-generating `setversion.sh` as part of native release assembly.

The safe suite covers consent and legacy/native dispatch with generated files,
dictionary parity and fingerprints of the original algorithms/benchmark
semantics. Native tests cover WAV conversion, capture/job state using fakes,
cancellation, meeting persistence, provider revocation/failure, engine identity
and diagnostic honesty. No real microphone/screen or user meeting is used.
The old full `dryrun.sh` remains a developer **integration** suite that examines
the real configured environment; do not run it as an autonomous release check.
Retired eggs are not rebuilt or required to match native source adapters;
`parity.sh --legacy-egg` is an explicit historical archive check.

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
