---
description: 检测本机可用的 shell（cmd / PowerShell 5.1 / pwsh7 / Git Bash）并验证 zops MCP 工具可用性
---

请检查当前机器的 shell 环境并报告 zops 插件状态：

1. 调用 `mcp__zops__run`，`command` 设为 `ver`，确认 cmd 可用并记录版本输出。
2. 依次探测（任选其一方式）：调用 `mcp__zops__run` 且 `shell` 分别为 `powershell`、`pwsh`、`bash`，命令为输出一条短标记（如 `Write-Output ok` / `echo ok`）。`pwsh` 或 `bash` 报 "not found" 属正常，说明未安装。
3. 调用 `mcp__zops__tree`（path 用当前目录，depth 1）确认文件工具正常。

最后用一张简表汇报：每个 shell 的可用性（含 pwsh/bash 的具体版本号，如有）、zops 四个工具（read/grep/tree/run）是否都正常响应、以及针对本机的建议（例如未装 pwsh7 时是否值得安装）。
