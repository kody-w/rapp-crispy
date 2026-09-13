#!/usr/bin/env python3
"""Safe release regressions: generated files only, no capture, cloud, or user state."""
import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import types
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / "rapp_crispy/singleton/rapp_crispy_agent.py"
TWIN = ROOT / "rapp_crispy/twin/agents/rapp_crispy_agent.py"

# Computed from 66df7c5 before the native port; these algorithms are intentionally
# retained, including benchmark limitations and the two-process live path.
PRESERVED = {
    "cli:resolve_engine": "a22f9c098ac1b5c8d31d12d56ce99c38ca7f9c67fbe9fcec584a6123defa6e8c",
    "cli:pick_mic": "140162127262666e3555d1998ccaec2bf4bce5c0a01e9787b935f3d9066453b0",
    "cli:cmd_denoise": "487882ac42eadca86ad6b1ddd598d2f3b628d532f0efe5ee6894813ba757017a",
    "cli:dictionary_prompt": "4236c41581258be0015afdfcef5f56dfe443429d566b3542edfc1295f4f4e898",
    "cli:apply_dictionary": "89943d7a5e660002057e7494540a2ef7501d154eeee9cbeb1c03ffaf5e027a40",
    "cli:cmd_transcribe": "005c9b380bc7f3f1357e4b3481e8ef57cf343c177a7d5a8255b6754a6ddc3e02",
    "cli:cmd_live_start": "c1f8b1db14fa2efbee79e773c008356e6e1ec6728a51471167ff9406ae9a233c",
    "agent:_pick_mic": "9ba36745c9502a438a7df1fa80541ed29c1f8a0f8565aaf869e2086a28605b3e",
    "agent:_apply_dictionary": "f1f21f25df10955b55e35f2d79349f9130776fb5f9970901a2198cd49afc5a73",
    "agent:_dict_prompt": "8b48d51a3c2981325e04c3bc64c74ed92359f9e98ca6210d69b1a4852e77808d",
    "agent:_engine": "9a2e49a453b077f715d246b140be02b72c3b0d5c0cdc949db23e02b7f7716748",
    "agent:_denoise": "429a5738a344b8cb796d0b7719871b7e314e58f7fae2d1a78049d98d15b53729",
    "agent:_bench": "f420ce4be33a8804e31eec955e81eccec91318eb293031553d11a62b0c8f5426",
    "tools/bench.sh": "d463bdf5f3bfb161aa20ff741c5e7113d4e0b92b3a8620669e5295898e10b828",
}


