#!/usr/bin/env python3
"""Record Apple JIT execution trees; drain only a proven cancelled job's builds."""

import argparse
import ctypes
import errno
import fcntl
import json
import os
import pwd
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path, PurePosixPath


RUNS_ROOT = Path("/Users/gha-jit-macos/Library/Caches/gha-jit-macos/runs")
BUILD_TOOLS = {"dart", "xcodebuild", "clang", "clang++", "swiftc", "swift-frontend",
               "cargo", "rustc", "ninja", "make", "cmake", "ld", "libtool"}


def identity(process):
    return tuple(process[name] for name in ("pid", "uid", "seconds", "microseconds"))


def protected(process):
    name = PurePosixPath(process["executable"]).name
    return name.startswith("Runner.") or name == "caffeinate" or process["pid"] == os.getpid()


def under(path, root):
    value = PurePosixPath(path)
    return value.is_absolute() and ".." not in value.parts and PurePosixPath(root) in value.parents


class BsdInfo(ctypes.Structure):
    # Public Darwin PROC_PIDTBSDINFO ABI, including microsecond creation time:
    # https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h
    _fields_ = [("prefix", ctypes.c_uint32 * 12), ("command", ctypes.c_char * 16),
                ("name", ctypes.c_char * 32), ("scheduling", ctypes.c_uint32 * 6),
                ("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]


class DarwinProcesses:
    """Read kernel identities and executable paths, never process arguments."""

    def __init__(self, uid):
        if sys.platform != "darwin" or ctypes.sizeof(BsdInfo) != 136:
            raise RuntimeError("Apple process inspection requires the supported Darwin ABI.")
        self.uid = uid
        self.library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                            ctypes.c_void_p, ctypes.c_int]
        self.library.proc_pidinfo.restype = ctypes.c_int
        self.library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.library.proc_pidpath.restype = ctypes.c_int

    def info(self, pid):
        result = BsdInfo()
        ctypes.set_errno(0)
        count = self.library.proc_pidinfo(pid, 3, 0, ctypes.byref(result), ctypes.sizeof(result))
        if count != ctypes.sizeof(result):
            if ctypes.get_errno() in {errno.ESRCH, errno.ENOENT}:
                return None
            raise RuntimeError(f"Cannot establish kernel identity for PID {pid}.")
        if result.prefix[3] != pid:
            raise RuntimeError("Kernel process identity changed while reading it.")
        return result

    def read(self, pid):
        before = self.info(pid)
        if before is None or before.prefix[5] != self.uid or before.prefix[1] == 5:  # SZOMB
            return None
        path = ctypes.create_string_buffer(4096)
        if self.library.proc_pidpath(pid, path, len(path)) <= 0:
            exited = self.info(pid)
            if exited is None or exited.prefix[1] == 5:
                return None
            raise RuntimeError(f"Cannot establish executable ownership for PID {pid}.")
        after = self.info(pid)
        if after is None or after.prefix[1] == 5:
            return None
        if (before.prefix[5], before.seconds, before.microseconds) != (
                after.prefix[5], after.seconds, after.microseconds):
            raise RuntimeError("PID was reused during process inspection.")
        return {"pid": pid, "ppid": int(after.prefix[4]), "pgid": int(after.scheduling[1]),
                "uid": int(after.prefix[5]),
                "seconds": int(after.seconds), "microseconds": int(after.microseconds),
                "executable": os.fsdecode(path.value)}

    def snapshot(self):
        pids = subprocess.check_output(["/bin/ps", "-U", str(self.uid), "-o", "pid="],
                                       text=True, timeout=5)
        result = {}
        for value in pids.split():
            process = self.read(int(value))
            if process is not None:
                result[process["pid"]] = process
        return result


class Tree:
    def __init__(self, root, uid, records=(), launcher_identity=None):
        self.root, self.uid = str(root), uid
        self.records = {identity(item): dict(item) for item in records}
        self.launcher_identity = launcher_identity

    def capture(self, snapshot, launcher=None):
        own = {pid: item for pid, item in snapshot.items() if item["uid"] == self.uid}
        selected = {identity(item) for item in own.values() if identity(item) in self.records}
        if launcher is not None and launcher in own:
            selected.add(identity(own[launcher]))
            self.launcher_identity = list(identity(own[launcher]))
            # Popen created a new session. Until poll()/wait() reaps that child,
            # its PID cannot be recycled: same-session group members are still
            # attributable even if an intermediate already exited. Never use a
            # remembered group number to discover processes after reaping.
            if own[launcher]["pgid"] == launcher:
                selected.update(identity(item) for item in own.values() if item["pgid"] == launcher)
        for item in own.values():
            if under(item["executable"], PurePosixPath(self.root) / "_work"):
                selected.add(identity(item))
        changed = True
        while changed:
            changed = False
            for item in own.values():
                parent = own.get(item["ppid"])
                if parent is not None and identity(parent) in selected and identity(item) not in selected:
                    selected.add(identity(item))
                    changed = True
        # Eligibility is retained by identity after a parent exits or execs.
        eligible = {key for key in selected if self.records.get(key, {}).get("build", False)}
        for item in own.values():
            key = identity(item)
            if key in selected and not protected(item) and (
                    under(item["executable"], PurePosixPath(self.root) / "_work")
                    or PurePosixPath(item["executable"]).name in BUILD_TOOLS):
                eligible.add(key)
        changed = True
        while changed:
            changed = False
            for item in own.values():
                key = identity(item)
                parent = own.get(item["ppid"])
                if (key in selected and key not in eligible and not protected(item)
                        and parent is not None and identity(parent) in eligible):
                    eligible.add(key)
                    changed = True
        for item in own.values():
            key = identity(item)
            if key in selected:
                self.records[key] = {**item, "build": key in eligible}
        if len(self.records) > 20000:
            raise RuntimeError("Process evidence limit reached; retaining the job for inspection.")
        return [item for item in own.values() if identity(item) in eligible and not protected(item)]


def save(path, data):
    if path.is_symlink() or (path.exists() and path.stat().st_uid != os.geteuid()):
        raise RuntimeError("Refusing to overwrite unfamiliar process evidence.")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", prefix=".process-tree-", dir=path.parent,
                                         delete=False) as stream:
            temporary = Path(stream.name)
            os.chmod(temporary, 0o600)
            json.dump(data, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def validate_root(root, run_id, job_id, attempt):
    if (not all(re.fullmatch(r"[0-9]+", value) for value in (run_id, job_id, attempt))
            or root != RUNS_ROOT / f"{run_id}-{job_id}-attempt{attempt}" / "runner"
            or root.is_symlink() or root.resolve() != root or not root.is_dir()
            or root.stat().st_uid != os.geteuid()
            or (root / "_diag").is_symlink() or not (root / "_diag").is_dir()
            or (root / "_diag").stat().st_uid != os.geteuid()):
        raise RuntimeError("Refusing process cleanup outside this exact owned runner.")


def journal(root, tree, scope, **extra):
    save(root / "_diag/process-tree.json", {"schema": 1, "scope": scope, "uid": tree.uid,
         "root": tree.root, "launcherIdentity": tree.launcher_identity,
         "complete": True, "records": list(tree.records.values()), **extra})


@contextmanager
def observer_lock(root):
    path = root / "_diag/process-tree.lock"
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if metadata.st_uid != os.geteuid() or not stat.S_ISREG(metadata.st_mode):
            raise RuntimeError("Unfamiliar process observer lock owner.")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


def supervise(root, scope, backend, launch):
    evidence = root / "_diag/process-tree.json"
    if evidence.exists() or evidence.is_symlink():
        raise RuntimeError("Refusing to reuse a process journal.")
    tree = Tree(root, os.geteuid())
    backend.snapshot()  # Fail before starting a job if inspection is unavailable.
    child = launch()
    try:
        while True:
            tree.capture(backend.snapshot(), launcher=child.pid)
            journal(root, tree, scope, phase="before-reap", complete=tree.launcher_identity is not None)
            result = child.poll()  # Capture the tree BEFORE observing/reaping exit.
            if result is not None:
                tree.capture(backend.snapshot())
                journal(root, tree, scope, phase="runner-exited", runnerExit=result,
                        complete=tree.launcher_identity is not None)
                return result
            time.sleep(1)
    except BaseException as error:
        journal(root, tree, scope, complete=False, phase="inspection-failed", errorType=type(error).__name__)
        # Never kill an active job because its observer failed or disconnected.
        raise


def cancelled_proof(proof, scope):
    run, job = proof.get("run", {}), proof.get("job", {})
    if (run.get("id") != int(scope["run"]) or run.get("run_attempt") != int(scope["attempt"])
            or run.get("status") != "completed" or run.get("conclusion") != "cancelled"
            or run.get("event") != "workflow_dispatch" or run.get("head_branch") != "main"
            or run.get("head_repository", {}).get("full_name") != "snapetech-org/PlezyNG"
            or job.get("id") != int(scope["job"]) or job.get("run_id") != int(scope["run"])
            or job.get("run_attempt") != int(scope["attempt"])
            or job.get("status") != "completed" or job.get("conclusion") != "cancelled"
            or proof.get("registrationGone") is not True):
        raise RuntimeError("Fresh completed cancellation and absent registration are required.")


def assert_idle(root, scope, backend):
    """Read-only guard for a workflow cleanup step while its observer is alive."""
    path = root / "_diag/process-tree.json"
    if path.is_symlink() or not path.is_file() or path.stat().st_uid != os.geteuid():
        raise RuntimeError("No owned process evidence; preserving scratch.")
    data = json.loads(path.read_text())
    if (data.get("schema") != 1 or data.get("scope") != scope or data.get("uid") != os.geteuid()
            or data.get("root") != str(root) or data.get("complete") is not True):
        raise RuntimeError("Incomplete process evidence; preserving scratch.")
    snapshot = backend.snapshot()
    launcher_identity = data.get("launcherIdentity")
    if not launcher_identity:
        raise RuntimeError("No captured launcher identity; preserving scratch.")
    launcher = snapshot.get(launcher_identity[0])
    if launcher is None or list(identity(launcher)) != launcher_identity:
        raise RuntimeError("Runner identity is no longer live; preserve scratch for terminal cleanup.")
    tree = Tree(root, os.geteuid(), data["records"], launcher_identity)
    if tree.capture(snapshot, launcher=launcher["pid"]):
        raise RuntimeError("Owned build consumers remain active; preserving scratch.")


def settle_idle(root, scope, backend, signal_process=os.kill, timeout=15):
    """Stop only this completed build's orphaned Interface Builder daemons.

    Xcode intentionally leaves ibtoold alive after xcodebuild exits. GitHub's
    post-job cleanup would terminate these, but workflow scratch cleanup runs
    earlier. Never stop a compiler, a non-orphan, or an unfamiliar process.
    """
    path = root / "_diag/process-tree.json"
    deadline = time.monotonic() + timeout
    signalled = set()
    while True:
        try:
            assert_idle(root, scope, backend)
            return
        except RuntimeError as error:
            if str(error) != "Owned build consumers remain active; preserving scratch.":
                raise
        data = json.loads(path.read_text())
        snapshot = backend.snapshot()
        launcher_identity = data["launcherIdentity"]
        launcher = snapshot.get(launcher_identity[0])
        if launcher is None or list(identity(launcher)) != launcher_identity:
            raise RuntimeError("Runner identity changed; preserving scratch.")
        tree = Tree(root, os.geteuid(), data["records"], launcher_identity)
        targets = tree.capture(snapshot, launcher=launcher["pid"])
        # A still-active build may own ibtoold as well. Only drain when all
        # remaining build consumers are the known orphaned idle service.
        if targets and all(item["ppid"] == 1 and item["executable"] ==
                "/Applications/Xcode.app/Contents/Developer/usr/bin/ibtoold" for item in targets):
            for target in targets:
                key = identity(target)
                if key in signalled:
                    continue
                current = backend.read(target["pid"])
                if (current is None or identity(current) != key or current["ppid"] != 1
                        or current["executable"] != target["executable"]):
                    continue
                print(f"Stopping completed-job Interface Builder service PID {current['pid']}", flush=True)
                try:
                    signal_process(current["pid"], signal.SIGTERM)
                except ProcessLookupError:
                    pass
                signalled.add(key)
        if time.monotonic() >= deadline:
            raise RuntimeError("Owned build consumers remain active; preserving scratch.")
        time.sleep(min(1, max(0, deadline - time.monotonic())))


def teardown(root, scope, proof, backend, signal_process=os.kill, timeout=15):
    cancelled_proof(proof, scope)
    evidence = root / "_diag/process-tree.json"
    if evidence.is_symlink() or not evidence.is_file() or evidence.stat().st_uid != os.geteuid():
        raise RuntimeError("A retained owned process journal is required.")
    data = json.loads(evidence.read_text())
    if (data.get("schema") != 1 or data.get("scope") != scope or data.get("uid") != os.geteuid()
            or data.get("root") != str(root) or data.get("complete") is not True
            or data.get("phase") != "runner-exited"):
        raise RuntimeError("Process capture is incomplete or belongs to a different job.")
    tree = Tree(root, os.geteuid(), data["records"], data.get("launcherIdentity"))
    deadline = time.monotonic() + timeout
    signalled = set()
    receipt = {"scope": scope, "proof": proof, "signals": [], "snapshots": []}
    receipt_path = root / "_diag" / f"cancellation-teardown-{time.time_ns()}.json"
    while True:
        snapshot = backend.snapshot()
        targets = tree.capture(snapshot)
        journal(root, tree, scope, phase="runner-exited", runnerExit=data.get("runnerExit"))
        receipt["snapshots"].append(list(tree.records.values()))
        save(receipt_path, receipt)  # Persist ALL descendants before the first signal.
        if any(under(item["executable"], root) and PurePosixPath(item["executable"]).name.startswith("Runner.")
               for item in snapshot.values()):
            receipt["result"] = "control-active"
            save(receipt_path, receipt)
            raise RuntimeError("The cancelled runner still has control processes; preserving them.")
        if not targets:
            receipt["result"] = "drained"
            save(receipt_path, receipt)
            return
        if time.monotonic() >= deadline:
            receipt["result"] = "still-busy"
            save(receipt_path, receipt)
            raise RuntimeError("Cancelled build consumers remain; preserving all runner data.")
        for target in targets:
            key = identity(target)
            if key in signalled:
                continue
            current = backend.read(target["pid"])
            if current is None or identity(current) != key or protected(current):
                continue
            receipt["signals"].append({"identity": list(key), "signal": "SIGTERM"})
            save(receipt_path, receipt)
            try:
                signal_process(current["pid"], signal.SIGTERM)
            except ProcessLookupError:
                pass
            signalled.add(key)
        time.sleep(min(1, max(0, deadline - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("supervise", "teardown", "assert-idle", "settle-idle"))
    parser.add_argument("run")
    parser.add_argument("job")
    parser.add_argument("attempt")
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    if os.geteuid() != pwd.getpwnam("gha-jit-macos").pw_uid:
        raise SystemExit("Only the Apple JIT service user may inspect this execution tree.")
    validate_root(args.root, args.run, args.job, args.attempt)
    scope = {name: getattr(args, name) for name in ("run", "job", "attempt")}
    backend = DarwinProcesses(os.geteuid())
    if args.mode in {"assert-idle", "settle-idle"}:
        (settle_idle if args.mode == "settle-idle" else assert_idle)(args.root, scope, backend)
        return
    with observer_lock(args.root):
        if args.mode == "teardown":
            teardown(args.root, scope, json.load(sys.stdin), backend)
        else:
            token = os.environ.pop("JIT_CONFIG")
            # Keep the direct child's PID reserved until capture precedes poll.
            signal.signal(signal.SIGCHLD, signal.SIG_DFL)
            result = supervise(args.root, scope, backend, lambda: subprocess.Popen(
                [str(args.root / "run.sh"), "--jitconfig", token], cwd=args.root,
                start_new_session=True))
            raise SystemExit(result if result >= 0 else 128 - result)


if __name__ == "__main__":
    main()
