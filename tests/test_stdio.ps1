# zops stdio end-to-end tests.
# Design: build ALL JSON-RPC requests into one file, feed them to mcp/server.ps1 via
# stdin redirect, capture stdout/stderr to files, then assert on the response lines by id.
# This avoids live-pipe deadlocks and PS 5.1 threading limits entirely.
# Pure ASCII on purpose: PS 5.1 parses BOM-less .ps1 as ANSI/GBK. Non-ASCII text is
# built from Unicode code points and sent as \uXXXX JSON escapes.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_stdio.ps1
$ErrorActionPreference = 'Stop'
$server = if ($env:ZOPS_TEST_SERVER) { $env:ZOPS_TEST_SERVER } else { Join-Path $PSScriptRoot '..\mcp\server.ps1' }
$pass = 0; $fail = 0

function JsonU([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -gt 126) { [void]$sb.Append(('\u' + ('{0:x4}' -f $c))) } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}
function JsonEsc([string]$s) {
    # proper JSON string escaping: backslash and quote first, then non-ASCII as \uXXXX
    $s = $s.Replace('\', '\\').Replace('"', '\"')
    return (JsonU $s)
}
function Req([int]$id, [string]$name, [hashtable]$toolArgs) {
    $pairs = @()
    foreach ($k in $toolArgs.Keys) {
        $v = $toolArgs[$k]
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) { $vv = [string]$v } else { $vv = '"' + (JsonEsc ([string]$v)) + '"' }
        $pairs += ('"' + (JsonU $k) + '":' + $vv)
    }
    return '{"jsonrpc":"2.0","id":' + $id + ',"method":"tools/call","params":{"name":"' + $name + '","arguments":{' + ($pairs -join ',') + '}}}'
}

