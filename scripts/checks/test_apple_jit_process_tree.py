#!/usr/bin/env python3
"""Exercise cancellation ownership with synthetic kernels; never signal a PID."""

import copy
import ctypes
import errno
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("apple_processes", ROOT / "scripts/apple_jit_process_tree.py")
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)


class FakeKernel:
    def __init__(self, values=()):
        self.values = {item["pid"]: dict(item) for item in values}
        self.signals = []

    def snapshot(self):
        return copy.deepcopy(self.values)

    def read(self, pid):
        return copy.deepcopy(self.values.get(pid))

    def terminate(self, pid, number):
        assert number == signal.SIGTERM
        self.signals.append(pid)
        self.values.pop(pid, None)
        for child in self.values.values():
            if child["ppid"] == pid:
                child["ppid"] = 1


class CancellationTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="pleazyng-cancel-tree-test-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name) / "runs/42-123-attempt1/runner"
        (self.root / "_diag").mkdir(parents=True)
        (self.root / "retained-product").write_text("preserve")
        self.uid = os.geteuid()
        self.scope = {"run": "42", "job": "123", "attempt": "1"}
        self.proof = {"run": {"id": 42, "run_attempt": 1, "status": "completed",
                       "conclusion": "cancelled", "event": "workflow_dispatch", "head_branch": "main",
                       "head_repository": {"full_name": "snapetech-org/PlezyNG"}},
                      "job": {"id": 123, "run_id": 42, "run_attempt": 1,
                              "status": "completed", "conclusion": "cancelled"},
                      "registrationGone": True}
        self.elapsed = 0
        clock = patch.object(processes.time, "monotonic", side_effect=lambda: self.elapsed)
        sleep = patch.object(processes.time, "sleep", side_effect=self.advance)
        clock.start()
        sleep.start()
        self.addCleanup(clock.stop)
        self.addCleanup(sleep.stop)

    def advance(self, seconds):
        self.elapsed += seconds

    def item(self, pid, parent, executable, uid=None, microseconds=123):
        return {"pid": pid, "ppid": parent, "pgid": 100, "uid": self.uid if uid is None else uid,
                "seconds": 1000, "microseconds": microseconds, "executable": str(executable)}

    def fixture(self):
        listener = self.item(100, 1, self.root / "bin/Runner.Listener")
        dart = self.item(200, 100, self.root / "_work/_temp/flutter/bin/cache/dart-sdk/bin/dart")
        xcode = self.item(300, 200, "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild")
        cleanup = self.item(400, 100, "/usr/bin/python3")
        kernel = FakeKernel([listener, dart, xcode, cleanup])
        tree = processes.Tree(self.root, self.uid)
        tree.capture(kernel.snapshot(), launcher=100)
        processes.journal(self.root, tree, self.scope, phase="runner-exited", runnerExit=1)
        kernel.values.pop(100)
        kernel.values[200]["ppid"] = 1
        kernel.values[400]["ppid"] = 1
        return kernel

    def drain(self, kernel, signal_process=None, **kwargs):
        return processes.teardown(self.root, self.scope, self.proof, kernel,
                                  signal_process=signal_process or kernel.terminate, **kwargs)

    def test_captures_child_before_parent_signal_and_handles_reparenting(self):
        kernel = self.fixture()
        def signal_recorded(pid, number):
            receipts = list((self.root / "_diag").glob("cancellation-teardown-*.json"))
            self.assertEqual(len(receipts), 1)
            records = json.loads(receipts[0].read_text())["snapshots"][0]
            self.assertIn(300, [item["pid"] for item in records])
            kernel.terminate(pid, number)
        self.drain(kernel, signal_recorded)
        self.assertEqual(set(kernel.signals), {200, 300})
        self.assertIn(400, kernel.values)  # Post-job Python cleanup was not a build branch.
        self.assertEqual((self.root / "retained-product").read_text(), "preserve")

    def test_remembers_global_compiler_after_parent_disappears(self):
        kernel = self.fixture()
        kernel.values.pop(200)
        kernel.values[300]["ppid"] = 1
        self.drain(kernel)
        self.assertEqual(kernel.signals, [300])

    def test_unreaped_launcher_group_captures_an_already_orphaned_compiler(self):
        tree = processes.Tree(self.root, self.uid)
        listener = self.item(100, 1, self.root / "bin/Runner.Listener")
        compiler = self.item(300, 1, "/Applications/Xcode.app/xcodebuild")
        kernel = FakeKernel([listener, compiler])
        tree.capture(kernel.snapshot(), launcher=100)
        processes.journal(self.root, tree, self.scope, phase="runner-exited", runnerExit=1)
        kernel.values.pop(100)
        self.drain(kernel)
        self.assertEqual(kernel.signals, [300])

    def test_never_uses_a_recycled_group_number_after_launcher_is_reaped(self):
        kernel = self.fixture()
        kernel.values.pop(200)
        kernel.values.pop(300)
        kernel.values[301] = self.item(301, 1, "/Applications/Xcode.app/xcodebuild")
        self.drain(kernel)
        self.assertEqual(kernel.signals, [])

    def test_new_job_other_uid_and_prefix_lookalike_are_preserved(self):
        kernel = self.fixture()
        other = self.root.parent.parent / "43-124-attempt1/runner"
        for item in [self.item(500, 1, other / "bin/Runner.Listener"),
                     self.item(600, 500, other / "_work/dart"),
                     self.item(700, 600, "/Applications/Xcode.app/xcodebuild"),
                     self.item(800, 200, "/usr/bin/clang", uid=self.uid + 1),
                     self.item(900, 1, str(self.root) + "/_work-other/dart")]:
            kernel.values[item["pid"]] = item
        self.drain(kernel)
        self.assertEqual(set(kernel.signals), {200, 300})
        self.assertTrue({400, 500, 600, 700, 800, 900}.issubset(kernel.values))

    def test_pid_reuse_in_same_second_is_not_signalled(self):
        kernel = self.fixture()
        kernel.values.pop(200)
        kernel.values[300] = self.item(300, 1, "/Applications/Xcode.app/xcodebuild", microseconds=124)
        self.drain(kernel)
        self.assertEqual(kernel.signals, [])

    def test_revalidates_identity_immediately_before_signal(self):
        kernel = self.fixture()
        real_read = kernel.read
        def reused(pid):
            value = real_read(pid)
            if pid == 300:
                value["microseconds"] += 1
                kernel.values[pid] = value
            return value
        kernel.read = reused
        self.drain(kernel)
        self.assertEqual(kernel.signals, [200])
        self.assertIn(300, kernel.values)

    def test_refuses_incomplete_or_different_job_evidence(self):
        for change in [{"complete": False}, {"scope": {**self.scope, "attempt": "2"}},
                       {"root": str(self.root) + "-other"}, {"phase": "before-reap"}]:
            with self.subTest(change=change):
                kernel = self.fixture()
                path = self.root / "_diag/process-tree.json"
                data = json.loads(path.read_text())
                path.write_text(json.dumps({**data, **change}))
                with self.assertRaisesRegex(RuntimeError, "incomplete or belongs"):
                    self.drain(kernel)
                self.assertEqual(kernel.signals, [])

    def test_requires_fresh_matching_terminal_cancellation(self):
        mutations = [("run", "status", "in_progress"), ("run", "conclusion", "failure"),
                     ("run", "head_branch", "feature"), ("run", "run_attempt", 2),
                     ("job", "id", 124), ("job", "run_id", 43), ("job", "run_attempt", 2),
                     ("job", "status", "in_progress"), ("job", "conclusion", "success")]
        for section, key, value in mutations:
            with self.subTest(section=section, key=key):
                proof = copy.deepcopy(self.proof)
                proof[section][key] = value
                with self.assertRaises(RuntimeError):
                    processes.cancelled_proof(proof, self.scope)
        with self.assertRaises(RuntimeError):
            processes.cancelled_proof({**self.proof, "registrationGone": False}, self.scope)

    def test_old_runner_controls_prevent_any_signals(self):
        kernel = self.fixture()
        kernel.values[100] = self.item(100, 1, self.root / "bin/Runner.Listener")
        with self.assertRaisesRegex(RuntimeError, "control processes"):
            self.drain(kernel)
        self.assertEqual(kernel.signals, [])

    def test_busy_consumers_get_only_sigterm_and_retain_all_data(self):
        kernel = self.fixture()
        signals = []
        with self.assertRaisesRegex(RuntimeError, "preserving all runner data"):
            self.drain(kernel, lambda pid, number: signals.append((pid, number)), timeout=2)
        self.assertEqual(set(signals), {(200, signal.SIGTERM), (300, signal.SIGTERM)})
        self.assertEqual(self.elapsed, 2)
        self.assertEqual((self.root / "retained-product").read_text(), "preserve")

    def test_new_descendant_is_journaled_before_signal_for_retry(self):
        kernel = self.fixture()
        first = [True]
        original_snapshot = kernel.snapshot
        def discover():
            if first[0]:
                first[0] = False
                kernel.values[301] = self.item(301, 300, "/usr/bin/clang")
            return original_snapshot()
        kernel.snapshot = discover
        def denied(pid):
            raise PermissionError("synthetic permission failure")
        kernel.read = denied
        with self.assertRaises(PermissionError):
            self.drain(kernel)
        journal = json.loads((self.root / "_diag/process-tree.json").read_text())
        self.assertIn(301, [item["pid"] for item in journal["records"]])
        self.assertEqual(kernel.signals, [])

    def test_observer_captures_before_poll_reaps_and_records_orphans(self):
        kernel = self.fixture()
        (self.root / "_diag/process-tree.json").unlink()
        kernel.values[100] = self.item(100, 1, self.root / "bin/Runner.Listener")
        kernel.values[200]["ppid"] = 100
        child = Mock(pid=100)
        def reap():
            journal = json.loads((self.root / "_diag/process-tree.json").read_text())
            self.assertEqual(journal["phase"], "before-reap")
            self.assertIn(300, [item["pid"] for item in journal["records"]])
            kernel.values.pop(100)
            kernel.values.pop(200)
            kernel.values[300]["ppid"] = 1
            return 1
        child.poll.side_effect = reap
        self.assertEqual(processes.supervise(self.root, self.scope, kernel, lambda: child), 1)
        self.drain(kernel)
        self.assertEqual(kernel.signals, [300])
        child.terminate.assert_not_called()
        child.kill.assert_not_called()

    def test_failed_observer_never_kills_active_runner(self):
        child = Mock(pid=100)
        backend = Mock()
        backend.snapshot.side_effect = [{}, RuntimeError("inspection failed")]
        with self.assertRaises(RuntimeError):
            processes.supervise(self.root, self.scope, backend, lambda: child)
        data = json.loads((self.root / "_diag/process-tree.json").read_text())
        self.assertFalse(data["complete"])
        child.poll.assert_not_called()
        child.terminate.assert_not_called()
        child.kill.assert_not_called()

    def test_unobserved_launcher_never_authorizes_an_unknown_orphan(self):
        kernel = FakeKernel([self.item(300, 1, "/Applications/Xcode.app/xcodebuild")])
        child = Mock(pid=100)
        child.poll.return_value = 1
        self.assertEqual(processes.supervise(self.root, self.scope, kernel, lambda: child), 1)
        data = json.loads((self.root / "_diag/process-tree.json").read_text())
        self.assertFalse(data["complete"])
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            self.drain(kernel)
        self.assertEqual(kernel.signals, [])

    def test_observer_lock_and_symlink_evidence_are_not_bypassed(self):
        with processes.observer_lock(self.root):
            with self.assertRaises(BlockingIOError):
                with processes.observer_lock(self.root):
                    self.fail("A second observer acquired the same job")
        marker = self.root / "retained-product"
        link = self.root / "_diag/redirect.json"
        link.symlink_to(marker)
        with self.assertRaises(RuntimeError):
            processes.save(link, {})
        self.assertEqual(marker.read_text(), "preserve")

    def test_exact_runner_root_validation(self):
        with patch.object(processes, "RUNS_ROOT", self.root.parent.parent):
            processes.validate_root(self.root, "42", "123", "1")
            with self.assertRaises(RuntimeError):
                processes.validate_root(self.root, "43", "123", "1")

    def test_workflow_idle_guard_is_read_only_and_preserves_unrelated_active_job(self):
        kernel = self.fixture()
        kernel.values[100] = self.item(100, 1, self.root / "bin/Runner.Listener")
        path = self.root / "_diag/process-tree.json"
        before = path.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "build consumers remain"):
            processes.assert_idle(self.root, self.scope, kernel)
        kernel.values.pop(200)
        kernel.values.pop(300)
        other = self.item(500, 1, self.root.parent.parent / "43-124-attempt1/runner/_work/dart")
        other["pgid"] = 500
        kernel.values[500] = other
        processes.assert_idle(self.root, self.scope, kernel)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(kernel.signals, [])
        kernel.values.pop(100)
        with self.assertRaisesRegex(RuntimeError, "no longer live"):
            processes.assert_idle(self.root, self.scope, kernel)

    def test_completed_build_drains_only_owned_orphan_ibtoold(self):
        kernel = self.fixture()
        kernel.values[100] = self.item(100, 1, self.root / "bin/Runner.Listener")
        kernel.values.pop(200)
        owned = self.item(350, 300, "/Applications/Xcode.app/Contents/Developer/usr/bin/ibtoold")
        kernel.values[350] = owned
        data = json.loads((self.root / "_diag/process-tree.json").read_text())
        tree = processes.Tree(self.root, self.uid, data['records'], data['launcherIdentity'])
        tree.capture(kernel.snapshot(), launcher=100)
        processes.journal(self.root, tree, self.scope)
        kernel.values.pop(300)
        kernel.values[350]['ppid'] = 1
        other = self.item(500, 1, owned['executable'])
        other['pgid'] = 500
        kernel.values[500] = other
        processes.settle_idle(self.root, self.scope, kernel, kernel.terminate)
        self.assertEqual(kernel.signals, [350])
        self.assertIn(500, kernel.values)
        self.assertIn(100, kernel.values)

    def test_completed_build_never_stops_a_still_active_compiler(self):
        kernel = self.fixture()
        kernel.values[100] = self.item(100, 1, self.root / "bin/Runner.Listener")
        with self.assertRaisesRegex(RuntimeError, "build consumers remain"):
            processes.settle_idle(self.root, self.scope, kernel, kernel.terminate, timeout=2)
        self.assertEqual(kernel.signals, [])

    def test_workflow_scratch_guard_runs_before_any_owned_deletion(self):
        nfs = self.root.parent / "fixture-nfs"
        (nfs / "runs").mkdir(parents=True)
        target = nfs / "runs/p42-1-macos"
        owner = nfs / "runs/.plezyng-apple-scratch-p42-1-macos.owner"
        helper = self.root / ".apple-jit-process-tree.py"
        shell = self.root.parent / "fixture-cleanup.sh"
        shell.write_text((ROOT / "scripts/cleanup_apple_jit_scratch.sh").read_text().replace(
            'readonly NFS_MOUNT="/Volumes/p"', f'readonly NFS_MOUNT="{nfs}"'))
        for status in [1, 0]:
            with self.subTest(observer_status=status):
                target.mkdir(exist_ok=True)
                (target / "product").write_text("keep until idle")
                owner.write_text(f"run_id=42\nrun_attempt=1\njob=build-macos\nsha=fixture\n"
                                 f"scratch_mode=nfs-derived-data\ntask_root={target}\n")
                helper.write_text(f"raise SystemExit({status})\n")
                result = subprocess.run(["bash", str(shell), "macos"], capture_output=True, text=True,
                    env={**os.environ, "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "1",
                         "GITHUB_JOB": "build-macos", "GITHUB_SHA": "fixture",
                         "APPLE_JIT_PROCESS_HELPER": str(helper),
                         "APPLE_JIT_PROCESS_RUNNER_ROOT": str(self.root), "APPLE_JIT_PROCESS_JOB_ID": "123"})
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(target.exists(), bool(status))
                self.assertEqual(owner.exists(), bool(status))

    def test_cancelled_workflow_retains_scratch_even_without_observer(self):
        target = self.root.parent / "cancelled-scratch"
        target.mkdir()
        product = target / "unfinished-build"
        product.write_text("retain")
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/cleanup_apple_jit_scratch.sh"), "macos"],
            capture_output=True, text=True,
            env={**os.environ, "APPLE_JIT_JOB_STATUS": "cancelled"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("retaining", result.stdout)
        self.assertEqual(product.read_text(), "retain")

    def test_every_apple_workflow_cleanup_receives_terminal_status(self):
        import yaml
        for workflow in ["build", "ci"]:
            document = yaml.safe_load((ROOT / f".github/workflows/{workflow}.yml").read_text())
            for job in document['jobs'].values():
                for step in job.get('steps', []):
                    if 'bash scripts/cleanup_apple_jit_scratch.sh' in step.get('run', ''):
                        self.assertEqual(step.get('env', {}).get('APPLE_JIT_JOB_STATUS'), '${{ job.status }}')


class DarwinAdapterTests(unittest.TestCase):
    def info(self, microseconds=123, status=2):
        value = processes.BsdInfo()
        value.prefix[1], value.prefix[3], value.prefix[4], value.prefix[5] = status, 300, 200, 501
        value.seconds, value.microseconds = 1000, microseconds
        value.scheduling[1] = 100
        return value

    def backend(self):
        backend = processes.DarwinProcesses.__new__(processes.DarwinProcesses)
        backend.uid = 501
        backend.library = Mock()
        def path(pid, buffer, length):
            buffer.value = b"/Applications/Xcode.app/xcodebuild"
            return len(buffer.value)
        backend.library.proc_pidpath.side_effect = path
        return backend

    def test_public_darwin_layout_and_creation_time_reads(self):
        self.assertEqual(ctypes.sizeof(processes.BsdInfo), 136)
        self.assertEqual(processes.BsdInfo.seconds.offset, 120)
        backend = self.backend()
        backend.info = Mock(side_effect=[self.info(), self.info()])
        item = backend.read(300)
        self.assertEqual(processes.identity(item), (300, 501, 1000, 123))
        self.assertEqual(item["executable"], "/Applications/Xcode.app/xcodebuild")

    def test_detects_microsecond_pid_reuse_and_ignores_zombies(self):
        backend = self.backend()
        backend.info = Mock(side_effect=[self.info(), self.info(microseconds=124)])
        with self.assertRaisesRegex(RuntimeError, "reused"):
            backend.read(300)
        backend.info = Mock(return_value=self.info(status=5))
        backend.library.proc_pidpath.reset_mock()
        self.assertIsNone(backend.read(300))
        backend.library.proc_pidpath.assert_not_called()

    def test_permission_failure_is_not_treated_as_an_exited_process(self):
        backend = self.backend()
        backend.library.proc_pidinfo.return_value = 0
        with patch.object(ctypes, "get_errno", return_value=errno.EPERM):
            with self.assertRaises(RuntimeError):
                backend.info(300)
        with patch.object(ctypes, "get_errno", return_value=errno.ESRCH):
            self.assertIsNone(backend.info(300))

    def test_snapshot_requests_only_pids_and_never_arguments(self):
        backend = self.backend()
        backend.read = Mock(return_value={"pid": 300})
        with patch.object(processes.subprocess, "check_output", return_value="300\n") as ps:
            self.assertEqual(backend.snapshot(), {300: {"pid": 300}})
        self.assertEqual(ps.call_args.args[0], ["/bin/ps", "-U", "501", "-o", "pid="])


class LauncherCancellationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("jq"), "launcher fixture requires jq")
    def test_nonzero_cancelled_runner_reaches_guarded_teardown_before_archival(self):
        with tempfile.TemporaryDirectory(prefix="pleazyng-cancel-launcher-test-") as temporary:
            root = Path(temporary)
            gh = root / "gh"
            gh.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
