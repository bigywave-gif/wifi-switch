import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_check", Path(__file__).with_name("check-release.py"))
release_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_check)


class ReleaseGuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "Resources").mkdir()
        (self.root / "dist").mkdir()
        (self.root / "release.json").write_text(json.dumps({"version": "0.1.36", "build": 37}))
        self.prepare()

    def prepare(self, version="0.1.37", build="38", readme_version=None):
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": version, "CFBundleVersion": build
        }))
        shown = readme_version or version
        (self.root / "README.md").write_text(
            f"本次内部包为 **{shown}，Apple Silicon**\n"
            f"1. 打开 `WiFi-Switch-{shown}-arm64-internal.dmg`\n"
        )
        (self.root / "CHANGELOG.md").write_text(
            f"# Changelog\n\n## [Unreleased]\n\n## [{version}] - 2026-10-22\n\n构建号：{build}\n\n"
            "### Fixed / 修复\n\n- 连接断开后清除旧的网络信息。\n\n"
            "### 验证与限制\n\n- 隔离状态测试通过；未切换真实网络。\n"
        )

    def test_missing_changelog_blocks_packaging(self):
        (self.root / "CHANGELOG.md").unlink()
        with self.assertRaises(OSError): release_check.validate(self.root)

    def test_incomplete_or_stale_notes_are_rejected(self):
        original = (self.root / "CHANGELOG.md").read_text()
        invalid = [
            original.replace("## [Unreleased]", "## [Pending]"),
            original.replace("[0.1.37]", "[0.1.36]"),
            original + "\n## [0.1.37] - 2026-10-22\n",
            original.replace("构建号：38", "构建号：37"),
            original.replace("2026-10-22", "2026-02-30"),
            original.replace("2026-10-22", "日期待核实"),
            original.replace("连接断开后清除旧的网络信息。", "待填写"),
            original.replace("- 连接断开后清除旧的网络信息。", ""),
            original.replace("### Fixed / 修复", "### 其他"),
            original.replace("### 验证与限制", "### 未知标题"),
            original.replace("- 隔离状态测试通过；未切换真实网络。", ""),
        ]
        for text in invalid:
            with self.subTest(text=text):
                (self.root / "CHANGELOG.md").write_text(text)
                with self.assertRaises(ValueError): release_check.validate(self.root)

    def test_historical_unknowns_do_not_block_a_complete_new_release(self):
        path = self.root / "CHANGELOG.md"
        path.write_text(path.read_text() + "\n## [0.1.35] - 日期待核实\n\n构建号：未核实\n")
        self.assertEqual(release_check.validate(self.root)["version"], "0.1.37")

    def test_fresh_version_is_accepted_without_changing_release(self):
        self.assertEqual(release_check.validate(self.root), {"version": "0.1.37", "build": 38})
        self.assertEqual(json.loads((self.root / "release.json").read_text())["build"], 37)

    def test_version_and_build_must_both_advance(self):
        for version, build in [("0.1.36", "38"), ("0.1.37", "37"), ("0.1.35", "36")]:
            with self.subTest(version=version, build=build):
                self.prepare(version, build)
                with self.assertRaises(ValueError): release_check.validate(self.root)

    def test_stale_readme_is_rejected(self):
        self.prepare(readme_version="0.1.36")
        with self.assertRaises(ValueError): release_check.validate(self.root)

    def test_existing_artifact_cannot_be_overwritten_even_if_record_is_old(self):
        (self.root / "dist/WiFi-Switch-0.1.37-arm64-internal.dmg").touch()
        with self.assertRaises(ValueError): release_check.validate(self.root)

    def test_only_matching_built_metadata_can_advance_record(self):
        output = self.root / "dist/WiFi Switch.app/Contents"
        output.mkdir(parents=True)
        (output / "Resources").mkdir()
        (output / "Resources/CHANGELOG.txt").write_bytes((self.root / "CHANGELOG.md").read_bytes())
        info = plistlib.loads((self.root / "Resources/Info.plist").read_bytes())
        info["CFBundleVersion"] = "37"
        (output / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError): release_check.record(self.root)
        self.assertEqual(json.loads((self.root / "release.json").read_text())["build"], 37)
        (output / "Info.plist").write_bytes((self.root / "Resources/Info.plist").read_bytes())
        release_check.record(self.root)
        self.assertEqual(json.loads((self.root / "release.json").read_text()), {"version": "0.1.37", "build": 38})
        with self.assertRaises(ValueError): release_check.record(self.root)

    def test_changed_bundled_notes_cannot_advance_release(self):
        output = self.root / "dist/WiFi Switch.app/Contents"
        (output / "Resources").mkdir(parents=True)
        (output / "Info.plist").write_bytes((self.root / "Resources/Info.plist").read_bytes())
        (output / "Resources/CHANGELOG.txt").write_text("stale history")
        with self.assertRaises(ValueError): release_check.record(self.root)
        self.assertEqual(json.loads((self.root / "release.json").read_text())["build"], 37)


if __name__ == "__main__":
    unittest.main()
