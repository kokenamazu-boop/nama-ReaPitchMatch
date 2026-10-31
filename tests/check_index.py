"""index.xml がLuaのメタデータと一致しているか確認します。"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
script_name = "nama-ReaPitchMatch.lua"
lua = (root / script_name).read_text(encoding="utf-8")


def metadata(tag: str) -> str:
    match = re.search(rf"^-- @{re.escape(tag)}\s*(.+)$", lua, re.MULTILINE)
    return match.group(1).strip() if match else ""


version = metadata("version")
author = metadata("author")
description = metadata("description")
assert version, "@version がありません"
assert author, "@author がありません"
assert description, "@description がありません"

tree = ET.parse(root / "index.xml")
index = tree.getroot()
assert index.tag == "index", "index要素がありません"
assert index.get("version") == "1", "index versionが1ではありません"
assert re.fullmatch(r"[0-9a-f]{40}", index.get("commit") or ""), "commitが40桁のSHAではありません"

reapack = index.find("./category/reapack")
assert reapack is not None, "category/reapack がありません"
assert reapack.get("name") == script_name, "スクリプト名が一致しません"
assert reapack.get("type") == "script", "typeがscriptではありません"
assert reapack.get("desc") == description, "descが@descriptionと一致しません"

entry = reapack.find("version")
assert entry is not None, "version要素がありません"
assert entry.get("name") == version, "versionが一致しません"
assert entry.get("author") == author, "authorが一致しません"
assert re.fullmatch(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", entry.get("time") or ""
), "timeがISO 8601 (UTC)ではありません"

source = entry.find("source")
assert source is not None, "source要素がありません"
assert source.get("main") == "main", "sourceのmain属性がありません"
url = source.text or ""
assert url.startswith("https://github.com/kokenamazu-boop/nama-ReaPitchMatch/raw/"), url
assert f"/raw/{index.get('commit')}/" in url, "source URLとcommitが一致しません"
assert url.endswith("/" + script_name), url

print(f"OK: index.xml {script_name} {version} ({index.get('commit')[:7]})")
