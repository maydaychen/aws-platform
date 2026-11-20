import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "build-universal.sh"
ROOT = SCRIPT.parent.parent


class BuildArgumentTests(unittest.TestCase):
    def capture_build_arguments(self, directory, *, through_symlink=False, architecture="arm64"):
        project = directory / "workspace with spaces"
        (project / "scripts").mkdir(parents=True)
        (project / "Assets" / "AppIcon").mkdir(parents=True)
        shutil.copy2(SCRIPT, project / "scripts" / SCRIPT.name)
        (project / "Package.resolved").write_text("{}\n")
        (project / "Assets" / "AppIcon" / "AppIcon.icns").write_bytes(b"fixture")
        tools = directory / "tools"
        tools.mkdir()
        log = directory / "arguments.json"
        executables = {
            "uname": "#!/bin/sh\nprintf 'Darwin\\n'\n",
            "xcrun": "#!/bin/sh\nprintf '/fixture/tool\\n'\n",
            "swift": """#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:] == ["build", "--help-hidden"]:
    print("swiftbuild")
    raise SystemExit(0)
with open(os.environ["BUILD_ARGUMENT_LOG"], "w") as stream:
    json.dump(sys.argv[1:], stream)
raise SystemExit(73)
""",
        }
        for name, source in executables.items():
            executable = tools / name
            executable.write_text(source)
            executable.chmod(0o755)
        invocation_root = project
        if through_symlink:
            invocation_root = directory / "workspace alias"
            invocation_root.symlink_to(project, target_is_directory=True)
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                           BUILD_ARGUMENT_LOG=str(log))
        result = subprocess.run([str(invocation_root / "scripts" / SCRIPT.name),
                                 "--architecture", architecture], env=environment,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 73)
        self.assertFalse((project / "dist").exists())
        return project, invocation_root, json.loads(log.read_text())

    def fixture_directory(self):
        temporary = ROOT / ".tmp" / "privacy-build-arguments"
        temporary.mkdir(parents=True, exist_ok=True)
        return tempfile.TemporaryDirectory(dir=temporary)

    def test_help_documents_architecture_and_version_without_building(self):
        result = subprocess.run([str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("universal|arm64|x86_64", result.stdout)
        self.assertIn("--version", result.stdout)
        self.assertIn("--build-number", result.stdout)

    def test_invalid_arguments_stop_before_build_or_directory_creation(self):
        for arguments in (
            ["--architecture", "intel"], ["--architecture"],
            ["--version", "0.2"], ["--version", "0.2.0</string>"],
            ["--build-number", "0"], ["--build-number", "1.2"],
            ["--output-dir"], ["--unknown"],
        ):
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(SCRIPT), *arguments], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("Building", result.stdout)

    def test_release_arguments_map_swift_c_and_cxx_with_workspace_spaces(self):
        for architecture in ("arm64", "x86_64"):
            with self.subTest(architecture=architecture), self.fixture_directory() as temporary:
                project, _, arguments = self.capture_build_arguments(Path(temporary), architecture=architecture)
                self.assertEqual(arguments[arguments.index("--arch") + 1], architecture)
                swift_flags = [arguments[index + 1] for index, value in enumerate(arguments) if value == "-Xswiftc"]
                self.assertEqual(swift_flags, ["-file-prefix-map", f"{project}=/build/aws-platform",
                                               "-debug-prefix-map", f"{project}=/build/aws-platform"])
                for forwarding_flag in ("-Xcc", "-Xcxx"):
                    compiler_flags = [arguments[index + 1] for index, value in enumerate(arguments)
                                      if value == forwarding_flag]
                    self.assertEqual(compiler_flags, [f"-ffile-prefix-map={project}=/build/aws-platform",
                                                      f"-fdebug-prefix-map={project}=/build/aws-platform"])

    def test_release_arguments_map_logical_and_canonical_workspace_paths(self):
        with self.fixture_directory() as temporary:
            project, alias, arguments = self.capture_build_arguments(Path(temporary), through_symlink=True)
            compiler_flags = [arguments[index + 1] for index, value in enumerate(arguments) if value == "-Xcc"]
            self.assertEqual(compiler_flags, [f"-ffile-prefix-map={alias}=/build/aws-platform",
                                              f"-fdebug-prefix-map={alias}=/build/aws-platform",
                                              f"-ffile-prefix-map={project}=/build/aws-platform",
                                              f"-fdebug-prefix-map={project}=/build/aws-platform"])

    @unittest.skipUnless(shutil.which("clang"), "Clang is required to inspect compiled file macros")
    def test_c_dependency_file_macros_are_remapped_in_actual_object_bytes(self):
        with self.fixture_directory() as temporary:
            project, _, arguments = self.capture_build_arguments(Path(temporary))
            source = project / "file macros.c"
            source.write_text("const char *file_macro = __FILE__;\n"
                              "const char *file_builtin = __builtin_FILE();\n")
            plain_object = project / "plain.o"
            mapped_object = project / "mapped.o"
            compiler_flags = [arguments[index + 1] for index, value in enumerate(arguments) if value == "-Xcc"]
            subprocess.run(["clang", "-c", str(source), "-o", str(plain_object)], check=True,
                           capture_output=True)
            subprocess.run(["clang", *compiler_flags, "-c", str(source), "-o", str(mapped_object)],
                           check=True, capture_output=True)
            self.assertIn(str(source).encode(), plain_object.read_bytes())
            mapped_bytes = mapped_object.read_bytes()
            self.assertNotIn(str(project).encode(), mapped_bytes)
            self.assertIn(b"/build/aws-platform/file macros.c", mapped_bytes)

    @unittest.skipUnless(shutil.which("xcrun") and shutil.which("clang"), "macOS tools are required")
    def test_debug_records_are_removed_without_losing_mapped_runtime_file_strings(self):
        with self.fixture_directory() as temporary:
            project, _, arguments = self.capture_build_arguments(Path(temporary))
            source, object_path, executable = project / "file.c", project / "file.o", project / "program"
            source.write_text('#include <stdio.h>\nint main(void) { puts(__FILE__); return 0; }\n')
            flags = [arguments[index + 1] for index, value in enumerate(arguments) if value == "-Xcc"]
            subprocess.run(["clang", "-g", *flags, "-c", str(source), "-o", str(object_path)],
                           capture_output=True, check=True)
            subprocess.run(["clang", "-g", str(object_path), "-o", str(executable)],
                           capture_output=True, check=True)
            expected = subprocess.check_output([str(executable)])
            self.assertEqual(expected, b"/build/aws-platform/file.c\n")
            self.assertIn(str(project).encode(), executable.read_bytes())
            subprocess.run(["xcrun", "strip", "-S", str(executable)], capture_output=True, check=True)
            self.assertNotIn(str(project).encode(), executable.read_bytes())
            self.assertEqual(subprocess.check_output([str(executable)]), expected)

    def test_per_slice_strip_runs_before_lipo_create_to_avoid_fat64_stdlib_tool_skip(self):
        script_text = SCRIPT.read_text(encoding="utf-8")
        slice_strip = 'xcrun strip -S "$stage_dir/$architecture/$app_name"'
        lipo_create = 'xcrun lipo -create "$stage_dir/arm64/$app_name" "$stage_dir/x86_64/$app_name"'
        stdlib_copy = "xcrun swift-stdlib-tool --copy"
        collect_licenses = 'scripts/collect-licenses.py" --output'
        self.assertIn(slice_strip, script_text)
        self.assertLess(script_text.index(slice_strip), script_text.index(lipo_create))
        self.assertLess(script_text.index(lipo_create), script_text.index(stdlib_copy))
        self.assertLess(script_text.index(stdlib_copy), script_text.index(collect_licenses))


if __name__ == "__main__":
    unittest.main()
