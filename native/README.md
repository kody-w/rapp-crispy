# RAPP Crispy native 1.5.1

The signed/notarized 1.5.1 applications are built from source commit
`873c06fd2930c8948e61e800abbf10af691ffb2d`. Publication metadata lives in a
later metadata-only commit.

A **real SwiftUI/AppKit macOS 14+ application**, not a wrapper around the
`crispy` shell command. App-owned AVFoundation capture, ScreenCaptureKit video,
AVAudioConverter WAV preparation, local Whisper jobs and meeting persistence
run from native controllers. The executable Swift package and XcodeGen app
target use the same sources.

## Everyday use

1. Open **RAPP Crispy.app**. Nothing records on launch.
2. In **Settings**, select **Base English** or **Small English** and click
   **Download verified model**. Download size, immutable source, license,
   SHA-256, progress and cancellation are visible. Only model data is fetched;
   no meeting content is uploaded. You can record before installing a model.
3. In **Record**, choose the microphone and an explicitly named enhancement
   engine. Click **Record**. The microphone permission belongs to
   `io.rapp.crispy`, not Terminal, Hammerspoon or a helper.
4. **Stop & process** releases capture and processes locally. **Cancel job**
   releases capture and stops subsequent work, keeping existing local files.
   A red recording indicator, elapsed timer, level meter, Dock badge and
   menu-bar stop/cancel controls make active capture visible even if the main
   window is closed. Quitting an active job requires a visible choice.
5. **Meetings** shows legacy and native history, audio playback, actual
   transcript/notes files, silent screen-video playback and Finder access.
   Select/download a model later and use **Transcribe locally** on saved audio.

Obtain permission from participants before recording. System permission
dialogs cannot be dismissed or overridden by this app; cancelling while a
microphone prompt is pending ensures capture does not start after the response.

## What is and is not supported

| Capability | Native implementation / boundary |
|---|---|
| Microphone | AVAudioEngine, explicit CoreAudio input, macOS 14; hardware input preferred, virtual input never selected automatically |
| Default enhancement | **Apple AVFoundation voice processing**, enabled and checked at capture time; automatic gain control disabled; no fallback if enabling/selecting the device fails |
| Original microphone | Explicit **no enhancement** option; a virtual input may already be processed by its owner |
| Advanced recorded enhancement | Existing DeepFilterNet3 file-to-file and FFmpeg `arnndn` RNNoise paths, explicitly selected; dependencies are **not bundled here** |
| Transcription | Parent-assembled `whisper-cli` via shared `SpeechTranscriber`; 16 kHz mono, 16-bit PCM WAV chunks, 300 seconds each, local English models |
| Personal dictionary | Existing canonical casing and longest-first `heard => Term` rewrites; no fuzzy matching. Native shared API does **not** expose legacy weighted prompt bias |
| Optional screen | User explicitly chooses a display or window before each recording session; ScreenCaptureKit + AVAssetWriter, max 1920-pixel edge, H.264 `.mov`, **video only** |
| Far-end/system audio | **Not captured.** Screen video does not capture other participants. Microphone-only recordings may include voices audible in the room |
| Native virtual microphone | **Not implemented.** Diagnostics report candidates, not fabricated readiness. No driver install or system routing change |
| Notes | Disabled until a user selects a provider, names its destination, approves its executable/configuration, and requests notes |
| Speaker identity/accent conversion | Not implemented or claimed |

**Apple voice processing is not DeepFilterNet or RNNoise.** The CLI's measured
noise-floor, speech-retention and RTF numbers must not be attributed to it.
No denoising-quality measurement is claimed for Apple voice processing in this
workstream; real-device quality and permissions remain a manual validation gate.
Raw audio is unavailable when that capture-time processor is enabled.

DeepFilterNet's supported native adapter expects **deep-filter 0.5.6**, whose
pinned `libDF/src/tract.rs` embeds DFN3 by default; it does not use `--pf`.
Inputs/outputs are normalized locally to 48 kHz mono PCM. Differently reported
versions are rejected rather than silently mislabeled. RNNoise requires
FFmpeg's advertised `arnndn` filter and a user-selected `.rnnn` file. The native
report records actual executable/model hashes, processing wall time / audio
duration (**RTF**, same ratio as CLI), not invented quality results.

## Data and recovery

The existing `~/.rappcrispy` tree is preserved (`CRISPY_HOME` remains a
development override). Reading legacy folders never adds metadata to them.
New meeting directories are collision-resistant, private, and contain:

| File | Meaning |
|---|---|
| `microphone.caf` | Local capture/recovery file at the device's format; retained after conversion, so budget space for both files |
| `mic.wav` | 48 kHz mono 16-bit PCM for original/advanced-engine capture |
| `mic.voiceprocessed.wav` | 48 kHz mono PCM **already processed by Apple**, never labeled raw or RNNoise |
| `mic.denoised.<id>.wav` | Actual selected advanced-engine output, without replacing the original |
| `screen.mov` | Separately selected, silent screen/window video; no synchronized mixed meeting track is claimed |
| `transcript.txt` | Actual local recognition result; an empty successful result means no speech detected |
| `notes.md` | Nonempty, successful provider output only; absent/skipped/failed notes are not fabricated |
| `native-meeting.json` | Native phase, engine identities, capture warnings, artifacts and model receipt |
| `device.txt` | Actual chosen microphone name |
| `.revisions/` | Previous transcript/notes versions when explicitly reprocessing |

