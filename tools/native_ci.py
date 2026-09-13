#!/usr/bin/env python3
"""Build/test the native app without capture, providers, signing, or user state."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "native"
PACKAGE_OPTIONS = [
    "--cache-path", ".build/ci-swiftpm-cache",
    "--config-path", ".build/ci-swiftpm-config",
    "--security-path", ".build/ci-swiftpm-security",
]


def explicit_cache_arguments(arguments, directory, native=NATIVE):
    """Preserve Git's bare-repository policy; explicitly address only build caches."""
    arguments = list(arguments)
    directory = Path(directory).resolve()
    native = Path(native).resolve()
    index = 0
    while index < len(arguments):
        value = arguments[index]
        if value == "-C" and index + 1 < len(arguments):
            directory = (directory / arguments[index + 1]).resolve()
            index += 2
        elif value.startswith("--git-dir"):
            return arguments
        elif value in ("-c", "--config-env") and index + 1 < len(arguments):
            index += 2
        elif value.startswith("-"):
            index += 1
        else:
            break
    caches = {
        (native / path).resolve() for path in (
            ".build/repositories",
            ".build/ci-swiftpm-cache/repositories",
            ".build/swiftpm-cache/repositories",
            "build/SourcePackages/repositories",
        )
    }
    if directory.parent in caches and native in directory.parents \
            and re.fullmatch(r"rapp-tools-[0-9a-f]+", directory.name):
        return ["--git-dir=" + str(directory), *arguments]
    return arguments


def forward_git():
    real = os.environ.get("CRISPY_CI_REAL_GIT")
    if not real or not Path(real).is_absolute() or Path(real).resolve() == Path(__file__).resolve():
        raise SystemExit("The CI Git adapter needs the original absolute Git executable")
    arguments = explicit_cache_arguments(sys.argv[1:], Path.cwd())
    os.execv(real, [real, *arguments])


def run(arguments, directory, environment):
    print("+ " + shlex.join([str(value) for value in arguments]), flush=True)
    subprocess.run(arguments, cwd=directory, env=environment, check=True)


def source_identity(root, expected):
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip())
    if expected:
        if not re.fullmatch(r"[0-9a-f]{40}", expected) or expected != actual:
            raise RuntimeError("Checkout does not match the requested exact native source SHA")
        if dirty:
            raise RuntimeError("The hosted native CI checkout must be clean before testing")
    return actual, dirty


def planned_checks(root=ROOT, native=NATIVE):
    return [
        ([sys.executable, "-m", "unittest", "discover", "-s", "tools", "-p", "test_native_ci.py", "-v"], root),
        (["swift", "test", *PACKAGE_OPTIONS, "-j", "2"], native),
        (["swift", "build", *PACKAGE_OPTIONS, "-j", "2"], native),
        (["bash", "tools/dryrun.sh", "--safe"], root),
        (["bash", "tools/parity.sh"], root),
        (["bash", "-n", "crispy", "hooks-notes.sh", "install.sh", "tools/dryrun.sh", "tools/parity.sh"], root),
    ]


def main():
    if len(sys.argv) != 1 or sys.platform != "darwin":
        raise SystemExit("Run tools/native_ci.py without arguments on macOS")
    source, dirty = source_identity(ROOT, os.environ.get("NATIVE_SOURCE_SHA"))
    print(f"Native source: {source}; local uncommitted changes: {dirty}", flush=True)
    work = NATIVE / ".build/ci-work"
    work.mkdir(mode=0o700, parents=True, exist_ok=True)
    result_file = work / "result.json"
    if result_file.exists() or result_file.is_symlink():
        result_file.unlink()
    bin_directory = NATIVE / ".build/ci-bin"
    bin_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    adapter = bin_directory / "git"
    script = Path(__file__).resolve()
    if adapter.exists() or adapter.is_symlink():
        if not adapter.is_symlink() or adapter.resolve() != script:
            raise RuntimeError("Refusing to replace an unexpected CI Git adapter")
    else:
        adapter.symlink_to(script)
    real_git = shutil.which("git")
    if not real_git or Path(real_git).resolve() == script:
        raise RuntimeError("Cannot identify the original Git executable")
    environment = os.environ.copy()
    environment.update({
        "CRISPY_CI_REAL_GIT": real_git,
        "PATH": str(bin_directory) + os.pathsep + environment.get("PATH", ""),
        "TMPDIR": str(work) + "/",
        "GIT_TERMINAL_PROMPT": "0",
        "CRISPY_HOME": str(work / "unused-user-state"),
        "CRISPY_NO_NOTES": "1",
        "CRISPY_NOTES_CONSENT": "0",
        "PYTHONDONTWRITEBYTECODE": "1",
    })
    environment.pop("RAPP_RUNTIME_BIN", None)
    for command, directory in planned_checks():
        run(command, directory, environment)
    command = ["swift", "build", *PACKAGE_OPTIONS, "--show-bin-path"]
    output = subprocess.check_output(command, cwd=NATIVE, env=environment, text=True).strip()
    executable = Path(output) / "RAPPCrispy"
    if NATIVE / ".build" not in executable.resolve().parents:
        raise RuntimeError("Swift returned a binary outside the project build directory")
    untouched = work / "self-check-must-not-create"
    if untouched.exists():
        raise RuntimeError("Unexpected state already exists at the no-capture self-check path")
    environment["CRISPY_HOME"] = str(untouched)
    run([str(executable), "--self-check"], NATIVE, environment)
    if untouched.exists():
        raise RuntimeError("The no-capture entrypoint unexpectedly created application state")
    result = {
        "kind": "native-ci-checks-only-not-distribution-evidence",
        "status": "passed",
        "source_sha": source,
        "local_uncommitted_changes": dirty,
        "runner_architecture": os.uname().machine,
        "checks": "Swift app/core tests and build, safe regressions/parity, Bash syntax, no-capture self-check",
        "capture_or_live_audio": False,
        "distribution_signing_or_notarization": False,
    }
    result_file.write_text(json.dumps(result, indent=2) + "\n")
    print("Native CI passed without capture, live providers, or distribution signing.", flush=True)


if __name__ == "__main__":
    if Path(sys.argv[0]).name == "git":
        forward_git()
    else:
        main()
