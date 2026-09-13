import importlib.util
from pathlib import Path
import shutil
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("native_ci", ROOT / "tools/native_ci.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class NativeCIRunnerTests(unittest.TestCase):
    def setUp(self):
        self.work = ROOT / "native/.build/ci-runner-tests" / str(uuid.uuid4())
        self.native = self.work / "native"
        self.native.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.work)

    def test_known_cache_gets_explicit_git_directory(self):
        cache = self.native / ".build/repositories/rapp-tools-123abcd"
        arguments = ["-C", str(cache), "rev-parse", "HEAD"]
        self.assertEqual(ci.explicit_cache_arguments(arguments, self.native, self.native),
                         ["--git-dir=" + str(cache), *arguments])
        self.assertEqual(ci.explicit_cache_arguments(["show", "HEAD"], cache, self.native),
                         ["--git-dir=" + str(cache), "show", "HEAD"])

    def test_unlisted_or_other_repository_is_not_granted_an_exception(self):
        for directory in [
            self.native / ".build/repositories/another-package-123abcd",
            self.native / ".build/unlisted/rapp-tools-123abcd",
            self.work / "outside/rapp-tools-123abcd",
        ]:
            original = ["-C", str(directory), "rev-parse", "HEAD"]
            self.assertEqual(ci.explicit_cache_arguments(original, self.native, self.native), original)

    def test_explicit_git_arguments_are_never_overridden(self):
        original = ["--git-dir=/explicit", "rev-parse", "HEAD"]
        self.assertEqual(ci.explicit_cache_arguments(original, self.native, self.native), original)

    def test_config_and_relative_directory_arguments_are_preserved(self):
        cache = self.native / ".build/ci-swiftpm-cache/repositories/rapp-tools-abcd"
        original = ["-c", "core.autocrlf=false", "-C", ".build", "-C",
                    "ci-swiftpm-cache/repositories/rapp-tools-abcd", "rev-parse", "HEAD"]
        self.assertEqual(ci.explicit_cache_arguments(original, self.native, self.native),
                         ["--git-dir=" + str(cache), *original])

    def test_symlink_escape_cannot_become_a_known_cache(self):
        outside = self.work / "outside"
        outside.mkdir()
        (self.native / ".build").mkdir()
        (self.native / ".build/repositories").symlink_to(outside)
        original = ["-C", str(self.native / ".build/repositories/rapp-tools-abcd"), "rev-parse", "HEAD"]
        self.assertEqual(ci.explicit_cache_arguments(original, self.native, self.native), original)

    def test_hosted_source_sha_and_clean_checkout_are_required(self):
        sha = "a" * 40
        with mock.patch.object(ci.subprocess, "check_output", side_effect=[sha + "\n", ""]):
            self.assertEqual(ci.source_identity(ROOT, sha), (sha, False))
        with mock.patch.object(ci.subprocess, "check_output", side_effect=[sha + "\n", ""]):
            with self.assertRaises(RuntimeError):
                ci.source_identity(ROOT, "b" * 40)
        with mock.patch.object(ci.subprocess, "check_output", side_effect=[sha + "\n", " M file\n"]):
            with self.assertRaises(RuntimeError):
                ci.source_identity(ROOT, sha)

    def test_command_plan_has_only_safe_build_and_test_actions(self):
        commands = [command for command, _ in ci.planned_checks()]
        self.assertTrue(any(command[:2] == ["swift", "test"] and command[-2:] == ["-j", "2"] for command in commands))
        self.assertTrue(any(command[:2] == ["swift", "build"] and command[-2:] == ["-j", "2"] for command in commands))
        self.assertIn(["bash", "tools/dryrun.sh", "--safe"], commands)
        self.assertIn(["bash", "tools/parity.sh"], commands)
        self.assertNotIn(["bash", "tools/dryrun.sh"], commands)
        for command in commands:
            self.assertNotIn("record", command)
            self.assertNotIn("screencapture", command)
            self.assertNotIn("codesign", command)

    def test_workflow_uses_both_runners_exact_sha_and_no_signing_secrets(self):
        workflow = (ROOT / ".github/workflows/native-ci.yml").read_text()
        self.assertIn("macos-latest", workflow)
        self.assertIn("macos-15-intel", workflow)
        self.assertIn("github.event.pull_request.head.sha || github.sha", workflow)
        self.assertIn("ref: ${{ env.NATIVE_SOURCE_SHA }}", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("python3 tools/native_ci.py", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("codesign", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