Native model data uses `~/.rappcrispy/models/native-speech/`, leaving existing
CLI ASR/denoise models untouched. New settings are `native-preferences.json`
and `native-notes-consent.json`. Symlink escapes, traversal, malformed metadata
and broken media are rejected or shown as explicit history issues. Interrupted
jobs are shown as interrupted, not resumed automatically. Completed artifacts
remain usable after failures/cancellation; incomplete CAF recordings can be
selected/reprocessed, with errors shown if they contain no audio frames.

## Notes consent

No provider runs by default, including an existing `hooks/notes.sh`.
The example hook's `claude -p` sends the transcript to **Anthropic**.
Native Settings lets the user choose a trusted executable and declare its
destination. A local-provider label is a user assertion, **not a network
sandbox**; the application is not sandboxed because it preserves the existing
meeting directory and supports user-owned executable hooks.

Consent is bound to executable bytes (SHA-256), path, name, kind and destination.
Changes require approval again. Configuration changes/revocation invalidate the
in-flight notes authorization, cancel the process job, and prevent saving a late
result. Revocation cannot recall already transmitted content or guarantee that
an independently detached process started by an arbitrary custom hook stops.
Provider authentication belongs to the provider; credentials are not collected
by this app.

Hooks receive the transcript path as argument 1 and
`--rappcrispy-explicit-consent` as argument 2. They must print actual Markdown
on stdout and exit successfully. No fabricated `notes.md` is written for a
missing provider, missing consent, empty response, cancellation or process error.
Any existing notes/transcript remain available if a new attempt fails.
The shipped Claude template redirects the transcript file to the provider's
standard input; transcript content is not placed in argv. Existing custom
hooks keep their path-based interface. The native runner itself passes only the
file path and consent marker, not transcript text, as arguments.

Legacy CLI/agent notes are now opt-in too: review the actual hook/destination,
then use `CRISPY_NOTES_CONSENT=1` for the desired invocation. `--no-notes` and
`notes=false` still override consent. Native approval does not enable legacy
cloud hooks globally.

## Optional existing loopback and developer compatibility

The preserved `crispy live` path still uses the original two-process RNNoise
pipeline. A **compatible, separately configured existing loopback** is an
optional prerequisite for that legacy feature, not for the native meeting app.
Device names or duplex channel counts are only candidates; they do not prove
that a device works or that remote participants are captured. The native app
neither installs a loopback driver nor launches the legacy live pipeline.

Singleton and twin adapters discover real `io.rapp.crispy` bundles in
`/Applications` or `~/Applications`, or an explicit `RAPP_CRISPY_APP`.
`record`/`run` open typed **prepare-recording** controls; they **never start
capture** from a URL. `doctor`/`live_status` use the app's read-only diagnostics.
Other commands and file-based `list`/`read` workflows remain available.
`CRISPY_BACKEND=legacy` explicitly retains headless recording; `auto` is the
default, and `native` fails visibly if no native app is installed. No RAPP
protocol fields, identity/Grail data or retired eggs are regenerated.

Supported app URLs: `rappcrispy://prepare-recording?name=...&seconds=...&screen=true`,
`history`, `meeting?id=...`, `diagnostics`, `models`. Unknown fields, path
traversal, duplicate query keys and out-of-range durations are rejected.
Buttons have stable `crispy.*` accessibility identifiers.

## Dependencies and release assembly

See [`Resources/RuntimeDependencies.json`](Resources/RuntimeDependencies.json)
and [`Resources/THIRD_PARTY_NOTICES.txt`](Resources/THIRD_PARTY_NOTICES.txt).
Required Whisper source matches the parent-owned build recipe: **v1.9.2,
`306c88f4d1286aec1bf96e544632897886af5501` (MIT)**, source archive SHA-256
`a6abd064fcca8b85e794d205abf328c522e9451db43a3eadc178b883b7d0e9cd`.
RAPP Tools builds the CPU backend for arm64 and x86_64 with static project
libraries, linking only macOS system libraries; consumer Macs need no Homebrew,
SDL, OpenMP or external dylibs. The parent release assembly starts from `bin/whisper-cli` in the verified
pre-sign runtime input and places the signed executable at
`Contents/MacOS/whisper-cli`. The architecture-specific
`rapp_crispy-1.5.1-<arch>.release-result.json` assets record both the pre-sign
runtime manifest and the final post-sign helper hash. Only the enclosing app is
stapled and Gatekeeper-assessed; the helper is code-signature- and hash-verified.
No executable is silently fetched by the app. `RAPP_RUNTIME_BIN` is only an
explicit development override.

DeepFilterNet 0.5.6 Darwin assets exist upstream under MIT/Apache-2.0; no
release-verified, signed, two-architecture distribution of them is supplied
here. A selected FFmpeg build additionally needs exact source/build/library
license review before redistribution. GregorR model rights rely on the
upstream README's non-copyrightability assertion, not an invented SPDX license.
These are **optional advanced-engine packaging blockers**, not a requirement
to install Homebrew for the Apple voice-processing path.

