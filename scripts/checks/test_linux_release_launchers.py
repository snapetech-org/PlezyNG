#!/usr/bin/env python3
"""Exercise release staging and installed launchers against packaging templates."""

import ast
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]


def step_script(workflow, name):
    text = (ROOT / ".github/workflows" / workflow).read_text()
    step = text.split(f"      - name: {name}\n", 1)[1].split("\n      - ", 1)[0]
    value = re.search(r"(?m)^        run: (.*)$", step)
    if value[1] == "|":
        return textwrap.dedent(step[value.end() + 1:])
    return value[1]


class LinuxReleaseLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pleazyng-launcher-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.packaging = self.root / "linux/packaging"
        shutil.copytree(ROOT / "linux/packaging", self.packaging)
        (self.root / "assets").mkdir()
        shutil.copy2(ROOT / "assets/pleazyng.png", self.root / "assets/pleazyng.png")
        shutil.copy2(ROOT / "LICENSE", self.root / "LICENSE")
        self.bundle = self.root / "build/linux/x64/release/bundle"
        (self.bundle / "lib").mkdir(parents=True)
        # A probe application records the wrapper's actual arguments and loader
        # environment; no Flutter or media runtime is substituted or qualified.
        executable = self.bundle / "pleazyng"
        executable.write_text(
            "#!/usr/bin/env python3\nimport json,os,sys\n"
            "print(json.dumps({'args':sys.argv[1:], 'libs':os.environ.get('LD_LIBRARY_PATH')}))\n"
        )
        executable.chmod(0o755)

    def run_script(self, script, **environment):
        return subprocess.run(["bash", "-euo", "pipefail", "-c", script],
                              cwd=self.root, env={**os.environ, **environment},
                              capture_output=True, text=True, check=True)

    def stage_release(self):
        self.run_script(step_script("build.yml", "Copy wrapper script into bundle"),
                        BUNDLE_DIR=str(self.bundle))

    def assert_launch(self, launcher, library_directory, **environment):
        self.assertTrue(os.access(launcher, os.X_OK), f"Launcher must be executable: {launcher}")
        result = subprocess.run([str(launcher), "a movie.mkv", "--title=a b"],
                                env={**os.environ, "LD_LIBRARY_PATH": "/existing", **environment},
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout), {
            "args": ["a movie.mkv", "--title=a b"],
            "libs": f"{library_directory}:/existing",
        })

    def test_release_and_ci_stage_executable_portable_launcher(self):
        for workflow, step in (("build.yml", "Copy wrapper script into bundle"),
                               ("ci.yml", "Copy wrapper script into the bundle")):
            with self.subTest(workflow=workflow):
                self.run_script(step_script(workflow, step), BUNDLE_DIR=str(self.bundle))
                self.assert_launch(self.bundle / "pleazyng.sh", self.bundle / "lib")
                self.assertFalse((self.bundle / "plezy.sh").exists())

    def test_appimage_entrypoint_executes_staged_bundle_launcher(self):
        self.stage_release()
        app = self.root / "Pleazyng.AppDir"
        shutil.copytree(self.bundle, app / "opt/pleazyng")
        shutil.copy2(self.packaging / "appimage/AppRun", app / "AppRun")
        (app / "AppRun").chmod(0o755)
        self.assert_launch(app / "AppRun", app / "opt/pleazyng/lib", APPDIR=str(app))

    def test_snap_staging_satisfies_actual_override_and_app_command(self):
        self.stage_release()
        self.run_script(step_script("build.yml", "Prepare Snap package inputs"),
                        BUNDLE_DIR=str(self.bundle), RELEASE_TAG="3.0.2")
        project = self.packaging / "snap"
        manifest = (project / "snapcraft.yaml").read_text()
        override = textwrap.dedent(manifest.split("    override-build: |\n", 1)[1]
                                   .split("    stage-packages:", 1)[0])
        installed = self.root / "snap-install"
        self.run_script(override, CRAFT_PROJECT_DIR=str(project),
                        CRAFT_PART_SRC=str(project / "src"), CRAFT_PART_INSTALL=str(installed))
        command = re.search(r"(?m)^    command: (.+)$", manifest)[1]
        self.assert_launch(installed / command, installed / "opt/pleazyng/lib")
        self.assertTrue((installed / "usr/share/applications/org.snapetech.pleazyng.desktop").is_file())

    @unittest.skipUnless(shutil.which("rpmbuild"), "rpmbuild is required for the source-RPM check")
    def test_copr_staging_supplies_every_declared_source(self):
        runner = self.root / "runner"
        assets = runner / "pleazyng-copr/assets"
        assets.mkdir(parents=True)
        for arch in ("x64", "arm64"):
            shutil.make_archive(str(assets / f"pleazyng-linux-{arch}"), "gztar", self.bundle)
        # This test checks SRPM input staging, not downloader integrity. Keep it
        # offline; exact helper-package verification has its own native checks.
        (self.packaging / "fetch-webkit-runtime.py").write_text(
            "import argparse\nfrom pathlib import Path\np=argparse.ArgumentParser()\n"
            "p.add_argument('--output',type=Path,required=True)\na=p.parse_args()\n"
            "for arch in ('x64','arm64'): (a.output/f'webkit-{arch}.deb').write_bytes(b'fixture')\n"
        )
        self.run_script(step_script("publish-copr.yml", "Build source RPM"),
                        RUNNER_TEMP=str(runner), RELEASE_TAG="v3.0.2", RELEASE_VERSION="3.0.2")
        top = runner / "pleazyng-rpmbuild"
        spec = (top / "SPECS/pleazyng.spec").read_text()
        for source in re.findall(r"(?m)^Source\d+:\s+(\S+)$", spec):
            self.assertTrue((top / "SOURCES" / source).is_file(), f"Missing RPM source: {source}")
        self.assertEqual(len(list((top / "SRPMS").glob("*.src.rpm"))), 1)

    @unittest.skipUnless(shutil.which("cc"), "cc is required for ELF dependency checks")
    def test_flatpak_runtime_check_resolves_app_and_converter_libraries(self):
        # Each probe needs a library available only inside its own closure.
        # Execute the production CHECK with only its /app mount relocated into
        # the fixture, so stale product paths or LD_LIBRARY_PATH cannot pass.
        library = self.root / "probe.c"
        library.write_text("int probe(void) { return 42; }\n")
        program = self.root / "main.c"
        program.write_text("int probe(void); int main(void) { return probe() != 42; }\n")
        subprocess.run(["cc", "-shared", "-fPIC", str(library), "-o",
                        str(self.bundle / "lib/libapp_probe.so")], check=True)
        subprocess.run(["cc", str(program), f"-L{self.bundle / 'lib'}", "-lapp_probe",
                        "-o", str(self.bundle / "pleazyng")], check=True)
        tools = self.bundle / "tools/dv"
        (tools / "lib/runtime").mkdir(parents=True)
        (tools / "libexec").mkdir()
        subprocess.run(["cc", "-c", str(library), "-o", str(tools / "lib/python.o")], check=True)
        subprocess.run(["cc", "-shared", "-fPIC", str(library), "-o",
                        str(tools / "lib/runtime/libconverter_probe.so")], check=True)
        subprocess.run(["cc", str(program), f"-L{tools / 'lib/runtime'}", "-lconverter_probe",
                        "-o", str(tools / "libexec/converter")], check=True)
        launcher = tools / "plezyng-dv-convert"
        launcher.write_text('#!/usr/bin/env bash\nroot="$(dirname "$0")"\n'
                            'export LD_LIBRARY_PATH="$root/lib/runtime"\n'
                            'exec "$root/libexec/converter" "$@"\n')
        launcher.chmod(0o755)
        self.stage_release()
        entry = self.root / "bin/pleazyng"
        entry.parent.mkdir()
        entry.symlink_to(self.bundle / "pleazyng.sh")
        module = ast.parse((self.packaging / "check-flatpak.py").read_text())
        check = next(ast.literal_eval(n.value) for n in module.body
                     if isinstance(n, ast.Assign) and any(
                         isinstance(t, ast.Name) and t.id == "CHECK" for t in n.targets))
        check = check.replace("/app/bin/pleazyng", str(entry))
        check = check.replace("/app/pleazyng", str(self.bundle))
        result = self.run_script(check)
        self.assertIn("Resolved all dependencies for 4 ELF objects", result.stdout)


if __name__ == "__main__":
    unittest.main()
