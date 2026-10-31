// ReaPack用の index.xml を、Luaファイルのメタデータと現在のコミットから生成します。
// 使い方: node tools/build-index.mjs
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const scriptName = "Jinriki_FilenamePitch_to_Target_Soloist.lua";
const repoUrl = "https://github.com/kokenamazu-boop/nama-ReaPitchMatch";
const repoName = "nama-ReaPitchMatch";

const source = readFileSync(join(root, scriptName), "utf8");
const lines = source.split(/\r?\n/);

function metadata(tag) {
  const prefix = `-- @${tag}`;
  const line = lines.find((value) => value.startsWith(prefix));
  return line ? line.slice(prefix.length).trim() : "";
}

const version = metadata("version");
const author = metadata("author");
const description = metadata("description");
const link = metadata("link") || repoUrl;

if (!version || !author || !description) {
  throw new Error("Luaファイルの @version / @author / @description を確認してください。");
}

function git(...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
}

const commit = git("rev-parse", "HEAD");
const commitDate = git("show", "-s", "--format=%cI", "HEAD");
const time = new Date(commitDate).toISOString().replace(/\.\d{3}Z$/, "Z");

function escapeXml(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

const sourceUrl = `${repoUrl}/raw/${commit}/${scriptName}`;
const xml = `<?xml version="1.0" encoding="utf-8"?>
<index version="1" commit="${escapeXml(commit)}" name="${escapeXml(repoName)}">
  <category name="Pitch">
    <reapack name="${escapeXml(scriptName)}" type="script" desc="${escapeXml(description)}">
      <metadata>
        <link rel="website">${escapeXml(link)}</link>
      </metadata>
      <version name="${escapeXml(version)}" author="${escapeXml(author)}" time="${escapeXml(time)}">
        <source main="main">${escapeXml(sourceUrl)}</source>
      </version>
    </reapack>
  </category>
</index>
`;

writeFileSync(join(root, "index.xml"), xml, "utf8");
console.log(`Wrote index.xml for ${scriptName} ${version} (${commit.slice(0, 7)})`);
