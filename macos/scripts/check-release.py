"""Require fresh, consistent release metadata before building a new DMG."""
import json
from pathlib import Path
import plistlib
import re
import sys
from datetime import date


def validate_changelog(root, version, build):
    text = (root / "CHANGELOG.md").read_text()
    entries = list(re.finditer(r"^## \[([^\]]+)\](?: - ([^\n]+))?\s*$", text, re.M))
    if not entries or entries[0][1] != "Unreleased":
        raise ValueError("CHANGELOG 必须以 Unreleased 区域开始")
    versions = [entry[1] for entry in entries[1:]]
    if not versions or versions[0] != version or versions.count(version) != 1:
        raise ValueError("CHANGELOG 顶部必须有唯一的当前版本条目")
    entry = entries[1]
    published = entry[2] or ""
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", published):
        raise ValueError("CHANGELOG 当前版本必须填写 YYYY-MM-DD 日期")
    date.fromisoformat(published)
    end = entries[2].start() if len(entries) > 2 else len(text)
    body = text[entry.end():end]
    if not re.search(rf"^构建号：{build}\s*$", body, re.M):
        raise ValueError("CHANGELOG 构建号必须与 Info.plist 一致")
    sections = re.split(r"^### (.+)\n", body, flags=re.M)
    changes = 0
    verified = False
    for title, content in zip(sections[1::2], sections[2::2]):
        title = title.strip()
        category = title.split(" / ", 1)[0]
        relevant = category in {"Added", "Changed", "Fixed", "Removed", "Deprecated", "Security"}
        if relevant or title == "验证与限制":
            bullets = re.findall(r"^- (\S[^\n]*)", content, re.M)
            if not bullets or any(re.search(r"待填写|待补充|\bTODO\b|\bTBD\b", line, re.I) for line in bullets):
                raise ValueError("CHANGELOG 的变更及验证限制必须填写实际内容，不能留空或保留模板")
            if relevant:
                changes += len(bullets)
            else:
                verified = True
    if not changes or not verified:
        raise ValueError("CHANGELOG 必须包含分类变更及验证与限制")


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("版本号必须为 major.minor.patch 格式")
    return tuple(map(int, value.split(".")))


def validate(root):
    info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    current = version_tuple(version)
    raw_build = info["CFBundleVersion"]
    if not isinstance(raw_build, str) or not raw_build.isdecimal() or int(raw_build) < 1:
        raise ValueError("构建号必须为正整数")
    build = int(raw_build)
    released = json.loads((root / "release.json").read_text())
    if current <= version_tuple(released["version"]) or build <= released["build"]:
        raise ValueError("新包的版本号和构建号都必须高于已发布版本，请更新 Resources/Info.plist")
    for package in (root / "dist").glob("WiFi-Switch-*-internal.dmg"):
        match = re.fullmatch(r"WiFi-Switch-(\d+\.\d+\.\d+)-.+-internal\.dmg", package.name)
        if match and current <= version_tuple(match[1]):
            raise ValueError("dist 中已有相同或更新版本的安装包，不能覆盖或回退")
    readme = (root / "README.md").read_text()
    heading = re.search(r"本次内部包为 \*\*([^，]+)，", readme)
    package_link = re.search(r"1\. 打开 `WiFi-Switch-([\d.]+)-", readme)
    if not heading or not package_link or heading[1] != version or package_link[1] != version:
        raise ValueError("README 的当前版本与安装文件名必须和 Info.plist 一致")
    validate_changelog(root, version, build)
    return {"version": version, "build": build}


def record(root):
    # Called only after signing, mount/content verification and SHA-256 generation.
    info = plistlib.loads((root / "dist/WiFi Switch.app/Contents/Info.plist").read_bytes())
    source = plistlib.loads((root / "Resources/Info.plist").read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if info[key] != source[key]:
            raise ValueError("构建产物与源文件版本不一致，不能记录发布")
    release = {"version": info["CFBundleShortVersionString"], "build": int(info["CFBundleVersion"])}
    validate_changelog(root, release["version"], release["build"])
    bundled_log = root / "dist/WiFi Switch.app/Contents/Resources/CHANGELOG.txt"
    if bundled_log.read_bytes() != (root / "CHANGELOG.md").read_bytes():
        raise ValueError("应用包内版本记录与源文件不一致，不能记录发布")
    previous = json.loads((root / "release.json").read_text())
    if version_tuple(release["version"]) <= version_tuple(previous["version"]) or release["build"] <= previous["build"]:
        raise ValueError("发布记录不能覆盖或回退")
    pending = root / "release.json.tmp"
    pending.write_text(json.dumps(release, indent=2) + "\n")
    pending.replace(root / "release.json")


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    try:
        if sys.argv[1:] == ["--record"]:
            record(root)
        elif not sys.argv[1:]:
            print("Release metadata verified:", validate(root))
        else:
            raise ValueError("用法：check-release.py [--record]")
    except (ValueError, KeyError, OSError) as error:
        sys.exit(f"打包已停止：{error}")