# codepoint-built Chinese fixture strings (GB18030 round-trip test)
$cnOld = [string][char]0x65E7 + [char]0x503C
$cnNew = [string][char]0x65B0 + [char]0x503C
$cnKey = [string][char]0x540D + [char]0x79F0 + ': '
$cnKeep = [string][char]0x4FDD + [char]0x6301 + [char]0x4E0D + [char]0x53D8

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('zops-test-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tmp)
$inFile = Join-Path $tmp 'in.jsonl'
$outFile = Join-Path $tmp 'out.jsonl'
$errFile = Join-Path $tmp 'err.txt'

# fixture files
$pyFile = Join-Path $tmp 'sample.py'
$pyBody = "import os`nclass Greeter:`n    def hello(self):`n        return `"hi`"`ndef main():`n    g = Greeter()`n    print(g.hello())`n"
[System.IO.File]::WriteAllText($pyFile, $pyBody, (New-Object System.Text.UTF8Encoding($false)))
$cnFile = Join-Path $tmp 'cn.txt'
[System.IO.File]::WriteAllText($cnFile, ($cnKey + $cnOld + [char]10 + $cnKeep), [System.Text.Encoding]::GetEncoding('GB18030'))
$plain = Join-Path $tmp 'plain.txt'
[System.IO.File]::WriteAllText($plain, "alpha beta`ngamma")

# --- build the request stream ---
$reqs = @()
$reqs += '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}'
$reqs += '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
$reqs += (Req 3 'edit' @{ path = $plain; find = 'nope-not-there'; replace = 'x' })
$reqs += (Req 4 'edit' @{ path = $plain; find = 'alpha'; replace = 'x'; expected_count = 2 })
$reqs += (Req 5 'edit' @{ path = $plain; find = 'beta'; replace = 'BETA'; expected_count = 1 })
$reqs += (Req 6 'edit' @{ path = $cnFile; find = $cnOld; replace = $cnNew })
$bak = $plain + '.bak'
$reqs += (Req 7 'diff' @{ a = $plain; b = $plain })
$reqs += (Req 8 'outline' @{ path = $pyFile })
$reqs += (Req 9 'outline' @{ path = $tmp })
$reqs += (Req 10 'status' @{ path = $tmp })
$reqs += (Req 11 'doctor' @{})
$reqs += (Req 12 'notes' @{ action = 'set'; key = 'bug'; value = 'located at sample.py:2' })
$reqs += (Req 13 'notes' @{ action = 'get'; key = 'bug' })
$reqs += (Req 14 'notes' @{ action = 'delete'; key = 'bug' })
$reqs += (Req 15 'notes' @{ action = 'get'; key = 'bug' })
$reqs += (Req 16 'read' @{ path = $pyFile; limit = 5 })
$reqs += (Req 17 'grep' @{ pattern = 'Greeter'; path = $tmp })
$reqs += (Req 18 'run' @{ command = 'echo run-regression-ok'; shell = 'cmd'; timeout_sec = 15 })
$cnEcho = [string][char]0x4E2D + [char]0x6587  # zhong wen
$reqs += (Req 19 'run' @{ command = ('echo ' + $cnEcho); shell = 'cmd'; timeout_sec = 15 })
$secret = 'key=sk-abc123def456ghi789jklmno'
$secFile = Join-Path $tmp 'sec.txt'
[System.IO.File]::WriteAllText($secFile, $secret, (New-Object System.Text.UTF8Encoding($false)))
# --- 0.3.0: write ---
$wFile = Join-Path $tmp 'created.txt'
$reqs += (Req 21 'write' @{ path = $wFile; content = 'hello zops' })
$reqs += (Req 22 'write' @{ path = $wFile; content = 'second' })
$reqs += (Req 23 'write' @{ path = $wFile; content = 'second v2'; overwrite = 1 })
# --- 0.3.0: replace ---
$rA = Join-Path $tmp 'ra.txt'
$rB = Join-Path $tmp 'rb.txt'
$reqs += (Req 24 'write' @{ path = $rA; content = 'foo alpha' })
$reqs += (Req 25 'write' @{ path = $rB; content = 'foo beta' })
$reqs += (Req 26 'replace' @{ path = $tmp; pattern = 'foo'; replace = 'FOO'; include = '*.txt'; apply = 1; expected_files = 2 })
# --- 0.3.0: json ---
$jFile = Join-Path $tmp 'data.json'
[System.IO.File]::WriteAllText($jFile, '{"data":{"items":[{"name":"zed"},{"name":"waldo"}]},"n":3}', (New-Object System.Text.UTF8Encoding($false)))
$reqs += (Req 27 'json' @{ path = $jFile; query = 'data.items[0].name' })
$badJson = Join-Path $tmp 'bad.json'
[System.IO.File]::WriteAllText($badJson, '{oops', (New-Object System.Text.UTF8Encoding($false)))
$reqs += (Req 28 'json' @{ path = $badJson })
# --- 0.3.0: port / http ---
$reqs += (Req 29 'port' @{ port = 135 })
$reqs += (Req 30 'http' @{ url = 'http://127.0.0.1:1/x'; timeout_sec = 3 })
# --- 0.3.0: run gate / mask / smart ---
$reqs += (Req 31 'run' @{ command = 'del /s /q zzz-gone.tmp'; shell = 'cmd'; timeout_sec = 10; cwd = $tmp })
$reqs += (Req 32 'run' @{ command = 'del /s /q zzz-gone.tmp'; shell = 'cmd'; timeout_sec = 10; confirm = 1; cwd = $tmp })
$secret = 'key=sk-abc123def456ghi789jklmno'
$reqs += (Req 33 'run' @{ command = ('echo ' + $secret); shell = 'cmd'; timeout_sec = 10 })
$smCmd = 'echo pytest -q & for /l %i in (1,1,60) do @echo test_case_@i PASSED'
$reqs += (Req 34 'run' @{ command = $smCmd; shell = 'cmd'; timeout_sec = 20; smart = 1 })
$reqs += (Req 35 'grep' @{ pattern = 'sk-'; path = $tmp; include = 'sec.txt' })
$reqs += (Req 36 'stats' @{})
$reqs += (Req 37 'frobnicate' @{})
$reqs += (Req 38 'diff' @{ a = (Join-Path $tmp 'diff-a.txt'); b = (Join-Path $tmp 'diff-b.txt') })
[System.IO.File]::WriteAllText((Join-Path $tmp 'diff-a.txt'), "line1`nline2 old`nline3", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $tmp 'diff-b.txt'), "line1`nline2 NEW`nline3", (New-Object System.Text.UTF8Encoding($false)))
# --- 0.3.1 bug-fix regressions ---
# string id: response must quote it (valid JSON)
$reqs += '{"jsonrpc":"2.0","id":"s1","method":"tools/call","params":{"name":"read","arguments":{"path":"' + (JsonEsc $plain) + '","limit":1}}}'
# invalid JSON request: must get -32700 parse error, not silence
$reqs += '{"jsonrpc":"2.0","id":98,"method":'
# utf16 file must be searchable by grep (BOM-aware binary check)
$u16 = Join-Path $tmp 'u16.txt'
[System.IO.File]::WriteAllText($u16, 'needle16 here', [System.Text.Encoding]::Unicode)
$reqs += (Req 41 'grep' @{ pattern = 'needle16'; path = $tmp; include = 'u16.txt' })
# json summary: bool shows as boolean, not number
$flagFile = Join-Path $tmp 'flag.json'
[System.IO.File]::WriteAllText($flagFile, '{"flag": true}', (New-Object System.Text.UTF8Encoding($false)))
$reqs += (Req 42 'json' @{ path = $flagFile })
# timeout kill: total elapsed must stay near timeout (no 2x5s dead waits)
$reqs += (Req 43 'run' @{ command = 'ping -n 11 127.0.0.1 >nul'; shell = 'cmd'; timeout_sec = 2; cwd = $tmp })
# read header: shown range must reflect budget truncation (not the pre-loop estimate)
$longFile = Join-Path $tmp 'long.txt'
[System.IO.File]::WriteAllText($longFile, (('x' * 300) + "`n" + ('y' * 300)), (New-Object System.Text.UTF8Encoding($false)))
$reqs += (Req 44 'read' @{ path = $longFile; max_chars = 400 })
# --- 0.3.1 gate-bypass regressions (round-2 audit) ---
$reqs += (Req 45 'run' @{ command = 'rmdir /s /q zzz4'; shell = 'cmd'; timeout_sec = 10; cwd = $tmp })
$reqs += (Req 46 'run' @{ command = 'del /f /s zzz5'; shell = 'cmd'; timeout_sec = 10; cwd = $tmp })
$reqs += (Req 47 'run' @{ command = 'git reset -q --hard HEAD~1'; shell = 'cmd'; timeout_sec = 10; cwd = $tmp })
$reqs += (Req 48 'run' @{ command = 'Remove-Item -r -fo E:\zzz6-zops-gone'; shell = 'powershell'; timeout_sec = 10 })
$reqs += (Req 49 'run' @{ command = 'echo postgres://admin:S3cretPass12@db.example.com/main'; shell = 'cmd'; timeout_sec = 10 })
$reqs += (Req 50 'run' @{ command = 'echo Authorization: Bearer ya29.a0AfH6SMBvfe123456789'; shell = 'cmd'; timeout_sec = 10 })
$beFile = Join-Path $tmp 'u16be.txt'
$reqs += (Req 51 'run' @{ command = ('[IO.File]::WriteAllText(''' + $beFile + ''', ''needleBE here'', [Text.Encoding]::BigEndianUnicode)'); shell = 'powershell'; timeout_sec = 10 })
$reqs += (Req 52 'grep' @{ pattern = 'needleBE'; path = $tmp; include = 'u16be.txt' })
$reqs += (Req 53 'run' @{ command = 'echo pytest -q & echo api_key = sk-live-abcdef1234567890abcdef & for /l %i in (1,1,80) do @echo t@i ok'; shell = 'cmd'; timeout_sec = 20; smart = 1 })
$reqs += (Req 54 'stats' @{})
# --- negative tests: legit commands must NOT be blocked (round-3 audit focus) ---
$reqs += (Req 55 'run' @{ command = 'git log -f'; shell = 'cmd'; timeout_sec = 10; cwd = $tmp })
$reqs += (Req 56 'run' @{ command = 'Remove-Item -Recurse E:\zzz7-zops-gone'; shell = 'powershell'; timeout_sec = 10 })
$reqs += (Req 57 'run' @{ command = 'Remove-Item -Recurse -Force E:\zzz8-zops-gone'; shell = 'powershell'; timeout_sec = 10 })
$reqs += (Req 58 'run' @{ command = 'git clean -f'; shell = 'cmd'; timeout_sec = 10; cwd = $tmp })
# --- 0.3.2 regressions (round-3 audit) ---
$reqs += (Req 59 'run' @{ command = 'rm -r -f E:\zzz9-zops-gone'; shell = 'bash'; timeout_sec = 10 })
$reqs += (Req 60 'run' @{ command = 'rm -r E:\zzz10-zops-gone'; shell = 'bash'; timeout_sec = 10 })
$reqs += (Req 61 'run' @{ command = 'git push --force-with-lease'; shell = 'cmd'; timeout_sec = 10; cwd = $tmp })
$beEdit = Join-Path $tmp 'beedit.txt'
$reqs += (Req 62 'run' @{ command = ('[IO.File]::WriteAllText(''' + $beEdit + ''', ''BE-line here'', [Text.Encoding]::BigEndianUnicode)'); shell = 'powershell'; timeout_sec = 10 })
$reqs += (Req 63 'edit' @{ path = $beEdit; find = 'BE-line here'; replace = 'BE-line here EDITED' })
$reqs += (Req 64 'replace' @{ path = $tmp; pattern = 'Greeter'; replace = 'X'; include = '*.py' })

# --- 0.3.4 regressions (round-7 audit P2/P3) ---
# P2-1: string booleans must never be coerced to true (guards + raw output)
$reqs += (Req 70 'write' @{ path = $rA; content = 'P2-1-CLOBBER'; overwrite = 'false' })
$reqs += (Req 71 'replace' @{ path = $tmp; pattern = 'FOO'; replace = 'NOPE'; include = 'ra.txt'; apply = 'false' })
$reqs += (Req 72 'run' @{ command = 'Remove-Item -Path E:\zzz-r7-gone -Rec -Fo'; shell = 'powershell'; timeout_sec = 10 })
$reqs += (Req 73 'run' @{ command = 'rm --recursive -f E:\zzz-r7-gone'; shell = 'cmd'; timeout_sec = 10 })
# P2-2: cross-pipeline recursive listing + forced delete, erase alias of del
$reqs += (Req 74 'run' @{ command = 'gci -r E:\zzz-r7-gone | ri -fo'; shell = 'powershell'; timeout_sec = 10 })
$reqs += (Req 75 'run' @{ command = 'erase /s /q zzz-r7-gone.tmp'; shell = 'cmd'; timeout_sec = 10; cwd = $tmp })
# P2-5: timeout must kill the whole tree (cmd -> powershell sleeper)
$sleeperFile = Join-Path $tmp 'r7sleeper.ps1'
[System.IO.File]::WriteAllText($sleeperFile, 'Start-Sleep -Seconds 6', (New-Object System.Text.UTF8Encoding($false)))
$reqs += (Req 76 'run' @{ command = ('cmd /c powershell -NoProfile -File "' + $sleeperFile + '"'); shell = 'cmd'; timeout_sec = 2; cwd = $tmp })
# P3-1/P3-2: deep nesting renders fully; out-of-range index errors
$deepFile = Join-Path $tmp 'deep.json'
$deepJson = ''
for ($d = 1; $d -le 10; $d++) { $deepJson += '{"l' + $d + '":' }
$deepJson += '"deepok"'
for ($d = 1; $d -le 10; $d++) { $deepJson += '}' }
[System.IO.File]::WriteAllText($deepFile, $deepJson, (New-Object System.Text.UTF8Encoding($false)))
$reqs += (Req 77 'json' @{ path = $deepFile; query = 'l1' })
$reqs += (Req 78 'json' @{ path = $jFile; query = 'data.items[9]' })
# P3-4: disk line reports the scanned path's drive (no double colon)
$reqs += (Req 79 'status' @{ path = $tmp })
# P3-5: batch array gets -32600, never silence
$reqs += '[{"jsonrpc":"2.0","id":901,"method":"ping"}]'
# P3-6: BOM-less UTF-16 is readable by read and searchable by grep
$u16nb = Join-Path $tmp 'u16-nobom.txt'
[System.IO.File]::WriteAllBytes($u16nb, [System.Text.Encoding]::Unicode.GetBytes('nobom16 needle here'))
$reqs += (Req 80 'read' @{ path = $u16nb })
$reqs += (Req 81 'grep' @{ pattern = 'nobom16'; path = $tmp; include = 'u16-nobom.txt' })
# P2-4: hyphenated words containing sk- must NOT be masked as api keys
$fpFile = Join-Path $tmp 'fp.txt'
[System.IO.File]::WriteAllText($fpFile, 'task-runner-scheduler-registry and disk-usage-monitoring-dashboard', (New-Object System.Text.UTF8Encoding($false)))
$reqs += (Req 82 'grep' @{ pattern = 'runner'; path = $tmp; include = 'fp.txt' })

# --- 0.3.5 regressions (round-8 audit F1-F5) ---
# F1: fake PE (MZ + zeros + DOS-stub text) must be treated as binary everywhere
$peFile = Join-Path $tmp 'fake.bin'
$peBody = New-Object byte[] 2048
$peBody[0] = 0x4D; $peBody[1] = 0x5A; $peBody[2] = 0x90
$stub = [System.Text.Encoding]::ASCII.GetBytes('This program cannot be run in DOS mode')
[Array]::Copy($stub, 0, $peBody, 100, $stub.Length)
[System.IO.File]::WriteAllBytes($peFile, $peBody)
$peShaBefore = (Get-FileHash $peFile -Algorithm SHA256).Hash
$reqs += (Req 83 'grep' @{ pattern = 'This program'; path = $tmp; include = 'fake.bin' })
$reqs += (Req 84 'replace' @{ path = $tmp; pattern = 'This program'; replace = 'XX'; include = 'fake.bin'; apply = 1 })
# F3: Stripe-style keys use underscores, not hyphens
$stripeFile = Join-Path $tmp 'stripe.txt'
# Fake Stripe-style key is assembled at runtime so the literal never lands in the repo (GitHub push protection)
[System.IO.File]::WriteAllText($stripeFile, ('line05 ' + 'sk' + '_live_51H' + ([char[]](97..122) -join '')), (New-Object System.Text.UTF8Encoding($false)))
$reqs += (Req 85 'grep' @{ pattern = 'line05'; path = $tmp; include = 'stripe.txt' })
# F1 second half: replace on BOM-less UTF-16 must round-trip through ONE decoder
$u16r = Join-Path $tmp 'u16-replace.txt'
[System.IO.File]::WriteAllBytes($u16r, [System.Text.Encoding]::Unicode.GetBytes('alpha16 beta16'))
$reqs += (Req 86 'replace' @{ path = $tmp; pattern = 'beta16'; replace = 'GAMMA16'; include = 'u16-replace.txt'; apply = 1 })
# F2: BOM-less UTF-16 with CJK content must read correctly (scored candidates)
$cjkText = [string][char]0x4E2D + [char]0x6587 + [char]0x6D4B + [char]0x8BD5
$u16c = Join-Path $tmp 'u16-cjk.txt'
# leading ASCII char = NULs at parity: realistic BOM-less UTF-16 (any newline does
# this); pure-CJK-no-ASCII intentionally decodes as GB18030 since round-9 F1
[System.IO.File]::WriteAllBytes($u16c, [System.Text.Encoding]::Unicode.GetBytes(('a' + $cjkText)))
$reqs += (Req 87 'read' @{ path = $u16c })

# --- 0.3.6 regressions (round-9 audit F1-F3) ---
# F1: GB18030 extended-range char must decode correctly and survive replace as GB18030
$gbChar = [string][char]0x5586
$gbxFile = Join-Path $tmp 'gbx.txt'
[System.IO.File]::WriteAllText($gbxFile, ('x' + $gbChar + 'y'), [System.Text.Encoding]::GetEncoding('GB18030'))
$reqs += (Req 88 'read' @{ path = $gbxFile })
$reqs += (Req 89 'replace' @{ path = $tmp; pattern = 'x'; replace = 'X'; include = 'gbx.txt'; apply = 1 })
# F2: UTF-8 with one stray NUL byte stays UTF-8 (readable, not demoted to UTF-16)
$nulFile = Join-Path $tmp 'nul8.txt'
$nulBytes = [System.Text.Encoding]::ASCII.GetBytes('alpha  beta')
$nulBytes[5] = 0  # 11 bytes: "alpha" + NUL + " beta" (same shape as the audit fixture)
[System.IO.File]::WriteAllBytes($nulFile, $nulBytes)
$reqs += (Req 90 'read' @{ path = $nulFile })
# F2 second half: grep/replace must also treat stray-NUL UTF-8 as text (stray-NUL
# exemption in Test-BinaryFile) and rewrite it byte-faithfully
$reqs += (Req 91 'replace' @{ path = $tmp; pattern = 'beta'; replace = 'BETA'; include = 'nul8.txt'; apply = 1 })

# --- 0.3.7 regressions (round-10 audit: F1 residual + F2 short-file) ---
# F1: GB18030 files whose text scores 0 in the ASCII+CJK good set (Latin, emoji)
$accFile = Join-Path $tmp 'acc.txt'
[System.IO.File]::WriteAllText($accFile, ([string][char]0xE9), [System.Text.Encoding]::GetEncoding('GB18030'))
$reqs += (Req 92 'read' @{ path = $accFile })
$emoFile = Join-Path $tmp 'emo.txt'
[System.IO.File]::WriteAllText($emoFile, ([string][char]0xD83D + [char]0xDE00), [System.Text.Encoding]::GetEncoding('GB18030'))
$reqs += (Req 93 'read' @{ path = $emoFile })
# F2: 4-byte BOM-less UTF-16LE 'hi' must not fall through as UTF-8-with-NUL
$hiFile = Join-Path $tmp 'hi16.txt'
[System.IO.File]::WriteAllBytes($hiFile, [System.Text.Encoding]::Unicode.GetBytes('hi'))
$reqs += (Req 94 'read' @{ path = $hiFile })
# round-11 F2: GB18030 four-byte symbol (outside the old allowlist) must decode
$sunFile = Join-Path $tmp 'sun.txt'
[System.IO.File]::WriteAllText($sunFile, ([string][char]0x2600), [System.Text.Encoding]::GetEncoding('GB18030'))
$reqs += (Req 95 'read' @{ path = $sunFile })
# round-12 F2: GB18030 with a PUA char must decode as GB18030 (PUA deny is UTF-16-only)
$puaText = 'a' + [string][char]0xE000 + 'b'
$puaFile = Join-Path $tmp 'pua.txt'
[System.IO.File]::WriteAllText($puaFile, $puaText, [System.Text.Encoding]::GetEncoding('GB18030'))
$reqs += (Req 96 'read' @{ path = $puaFile })
[System.IO.File]::WriteAllLines($inFile, $reqs, (New-Object System.Text.UTF8Encoding($false)))

# --- run the server (stdin/stdout/stderr via file redirect; deterministic) ---
$cmdLine = '/c chcp 65001 >nul & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $server + '" < "' + $inFile + '" > "' + $outFile + '" 2> "' + $errFile + '"'
$proc = Start-Process cmd -ArgumentList $cmdLine -PassThru -WindowStyle Hidden
if (-not $proc.WaitForExit(180000)) {
    try { $proc.Kill() } catch {}
    $dump = 'E:\Zcode Work\temp\hang-dump'
    [void][System.IO.Directory]::CreateDirectory($dump)
    try { Copy-Item $inFile (Join-Path $dump 'in.jsonl') -Force } catch {}
    try { Copy-Item $outFile (Join-Path $dump 'out.jsonl') -Force } catch {}
    try { Copy-Item $errFile (Join-Path $dump 'err.txt') -Force } catch {}
    Write-Output ('FAIL  server did not finish within 180s (possible hang); artifacts in ' + $dump)
    exit 1
}

# --- collect responses by id ---
$outText = $null
for ($try = 0; $try -lt 30; $try++) {
    try { $outText = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8); Write-Output ('[suite] out.jsonl readable at retry ' + $try); break } catch {
        $len = (Get-Item $outFile -ErrorAction SilentlyContinue).Length
        Write-Output ('[suite] retry ' + $try + ' locked, size ' + $len)
        Start-Sleep -Milliseconds 1000
    }
}
if ($null -eq $outText) {
    Write-Output 'FAIL  out.jsonl unreadable after 30 retries'
    $errDump = ''
    if ([System.IO.File]::Exists($errFile)) { $errDump = [System.IO.File]::ReadAllText($errFile) }
    Write-Output ('server stderr tail: ' + $errDump.Substring([Math]::Max(0, $errDump.Length - 300)))
    exit 1
}
$resp = @{}
foreach ($line in @(($outText -replace "`r`n", "`n") -split "`n")) {
    if ($line.Trim() -eq '') { continue }
    try {
        $m = ConvertFrom-Json $line
        $resp[[int]$m.id] = $m
    } catch {}
}
function Get-RespText([int]$id) {
    $m = $resp[$id]
    if ($null -eq $m) { return $null }
    return [string]$m.result.content[0].text
}
function Assert([string]$name, [bool]$cond, [string]$detail) {
    if ($cond) { $script:pass++; Write-Output ("PASS  " + $name) }
    else { $script:fail++; Write-Output ("FAIL  " + $name + " :: " + $detail) }
}

# --- assertions ---
 Assert 'initialize version 0.3.9' ($resp[1].result.serverInfo.version -eq '0.3.9') ([string]$resp[1].result.serverInfo.version)
$names = @($resp[2].result.tools | ForEach-Object { $_.name })
    Assert 'tools/list has 16 tools' ($names.Count -eq 16) ('got: ' + ($names -join ','))
    $need = @('read','grep','tree','run','edit','diff','outline','status','doctor','notes','write','replace','json','port','http','stats')
$missing = @($need | Where-Object { $names -notcontains $_ })
Assert 'all expected tool names' ($missing.Count -eq 0) ('missing: ' + ($missing -join ','))

Assert 'edit 0 occurrences -> isError' ($resp[3].result.isError -eq $true) (Get-RespText 3)
Assert 'edit expected_count mismatch -> isError' ($resp[4].result.isError -eq $true) (Get-RespText 4)
$t5 = Get-RespText 5
Assert 'edit ok reports applied 1' (($resp[5].result.isError -eq $false) -and ($t5 -match 'applied 1')) ([string]$t5)
$after = [System.IO.File]::ReadAllText($plain)
Assert 'edit content actually replaced' ($after.Contains("alpha BETA`ngamma")) '[masked content check]'

Assert 'edit GB18030 file' ($resp[6].result.isError -eq $false) (Get-RespText 6)
$round = [System.Text.Encoding]::GetEncoding('GB18030').GetString([System.IO.File]::ReadAllBytes($cnFile))
Assert 'edit GB18030 content preserved' ($round.Contains($cnKey + $cnNew) -and $round.Contains($cnKeep)) '[masked GB18030 roundtrip]'
Assert 'edit GB18030 no stray bytes' ([System.IO.File]::ReadAllBytes($cnFile).Length -eq ([System.Text.Encoding]::GetEncoding('GB18030').GetByteCount($cnKey + $cnNew + [char]10 + $cnKeep))) ('len=' + [System.IO.File]::ReadAllBytes($cnFile).Length)

$t7 = Get-RespText 7
Assert 'diff identical' ([string]$t7 -match 'identical') ([string]$t7)

$t8 = Get-RespText 8
Assert 'outline file shows class+def' (($t8 -match 'class Greeter') -and ($t8 -match 'def main')) ([string]$t8)
$t9 = Get-RespText 9
Assert 'outline directory scan' ([string]$t9 -match 'sample.py') ([string]$t9)

$t10 = Get-RespText 10
Assert 'status has files+cheatsheet' (([string]$t10 -match 'files:') -and ([string]$t10 -match 'cheatsheet:')) ([string]($t10 | Select-Object -First 1))

$t11 = Get-RespText 11
Assert 'doctor shells cmd present' ([string]$t11 -match 'OK    shell cmd') ([string]$t11)
Assert 'doctor finds git (junction or PATH)' ([string]$t11 -match 'git\.exe') ([string]$t11)

$t12 = Get-RespText 12
Assert 'notes set' ($resp[12].result.isError -eq $false) ([string]$t12)
$t13 = Get-RespText 13
Assert 'notes get round trip' ([string]$t13 -match 'located at sample.py:2') ([string]$t13)
$t15 = Get-RespText 15
Assert 'notes deleted' ([string]$t15 -match "no note 'bug'") ([string]$t15)

$t16 = Get-RespText 16
Assert 'read regression' ([string]$t16 -match 'class Greeter') ([string]$t16)
$t17 = Get-RespText 17
Assert 'grep regression' ([string]$t17 -match 'Greeter') ([string]$t17)
$t18 = Get-RespText 18
Assert 'run regression' ([string]$t18 -match 'run-regression-ok') ([string]$t18)
$t19 = Get-RespText 19
Assert 'run GBK chinese output decoded' ([string]$t19 -match $cnEcho) ('[masked cn output check]')

$t21 = Get-RespText 21
Assert 'write create' (($resp[21].result.isError -eq $false) -and ($t21 -match 'created')) ([string]$t21)
Assert 'write exists without overwrite -> isError' ($resp[22].result.isError -eq $true) (Get-RespText 22)
$t23 = Get-RespText 23
Assert 'write overwrite' (($resp[23].result.isError -eq $false) -and ($t23 -match 'overwritten')) ([string]$t23)

$t26 = Get-RespText 26
Assert 'replace apply expected_files=2' (($resp[26].result.isError -eq $false) -and ([string]$t26 -match '2 file\(s\) WRITTEN')) ([string]$t26)
$raAfter = [System.IO.File]::ReadAllText($rA)
Assert 'replace content changed' ($raAfter -eq 'FOO alpha') '[masked content check]'

$t27 = Get-RespText 27
Assert 'json query value' ([string]$t27 -match 'zed') ([string]$t27)
Assert 'json broken -> isError' ($resp[28].result.isError -eq $true) ((Get-RespText 28) -match 'invalid JSON')

$t29 = Get-RespText 29
Assert 'port finds listener' ([string]$t29 -match 'pid=') ([string]$t29)
$t30 = Get-RespText 30
Assert 'http refused port -> structured ERROR' ([string]$t30 -match 'ERROR') ([string]$t30)

Assert 'run dangerous gate -> isError' ($resp[31].result.isError -eq $true) ((Get-RespText 31) -match 'blocked')
$t32 = Get-RespText 32
Assert 'run gate passes with confirm' (($resp[32].result.isError -eq $false) -and ([string]$t32 -match 'exit=')) ([string]$t32)
$t33 = Get-RespText 33
Assert 'run masks api key' (([string]$t33 -match 'REDACTED:api-key') -and ([string]$t33 -notmatch 'sk-abc123def456ghi789jklmno')) '[masked run output]'
$t34 = Get-RespText 34
Assert 'run smart filter collapses' (([string]$t34 -match '\[zops:smart\] test') -and ([string]$t34 -match 'ALL PASS')) ([string]$t34)
$t35 = Get-RespText 35
Assert 'grep masks secrets' ([string]$t35 -match 'REDACTED:api-key') '[masked grep output]'
$t36 = Get-RespText 36
Assert 'stats ledger aggregates' ([string]$t36 -match 'total: \d+ call') ([string]$t36)

Assert 'unknown tool -> isError' ($resp[37].result.isError -eq $true) (Get-RespText 37)
$t38 = Get-RespText 38
Assert 'diff shows change (git path)' ([string]$t38 -match 'NEW') ([string]$t38)

# --- 0.3.1 bug-fix regressions ---
Assert 'string id response is valid JSON with quoted id' (($outText -match '\"id\":\"s1\"') -and ($outText -match '\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"result\"')) 'no quoted s1 id in output'
Assert 'invalid JSON request -> -32700' ($outText -match '\"code\":-32700') 'no parse error reply'
$t41 = Get-RespText 41
Assert 'grep finds utf16 file content' ([string]$t41 -match 'u16.txt:1:') ([string]$t41)
$t42 = Get-RespText 42
Assert 'json bool shows boolean' ([string]$t42 -match 'boolean') ([string]$t42)
$t43 = Get-RespText 43
Assert 'timeout kill stays near timeout (no dead waits)' ([string]$t43 -match 'elapsed=[0-7]\.\d') ([string]$t43)
$t44 = Get-RespText 44
Assert 'read header reflects budget truncation' ([string]$t44 -match 'showing 1-1') ([string]$t44)

# --- 0.3.1 gate-bypass / masking / BE regressions ---
Assert 'gate blocks rmdir /s /q' ($resp[45].result.isError -eq $true) (Get-RespText 45)
Assert 'gate blocks del /f /s' ($resp[46].result.isError -eq $true) (Get-RespText 46)
Assert 'gate blocks git reset -q --hard' ($resp[47].result.isError -eq $true) (Get-RespText 47)
Assert 'gate blocks Remove-Item -r -fo' ($resp[48].result.isError -eq $true) (Get-RespText 48)
$t49 = Get-RespText 49
Assert 'mask db-url credentials' (([string]$t49 -match 'REDACTED:db-url') -and ([string]$t49 -notmatch 'S3cretPass12')) '[masked db-url output]'
$t50 = Get-RespText 50
Assert 'mask bearer token' (([string]$t50 -match 'REDACTED:bearer') -and ([string]$t50 -notmatch 'ya29.a0AfH6')) '[masked bearer output]'
$t51 = Get-RespText 51
Assert 'run writes utf16be fixture' ($resp[51].result.isError -eq $false) ([string]$t51)
$t52 = Get-RespText 52
Assert 'grep finds utf16be file' ([string]$t52 -match 'u16be.txt:1:') ([string]$t52)
$t53 = Get-RespText 53
$fullPath = if ([string]$t53 -match 'full output kept at (.+)$') { $matches[1].Trim() } else { $null }
Assert 'smart full output file exists' ($null -ne $fullPath -and [System.IO.File]::Exists($fullPath)) '[no full-output path]'
$fullContent = if ($fullPath -and [System.IO.File]::Exists($fullPath)) { [System.IO.File]::ReadAllText($fullPath) } else { '' }
Assert 'smart full output file masked (no plaintext secret)' (([string]$fullContent -notmatch 'sk-live-abcdef1234567890abcdef') -and ([string]$fullContent -match 'REDACTED')) '[masked full-file check]'
$t54 = Get-RespText 54
Assert 'stats by-day shows chars' ([string]$t54 -match 'calls, \d+ chars') ([string]$t54)

# --- negative tests: legit commands must pass the gate (round-3 audit focus) ---
$t55 = Get-RespText 55
Assert 'gate passes git log -f' (([string]$t55 -match 'exit=') -and ([string]$t55 -notmatch 'blocked')) '[git log -f output]'
$t56 = Get-RespText 56
Assert 'gate passes Remove-Item -Recurse (no Force)' (([string]$t56 -match 'exit=') -and ([string]$t56 -notmatch 'blocked')) '[Remove-Item -Recurse output]'
Assert 'gate blocks Remove-Item -Recurse -Force' ($resp[57].result.isError -eq $true) (Get-RespText 57)
Assert 'gate blocks git clean -f' ($resp[58].result.isError -eq $true) (Get-RespText 58)

# --- 0.3.2 regressions (round-3 audit: R3-1/R3-2/R3-3) ---
Assert 'gate blocks rm -r -f (adjacent split)' ($resp[59].result.isError -eq $true) (Get-RespText 59)
$t60 = Get-RespText 60
Assert 'gate passes rm -r (no force)' (([string]$t60 -match 'exit=') -and ([string]$t60 -notmatch 'blocked')) '[rm -r output]'
$t61 = Get-RespText 61
Assert 'gate passes --force-with-lease' (([string]$t61 -match 'exit=') -and ([string]$t61 -notmatch 'blocked')) '[force-with-lease output]'
Assert 'run writes utf16be fixture' ($resp[62].result.isError -eq $false) (Get-RespText 62)
$t63 = Get-RespText 63
Assert 'edit utf16be file succeeds' ($resp[63].result.isError -eq $false) ([string]$t63)
$beAfter = [System.IO.File]::ReadAllText($beEdit, [System.Text.Encoding]::BigEndianUnicode)
Assert 'edit utf16be content preserved' ($beAfter -eq 'BE-line here EDITED') '[masked BE roundtrip]'
$t64 = Get-RespText 64
Assert 'replace dry-run listing intact (no pipeline unroll)' (([string]$t64 -match 'sample\.py: 2 match\(es\)') -and ([string]$t64 -match 'sample: Greeter')) ([string]$t64)
$t11b = Get-RespText 11
$tail11 = [string]$t11b
Assert 'doctor cheatsheet mentions new tools' ([string]$t11b -match 'http\(url') ('TAIL: ' + $tail11.Substring([Math]::Max(0, $tail11.Length - 260)))

# --- 0.3.4 regressions (round-7 audit P2/P3) ---
Assert 'P2-1 write overwrite:"false" refused' ($resp[70].result.isError -eq $true) (Get-RespText 70)
Assert 'P2-1 write content untouched' (([System.IO.File]::ReadAllText($rA)) -eq 'FOO alpha') '[rA content check]'
$t71 = Get-RespText 71
Assert 'P2-1 replace apply:"false" stays dry-run' (($resp[71].result.isError -eq $false) -and ([string]$t71 -notmatch 'WRITTEN')) ([string]$t71)
Assert 'P2-1 replace content untouched' (([System.IO.File]::ReadAllText($rA)) -eq 'FOO alpha') '[rA content check 2]'
Assert 'P2-2 gate blocks Remove-Item -Rec -Fo' ($resp[72].result.isError -eq $true) (Get-RespText 72)
Assert 'P2-2 gate blocks rm --recursive -f' ($resp[73].result.isError -eq $true) (Get-RespText 73)
Assert 'P2-2 gate blocks gci -r | ri -fo' ($resp[74].result.isError -eq $true) (Get-RespText 74)
Assert 'P2-2 gate blocks erase /s /q' ($resp[75].result.isError -eq $true) (Get-RespText 75)
$t76 = Get-RespText 76
Assert 'P2-5 timeout kills process tree' ([string]$t76 -match 'tree killed') ([string]$t76)
Start-Sleep -Milliseconds 800
$orphan = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'r7sleeper' })
Assert 'P2-5 no orphan grandchild left' ($orphan.Count -eq 0) ('survivors: ' + (($orphan | ForEach-Object { $_.ProcessId }) -join ','))
$t77 = Get-RespText 77
Assert 'P3-1 deep json renders fully' ([string]$t77 -match 'deepok') ([string]$t77)
$t78 = Get-RespText 78
Assert 'P3-2 json index out of range errors' (($resp[78].result.isError -eq $true) -and ([string]$t78 -match 'out of range')) ([string]$t78)
$t79 = Get-RespText 79
Assert 'P3-4 status disk line uses scanned drive' ([string]$t79 -match ('disk ' + [regex]::Escape($tmp.Substring(0, 3)) + ' free')) ([string]$t79)
Assert 'P3-5 batch array gets -32600' ($outText -match '\"code\":-32600') 'no -32600 reply for batch'
$t80 = Get-RespText 80
Assert 'P3-6 read BOM-less utf16 decodes' (([string]$t80 -match 'nobom16') -and ([string]$t80 -notmatch '\x00')) ([string]$t80)
$t81 = Get-RespText 81
Assert 'P3-6 grep finds BOM-less utf16' ([string]$t81 -match 'u16-nobom.txt:1:') ([string]$t81)
$t82 = Get-RespText 82
Assert 'P2-4 no false-positive mask on sk- words' (([string]$t82 -match 'task-runner-scheduler-registry') -and ([string]$t82 -notmatch 'REDACTED')) ([string]$t82)

# --- 0.3.5 regressions (round-8 audit F1-F5) ---
$t83 = Get-RespText 83
Assert 'F1 fake PE skipped by grep' ([string]$t83 -match 'no matches') ([string]$t83)
Assert 'F1 fake PE untouched by replace apply' ((Get-FileHash $peFile -Algorithm SHA256).Hash -eq $peShaBefore) '[fake.bin hash]'
$t85 = Get-RespText 85
Assert 'F3 stripe sk_live_ masked' (([string]$t85 -match 'REDACTED:api-key') -and ([string]$t85 -notmatch '51Habcdefghijklmnopqrstuvwxyz')) '[masked stripe output]'
$t86 = Get-RespText 86
Assert 'F1 utf16 replace two-pass consistent' (($resp[86].result.isError -eq $false) -and ([System.Text.Encoding]::Unicode.GetString([System.IO.File]::ReadAllBytes($u16r)) -eq 'alpha16 GAMMA16')) ([string]$t86)
$t87 = Get-RespText 87
Assert 'F2 cjk BOM-less utf16 reads correctly' ([string]$t87 -match $cjkText) ([string]$t87)

# --- 0.3.6 regressions (round-9 audit F1-F3) ---
$t88 = Get-RespText 88
Assert 'F1 GB18030 extended char decodes correctly' ([string]$t88 -match $gbChar) ([string]$t88)
Assert 'F1 GB18030 replace keeps GB18030 bytes' (([System.Text.Encoding]::GetEncoding('GB18030').GetString([System.IO.File]::ReadAllBytes($gbxFile))) -eq ('X' + $gbChar + 'y')) '[gbx content check]'
$t90 = Get-RespText 90
Assert 'F2 UTF-8 with stray NUL stays readable' (([string]$t90 -match 'alpha') -and ([string]$t90 -match 'beta')) ([string]$t90)
Assert 'F2 replace applies on UTF-8 with stray NUL' (([System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($nulFile))) -eq ('alpha' + [char]0 + ' BETA')) '[nul8 content check]'
$t92 = Get-RespText 92
Assert 'F1 GB18030 latin-1 char decodes correctly' ([string]$t92 -match [string][char]0xE9) ([string]$t92)
$t93 = Get-RespText 93
Assert 'F1 GB18030 emoji decodes correctly' ([string]$t93 -match ([string][char]0xD83D + [string][char]0xDE00)) ([string]$t93)
$t94 = Get-RespText 94
Assert 'F2 short BOM-less utf16 reads correctly' ([string]$t94 -match 'hi') ([string]$t94)
$t95 = Get-RespText 95
Assert 'F2 GB18030 four-byte symbol decodes correctly' ([string]$t95 -match [string][char]0x2600) ([string]$t95)
$t96 = Get-RespText 96
Assert 'F2 GB18030 PUA char decodes correctly' ([string]$t96 -match $puaText) ([string]$t96)

if ($fail -gt 0) {
    Write-Output ''
    Write-Output '--- server stderr ---'
    if ([System.IO.File]::Exists($errFile)) { Write-Output ([System.IO.File]::ReadAllText($errFile)) }
}

try { [System.IO.Directory]::Delete($tmp, $true) } catch {}
Write-Output ''
Write-Output ('zops stdio tests: ' + $pass + ' passed, ' + $fail + ' failed')
if ($fail -gt 0) { exit 1 } else { exit 0 }