root=pathlib.Path(os.environ['FIXTURE_ROOT'])
state=root/'requests.json'
counts=json.loads(state.read_text()) if state.exists() else {}
args=sys.argv[1:]
key=' '.join(args)
counts[key]=counts.get(key,0)+1
state.write_text(json.dumps(counts))
run={'id':42,'run_attempt':1,'status':'completed','conclusion':'cancelled',
     'event':'workflow_dispatch','head_branch':'main',
     'head_repository':{'full_name':'snapetech-org/PlezyNG'}}
job={'id':123,'run_id':42,'run_attempt':1,'status':'completed','conclusion':'cancelled',
     'labels':['private-apple','macOS','ARM64','gha-42-build-macos']}
if args[:2]==['repo','view']:
 print('snapetech-org/PlezyNG')
elif any('generate-jitconfig' in value for value in args):
 print('fixture-not-a-real-credential')
elif args==['api','repos/snapetech-org/PlezyNG/actions/runs/42']:
 if counts[key]<=2:run['status']='in_progress';run['conclusion']=None
 print(json.dumps(run))
elif args==['api','repos/snapetech-org/PlezyNG/actions/runs/42/jobs?per_page=100']:
 if counts[key]==1:job['status']='queued';job['conclusion']=None
 print(json.dumps({'jobs':[job]}))
