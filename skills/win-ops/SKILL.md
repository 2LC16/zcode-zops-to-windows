---
name: win-ops
description: Windows 环境下省 token 的文件、Shell 与代码编辑操作指南。当需要读取大文件/日志、搜索代码、看代码骨架、编辑文件、对比差异、了解项目状态、检查环境，或遇到 cmd/PowerShell 引号、编码、&& 兼容问题时使用。配合 zcode-zops MCP 工具（read/grep/tree/run/edit/diff/outline/status/doctor/notes）。Use when reading/editing files, searching code, outlining projects, running Windows shell commands, or fighting cmd/PowerShell quoting and encoding issues.
---

# Windows 省 token 操作指南（win-ops）

## 省 token 工作流（核心）

| 任务 | 用法 |
|---|---|
| 了解项目 | `status` 一次拿全：git 分支/脏文件/最后提交、文件总量、最大文件、大日志、磁盘剩余 |
| 看环境 | `doctor`：shell/python/git/node 可用性 + 编码坑提示 |
| 找代码 | `grep`（正则 + `include: "*.ts"` + `max_results`；字面量加 `plain: true`） |
| 看骨架 | `outline`：def/class/function/interface 定义带行号——先看骨架再精准 read，探索期省大头 |
| 读内容 | `read`：`offset/limit` 分页、`tail: 100` 看日志尾 |
| 改文件 | **`edit`**：`find/replace` 原子替换（别再 read 整文件→重写）；`expected_count` 防改错位置；0 命中或次数不符 isError 且不落盘 |
| 核验改动 | `diff`（a vs b，git diff 优先；对比 .bak 也行） |
| 记发现 | **`notes`**：`set/get/list/delete/clear`，按工作区持久化——跨压缩/跨会话保存关键结论（「bug 在 X:123」），消灭重复探索 |
| 跑命令 | `run`：`shell=cmd` 默认，`powershell`/`pwsh`/`bash` 可选；`smart:true` 按命令类型压缩输出（测试→只留失败）；危险命令被门禁拦下需 `confirm:true`；密钥自动遮蔽 |
| 新建文件 | `write`：带编码选项；改已有文件用 `edit`，新建用 `write` |
| 批量替换 | `replace`：跨文件正则替换，默认 dry-run，`apply:true`+`expected_files` 落盘 |
| 查 JSON | `json`：结构速览 / 点路径取值 |
| 端口排查 | `port`：端口→PID→进程名，`kill:true`+`confirm:true` 可杀 |
| 本机请求 | `http`：localhost 可达的结构化 HTTP（WebFetch 不支持 localhost） |
| 用量账本 | `stats`：zcode-zops 自己省了多少 token，按工具/按天 |

省 token 顺序：**status/outline 定位 → grep 找点 → read 精读 → edit/write 修改 → diff 核验**；长输出命令加 `smart:true`。

## 本机环境事实（2026-11-21 实测）

- ZCode 的 Bash 工具在 Windows 上走 **cmd.exe**：支持 `&&`，没有 `ls/grep/head/rm`；等价物 `dir /b`、`findstr`、`del /s /q`。**cmd 里 `;` 不是分隔符，会原样进参数**——连接命令用 `&`。
- Shell 可用性（zcode-zops run 自动探测）：`cmd` ✓、`powershell` 5.1 ✓、`bash` 5.3 ✓（PortableGit，经 `%LOCALAPPDATA%\Programs\Git` 目录联接）、`pwsh` ✗ 未装。
- **PS 5.1 解析无 BOM 的 .ps1 按 ANSI/GBK**：写含中文的 .ps1 必须存成 UTF-8 with BOM，或整文件纯 ASCII（非 ASCII 用 `[char]0xXXXX` 码点构造）。
- 中文文本常见三种编码：UTF-8（带/不带 BOM）、UTF-16、GBK。zcode-zops read/edit/grep 自动识别，cmd 的 `type` 不识别 UTF-8。
- **ZCode 宿主对单次 MCP 调用约 30 秒上限**：`run` 的 `timeout_sec` 传大也没用，长任务（构建/下载）用会话的后台 shell 跑。

## 引号与转义速查

**cmd.exe（Bash 工具 / run 的 shell=cmd）**

- 双引号包裹参数；转义只有 `^`；`%VAR%` 会先展开；管道、重定向可用
- 没有单引号：内容含双引号用 `\"` 或改用 PowerShell

**PowerShell 5.1（run 的 shell=powershell）**

- 单引号 = 字面量（推荐默认），双引号会插值 `$var`
- **不支持 `&&` / `||`**，用 `;` 或 `if ($?) { ... }`
- 运算符优先级坑：`$sb.Append('a' + $b -replace 'x','y')` 会把 `-replace` 拆成数组参数——先算好字符串再传参
- `Sort-Object { -$_[0] }` 的一元负号会作用到整个数组——用 `-Descending`
- 管道会把双元素数组摊平——成对数据用 `[pscustomobject]` 装载再过管道

## 已知坑

- `bash` 裸命令在 PATH 上仍指向 System32 的 WSL 桩（本机未装 WSL）——用 zcode-zops `run shell=bash` 或完整路径 `D:\PortableGit\bin\bash.exe`
- PS 5.1 `ConvertTo-Json` 会把单元素数组塌缩成对象——需要精确 JSON 时用 zcode-zops 工具而非临时 PS 脚本
- cmd 里中文输出是 GBK；需要 UTF-8 输出时 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`
