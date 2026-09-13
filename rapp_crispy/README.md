# RAPP Crispy 1.5.0

## Native macOS app first

**[Download the native 1.5.0 release](https://github.com/kody-w/rapp-crispy/releases/tag/v1.5.0)**
for macOS 14.0 or later:

- [Apple Silicon (`arm64`) ZIP](https://github.com/kody-w/rapp-crispy/releases/download/v1.5.0/rapp_crispy-1.5.0-arm64.zip)
- [Intel (`x86_64`) ZIP](https://github.com/kody-w/rapp-crispy/releases/download/v1.5.0/rapp_crispy-1.5.0-x86_64.zip)

Double-click the ZIP in Finder, drag `RAPPCrispy.app` to Applications, and launch
it normally. The ZIP contains a Developer ID signed, notarized/stapled native
SwiftUI/AppKit app with its local CPU Whisper helper. No Homebrew, Terminal,
Python, Hammerspoon or local ASR server is required for native capture and
transcription. Speech model data is selected and downloaded separately in
Settings, with its source, size, SHA-256 and progress visible.

Nothing records on launch. Choose a microphone and click **Record** to request
app-owned Microphone permission. Active state, **Stop & process** and
**Cancel job** are visible. Optional screen/window capture requires explicit
selection and its own permission; it records **video only**, not remote
participants or system audio.

Exact archive bytes/hashes and immutable content-addressed publisher reports
are in `manifest.json`, `index_entry.json` and the
[main download table](../README.md#native-app). The report filename suffix
hashes the report itself, not the ZIP. ZIP evidence checks the enclosed app's
signature, notarization and staple; it does not claim the ZIP has a staple.
Public byte/reference validation is not independent authentication of Apple
reports or RAPP/1 acceptance by the Store.

The native-build source is
[`656537dacb605d0298a9552ffc882936cec41cc3`](https://github.com/kody-w/rapp-crispy/commit/656537dacb605d0298a9552ffc882936cec41cc3),
with [same-source CI](https://github.com/kody-w/rapp-crispy/actions/runs/34735277189).
This subsequent metadata/integration revision is separate: federation must pin
singleton/UI URLs to the published metadata commit, while `desktop.source` and
the `v1.5.0` tag retain the native-build commit.

## Local data and explicit notes consent

Native capture, Apple voice processing and Whisper transcription run locally.
Existing recordings, transcripts and notes stay under
`~/.rappcrispy/meetings/`. Reading legacy folders does not rewrite them; cancelled
or failed jobs retain completed files. Model downloads fetch public model data
without uploading meeting content.

**Notes are disabled by default.** Select a provider executable, name its
destination, approve its configuration/bytes, and explicitly request notes.
The example Claude hook sends authorized transcripts to **Anthropic** using
stdin rather than transcript text in argv. Revocation stops future authorization
and cancels an active notes job, but cannot recall already transmitted content.
A user-selected “local” executable is not a network sandbox. Missing provider,
missing consent, errors or empty output do not create fabricated completed notes.

Native approval does not authorize legacy hooks globally. Legacy CLI/agent
notes additionally require `CRISPY_NOTES_CONSENT=1` after reviewing the hook;
`--no-notes` or `notes=false` still skips it.

## Enhancement and loopback boundaries

The native default is **Apple AVFoundation voice processing during capture**.
It is not DeepFilterNet or RNNoise, and there is no unprocessed original in
that mode. “Original microphone” explicitly requests no native enhancement;
a virtual input may already be processed by its owning application.

The existing advanced developer/CLI paths remain available but **unbundled**:

- DeepFilterNet3 requires a trusted `deep-filter` executable; the native adapter
  expects 0.5.6 and does not enable the rejected `--pf` post-filter.
- RNNoise requires a compatible FFmpeg `arnndn` filter and a selected `.rnnn` model.
- A separately configured, compatible **existing loopback** is optional for
  legacy `crispy live` routing. The native app neither installs a driver nor
  implements live virtual-microphone routing. Device names/duplex channels are
  candidates, not proof of working routing or far-end capture.

The original CLI benchmarks and reporting semantics are retained. Their
noise-floor, speech-retention and RTF measurements **do not describe Apple
voice processing**. Neither legacy engine reliably removes background voices;
see the [measured limitations](../README.md#measured-denoise-performance).
No accent conversion, target-speaker extraction or system/far-end capture is claimed.

## Secondary Python and UI integration

Installing `rapp_crispy_agent.py` or opening the local integration UI **does not
install the native app**, its runtime/model, or macOS permissions. It requires
the usual Python `BasicAgent` host; it is optional integration rather than a
consumer installer.

| Action | With a native app installed / compatibility behavior |
|---|---|
| `doctor`, `live_status` | Read-only native diagnostics; native live routing is explicitly not implemented |
| `record`, `run` | Prepare visible app controls only; the user must review choices and press Record |
| `list`, `read` | Read local meeting files; native and legacy history remains on disk |
| `notes` | Optional legacy hook path; no cloud execution by default |
| `denoise`, `transcribe`, `bench` | Preserved legacy/developer paths and their separately configured dependencies |

`CRISPY_BACKEND=legacy` explicitly selects old headless capture; that workflow
requires `seconds`, its own FFmpeg, denoise models and localhost whisper server.
`RAPP_CRISPY_APP` can identify an explicit native installation. Native URL
dispatch never starts recording or grants notes consent by itself.

The retired egg is retained as historical data, not regenerated or advertised
as the 1.5.0 native installer. Identity/protocol records are unchanged.

MIT.