class SafeRegressions(unittest.TestCase):
    def setUp(self):
        self.work = ROOT / ".build/safe-regressions" / str(uuid.uuid4())
        self.work.mkdir(parents=True)
        for name in ("home", "work", "bin"):
            (self.work / name).mkdir()
        self.environment = mock.patch.dict(os.environ, {
            "HOME": str(self.work / "home"),
            "CRISPY_HOME": str(self.work / "state"),
            "CRISPY_BACKEND": "legacy",
            "CRISPY_NOTES_CONSENT": "0",
            "CRISPY_NO_NOTES": "0",
            "CRISPY_DICT": str(self.work / "dictionary.txt"),
            "FFMPEG": str(self.work / "missing-fixture-ffmpeg"),
            "TMPDIR": str(self.work / "work"),
            "PATH": str(self.work / "bin") + os.pathsep + os.environ.get("PATH", ""),
        })
        self.environment.start()
        stub = types.ModuleType("agents.basic_agent")
        stub.BasicAgent = type("BasicAgent", (), {"__init__": lambda self, *a, **kw: None})
        self.modules = mock.patch.dict(sys.modules, {"agents": types.ModuleType("agents"), "agents.basic_agent": stub})
        self.modules.start()
        spec = importlib.util.spec_from_file_location("crispy_release_fixture", AGENT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.agent = self.module.RappCrispyAgent()
        self.meeting = Path(self.module.MEETINGS) / "generated-meeting"
        self.meeting.mkdir()
        with wave.open(str(self.meeting / "mic.wav"), "wb") as output:
            output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            output.writeframes(b"\0\0" * 1600)
        (self.meeting / "transcript.txt").write_text("Synthetic meeting decision: test local consent.", encoding="utf-8")
        self.called = self.work / "provider-called"
        self.hook = Path(self.module.HOOKS) / "notes.sh"
        self.write_hook(f"touch {shlex.quote(str(self.called))}\nprintf '## Summary\\nSynthetic provider output.\\n'")
        # If the shipped hook's consent guard regresses, even its claude command
        # resolves to this fixture, never to a real provider.
        claude = self.work / "bin/claude"
        claude.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(self.called))}\nprintf 'fixture claude only\\n'\n")
        claude.chmod(0o700)

    def tearDown(self):
        self.modules.stop()
        self.environment.stop()
        shutil.rmtree(self.work)

    def write_hook(self, body):
        self.hook.write_text("#!/bin/sh\nset -eu\n" + body + "\n", encoding="utf-8")
        self.hook.chmod(0o700)

    def cli(self, *arguments):
        return subprocess.run([str(ROOT / "crispy"), *map(str, arguments)], capture_output=True, text=True, timeout=15)

    def native_bundle(self):
        app = self.work / "RAPP Crispy.app"
        binary = app / "Contents/MacOS/RAPPCrispy"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o700)
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "io.rapp.crispy", "CFBundleExecutable": "RAPPCrispy"}, handle)
        os.environ["CRISPY_BACKEND"] = "native"
        os.environ["RAPP_CRISPY_APP"] = str(app)
        return app, binary

    def test_shipped_hook_refuses_without_explicit_consent(self):
        result = subprocess.run([str(ROOT / "hooks-notes.sh"), str(self.meeting / "transcript.txt")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 3)
        self.assertIn("Notes disabled", result.stderr)
        self.assertFalse(self.called.exists())

    def test_approved_shipped_hook_keeps_transcript_out_of_argv(self):
        arguments = self.work / "provider-arguments.txt"
        stdin = self.work / "provider-stdin.txt"
        claude = self.work / "bin/claude"
        claude.write_text(
            "#!/bin/sh\nset -eu\n"
            f"printf '%s\\n' \"$@\" > {shlex.quote(str(arguments))}\n"
            f"cat > {shlex.quote(str(stdin))}\n"
            "printf '## Summary\\nSynthetic fixture output.\\n'\n"
        )
        os.environ["CRISPY_NOTES_CONSENT"] = "1"
        result = subprocess.run([str(ROOT / "hooks-notes.sh"), str(self.meeting / "transcript.txt")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        transcript = (self.meeting / "transcript.txt").read_text()
        self.assertEqual(stdin.read_text(), transcript)
        self.assertNotIn(transcript, arguments.read_text())
        self.assertEqual(arguments.read_text().splitlines()[0], "-p")
        self.assertIn("Synthetic fixture output.", result.stdout)

    def test_cli_notes_disabled_by_default_but_transcript_remains(self):
        result = self.cli("notes", self.meeting)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("notes disabled", result.stdout)
        self.assertFalse(self.called.exists())
        self.assertTrue((self.meeting / "transcript.txt").exists())
        self.assertFalse((self.meeting / "notes.md").exists())

    def test_cli_opt_in_only_runs_selected_fixture_provider(self):
        os.environ["CRISPY_NOTES_CONSENT"] = "1"
        result = self.cli("notes", self.meeting)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.called.exists())
        self.assertEqual((self.meeting / "notes.md").read_text(), "## Summary\nSynthetic provider output.\n")

    def test_cli_no_notes_overrides_even_explicit_consent(self):
        os.environ["CRISPY_NOTES_CONSENT"] = "1"
        result = self.cli("notes", "--no-notes", self.meeting)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("notes skipped", result.stdout)
        self.assertFalse(self.called.exists())

    def test_empty_provider_keeps_old_notes_and_no_completed_claim(self):
        os.environ["CRISPY_NOTES_CONSENT"] = "1"
        (self.meeting / "notes.md").write_text("Original notes kept.")
        self.write_hook("exit 0")
        result = self.cli("notes", self.meeting)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("returned no content", result.stdout)
        self.assertEqual((self.meeting / "notes.md").read_text(), "Original notes kept.")

    def test_adapter_notes_are_off_by_default_and_require_separate_consent(self):
        self.assertIn("SKIPPED", self.agent.perform(action="notes", meeting=self.meeting.name))
        self.assertIn("DISABLED", self.agent.perform(action="notes", meeting=self.meeting.name, notes=True))
        self.assertFalse(self.called.exists())
        os.environ["CRISPY_NOTES_CONSENT"] = "1"
        result = self.agent.perform(action="notes", meeting=self.meeting.name, notes=True)
        self.assertIn("Synthetic provider output", result)
        self.assertTrue(self.called.exists())

    def test_native_discovery_and_typed_recording_dispatch_never_capture(self):
        app, _ = self.native_bundle()
        with mock.patch.object(self.module, "_run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            result = self.agent.perform(action="run", name="Design review & delivery", seconds=30, screen=True, notes=True)
        self.assertIn("Capture has NOT started", result)
        arguments = run.call_args.args[0]
        self.assertEqual(arguments[:3], ["/usr/bin/open", "-a", str(app)])
        url = urlsplit(arguments[3])
        self.assertEqual(url.hostname, "prepare-recording")
        self.assertEqual(parse_qs(url.query), {"name": ["Design review & delivery"], "seconds": ["30"], "screen": ["true"]})
        self.assertNotIn("+", url.query, "Native URL query decoding is not HTML form decoding")
        self.assertFalse(self.called.exists())

    def test_native_diagnostics_are_read_only_and_invalid_bundle_does_not_fallback(self):
        app, binary = self.native_bundle()
        response = '{"nativeVirtualMicrophoneRunning": false, "farEndAudioCaptured": false}'
        with mock.patch.object(self.module, "_run", return_value=subprocess.CompletedProcess([], 0, response, "")) as run:
            self.assertEqual(json.loads(self.agent.perform(action="doctor"))["farEndAudioCaptured"], False)
        self.assertEqual(run.call_args.args[0], [str(binary), "--diagnostics-json"])
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "wrong", "CFBundleExecutable": "RAPPCrispy"}, handle)
        self.assertIn("No valid", self.agent.perform(action="record", seconds=20))

    def test_native_typed_values_are_bounded_and_legacy_bypass_remains(self):
        self.native_bundle()
        for kwargs in [{"seconds": -1}, {"seconds": True}, {"seconds": 86401}, {"screen": "false"}, {"name": "bad\nname"}]:
            with self.assertRaises(ValueError):
                self.module._native_recording_url(kwargs)
        os.environ["CRISPY_BACKEND"] = "legacy"
        self.assertIsNone(self.module._native_app())
        with mock.patch.object(self.agent, "_record", return_value="legacy fixture recorder") as record:
            self.assertEqual(self.agent.perform(action="record", seconds=20), "legacy fixture recorder")
        record.assert_called_once_with(20, None, False)

    def test_native_meeting_audio_is_readable_by_legacy_views_and_notes(self):
        (self.meeting / "mic.wav").rename(self.meeting / "mic.voiceprocessed.wav")
        (self.meeting / "native-meeting.json").write_text(json.dumps({"audioFilename": "mic.voiceprocessed.wav"}))
        self.assertEqual(Path(self.module._meeting_audio(str(self.meeting))).name, "mic.voiceprocessed.wav")
        listing = json.loads(self.agent.perform(action="list"))
        self.assertEqual(listing["meetings"][0]["seconds"], 0.1)
        self.assertIn("SKIPPED", self.agent.perform(action="notes", meeting=self.meeting.name))
        self.assertEqual(self.cli("notes", self.meeting).returncode, 0)
        self.assertFalse(self.called.exists())

    def test_dictionary_behavior_matches_existing_safe_dryrun_cases(self):
        dictionary = self.work / "dictionary.txt"
        dictionary.write_text("OpenRappter\nKody Wildflower\nC++\nF#\nGPT-4\nOpen Raptor => OpenRappter\n")
        cases = {
            "openrappter is shipping": "OpenRappter is shipping",
            "we use open raptor daily": "we use OpenRappter daily",
            "i write c++ and f# and gpt-4": "i write C++ and F# and GPT-4",
            "a velociraptor is not a term": "a velociraptor is not a term",
        }
        for text, expected in cases.items():
            output = subprocess.run([sys.executable, str(ROOT / "tools/dictfix.py"), str(dictionary)],
                                    input=text, capture_output=True, text=True, check=True, timeout=10).stdout
            self.assertEqual(output, expected)
            self.assertEqual(self.module._apply_dictionary(text), expected)

    def test_existing_algorithms_benchmarks_and_source_adapters_are_preserved(self):
        cli = (ROOT / "crispy").read_text()
        agent = AGENT.read_text()
        functions = {n.name: ast.get_source_segment(agent, n) for n in ast.walk(ast.parse(agent)) if isinstance(n, ast.FunctionDef)}
        for key, expected in PRESERVED.items():
            with self.subTest(source=key):
                if key.startswith("cli:"):
                    text = re.search(r"^" + key.split(":")[1] + r"\(\) \{.*?^\}", cli, re.M | re.S).group().encode()
                elif key.startswith("agent:"):
                    text = functions[key.split(":")[1]].encode()
                else:
                    text = (ROOT / key).read_bytes()
                self.assertEqual(hashlib.sha256(text).hexdigest(), expected)
        self.assertEqual(AGENT.read_bytes(), TWIN.read_bytes())

    def test_native_capture_source_targets_macos14_and_never_a_terminal_launcher(self):
        core = ROOT / "native/Sources/RAPPCrispyCore"
        sources = "\n".join(path.read_text() for path in core.glob("*.swift"))
        self.assertNotIn("SCRecordingOutput", sources)
        self.assertNotIn("captureMicrophone", sources)
        self.assertIn("AVAudioEngine()", sources)
        self.assertIn("setVoiceProcessingEnabled(true)", sources)
        self.assertIn("configuration.capturesAudio = false", sources)
        main = (ROOT / "native/Sources/RAPPCrispy/RAPPCrispyApp.swift").read_text()
        self.assertIn("struct RAPPCrispyApp: App", main)
        self.assertNotIn("/bin/bash", main)
        with (ROOT / "native/Resources/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["LSMinimumSystemVersion"], "14.0")
        self.assertIn("NSMicrophoneUsageDescription", info)

    def test_runtime_provenance_matches_the_parent_source_recipe(self):
        declared = json.loads((ROOT / "native/Resources/RuntimeDependencies.json").read_text())["required"][0]
        self.assertEqual(declared["name"], "whisper.cpp")
        self.assertEqual(declared["license"], "MIT")
        self.assertEqual(declared["backend"], "cpu")
        self.assertRegex(declared["sourceCommit"], r"^[0-9a-f]{40}$")
        self.assertRegex(declared["sourceArchiveSHA256"], r"^[0-9a-f]{64}$")
        self.assertTrue(all(path.startswith(("/usr/lib/", "/System/Library/"))
                            for path in declared["dynamicLibraries"]))
        recipe = next((path for path in [
            ROOT / "native/.build/checkouts/rapp-tools/native/dependencies/whisper.json",
            ROOT / "native/build/SourcePackages/checkouts/rapp-tools/native/dependencies/whisper.json",
        ] if path.is_file()), None)
        if recipe is not None:
            expected = json.loads(recipe.read_text())
            self.assertEqual(declared["version"], expected["version"])
            self.assertEqual(declared["sourceArchiveURL"], expected["source_url"])
            self.assertEqual(declared["sourceArchiveSHA256"], expected["source_sha256"])
            self.assertEqual(declared["architectures"], expected["architectures"])
        notice = (ROOT / "native/Resources/THIRD_PARTY_NOTICES.txt").read_text()
        self.assertIn("whisper.cpp v" + declared["version"], notice)
        self.assertIn(declared["sourceCommit"], notice)
        self.assertIn(declared["sourceArchiveSHA256"], notice)

    def test_shared_support_is_immutably_pinned_for_both_build_systems(self):
        package = (ROOT / "native/Package.swift").read_text()
        project = (ROOT / "native/project.yml").read_text()
        expected_url = "https://github.com/kody-w/rapp-tools.git"
        swift_revision = re.search(r'revision:\s*"([a-f0-9]{40})"', package).group(1)
        xcode_revision = re.search(r"revision:\s*([a-f0-9]{40})", project).group(1)
        self.assertEqual(swift_revision, xcode_revision)
        self.assertNotIn(".package(path:", package)
        self.assertNotIn("path: ../../rapp-tools", project)
        self.assertIn(expected_url, package)
        self.assertIn(expected_url, project)
        declared_support = json.loads((ROOT / "native/Resources/RuntimeDependencies.json").read_text())["sharedSupport"]
        self.assertEqual(declared_support["repository"], expected_url)
        self.assertEqual(declared_support["revision"], swift_revision)
        for path in [
            ROOT / "native/Package.resolved",
            ROOT / "native/RAPPCrispy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        ]:
            resolved = json.loads(path.read_text())
            pin = next(item for item in resolved["pins"] if item["identity"] == "rapp-tools")
            self.assertEqual(pin["location"], expected_url)
            self.assertEqual(pin["state"]["revision"], swift_revision)
            self.assertIsNone(pin["state"].get("branch"))
            self.assertIsNone(pin["state"].get("version"))

    def test_runtime_entrypoint_uses_shared_resolution_without_creating_app_state(self):
        binary = ROOT / "native/.build/debug/RAPPCrispy"
        if not binary.is_file():
            self.skipTest("Build native/RAPPCrispy first for the compiled entrypoint check")
        runtime = self.work / "bin/whisper-cli"
        runtime.write_text("#!/bin/sh\nexit 0\n")
        runtime.chmod(0o700)
        environment = os.environ.copy()
        environment["RAPP_RUNTIME_BIN"] = str(runtime.parent)
        environment["CRISPY_HOME"] = str(self.work / "app-state-must-not-exist")
        result = subprocess.run([str(binary), "--runtime-check"], capture_output=True, text=True,
                                env=environment, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["whisper_cli"], str(runtime))
        self.assertFalse(Path(environment["CRISPY_HOME"]).exists())
        runtime.unlink()
        missing = subprocess.run([str(binary), "--runtime-check"], capture_output=True, text=True,
                                 env=environment, timeout=10)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("whisper-cli", missing.stderr)
        self.assertFalse(Path(environment["CRISPY_HOME"]).exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
