# zcode-zops to Windows — token-efficient Windows ops toolkit for ZCode

A single-file PowerShell MCP plugin that gives ZCode agents **16 token-saving tools** for everyday work on Windows: capped file reads, code search, atomic edits, smart command output filtering, secret masking, and more. Every output is budgeted; every failure is honest.

> ~60–90% of an agent's token spend is raw command output and file dumps. zcode-zops caps and cleans all of it.

## Why

AI coding agents burn most of their tokens on things that are not the task: full file dumps, verbose build logs, 40-line `git status` output, and re-reading files they already edited. zcode-zops replaces those calls with budgeted, structured, encoding-aware equivalents.

## Requirements

- Windows 10/11
- PowerShell 5.1 (built into Windows) — nothing else required
- Optional: [Git](https://git-scm.com/) (better diffs), PowerShell 7 (`pwsh`), any Node.js runtime — all auto-detected, all optional

## Install

### Option A — marketplace (recommended)

This repo ships its own marketplace catalog ([`marketplace.json`](./marketplace.json)), served straight from GitHub. In ZCode:

1. Open the plugin marketplace page → gear icon → **Marketplace Sources / 市场源** → add a source by URL:

   ```
   https://raw.githubusercontent.com/2LC16/zcode-zops-to-windows/main/marketplace.json
   ```

2. Refresh, install **`zcode-zops-to-windows@2lc16-plugins`**, restart ZCode.

The catalog points at [`dist/plugin.zip`](./dist/plugin.zip) (pinned by `sha256`), so installation does not require cloning this repo. The same bytes are attached to the [v0.3.9 release](https://github.com/2LC16/zcode-zops-to-windows/releases/tag/v0.3.9) when the upload host is reachable.

### Option B — manual

1. Clone this repo (or download and extract).
2. Copy the whole folder into your ZCode plugin cache:

```
C:\Users\<you>\.zcode\cli\plugins\cache\<marketplace>\zcode-zops-to-windows\<version>\
```

3. Enable it in `C:\Users\<you>\.zcode\cli\config.json`:

```json
"plugins": { "enabledPlugins": { "zcode-zops-to-windows@2lc16-plugins": true } }
```

4. Restart ZCode. Done — the MCP server spawns automatically.

5. **Recommended** — tell your agent to actually reach for the tools. Generic "prefer efficient tools" wording was measured to change little; a concrete block with explicit exclusions works better. Append to your global `AGENTS.md` (`~/.zcode/AGENTS.md`) or the project's:

````markdown
## zcode-zops — use these by default
- Read files with `read` (paged / `tail` / char budget) instead of `cat` / `type`; search with `grep`; survey a tree with `tree` / `outline` / `status`; inspect JSON with `json`.
- Edit with `edit` (atomic find/replace + `expected_count`) and verify with `diff` — never read a whole file just to rewrite it. Create files with `write`.
- Run commands through `run` (always `smart: true` when output can exceed ~6000 chars); dangerous commands need an explicit `confirm: true`.
- Persist cross-turn findings in `notes` so they survive context compaction.
- Fall back to native tools when: a task must outlive the ~30 s per-call host cap (builds, downloads — use the session's background shell), a tiny file reads in one go, an action needs an interactive editor panel, or a tool errors twice in a row.
````

## The 16 tools

| Tool | What it does |
|---|---|
| `read` | Paged file reads (offset/limit/tail), char-budgeted, auto-detects UTF-8/BOM/UTF-16/GB18030 |
| `grep` | Regex search across files/dirs, capped matches, secret masking |
| `tree` | Directory tree with depth/entry caps, skips node_modules/.git/... |
| `run` | Shell runner (cmd/PowerShell/pwsh/bash): capped output, timeout kill, optional rtk-style `smart` filtering, dangerous-command gate, secret masking |
| `edit` | Atomic find/replace with `expected_count` guard — 0 hits or mismatch = error, nothing written |
| `write` | Create new files with explicit encoding (complements `edit`) |
| `diff` | Capped two-file diff via git, coarse fallback without |
| `outline` | Code skeleton scan: def/class/fn/interface per language, file or dir |
| `status` | One-call workspace snapshot: git, file totals, largest files, big logs, disk |
| `doctor` | Environment health: shells, python/git/node, disk, temp, encoding notes |
| `notes` | Per-workspace persistent scratchpad — key findings survive compaction |
| `replace` | Multi-file regex replace: dry-run by default, `apply` + `expected_files` writes |
| `json` | JSON validate/inspect: structure summary or dot-path query |
| `port` | Port → PID → process name; optional kill with confirm |
| `http` | Local-capable structured HTTP probe (status/duration/size/body) |
| `stats` | The ledger: calls, output chars, estimated tokens (~chars/4), per tool/day |

## The rtk-style promises (for `run smart`, masking, and every filter)

1. **Never blocks** — if a filter fails you get the raw output.
2. **Never worse** — filtered output is only used when strictly shorter.
3. **Nothing hidden** — truncated output names where the full version is kept.

## Safety rails

- Dangerous commands (`rm -rf`, `del /s`, `git reset --hard`, `format X:`, ...) are **refused** unless `confirm: true`.
- Secret-shaped strings (API keys, JWTs, private keys) are **masked** as `[REDACTED:*]` in `run`/`grep` output unless `raw: true`. (`read` stays unmasked so editing config files stays lossless.)
- `replace` is dry-run by default; writing requires `apply: true` and can be pinned with `expected_files`.

## Environment variables (all optional)

| Var | Effect |
|---|---|
| `ZOPS_DATA_DIR` | Where `notes`/`stats` store data. Default: `%LOCALAPPDATA%\zops`. |
| `ZOPS_DISABLE_GIT` | Set to force git-off fallback paths (coarse diff, no git in status/doctor). |

## Notes and limits

- The ZCode host caps a single MCP call at ~30s — run long builds/tests through the host's background shell instead.
- `run` masks secrets in output; `read` does not (editing files with keys must stay lossless).
- Works without admin rights. Data dir, temp scripts and the plugin cache can all live on any drive.
- Encoding auto-detection heuristics (no BOM): a UTF-16LE file whose first 2KB is dominated by characters from the U+xx00 columns (e.g. walls of U+4E00 with fullwidth spaces) can be misread as UTF-16BE — plain prose never hits this; files with a BOM are always exact.
- A BOM-less UTF-16 file that is pure CJK with no ASCII byte at all decodes as GB18030 (the two byte structures are identical; the more common encoding wins). A BOM-less UTF-16 byte stream that happens to be valid GB18030 (C1/PUA four-byte ranges) also decodes as GB18030.
- Text files whose first bytes look like a known binary signature (MZ/PK/GIF/RIFF/PDF/gzip/7z/ELF/JPEG/PNG) are skipped by `grep`/`replace` as binary.
- `replace` patterns match per UTF-16 code unit — an astral character (emoji, CJK Ext-B) is two units, so wide patterns like `\S` replace it with two characters; use the literal surrogate pair to replace it whole.

## Testing

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_stdio.ps1
```

100 end-to-end assertions over stdio JSON-RPC (all 16 tools + error paths + encoding round-trips). The suite drives the real server process through stdin/stdout file redirection, so it is deterministic and needs no interactive pipes.

## Credits

- [rtk (Rust Token Killer)](https://github.com/rtk-ai/rtk) — the per-command output filtering philosophy and the three promises
- [dsh-ops / dsh-std](https://github.com/T-Auto/dsh-std) and the [awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin) community — tool-seam ideas and the encoding pitfalls that shaped this
- Built for [ZCode](https://zcode.ai)

## License

MIT — see [LICENSE](LICENSE).