elif args==['api','repos/snapetech-org/PlezyNG/actions/jobs/123']:
 print(json.dumps(job))
elif args[:1]==['api'] and 'runner-groups/8/runners?' in key:
 print('{"runners":[]}')
else:raise SystemExit('Unexpected fixture GitHub operation')
''')
            ssh = root / "ssh"
            ssh.write_text('''#!/usr/bin/env python3
import io,json,os,pathlib,sys,tarfile
root=pathlib.Path(os.environ['FIXTURE_ROOT'])
body=sys.stdin.read()
command=sys.argv[-1]
def event(value):
 with (root/'events').open('a') as stream:stream.write(value+'\\n')
if 'supervise ' in body:
 event('launch')
 raise SystemExit(1)
if ' teardown ' in command:
 proof=json.loads(body)
 assert proof['run']['status']=='completed' and proof['run']['conclusion']=='cancelled'
 assert proof['job']['id']==123 and proof['job']['run_attempt']==1
 assert proof['registrationGone'] is True
 event('teardown')
elif 'def clean(derived_root' in body:
 event('derived')
elif '/usr/bin/tar -czf -' in body:
 event('archive')
 output=io.BytesIO()
 with tarfile.open(fileobj=output,mode='w:gz') as archive:
  info=tarfile.TarInfo('_diag/proof.json');info.size=2
  archive.addfile(info,io.BytesIO(b'{}'))
 sys.stdout.buffer.write(output.getvalue())
elif 'shutil.rmtree(run_root)' in body:
 event('remove')
''')
            gh.chmod(0o755)
            ssh.chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/launch_apple_jit_runner.sh"), "42", "123"],
                env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                     "FIXTURE_ROOT": str(root), "APPLE_JIT_RUNNER_GROUP_ID": "8",
                     "APPLE_JIT_EVIDENCE_DIR": str(root / "evidence")},
                text=True, capture_output=True, timeout=15,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual((root / "events").read_text().splitlines(),
                             ["launch", "teardown", "derived", "archive"])
            self.assertIn("retaining runner", result.stderr)
            self.assertEqual(len(list((root / "evidence").glob("*-runner-diag.tar.gz"))), 1)
            self.assertNotIn("fixture-not-a-real-credential", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