Both `Package.swift` and `project.yml` pin the shared package to
`https://github.com/kody-w/rapp-tools.git` at immutable revision
`f0bc616c2aed34f2a88888806ed056ec7bafba61`. SwiftPM and Xcode shared
`Package.resolved` files are checked in. The app can resolve/build without a
sibling RAPP Tools worktree.

The app target has a real bundle ID, usage descriptions, privacy manifest,
hardened-runtime settings and audio-input entitlement. No signing,
notarization, Intel-runtime execution or public release success is asserted
by these source files. The parent owns final runtime assembly,
signing/notarization, catalog/version integration and release. The published
1.5.1 reports are linked from the repository and application READMEs.

## Build and safe checks

The pinned public support package is resolved by SwiftPM/Xcode; no sibling
checkout or global Git identity change is needed. For development only:

```bash
cd native
mkdir -p .build/tool-work
TMPDIR="$PWD/.build/tool-work/" swift test -j 2
TMPDIR="$PWD/.build/tool-work/" swift build -j 2
.build/debug/RAPPCrispy --self-check
xcodegen generate --spec project.yml --quiet
xcodebuild -project RAPPCrispy.xcodeproj -scheme RAPPCrispy \
  -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath .build/ci-xcode -jobs 2 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
cd ..
./tools/dryrun.sh --safe
./tools/parity.sh
```

### Same-repository native CI

`.github/workflows/native-ci.yml` runs on `macos-latest` and `macos-15-intel`
for pushes, pull requests and manual dispatch. Checkout and the runner verify
the exact requested source SHA; pull requests test their head commit, not an
implicit merge checkout. Different source SHAs cannot cancel each other's runs.
The workflow has read-only repository permission and no signing secrets.

Both jobs execute the same local entrypoint from the repository root:

```bash
python3 tools/native_ci.py
```

It runs CI-runner unit tests, `swift test -j 2`, `swift build -j 2`,
`tools/dryrun.sh --safe`, parity and Bash syntax checks, an unsigned Xcode app
build/test, then both built entry points' `RAPPCrispy --self-check`.
Build/cache/work files stay under `native/.build`.
Only synthetic fixtures and consent-disabled defaults are used: no microphone,
screen permission, live audio, actual notes provider, model download or
distribution signing is invoked. The CI runner also explicitly addresses only its known package
caches for Git hosts using `safe.bareRepository=explicit`, without overriding
that policy. Its local result is a test receipt, not distribution evidence.

Publication must reference a genuinely successful public Actions run at the
final native source SHA. Adding or locally testing the workflow does not create
such a run; the parent pushes the final commit and verifies Actions before release.

If a build host enforces Git's `safe.bareRepository=explicit` policy, older
SwiftPM/Xcode cache commands may need explicit `--git-dir` addressing for their
known package-cache repositories. This is a build-tool compatibility issue, not
a missing revision. Our local validation uses a process-local adapter limited
to those cache paths, without changing Git's safety policy or global identity.
It is not part of the app and is not needed by end users.

`--self-check` exits before creating app state or accessing a microphone.
`--runtime-check` additionally resolves the local speech executable through
shared `RuntimeTools`, prints its actual path as JSON and exits before app state
or device queries. Missing runtimes return a nonzero exit code, not a success
placeholder. This is a packaging/resolution check, not an ASR-quality test.
Use the actual generated `.app` bundle for interactive capture; the bare
SwiftPM executable is a development/test entry point, not a replacement for the
bundle's permission usage descriptions and signing identity.
`--diagnostics-json` enumerates device metadata/permission status only; it does
not request permission or capture media. XcodeGen `project.yml` provides real
app, core-framework and unit-test targets. Parent assembly supplies a runtime
folder as a **folder reference** preserving `runtime/bin/` paths.

Swift tests generate PCM WAV/transcript/fixture-hook data inside `native/.build/`
and exercise state, cancellation, permission errors (fakes only), local
conversion/chunking, persistence, traversal/symlinks, consent/revocation,
provider failure, engine identity and diagnostics. Fixture engine executables
test invocation contracts, **not denoising quality**. The safe legacy suite
uses private generated directories under `.build/`; it never reads a real
meeting, starts a real provider, touches microphone/screen capture, or depends
on Homebrew/ASR. Source fingerprints protect the original algorithms and
benchmark/reporting semantics. The old full `dryrun.sh` remains an integration
suite against developer dependencies/user environment; **do not run it as an
autonomous release check**.

### Remaining manual gates

- Signed-app microphone allow/deny/revoke on a real macOS 14 machine.
- Selected-device behavior and Apple voice-processing quality on actual inputs.
- Explicit display/window permission, output video, and stopping sharing via
  system controls; no autonomous screen capture was performed.
- Bundled real Whisper/model recognition and responsiveness on both advertised
  architectures; model downloads are user-driven, not run by the app tests.
- Release artifact signatures, hardened helper loading and notarization.
