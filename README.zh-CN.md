# zcode-zops to Windows — 给 ZCode 的 Windows 省 token 工具集（中文说明）

单文件 PowerShell MCP 插件，给 ZCode agent **16 个省 token 工具**：封顶读文件、代码搜索、原子编辑、按命令类型压缩输出、密钥遮蔽等。所有输出有预算，所有失败都诚实。

> agent 的 token 大头不是任务本身，而是原始命令输出和整文件倾倒。zcode-zops 把这些全部封顶、清洗、结构化。

## 环境要求

- Windows 10/11
- PowerShell 5.1（系统自带）——其他什么都不用装
- 可选：Git（更好的 diff）、PowerShell 7、任意 Node 运行时——全部自动探测，缺了不影响

## 安装

### 方式 A — 插件市场

marketplace 里有 `zcode-zops-to-windows@dev-zops` 就直接装，装完重启 ZCode。

### 方式 B — 手动

1. clone 或下载本仓库
2. 整个文件夹拷进 ZCode 插件缓存：

```
C:\Users\<你>\.zcode\cli\plugins\cache\<marketplace>\zcode-zops-to-windows\<version>\
```

3. 在 `C:\Users\<你>\.zcode\cli\config.json` 里启用：

```json
"plugins": { "enabledPlugins": { "zcode-zops-to-windows@dev-zops": true } }
```

4. 重启 ZCode 即可，MCP server 自动拉起。

5. **建议**——顺手告诉智能体「默认就用这些工具」。实测：泛泛一句「优先用高效工具」几乎没用，写成带明确例外清单的具体块才有效。往全局 `AGENTS.md`（`~/.zcode/AGENTS.md`）或项目根的 AGENTS.md 追加：

````markdown
## zcode-zops — 默认优先调用
- 读文件用 `read`（分页 / `tail` / 字数封顶）而不是 `cat`/`type`；搜代码用 `grep`；摸工程用 `tree` / `outline` / `status`；看 JSON 用 `json`。
- 改文件用 `edit`（原子查找替换 + `expected_count`），改完用 `diff` 核验——不要「整读文件再重写」；新建文件用 `write`。
- 跑命令用 `run`（输出可能超过 ~6000 字符时务必加 `smart: true`）；危险命令需显式 `confirm: true`。
- 跨轮次关键结论写进 `notes`，这样上下文压缩后还在。
- 这些场景回退原生工具：需要超出单次 ~30 秒宿主上限的长任务（构建/下载，走会话的后台 shell）、小文件一次性读取、需要专有交互面板、以及同一工具连续失败 2 次。
````

## 16 个工具速览

| 工具 | 作用 |
|---|---|
| `read` | 分页读文件（offset/limit/tail），字符预算，自动识别 UTF-8/BOM/UTF-16/GB18030 |
| `grep` | 跨文件正则搜索，命中封顶，密钥自动遮蔽 |
| `tree` | 目录树，深度/条目封顶，跳过 node_modules/.git/... |
| `run` | Shell 执行（cmd/PowerShell/pwsh/bash）：输出封顶、超时杀进程、可选 rtk 式 `smart` 压缩、危险命令门禁、密钥遮蔽 |
| `edit` | 原子查找替换，`expected_count` 防呆——0 命中或次数不符直接报错不落盘 |
| `write` | 新建文件，显式编码（补 `edit` 只能改已有文件的空缺） |
| `diff` | 双文件对比，git 优先，无 git 走粗粒度回退，输出封顶 |
| `outline` | 代码骨架：def/class/fn/interface 按语言识别，单文件或目录 |
| `status` | 一次拿全：git 状态、文件总量、最大文件、大日志、磁盘 |
| `doctor` | 环境体检：shell/python/git/node、磁盘、temp、编码提示 |
| `notes` | 按工作区持久化便签——关键结论跨压缩/跨会话不丢 |
| `replace` | 跨文件批量替换：默认 dry-run，`apply` + `expected_files` 才写 |
| `json` | JSON 校验/速览/点路径取值 |
| `port` | 端口 → PID → 进程名；可 kill（需 confirm） |
| `http` | 本机可达的结构化 HTTP 探测（status/耗时/大小/body） |
| `stats` | 用量账本：调用数、输出字符、估算 token（~chars/4），按工具/按天 |

## 三承诺（run smart / 遮罩 / 所有过滤器）

1. **绝不卡死**——过滤器出错就回退原始输出
2. **绝不更差**——只有严格变短才采用过滤结果
3. **绝不隐藏**——被截断的输出会写明完整版保存在哪

## 安全护栏

- 危险命令（`rm -rf`、`del /s`、`git reset --hard`、`format X:` 等）**默认拒绝**，`confirm: true` 才放行
- 密钥形状的字符串（API key、JWT、私钥）在 `run`/`grep` 输出里**自动遮蔽**为 `[REDACTED:*]`；`read` 不遮蔽（编辑带密钥的配置文件必须无损）
- `replace` 默认 dry-run；写盘需要 `apply: true` 并可用 `expected_files` 锁定影响面

## 环境变量（全部可选）

| 变量 | 作用 |
|---|---|
| `ZOPS_DATA_DIR` | notes/stats 数据目录。默认 `%LOCALAPPDATA%\zops`。 |
| `ZOPS_DISABLE_GIT` | 置 1 强制走无 git 回退路径（粗粒度 diff 等）。 |

## 限制

- ZCode 宿主对单次 MCP 调用约 30 秒上限——长构建/长测试走宿主的后台 shell
- 无需管理员权限；数据目录、临时脚本、插件缓存都可放任意盘
- 编码自动探测（无 BOM 时）：UTF-16LE 文件若开头 2KB 被低字节为 0x00 的字符（如 U+4E00、全角空格）占据超过 60%，可能被误读为 UTF-16BE——普通中英文正文不会触发；带 BOM 的文件永远精确
- 纯 CJK 且不含任何 ASCII 字节的无 BOM UTF-16 文件按 GB18030 解（两者字节结构相同，按更常见的编码取舍）；若字节流恰好也是合法 GB18030（含 C1/PUA 四字节区）同样按 GB 解
- 开头字节命中已知二进制签名（MZ/PK/GIF/RIFF/PDF/gzip/7z/ELF/JPEG/PNG）的文本文件会被 `grep`/`replace` 当二进制跳过
- `replace` 的模式按 UTF-16 码元匹配——星形字符（emoji、CJK 扩展 B）是两个码元，`\S` 这类宽模式会替换成两个字符；要整字符替换请用字面代理对

## 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_stdio.ps1
```

100 项 stdio JSON-RPC 端到端断言（16 个工具 + 错误路径 + 编码往返），文件重定向驱动真实 server 进程，确定性、无交互管道。

## 致谢

- [rtk (Rust Token Killer)](https://github.com/rtk-ai/rtk) —— 按命令类型过滤输出的理念与三承诺
- [dsh-ops / dsh-std](https://github.com/T-Auto/dsh-std) 与 [awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin) 社区 —— 工具缝隙的灵感与塑造本插件的编码坑
- 为 [ZCode](https://zcode.ai) 而建

## 许可

MIT，见 [LICENSE](LICENSE)。
