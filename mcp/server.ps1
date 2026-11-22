# zops MCP server (stdio JSON-RPC 2.0).
# Pure PowerShell 5.1, zero dependencies. Keep this file ASCII-only: it is read
# as ANSI when saved without BOM, so any non-ASCII literal would corrupt parsing.
# JSON output is assembled manually because ConvertTo-Json in PS 5.1 collapses
# single-element arrays, which breaks the MCP content[] shape.

$ErrorActionPreference = 'Stop'

$script:ServerName = 'zops'
    $script:ServerVersion = '0.3.9'
$script:DefaultProtocol = '2024-11-05'
$script:MaxFileBytes = 50MB
$script:MaxGrepFileBytes = 20MB
$script:MaxGrepFiles = 5000
$script:MaxLineChars = 2000
$script:MaxMatchChars = 500

# ---------- UTF-8 stdio (bypasses console codepage entirely) ----------
$script:StdIn = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)))
$script:StdOut = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding($false)))
$script:StdOut.AutoFlush = $true

# ---------- JSON writer ----------
$script:ReJsonEscape = [regex]'["\x00-\x1f\\]'

function ConvertTo-JsonString([string]$s) {
    if ($null -eq $s) { return '""' }
    $escaped = $script:ReJsonEscape.Replace($s, {
        param($m)
        $c = $m.Value[0]
        if ($c -eq '"') { return '\"' }
        if ($c -eq '\') { return '\\' }
        if ($c -eq "`n") { return '\n' }
        if ($c -eq "`r") { return '\r' }
        if ($c -eq "`t") { return '\t' }
        return ('\u{0:x4}' -f [int]$c)
    })
    return ('"' + $escaped + '"')
}

function ConvertTo-JsonNumber([object]$v) {
    return $v.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-JsonText {
    param([object]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }
    if ($Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int] -or $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return (ConvertTo-JsonNumber $Value)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = @()
        foreach ($k in $Value.Keys) {
            $parts += (ConvertTo-JsonString ([string]$k)) + ':' + (ConvertTo-JsonText $Value[$k])
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($v in $Value) { $parts += (ConvertTo-JsonText $v) }
        return '[' + ($parts -join ',') + ']'
    }
    return (ConvertTo-JsonString ([string]$Value))
}

# ---------- helpers ----------
function Expand-ToolPath([string]$p) {
    $base = (Get-Location).Path
    if ([string]::IsNullOrWhiteSpace($p)) { return $base }
    $r = $p.Trim().Trim('"')
    if ($r -eq '~') { return $HOME }
    if ($r.StartsWith('~/') -or $r.StartsWith('~\')) { $r = Join-Path $HOME $r.Substring(2) }
    if ([System.IO.Path]::IsPathRooted($r)) { return $r }
    return (Join-Path $base $r)
}

# Shared smart decoder: returns Text plus the Encoding and BOM length needed to
# write the bytes back identically. BOM first, then strict UTF-8, then a scored
# comparison of UTF-16 LE/BE and GB18030 candidates, then system ANSI.
# replace's counting pass and write pass BOTH go through this function - two
# different decoders on the same file is how 0.3.4 corrupted binaries (round8 F1).
function Read-SmartDecode([byte[]]$bytes) {
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return @{ Text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3); Enc = [System.Text.Encoding]::UTF8; Skip = 3 }
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return @{ Text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2); Enc = [System.Text.Encoding]::Unicode; Skip = 2 }
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return @{ Text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2); Enc = [System.Text.Encoding]::BigEndianUnicode; Skip = 2 }
    }
    if ($bytes.Length -eq 0) { return @{ Text = ''; Enc = [System.Text.Encoding]::UTF8; Skip = 0 } }
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    $utf8Text = $null
    try { $utf8Text = $strict.GetString($bytes) } catch {}
    if ($null -ne $utf8Text) {
        # F2 (round9): a genuine UTF-8 file with one stray NUL byte stays UTF-8;
        # only a strong single-parity NUL pattern (the BOM-less UTF-16 signature,
        # >30% of the head at one parity) demotes it to candidate scoring below
        $nulDom = $false
        $preferLE = $false; $preferBE = $false
        # F2 (round10): the gate was -gt 16, which let pure-ASCII BOM-less UTF-16
        # files of <=16 bytes pass as "UTF-8 with NULs" - any 2+ char file (>=4
        # bytes) is old enough to test the parity signature
        if ($bytes.Length -ge 4) {
            $m = [Math]::Min($bytes.Length, 2048); $e2 = 0; $o2 = 0
            for ($i = 0; $i -lt $m; $i++) { if ($bytes[$i] -eq 0) { if (($i % 2) -eq 0) { $e2++ } else { $o2++ } } }
            if (($e2 / $m) -gt 0.3 -or ($o2 / $m) -gt 0.3) {
                $nulDom = $true
                # round-11: the dominant parity names the true UTF-16 encoding
                # (LE text = NULs at odd byte positions, BE text = NULs at even)
                if (($o2 / $m) -gt ($e2 / $m)) { $preferLE = $true } else { $preferBE = $true }
            }
        }
        if (-not $nulDom) { return @{ Text = $utf8Text; Enc = $strict; Skip = 0 } }
    }
    # P3-6/F2 (round8) + F1 (round9): no BOM. Strict UTF-8 either failed or shows
    # the UTF-16 NUL-parity signature. Score candidate decodings: NUL or control
    # characters veto a candidate, printable-ASCII/CJK density scores it, and an
    # exact 2-bytes-per-char decode earns a structural bonus. GB18030 is evaluated
    # FIRST and the bonus may only lift UTF-16 when GB18030 is vetoed or scores
    # below 1.0 - GBK extended-range hanzi (e.g. bytes 86 B4 = U+5586) decode as
    # clean Han in GB18030 AND as plausible Han in UTF-16BE, and that tie must go
    # to GB18030 (0.3.4 behaviour) or replace would rewrite correct files as UTF-16.
    $bestText = $null; $bestEnc = $null; $bestScore = -1.0
    $n = $bytes.Length
    $gbSeen = $false; $gbScore = -1.0; $gbClean = $false
    foreach ($candEnc in @([System.Text.Encoding]::GetEncoding('GB18030'), [System.Text.Encoding]::Unicode, [System.Text.Encoding]::BigEndianUnicode)) {
        $t = $null
        try { $t = $candEnc.GetString($bytes) } catch { continue }
        if ($null -eq $t -or $t.Length -eq 0) { continue }
        $isGb = ($candEnc -eq [System.Text.Encoding]::GetEncoding('GB18030'))
        $lim = [Math]::Min($t.Length, 4096)
        $good = 0; $bad = 0
        $i = 0
        while ($i -lt $lim) {
            $cv = [int][char]$t[$i]
            # F1 (round10): a VALID astral surrogate pair (emoji, CJK Ext-B, ...) is
            # a sign of a coherent decode - count it good. Scoring per UTF-16 unit
            # made GB18030's CORRECT emoji decode (high+low surrogate) score 0 and
            # lose to a bonus-boosted wrong UTF-16 candidate.
            if ($cv -ge 0xD800 -and $cv -le 0xDBFF) {
                $cv2 = 0
                # F1 (round11): lookahead must use the REAL string length, not the
                # 4096 scoring window - a high surrogate at the window edge is a
                # legal pair start, not a lone surrogate
                if (($i + 1) -lt $t.Length) { $cv2 = [int][char]$t[$i + 1] }
                if ($cv2 -ge 0xDC00 -and $cv2 -le 0xDFFF) { $good += 2; $i += 2; continue }  # both units are good text - counting 1 halves the density
                $bad++; $i++; continue
            }
            if ($cv -ge 0xDC00 -and $cv -le 0xDFFF) { $bad++; $i++; continue }
            if ($cv -eq 0xFFFD) {
                # F3 (round-10 follow-up): the last decode unit of an ODD-length
                # truncated file is a natural U+FFFD orphan - neutral, not a
                # wrongness signal (without this the whole UTF-16 candidate gets
                # vetoed and replace pass-1 loses the match entirely). Mid-string
                # or even-length FFFD stays a hard veto.
                $isTrailingOrphan = (($candEnc -eq [System.Text.Encoding]::Unicode -or $candEnc -eq [System.Text.Encoding]::BigEndianUnicode) -and ($n % 2 -eq 1) -and ($i -eq ($lim - 1)))
                if (-not $isTrailingOrphan) { $bad++; $i++; continue }
                $i++; continue
            }
            # F2 (round11): DENYLIST scoring. The old allowlist could never cover
            # all of BMP - GB18030 four-byte symbols (U+2600 sun, dingbats, ...)
            # decoded CORRECTLY yet scored 0 while the wrong UTF-16 read landed in
            # CJK Ext-A and won. Everything is good text except the classic
            # artifacts of a wrong decode: NUL, C0/C1 controls (tab/LF/CR exempt),
            # DEL, and PUA.
            if ($cv -eq 0 -or ($cv -lt 0x20 -and $cv -ne 9 -and $cv -ne 10 -and $cv -ne 13) -or $cv -eq 0x7F) { $bad++; $i++; continue }
            # F2 (round12): PUA and C1 are denied for UTF-16 candidates only -
            # GB18030 maps both ranges intentionally (U+E000-F8FF <-> 0xAAA1-AFFE
            # two-byte codes, C1 <-> GB two-byte codes), so denying them vetoed
            # the one CORRECT decode of a GB18030 file containing PUA characters.
            if (-not $isGb) {
                if (($cv -ge 0x7F -and $cv -le 0x9F) -or ($cv -ge 0xE000 -and $cv -le 0xF8FF)) { $bad++; $i++; continue }
            }
            $good++
            $i++
        }
        if ($isGb) { $gbSeen = $true }
        if ($bad -gt 0) { continue }
        $base = $good / [Math]::Max(1, $lim)
        if ($isGb) { $gbScore = $base; $gbClean = $true }
        # F1 (round10): the structural bonus must never CREATE a win. It applies
        # only when GB18030 is absent/vetoed, or decoded imperfectly (< 1.0) AND
        # this UTF-16 base is strictly better - a 0.0 UTF-16 candidate can never
        # beat a 0.0 GB18030 candidate, and a 1.0 tie always goes to GB18030.
        if (($candEnc -eq [System.Text.Encoding]::Unicode -or $candEnc -eq [System.Text.Encoding]::BigEndianUnicode) -and ($n % 2 -eq 0) -and $t.Length -eq ($n / 2) -and ((-not $gbClean) -or ($gbScore -lt 1.0 -and $base -gt $gbScore))) { $score = $base + 0.05 } else { $score = $base }
        # round-11 observation 1: dominant NUL parity names the true UTF-16
        # encoding - break LE/BE ties with it. Only reachable when NULs exist,
        # i.e. when GB18030 was already vetoed, so a clean GB still wins ties.
        if (($candEnc -eq [System.Text.Encoding]::Unicode -and $preferLE) -or ($candEnc -eq [System.Text.Encoding]::BigEndianUnicode -and $preferBE)) { $score += 0.05 }
        if ($score -gt $bestScore) { $bestScore = $score; $bestText = $t; $bestEnc = $candEnc }
    }
    if ($null -ne $bestText) { return @{ Text = $bestText; Enc = $bestEnc; Skip = 0 } }
    # every candidate vetoed (true binary read as text): keep the legacy chain
    if ($null -ne $utf8Text) { return @{ Text = $utf8Text; Enc = $strict; Skip = 0 } }
    try { $gb = [System.Text.Encoding]::GetEncoding('GB18030'); return @{ Text = $gb.GetString($bytes); Enc = $gb; Skip = 0 } } catch {}
    return @{ Text = [System.Text.Encoding]::Default.GetString($bytes); Enc = [System.Text.Encoding]::Default; Skip = 0 }
}

function Read-BytesTextSmart([byte[]]$bytes) {
    return (Read-SmartDecode $bytes).Text
}

function Read-FileTextSmart([string]$path) {
    return (Read-SmartDecode ([System.IO.File]::ReadAllBytes($path))).Text
}

function Test-BinaryFile([string]$path) {
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $buf = New-Object byte[] 2048
            $n = $fs.Read($buf, 0, 2048)
            # UTF-16 BOM: null bytes are the encoding, not binary content
            if ($n -ge 2 -and (($buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) -or ($buf[0] -eq 0xFE -and $buf[1] -eq 0xFF))) { return $false }
            # F1 (round8): magic numbers veto the UTF-16 parity heuristic below -
            # PE/ELF/ZIP/PNG/RIFF/PDF/gzip/7z/GIF/JPEG zero padding must never read
            # as text (0.3.4 let replace rewrite a real cmd.exe as garbage)
            if ($n -ge 2 -and $buf[0] -eq 0x4D -and $buf[1] -eq 0x5A) { return $true }
            if ($n -ge 4 -and $buf[0] -eq 0x7F -and $buf[1] -eq 0x45 -and $buf[2] -eq 0x4C -and $buf[3] -eq 0x46) { return $true }
            if ($n -ge 2 -and $buf[0] -eq 0x50 -and $buf[1] -eq 0x4B) { return $true }
            if ($n -ge 4 -and $buf[0] -eq 0x89 -and $buf[1] -eq 0x50 -and $buf[2] -eq 0x4E -and $buf[3] -eq 0x47) { return $true }
            if ($n -ge 4 -and $buf[0] -eq 0x52 -and $buf[1] -eq 0x49 -and $buf[2] -eq 0x46 -and $buf[3] -eq 0x46) { return $true }
            if ($n -ge 4 -and $buf[0] -eq 0x25 -and $buf[1] -eq 0x50 -and $buf[2] -eq 0x44 -and $buf[3] -eq 0x46) { return $true }
            if ($n -ge 2 -and $buf[0] -eq 0x1F -and $buf[1] -eq 0x8B) { return $true }
            if ($n -ge 4 -and $buf[0] -eq 0x37 -and $buf[1] -eq 0x7B -and $buf[2] -eq 0xBC -and $buf[3] -eq 0xAF) { return $true }
            if ($n -ge 3 -and $buf[0] -eq 0x47 -and $buf[1] -eq 0x49 -and $buf[2] -eq 0x46) { return $true }
            if ($n -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xD8) { return $true }
            # P3-6 (round7) + F1 guard (round8): BOM-less UTF-16 shows NUL at one
            # stable parity - but the heuristic may only fire when EVERY non-NUL
            # byte in the head is printable text. Any control byte means binary.
            if ($n -gt 16) {
                $evenNul = 0; $oddNul = 0; $ctrl = $false
                for ($i = 0; $i -lt $n; $i++) {
                    $b = $buf[$i]
                    if ($b -eq 0) { if (($i % 2) -eq 0) { $evenNul++ } else { $oddNul++ }; continue }
                    if (($b -lt 0x20 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13) -or $b -eq 0x7F) { $ctrl = $true; break }
                }
                if (-not $ctrl) {
                    if (($oddNul / $n) -gt 0.35 -or ($evenNul / $n) -gt 0.35) { return $false }
                }
            }
            # F2 (round9): a FEW stray NULs in otherwise-text bytes are not a binary
            # signature (UTF-8 may legally contain NUL) - only a substantial NUL
            # population means binary. Read-SmartDecode handles either encoding safely
            # and replace re-encodes byte-faithfully, so the old blanket rule is gone.
            $nulCount = 0
            for ($i = 0; $i -lt $n; $i++) { if ($buf[$i] -eq 0) { $nulCount++ } }
            if ($nulCount -eq 0) { return $false }
            if ($nulCount -le 4 -or (($nulCount * 100) / $n) -le 2.0) { return $false }
            return $true
        } finally { $fs.Close() }
    } catch { return $true }
}

function Get-DisplayPath([string]$full) {
    $cwd = (Get-Location).Path
    if ($cwd -and $full.StartsWith($cwd, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($cwd.Length)
        if ($rel.StartsWith('\') -or $rel.StartsWith('/')) { $rel = $rel.Substring(1) }
        if ($rel -eq '') { return '.' }
        return $rel
    }
    return $full
}

function Get-ArgBool($a, [string]$name, [bool]$default) {
    # P2-1 (round7): [bool]"false" is $true in PowerShell - any non-empty string is
    # truthy, so a string "false" silently ENABLED confirm/overwrite/apply/kill/raw.
    # Real booleans pass through; numbers follow the usual 0=false rule; common
    # string spellings map explicitly; anything else throws instead of silently
    # meaning "true".
    $prop = $a.PSObject.Properties[$name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $default }
    $v = $prop.Value
    if ($v -is [bool]) { return $v }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return ($v -ne 0) }
    if ($v -is [string]) {
        $s = $v.Trim().ToLowerInvariant()
        if ($s -in @('true', '1', 'yes', 'on')) { return $true }
        if ($s -in @('false', '0', 'no', 'off', '')) { return $false }
        throw "zops: argument '$name' must be a boolean (true/false), got string '$v'"
    }
    throw "zops: argument '$name' must be a boolean, got $($v.GetType().Name)"
}

function Get-ArgInt($a, [string]$name, [int]$default) {
    $prop = $a.PSObject.Properties[$name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $default }
    try { return [int]$prop.Value } catch { return $default }
}

function Get-ArgString($a, [string]$name) {
    $prop = $a.PSObject.Properties[$name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return '' }
    return [string]$prop.Value
}

# ---------- tool: read ----------
function Invoke-ToolRead($toolArgs) {
    $path = Expand-ToolPath (Get-ArgString $toolArgs 'path')
    if (-not [System.IO.File]::Exists($path)) { throw "file not found: $path" }
    $fi = New-Object System.IO.FileInfo($path)
    if ($fi.Length -gt $script:MaxFileBytes) { throw "file too large ($($fi.Length) bytes, limit $($script:MaxFileBytes)): $path" }

    $text = (Read-FileTextSmart $path) -replace "`r`n", "`n"
    $lines = @($text -split "`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines = @($lines | Select-Object -First ($lines.Count - 1))
    }
    $total = $lines.Count
    if ($total -eq 0) { return "[zops:read] $path | empty file" }

    $maxChars = Get-ArgInt $toolArgs 'max_chars' 12000
    if ($maxChars -lt 500) { $maxChars = 500 }
    $start = Get-ArgInt $toolArgs 'offset' 1
    $limit = Get-ArgInt $toolArgs 'limit' 400
    if ($limit -lt 1) { $limit = 1 }
    $tail = Get-ArgInt $toolArgs 'tail' 0
    if ($tail -gt 0) {
        $start = $total - $tail + 1
        if ($start -lt 1) { $start = 1 }
        $limit = $total - $start + 1
    }
    if ($start -lt 1) { $start = 1 }
    if ($start -gt $total) { return "[zops:read] $path | total $total lines | offset $start is past the end" }
    $end = $start + $limit - 1
    if ($end -gt $total) { $end = $total }

    $showNums = Get-ArgBool $toolArgs 'line_numbers' $true
    $body = New-Object System.Text.StringBuilder
    $shownEnd = $start - 1
    $used = 0
    for ($i = $start; $i -le $end; $i++) {
        $line = $lines[$i - 1]
        if ($line.Length -gt $script:MaxLineChars) {
            $line = $line.Substring(0, $script:MaxLineChars) + ' ...[line truncated, ' + $line.Length + ' chars]'
        }
        $chunk = ''
        if ($showNums) { $chunk = "${i}: " }
        $chunk += $line
        if ($used + $chunk.Length + 1 -gt $maxChars -and $i -gt $start) {
            $body.Append("[zops] char budget ($maxChars) reached after line $($i - 1); next page: offset=$i limit=$limit`n")
            break
        }
        [void]$body.Append($chunk)
        [void]$body.Append("`n")
        $used += $chunk.Length + 1
        $shownEnd = $i
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[zops:read] $path | total $total lines | showing $start-$shownEnd")
    if ($tail -gt 0) { [void]$sb.Append(" (tail mode)") }
    [void]$sb.Append("`n")
    [void]$sb.Append($body.ToString().TrimEnd())
    return $sb.ToString().TrimEnd()
}

# ---------- tool: grep ----------
function Invoke-ToolGrep($toolArgs) {
    $rawPattern = Get-ArgString $toolArgs 'pattern'
    if ($rawPattern -eq '') { throw 'pattern is required' }
    $noMask = Get-ArgBool $toolArgs 'raw' $false
    $pattern = $rawPattern
    if (Get-ArgBool $toolArgs 'plain' $false) { $pattern = [regex]::Escape($pattern) }
    $opts = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    if (Get-ArgBool $toolArgs 'ignore_case' $false) { $opts = $opts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    try {
        $rx = New-Object System.Text.RegularExpressions.Regex($pattern, $opts)
    } catch {
        throw "invalid regex pattern: $($_.Exception.Message)"
    }

    $root = Expand-ToolPath (Get-ArgString $toolArgs 'path')
    $include = Get-ArgString $toolArgs 'include'
    $maxResults = Get-ArgInt $toolArgs 'max_results' 100
    if ($maxResults -lt 1) { $maxResults = 1 }

    $files = @()
    if ([System.IO.File]::Exists($root)) {
        $files = @($root)
    } elseif ([System.IO.Directory]::Exists($root)) {
        $all = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force:$false -ErrorAction SilentlyContinue)
        if ($all.Count -gt $script:MaxGrepFiles) {
            throw "directory tree has $($all.Count) files (limit $($script:MaxGrepFiles)); narrow the search path or use include filter"
        }
        $files = @($all | ForEach-Object { $_.FullName })
        if ($include -ne '') {
            $files = @($files | Where-Object { (Split-Path $_ -Leaf) -like $include })
        }
    } else {
        throw "path not found: $root"
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[zops:grep] /$rawPattern/ in $(Get-DisplayPath $root) | max $maxResults results")
    if ($include -ne '') { [void]$sb.Append(" | include=$include") }
    [void]$sb.Append("`n")
    $count = 0
    $scanned = 0
    $skipped = 0
    $capped = $false
    foreach ($f in $files) {
        if ($capped) { break }
        $fi = New-Object System.IO.FileInfo($f)
        if ($fi.Length -gt $script:MaxGrepFileBytes) { $skipped++; continue }
        if (Test-BinaryFile $f) { $skipped++; continue }
        $text = $null
        try { $text = Read-FileTextSmart $f } catch { $skipped++; continue }
        $scanned++
        $lineNo = 0
        foreach ($line in @($text -replace "`r`n", "`n" -split "`n")) {
            $lineNo++
            if (-not $rx.IsMatch($line)) { continue }
            $count++
            $disp = $line
            if (-not $noMask) { $disp = Hide-ZopsSecrets $disp }
            if ($disp.Length -gt $script:MaxMatchChars) { $disp = $disp.Substring(0, $script:MaxMatchChars) + ' ...[truncated]' }
            [void]$sb.Append((Get-DisplayPath $f) + ":$lineNo" + ': ' + $disp + "`n")
            if ($count -ge $maxResults) {
                $capped = $true
                [void]$sb.Append("[zops] result cap ($maxResults) reached; refine pattern or raise max_results`n")
                break
            }
        }
    }
    if ($count -eq 0) { [void]$sb.Append("no matches | $scanned files scanned, $skipped skipped") }
    return $sb.ToString().TrimEnd()
}

# ---------- tool: tree ----------
$script:TreeCount = 0

function Add-TreeLevel([string]$dir, [int]$level, [int]$maxDepth, [string]$prefix, [System.Collections.Generic.List[string]]$out,
    [int]$maxEntries, [string]$include, [System.Collections.Generic.List[string]]$skip, [bool]$hidden) {

    if ($script:TreeCount -ge $maxEntries) { return $true }
    $items = @(Get-ChildItem -LiteralPath $dir -Force:$hidden -ErrorAction SilentlyContinue)
    $dirs = @($items | Where-Object { $_.PSIsContainer } | Sort-Object Name)
    $files = @($items | Where-Object { -not $_.PSIsContainer } | Sort-Object Name)
    if ($include -ne '') {
        $files = @($files | Where-Object { $_.Name -like $include })
    }
    $dirs = @($dirs | Where-Object { $skip -notcontains $_.Name.ToLowerInvariant() })

    $all = @($dirs + $files)
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($script:TreeCount -ge $maxEntries) {
            $out.Add($prefix + '... [zops] entry cap reached, raise max_entries or narrow path')
            return $true
        }
        $item = $all[$i]
        $last = ($i -eq $all.Count - 1)
        $conn = if ($last) { '+- ' } else { '|- ' }
        if ($item.PSIsContainer) {
            $out.Add($prefix + $conn + $item.Name + '/')
            $script:TreeCount++
            if ($level -lt $maxDepth) {
                $childPrefix = if ($last) { $prefix + '   ' } else { $prefix + '|  ' }
                $stop = Add-TreeLevel -dir $item.FullName -level ($level + 1) -maxDepth $maxDepth -prefix $childPrefix -out $out -maxEntries $maxEntries -include $include -skip $skip -hidden $hidden
                if ($stop) { return $true }
            }
        } else {
            $sizeLabel = ''
            if ($item.Length -ge 1MB) { $sizeLabel = ' (' + [Math]::Round($item.Length / 1MB, 1).ToString([System.Globalization.CultureInfo]::InvariantCulture) + 'MB)' }
            elseif ($item.Length -ge 1KB) { $sizeLabel = ' (' + [Math]::Round($item.Length / 1KB, 0).ToString([System.Globalization.CultureInfo]::InvariantCulture) + 'KB)' }
            $out.Add($prefix + $conn + $item.Name + $sizeLabel)
            $script:TreeCount++
        }
    }
    return $false
}

function Invoke-ToolTree($toolArgs) {
    $root = Expand-ToolPath (Get-ArgString $toolArgs 'path')
    if (-not [System.IO.Directory]::Exists($root)) { throw "directory not found: $root" }
    $maxDepth = Get-ArgInt $toolArgs 'depth' 2
    if ($maxDepth -lt 1) { $maxDepth = 1 }
    if ($maxDepth -gt 8) { $maxDepth = 8 }
    $maxEntries = Get-ArgInt $toolArgs 'max_entries' 400
    if ($maxEntries -lt 1) { $maxEntries = 1 }
    $include = Get-ArgString $toolArgs 'include'
    $hidden = Get-ArgBool $toolArgs 'show_hidden' $false

    $skipStr = 'node_modules,.git,dist,target,__pycache__,.venv,venv,.zcode'
    $skipArg = Get-ArgString $toolArgs 'skip_dirs'
    if ($skipArg -ne '') {
        if ($skipArg -eq 'none') { $skipStr = '' } else { $skipStr = $skipArg }
    }
    $skip = New-Object System.Collections.Generic.List[string]
    foreach ($s in ($skipStr -split ',')) {
        $t = $s.Trim().ToLowerInvariant()
        if ($t -ne '') { $skip.Add($t) }
    }

    $script:TreeCount = 0
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("[zops:tree] $(Get-DisplayPath $root) | depth $maxDepth | cap $maxEntries entries")
    [void](Add-TreeLevel -dir $root -level 1 -maxDepth $maxDepth -prefix '' -out $out -maxEntries $maxEntries -include $include -skip $skip -hidden $hidden)
    $out.Add("[zops] $($script:TreeCount) entries")
    return ($out -join "`n")
}

# ---------- tool: run ----------
function Find-ShellProgram([string]$want) {
    $candidates = @()
    if ($want -eq 'pwsh') {
        $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($cmd) { $candidates += $cmd.Source }
        $candidates += @('C:\Program Files\PowerShell\7\pwsh.exe', 'C:\Program Files\PowerShell\7-preview\pwsh.exe')
    } elseif ($want -eq 'bash') {
        $candidates += @(
            'C:\Program Files\Git\bin\bash.exe',
            'C:\Program Files\Git\usr\bin\bash.exe',
            'C:\Program Files (x86)\Git\bin\bash.exe',
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
        )
        $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notlike 'C:\Windows\*') { $candidates += $cmd.Source }
    } elseif ($want -eq 'powershell') {
        $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if ($cmd) { return @{ prog = $cmd.Source; shell = 'powershell' } }
        $candidates += @((Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    } elseif ($want -eq 'cmd') {
        return @{ prog = (Join-Path $env:WINDIR 'System32\cmd.exe'); shell = 'cmd' }
    }
    foreach ($c in $candidates) {
        if ($c -and [System.IO.File]::Exists($c)) {
            $label = $want
            if ($want -eq 'pwsh') {
                try { $label = 'pwsh ' + (& $c -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null) } catch {}
            } elseif ($want -eq 'bash') {
                try { $label = 'bash ' + (& $c --version 2>$null | Select-Object -First 1) } catch {}
            }
            return @{ prog = $c; shell = $label }
        }
    }
    return $null
}

# ---------- 0.3.0 helpers: secret mask / smart filter / danger gate / ledger ----------
$script:SecretRules = @(
    @('-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----', '[REDACTED:private-key]'),
    @('eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', '[REDACTED:jwt]'),
    @('AKIA[0-9A-Z]{16}', '[REDACTED:aws-key]'),
    @('ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}', '[REDACTED:github-token]'),
    # P2-4 (round7): left boundary + key-like shape. The old sk-[..]{16,} matched
    # the "sk-" inside ordinary hyphenated words (task-runner-scheduler-...).
    # Real keys are dense alnum (OpenAI/DeepSeek run >=24 chars) or carry a known
    # provider prefix (sk-live-/sk-proj-/sk-ant-...).
    @('(?<![A-Za-z0-9])sk-[A-Za-z0-9]{24,}', '[REDACTED:api-key]'),
    # F3 (round8): Stripe separators are underscores (sk_live_...), not hyphens -
    # accept both, keep the left boundary so task-/disk- words stay unmolested
    @('(?<![A-Za-z0-9])sk[_-](?:live|test|proj|ant|svcacct)[_-][A-Za-z0-9_-]{16,}', '[REDACTED:api-key]'),
    @('xox[baprs]-[A-Za-z0-9-]{10,}', '[REDACTED:slack-token]'),
    @('\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^\s/@]+:[^\s/@]+@', '[REDACTED:db-url]'),
    @('\bBearer\s+[A-Za-z0-9._\-]{16,}', '[REDACTED:bearer]'),
    @('(?i)(api[_-]?key|secret|token|password|passwd|pwd)\s*[:=]\s*["'']?[A-Za-z0-9_\-/+=]{12,}', '[REDACTED:credential]')
)

function Hide-ZopsSecrets([string]$text) {
    if ($null -eq $text -or $text.Length -eq 0) { return $text }
    foreach ($r in $script:SecretRules) {
        try { $text = [regex]::Replace($text, $r[0], $r[1]) } catch {}
    }
    return $text
}

$script:DangerPatterns = @(
    # rd/rmdir/del/erase: /s anywhere in the tail (rmdir /s /q, del /f /s, ...)
    # (round7 P2-2: "erase" is a cmd alias of del and slipped the old list)
    '\b(?:rd|rmdir|del|erase)\b[^;|&]*\/[sS]\b',
    # rm: recursive+force in any order - short clusters (-rf/-fr), long options,
    # GNU prefix abbreviations (--rec/--fo), mixed long+short freely. One dual
    # lookahead covers all of them (round7 P2-2: the old pair missed mixes like
    # "rm --recursive -f"). NOTE: \brm\s+ consumed the space, so the lookahead's
    # dash must be preceded by (?:\s|^) - \s- alone never matches here.
    '\brm\s+(?=(?:.*\s)?(?:-[a-zA-Z]*r|--rec(?:u(?:r(?:s(?:i(?:v(?:e)?)?)?)?)?)?\b))(?=(?:.*\s)?(?:-[a-zA-Z]*f|--f(?:o(?:r(?:c(?:e)?)?)?)?\b))',
    # PowerShell Remove-Item / ri: abbreviation-tolerant recursive+force, any order
    # (-Rec/-Recu/... and -Fo/-Forc/... are legal PS parameter prefixes; round7 P2-2)
    '\b(?:Remove-Item|ri)\b(?=(?:[^;|&\r\n]*\s)?-r(?:e(?:c(?:u(?:r(?:s(?:e)?)?)?)?)?)?\b)(?=(?:[^;|&\r\n]*\s)?-f(?:o(?:r(?:c(?:e)?)?)?)?\b)',
    '\b(?:Remove-Item|ri)\b(?=(?:[^;|&\r\n]*\s)?-f(?:o(?:r(?:c(?:e)?)?)?)?\b)(?=(?:[^;|&\r\n]*\s)?-r(?:e(?:c(?:u(?:r(?:s(?:e)?)?)?)?)?)?\b)',
    # cross-pipeline: recursive listing piped into a delete cmdlet with force
    # (round7 P2-2: "gci -r x | ri -fo" split the flags across two segments and ran)
    '\b(?:gci|get-childitem|dir|ls)\b[^;|&\r\n]*\s-(?:r\b|R\b|rec(?:u(?:r(?:s(?:e)?)?)?)?\b)[^;|&\r\n]*\|\s*(?:ri|remove-item|del|erase|rm)\b[^;|&\r\n]*\s-f(?:o(?:r(?:c(?:e)?)?)?)?\b',
    # cmd: dir /s piped into del/erase/rd, or FOR /R walking a tree to delete
    '\bdir\b[^;|&\r\n]*\/[sS]\b[^;|&\r\n]*\|\s*(?:del|erase|rd|rmdir)\b',
    '\bfor\s+\/r\b[^&\r\n]*\bdo\b[^&\r\n]*\b(?:del|erase|rd|rmdir)\b',
    # git: --hard reachable from reset/checkout/restore; push force, short or long
    '\bgit\s+(?:reset|checkout|restore)\b[^;|&]*--hard\b',
    '\bgit\s+push\b[^;|&]*(--force(?!-with-lease)|\s-f\b)',
    '\bgit\s+clean\b[^;|&]*-[a-zA-Z]*f',
    '\bformat\s+[a-zA-Z]:',
    '\bdiskpart\b',
    '\bshutdown\b',
    '\bbcdedit\b',
    '\bvssadmin\s+delete'
)

function Test-ZopsDangerous([string]$command) {
    $hits = @()
    foreach ($p in $script:DangerPatterns) {
        try { if ([regex]::IsMatch($command, $p, 'IgnoreCase')) { $hits += $p } } catch {}
    }
    return $hits
}

function Get-ZopsSmartCategory([string]$command) {
    $c = ' ' + $command.ToLowerInvariant() + ' '
    if ($c -match '(pytest|go test|cargo test|\bnpm (run )?test\b|\bvitest\b|\bjest\b)') { return 'test' }
    if ($c -match '\bgit status\b') { return 'git-status' }
    if ($c -match '\bgit diff\b') { return 'git-diff' }
    if ($c -match '\bgit log\b') { return 'git-log' }
    if ($c -match '\b(npm|pnpm|yarn) (install|i|add|update|ci)\b|\bpip install\b') { return 'install' }
    if ($c -match '\b(eslint|ruff check|flake8|clippy|mypy)\b') { return 'lint' }
    if ($c -match '\b(tsc|msbuild|dotnet build|make)\b|\b(mvn|gradle)\b') { return 'build' }
    return $null
}

function Invoke-ZopsSmartFilter([string]$cat, [string]$text) {
    # rtk promises, ported: never blocks (caller falls back to raw on error),
    # never worse (caller only swaps when strictly shorter), nothing hidden
    # (caller prints where the full output is kept).
    $lines = @($text -replace "`r`n", "`n" -split "`n")
    $out = New-Object System.Collections.Generic.List[string]
    switch ($cat) {
        'test' {
            $failIdx = New-Object System.Collections.Generic.List[int]
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '(?i)(fail|error|assert|panic|traceback|EXCEPTION|denied|cannot find)') { $failIdx.Add($i) }
            }
            if ($failIdx.Count -eq 0) {
                return ('ALL PASS (' + $lines.Count + ' lines collapsed). tail: ' + ((@($lines | Select-Object -Last 2)) -join ' | '))
            }
            $want = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($i in $failIdx) { for ($j = $i; $j -le [Math]::Min($i + 2, $lines.Count - 1); $j++) { [void]$want.Add($j) } }
            for ($i = 0; $i -lt [Math]::Min(2, $lines.Count); $i++) { [void]$want.Add($i) }
            for ($i = [Math]::Max(0, $lines.Count - 3); $i -lt $lines.Count; $i++) { [void]$want.Add($i) }
            $prev = -2
            foreach ($i in ($want | Sort-Object)) {
                if ($i - $prev -gt 1) { $out.Add('...') }
                $out.Add($lines[$i]); $prev = $i
            }
        }
        'git-status' {
            foreach ($l in $lines) { if ($l.Trim() -ne '' -and $l -notmatch '^\s{2,}\(use ') { $out.Add($l) } }
        }
        'git-diff' {
            foreach ($l in $lines) { if ($l -match '^(diff |index |@@ |[+-])') { $out.Add($l) } }
        }
        'git-log' {
            foreach ($l in @($lines | Select-Object -First 30)) { $out.Add($l) }
            if ($lines.Count -gt 30) { $out.Add('...') }
        }
        'install' {
            foreach ($l in @($lines | Where-Object { $_ -match '(?i)(error|warn|ERR!|vulnerab|added|removed|changed)' } | Select-Object -First 30)) { $out.Add($l) }
            foreach ($l in @($lines | Select-Object -Last 3)) { $out.Add($l) }
        }
        'lint' {
            foreach ($l in @($lines | Select-Object -First 60)) { $out.Add($l) }
            if ($lines.Count -gt 60) { $out.Add('...') }
            foreach ($l in @($lines | Select-Object -Last 2)) { $out.Add($l) }
        }
        'build' {
            foreach ($l in $lines) { if ($l -match '(?i)(error|warning|failed|BUILD)') { $out.Add($l) } }
            foreach ($l in @($lines | Select-Object -Last 3)) { $out.Add($l) }
        }
        default { return $text }
    }
    if ($out.Count -eq 0) { return $text }
    return ($out -join "`n")
}

function Get-ZopsDataDir {
    # user keeps C: clean: ledger/notes live on E: (env ZOPS_DATA_DIR overrides)
    $base = $env:ZOPS_DATA_DIR
    if (-not $base -or $base.Trim() -eq '') { $base = Join-Path $env:LOCALAPPDATA 'zops' }
    return $base.TrimEnd('\')
}

function Write-ZopsLedger([string]$tool, [int]$outChars, [double]$ms) {
    try {
        $dir = Join-Path (Get-ZopsDataDir) 'stats'
        if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        if (-not $script:StatsSwept) {
            # keep 30 days of ledger, rotate the rest (once per process)
            $script:StatsSwept = $true
            $cutoff = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
            Get-ChildItem $dir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -lt $cutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        $file = Join-Path $dir ((Get-Date -Format 'yyyy-MM-dd') + '.jsonl')
        $rec = '{"t":"' + (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') + '","tool":"' + $tool + '","chars":' + $outChars + ',"ms":' + [Math]::Round($ms) + '}'
        [System.IO.File]::AppendAllText($file, $rec + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Invoke-ToolRun($toolArgs) {
    $command = Get-ArgString $toolArgs 'command'
    if ($command.Trim() -eq '') { throw 'command is required' }
    $want = (Get-ArgString $toolArgs 'shell').ToLowerInvariant()
    if ($want -eq '') { $want = 'auto' }
    $timeoutSec = Get-ArgInt $toolArgs 'timeout_sec' 60
    if ($timeoutSec -lt 1) { $timeoutSec = 1 }
    if ($timeoutSec -gt 600) { $timeoutSec = 600 }
    $maxChars = Get-ArgInt $toolArgs 'max_chars' 6000
    if ($maxChars -lt 500) { $maxChars = 500 }
    $cwd = Expand-ToolPath (Get-ArgString $toolArgs 'cwd')
    if (-not [System.IO.Directory]::Exists($cwd)) { $cwd = (Get-Location).Path }
    $smart = Get-ArgBool $toolArgs 'smart' $false
    $rawOut = Get-ArgBool $toolArgs 'raw' $false

    # dangerous-command gate (safety-net idea): refuse until confirm:true
    # F4 (round8): evaluate confirm unconditionally so a malformed value errors
    # even for harmless commands (lazy evaluation used to hide it)
    $confirm = Get-ArgBool $toolArgs 'confirm' $false
    $danger = Test-ZopsDangerous $command
    if ($danger -and -not $confirm) {
        throw "dangerous command blocked: $($danger -join '; ') - re-run with confirm:true if you really mean it"
    }

    $resolved = $null
    if ($want -eq 'auto') {
        $resolved = Find-ShellProgram 'cmd'
    } else {
        $resolved = Find-ShellProgram $want
        if ($null -eq $resolved) { throw "shell '$want' not found on this machine (auto falls back to cmd)" }
    }
    $prog = $resolved.prog
    $shellName = $resolved.shell

    $argList = @()
    $tmpScript = $null
    try {
        if ($resolved.shell -eq 'cmd') {
            $argList = @('/d', '/s', '/c', ('"' + $command + '"'))
        } elseif ($shellName -like 'powershell*') {
            $tmpScript = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("zops-" + [System.Guid]::NewGuid().ToString('N') + ".ps1"))
            [System.IO.File]::WriteAllText($tmpScript, $command, (New-Object System.Text.UTF8Encoding($true)))
            $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $tmpScript + '"'))
        } elseif ($shellName -like 'pwsh*') {
            $tmpScript = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("zops-" + [System.Guid]::NewGuid().ToString('N') + ".ps1"))
            [System.IO.File]::WriteAllText($tmpScript, $command, (New-Object System.Text.UTF8Encoding($true)))
            $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $tmpScript + '"'))
        } elseif ($shellName -like 'bash*') {
            $tmpScript = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("zops-" + [System.Guid]::NewGuid().ToString('N') + ".sh"))
            [System.IO.File]::WriteAllText($tmpScript, ($command -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
            $argList = @('-c', ('"' + ($tmpScript -replace '\\', '/') + '"'))
        } else {
            throw "unknown shell: $shellName"
        }

        $timedOut = $false
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # CreateNoWindow is the only reliable window suppressor here: PS 5.1's
        # Start-Process with -RedirectStandard* forces UseShellExecute=false, which
        # silently ignores -WindowStyle Hidden and pops a visible console per call.
        $pi = New-Object System.Diagnostics.ProcessStartInfo
        $pi.FileName = $prog
        $pi.Arguments = ($argList -join ' ')
        $pi.WorkingDirectory = $cwd
        $pi.UseShellExecute = $false
        $pi.CreateNoWindow = $true
        $pi.RedirectStandardOutput = $true
        $pi.RedirectStandardError = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $pi
        $stdoutText = ''
        $stderrText = ''
        try {
            [void]$proc.Start()
            # capture raw bytes so the same BOM/UTF-8/GB18030 auto-detect as the old
            # file-redirection path still applies (cmd prints GBK Chinese here)
            $outMs = New-Object System.IO.MemoryStream
            $errMs = New-Object System.IO.MemoryStream
            $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($outMs)
            $errTask = $proc.StandardError.BaseStream.CopyToAsync($errMs)
            if (-not $proc.WaitForExit($timeoutSec * 1000)) {
                $timedOut = $true
                # P2-5 (round7): kill the whole process tree. Killing only the direct
                # child left grandchildren (cmd -> powershell/npm/test runners) running
                # for minutes while the reply claimed "process killed". taskkill /T /F
                # is hidden-window safe (CreateNoWindow + UseShellExecute=false).
                try {
                    $tk = New-Object System.Diagnostics.ProcessStartInfo
                    $tk.FileName = 'taskkill'
                    $tk.Arguments = "/PID $($proc.Id) /T /F"
                    $tk.UseShellExecute = $false
                    $tk.CreateNoWindow = $true
                    $tkProc = [System.Diagnostics.Process]::Start($tk)
                    try { [void]$tkProc.WaitForExit(3000) } finally { try { $tkProc.Dispose() } catch {} }
                } catch {}
                try { $proc.Kill() } catch {}  # belt-and-suspenders if taskkill failed
                [void]$proc.WaitForExit()
            }
            $exitCode = 0
            try { if ($null -ne $proc.ExitCode) { $exitCode = $proc.ExitCode } } catch {}
            # killed processes may never EOF the redirected streams (orphaned
            # grandchildren hold handles) - take whatever bytes landed, never wait long
            try { [void]$outTask.Wait(1200) } catch {}
            try { [void]$errTask.Wait(1200) } catch {}
            try { $stdoutText = (Read-BytesTextSmart $outMs.ToArray()).TrimEnd() } catch {}
            try { $stderrText = (Read-BytesTextSmart $errMs.ToArray()).TrimEnd() } catch {}
        } finally {
            $sw.Stop()
            try { $proc.Dispose() } catch {}
        }

        # A2 first: secret masking (raw:true skips) - masking happens BEFORE anything
        # is written to disk so the full-output file never contains plaintext secrets
        if (-not $rawOut) {
            $stdoutText = Hide-ZopsSecrets $stdoutText
            $stderrText = Hide-ZopsSecrets $stderrText
        }
        # A1: per-command smart filter (rtk idea) - only swaps when strictly shorter,
        # keeps the (already masked) full output in a temp file and says where it is
        if ($smart -and -not $timedOut -and $stdoutText.Length -gt 400) {
            $cat = Get-ZopsSmartCategory $command
            if ($cat) {
                try {
                    $filtered = Invoke-ZopsSmartFilter $cat $stdoutText
                    if ($null -ne $filtered -and $filtered.Length -gt 0 -and $filtered.Length -lt $stdoutText.Length) {
                        $fullFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('zops-smart-' + [Guid]::NewGuid().ToString('N') + '.log'))
                        [System.IO.File]::WriteAllText($fullFile, $stdoutText, (New-Object System.Text.UTF8Encoding($false)))
                        $stdoutText = $filtered + "`n[zops:smart] ${cat}: $($stdoutText.Length) -> $($filtered.Length) chars; full output kept at $fullFile"
                    }
                } catch {}
            }
        }

        $sb = New-Object System.Text.StringBuilder
        $status = "exit=$exitCode"
        # "tree killed" is literal truth since P2-5 (round7): taskkill /T /F takes
        # the whole descendant chain down, not just the direct child
        if ($timedOut) { $status = "TIMEOUT after ${timeoutSec}s, process tree killed" }
        [void]$sb.Append("[zops:run] shell=$shellName $status elapsed=$([Math]::Round($sw.Elapsed.TotalSeconds, 1).ToString([System.Globalization.CultureInfo]::InvariantCulture))s cwd=$(Get-DisplayPath $cwd)`n")
        $body = ''
        if ($stdoutText -ne '') { $body += $stdoutText + "`n" }
        if ($stderrText -ne '') {
            foreach ($ln in @($stderrText -replace "`r`n", "`n" -split "`n")) { $body += '[stderr] ' + $ln + "`n" }
        }
        if ($body -eq '') { $body = "(no output)`n" }
        if ($body.Length -gt $maxChars) {
            $head = [Math]::Floor($maxChars * 0.6)
            $tailN = $maxChars - $head - 80
            $omitted = $body.Length - $head - $tailN
            $body = $body.Substring(0, $head) + "`n[zops] ... $omitted chars omitted (raise max_chars or reduce output) ...`n" + $body.Substring($body.Length - $tailN)
        }
        [void]$sb.Append($body.TrimEnd())
        return $sb.ToString()
    } finally {
        if ($tmpScript -and [System.IO.File]::Exists($tmpScript)) {
            try { [System.IO.File]::Delete($tmpScript) } catch {}
        }
    }
}

# ---------- shared helpers for extended tools ----------
function Get-ZopsCheatSheet {
    return 'cheatsheet: read(path,offset,limit,tail,max_chars) | grep(pattern,path,include,plain,raw,max_results) | tree(path,depth,max_entries) | run(command,shell[cmd|powershell|pwsh|bash],smart,confirm,raw,timeout_sec,max_chars) | edit(path,find,replace,expected_count,occurrence[first|all]) | write(path,content,overwrite,encoding) | replace(path,pattern,replace,include,apply,expected_files) | diff(a,b,context,max_chars) | outline(path,ext,max_entries) | json(path,query) | status | doctor | notes(action[set|get|list|delete|clear],key,value) | port(port,kill,confirm) | http(url,method,headers,body,timeout_sec,max_chars,insecure) | stats'
}

function Find-GitExe {
    if ($env:ZOPS_DISABLE_GIT) { return $null }  # test switch: force the no-git fallback paths
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files (x86)\Git\cmd\git.exe'
    )
    foreach ($c in $cands) {
        if ($c -and [System.IO.File]::Exists($c)) { return $c }
    }
    return $null
}

function Split-TextLines([string]$text) {
    $norm = $text -replace "`r`n", "`n"
    $lines = @($norm -split "`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines = @($lines | Select-Object -First ($lines.Count - 1))
    }
    return $lines
}

function Get-TopLevelEntries([string]$root, [string[]]$skipNames) {
    $out = @()
    try {
        foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($root)) {
            $name = [System.IO.Path]::GetFileName($e)
            if ($skipNames -contains $name.ToLowerInvariant()) { continue }
            $out += ,@($e, ([System.IO.File]::Exists($e)))
        }
    } catch {}
    return $out
}

# ---------- tool: edit ----------
function Invoke-ToolEdit($toolArgs) {
    $path = Expand-ToolPath (Get-ArgString $toolArgs 'path')
    if (-not [System.IO.File]::Exists($path)) { throw "file not found: $path" }
    $fi = New-Object System.IO.FileInfo($path)
    if ($fi.Length -gt 20MB) { throw "file too large for edit ($($fi.Length) bytes, limit 20MB): $path" }
    $find = Get-ArgString $toolArgs 'find'
    if ($find -eq '') { throw 'find is required (text to locate; use read/grep first)' }
    if ($find.Length -gt 20000) { throw "find too long ($($find.Length) chars, limit 20000)" }
    $replace = Get-ArgString $toolArgs 'replace'
    if ($replace.Length -gt 40000) { throw "replace too long ($($replace.Length) chars, limit 40000)" }
    $expected = Get-ArgInt $toolArgs 'expected_count' 0
    $occurrence = (Get-ArgString $toolArgs 'occurrence').ToLowerInvariant()
    if ($occurrence -ne 'first' -and $occurrence -ne 'all') { $occurrence = 'all' }

    $bytes = [System.IO.File]::ReadAllBytes($path)
    # same decode chain as Read-FileTextSmart, but keep the encoding for write-back
    $enc = $null; $skip = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = [System.Text.Encoding]::UTF8; $skip = 3 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [System.Text.Encoding]::Unicode; $skip = 2 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = [System.Text.Encoding]::BigEndianUnicode; $skip = 2 }
    else {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        try { [void]$strict.GetString($bytes); $enc = $strict } catch {
            try { [void][System.Text.Encoding]::GetEncoding('GB18030').GetString($bytes); $enc = [System.Text.Encoding]::GetEncoding('GB18030') } catch { $enc = [System.Text.Encoding]::Default }
        }
    }
    $text = $enc.GetString($bytes, $skip, $bytes.Length - $skip)
    $eol = $null
    if ($text.Contains("`r`n")) { $eol = "`r`n" } elseif ($text.Contains("`n")) { $eol = "`n" }
    $norm = $text -replace "`r`n", "`n"
    $findN = $find -replace "`r`n", "`n"
    $repN = $replace -replace "`r`n", "`n"

    $count = 0; $firstPos = -1; $idx = 0
    while ($true) {
        $idx = $norm.IndexOf($findN, $idx, [System.StringComparison]::Ordinal)
        if ($idx -lt 0) { break }
        if ($count -eq 0) { $firstPos = $idx }
        $count++
        $idx += [Math]::Max(1, $findN.Length)
    }
    if ($count -eq 0) { throw "find: 0 occurrences in $path - nothing written (check exact text/whitespace via read)" }
    if ($expected -gt 0 -and $count -ne $expected) { throw "find: $count occurrence(s), expected_count=$expected - nothing written" }

    if ($occurrence -eq 'first') {
        $newNorm = $norm.Substring(0, $firstPos) + $repN + $norm.Substring($firstPos + $findN.Length)
        $applied = 1
        $newPos = $firstPos
    } else {
        $newNorm = $norm.Replace($findN, $repN)
        $applied = $count
        $newPos = $newNorm.IndexOf($repN, [System.StringComparison]::Ordinal)
        if ($newPos -lt 0) { $newPos = [Math]::Max(0, $firstPos) }
    }
    if ($eol) { $out = $newNorm -replace "`n", $eol } else { $out = $newNorm }
    $newBytes = $enc.GetBytes($out)
    if ($skip -gt 0) {
        $all = New-Object byte[] ($skip + $newBytes.Length)
        [Array]::Copy($bytes, 0, $all, 0, $skip)
        [Array]::Copy($newBytes, 0, $all, $skip, $newBytes.Length)
        $newBytes = $all
    }
    [System.IO.File]::WriteAllBytes($path, $newBytes)

    $oldLines = (Split-TextLines $norm).Count
    $newLines = (Split-TextLines $newNorm).Count
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[zops:edit] $path | found $count, applied $applied ($occurrence) | bytes $(($newBytes.Length - $bytes.Length)) lines $(($newLines - $oldLines))`n")
    $ctxBefore = $norm.Substring([Math]::Max(0, $firstPos - 40), [Math]::Min(40, $firstPos))
    $take = [Math]::Min($findN.Length, 200)
    $ctxAfter = $newNorm.Substring($newPos, [Math]::Min(220, $newNorm.Length - $newPos))
    $prevBefore = ('before: ' + $ctxBefore + $findN.Substring(0, $take)) -replace "`n", ' / '
    $prevAfter = ('after : ' + $ctxAfter) -replace "`n", ' / '
    [void]$sb.Append($prevBefore)
    [void]$sb.Append("`n")
    [void]$sb.Append($prevAfter)
    if ($ctxAfter.Length -ge 220) { [void]$sb.Append(' ...') }
    return $sb.ToString()
}

# ---------- tool: diff ----------
function Invoke-ToolDiff($toolArgs) {
    $aPath = Expand-ToolPath (Get-ArgString $toolArgs 'a')
    $bPath = Expand-ToolPath (Get-ArgString $toolArgs 'b')
    foreach ($p in @($aPath, $bPath)) {
        if (-not [System.IO.File]::Exists($p)) { throw "file not found: $p" }
    }
    $ctx = Get-ArgInt $toolArgs 'context' 3
    if ($ctx -lt 0) { $ctx = 0 }
    if ($ctx -gt 10) { $ctx = 10 }
    $maxChars = Get-ArgInt $toolArgs 'max_chars' 6000
    if ($maxChars -lt 500) { $maxChars = 500 }

    $git = Find-GitExe
    if ($git) {
        $outText = ''
        try {
            # stdout only: git's CRLF warnings go to stderr, and 2>&1 under PS 5.1
            # turns them into ErrorRecords that blow up the pipeline (empty output
            # would be misread as "identical")
            $outText = (& $git diff --no-index --no-color "--unified=$ctx" -- $aPath $bPath | Out-String)
        } catch { $outText = '' }
        if ($outText -and $outText.Trim() -ne '') {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append("[zops:diff] $aPath vs $bPath (git)`n")
            $body = @(($outText -replace "`r`n", "`n") -split "`n") | Where-Object { $_ -notmatch '^(diff |index |--- |\+\+\+ |old mode|new mode|similarity)' }
            $used = 0
            foreach ($l in $body) {
                if ($used + $l.Length + 1 -gt $maxChars) {
                    [void]$sb.Append("[zops] char budget ($maxChars) reached; diff truncated`n")
                    break
                }
                if ($l.Length -gt $script:MaxLineChars) { $l = $l.Substring(0, $script:MaxLineChars) + ' ...' }
                [void]$sb.Append($l + "`n")
                $used += $l.Length + 1
            }
            return $sb.ToString().TrimEnd()
        }
        return "[zops:diff] $aPath vs $bPath (git) | identical"
    }

    # fallback without git: coarse prefix/suffix trim report
    $la = Split-TextLines (Read-FileTextSmart $aPath)
    $lb = Split-TextLines (Read-FileTextSmart $bPath)
    if (($la -join "`n") -eq ($lb -join "`n")) { return "[zops:diff] $aPath vs $bPath | identical" }
    $n = [Math]::Min($la.Count, $lb.Count); $pre = 0
    while ($pre -lt $n -and $la[$pre] -eq $lb[$pre]) { $pre++ }
    $suf = 0; $na = $la.Count; $nb = $lb.Count
    while ($suf -lt ($n - $pre) -and $la[$na - 1 - $suf] -eq $lb[$nb - 1 - $suf]) { $suf++ }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[zops:diff] $aPath vs $bPath | git not found, coarse diff`n")
    [void]$sb.Append("common prefix $pre lines, common suffix $suf lines`n")
    [void]$sb.Append("changed region: a[$($pre + 1)..$($na - $suf)] ($($na - $suf - $pre) lines) -> b[$($pre + 1)..$($nb - $suf)] ($($nb - $suf - $pre) lines)`n")
    $shown = 0
    for ($i = $pre; $i -lt [Math]::Min($pre + 20, $na - $suf); $i++) {
        if ($shown + $la[$i].Length + 2 -gt $maxChars) { break }
        [void]$sb.Append("- $($la[$i])`n"); $shown += $la[$i].Length + 2
    }
    for ($i = $pre; $i -lt [Math]::Min($pre + 20, $nb - $suf); $i++) {
        if ($shown + $lb[$i].Length + 2 -gt $maxChars) { break }
        [void]$sb.Append("+ $($lb[$i])`n"); $shown += $lb[$i].Length + 2
    }
    return $sb.ToString().TrimEnd()
}

# ---------- tool: outline ----------
function Get-OutlinePatterns([string]$ext) {
    switch ($ext) {
        '.py' { return @('^\s*(async\s+def|def|class)\s+[\w~]+') }
        '.ps1' { return @('^\s*function\s+[\w\.-]+') }
        '.js' { return @('^\s*(export\s+)?(default\s+)?(async\s+)?(function\s*\*?\s*[\w$]+|class\s+[\w$]+|const\s+[\w$]+\s*=\s*(async\s*)?\(|let\s+[\w$]+\s*=\s*(async\s*)?\(|interface\s+[\w$]+|type\s+[\w$]+\s*=|enum\s+[\w$]+)') }
        '.jsx' { return @('^\s*(export\s+)?(default\s+)?(async\s+)?(function\s*\*?\s*[\w$]+|class\s+[\w$]+|const\s+[\w$]+\s*=\s*(async\s*)?\(|interface\s+[\w$]+|type\s+[\w$]+\s*=|enum\s+[\w$]+)') }
        '.ts' { return @('^\s*(export\s+)?(default\s+)?(async\s+)?(function\s*\*?\s*[\w$]+|class\s+[\w$]+|const\s+[\w$]+\s*=\s*(async\s*)?\(|interface\s+[\w$]+|type\s+[\w$]+\s*=|enum\s+[\w$]+)') }
        '.tsx' { return @('^\s*(export\s+)?(default\s+)?(async\s+)?(function\s*\*?\s*[\w$]+|class\s+[\w$]+|const\s+[\w$]+\s*=\s*(async\s*)?\(|interface\s+[\w$]+|type\s+[\w$]+\s*=|enum\s+[\w$]+)') }
        '.mjs' { return @('^\s*(export\s+)?(default\s+)?(async\s+)?(function\s*\*?\s*[\w$]+|class\s+[\w$]+|const\s+[\w$]+\s*=\s*(async\s*)?\()') }
        '.cjs' { return @('^\s*(export\s+)?(default\s+)?(async\s+)?(function\s*\*?\s*[\w$]+|class\s+[\w$]+|const\s+[\w$]+\s*=\s*(async\s*)?\()') }
        '.go' { return @('^func\s', '^type\s+[\w]+\s+(struct|interface)') }
        '.rs' { return @('^\s*(pub\s+)?(async\s+)?(fn|struct|enum|trait|impl|mod)\s+[\w<>, ]*[\w]+') }
        '.java' { return @('^\s*(public|private|protected|internal|static|final|abstract|sealed|override)\s+[\w\<\>, \s]*(class|interface|enum|record)\s+\w+') }
        '.cs' { return @('^\s*(public|private|protected|internal|static|sealed|abstract|partial)\s+[\w\<\>, \s]*(class|interface|enum|record|struct)\s+\w+') }
        '.c' { return @('^(typedef|struct|union|enum)\b[^;{]*$|^(static\s+)?[\w\*\s]+\([^;]*\)\s*\{') }
        '.h' { return @('^(typedef|struct|union|enum)\b[^;{]*$|^[\w\*\s]+\([^;]*\)\s*;') }
        '.cpp' { return @('^(typedef|struct|union|enum)\b[^;{]*$|^(static\s+)?[\w\*\s:\<\>~]+\([^;]*\)\s*\{') }
        '.hpp' { return @('^(typedef|struct|union|enum)\b[^;{]*$|^[\w\*\s:\<\>~]+\([^;]*\)\s*;') }
        '.md' { return @('^#{1,6}\s') }
        default { return $null }
    }
}

function Invoke-ToolOutline($toolArgs) {
    $path = Expand-ToolPath (Get-ArgString $toolArgs 'path')
    $maxEntries = Get-ArgInt $toolArgs 'max_entries' 300
    if ($maxEntries -lt 10) { $maxEntries = 10 }
    if ($maxEntries -gt 2000) { $maxEntries = 2000 }
    $maxChars = Get-ArgInt $toolArgs 'max_chars' 6000
    if ($maxChars -lt 500) { $maxChars = 500 }
    $sb = New-Object System.Text.StringBuilder
    $used = 0
    $shownEntries = 0

    if ([System.IO.File]::Exists($path)) {
        $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        $pats = Get-OutlinePatterns $ext
        if ($null -eq $pats) { throw "no outline patterns for '$ext'; use grep instead" }
        $lines = Split-TextLines (Read-FileTextSmart $path)
        [void]$sb.Append("[zops:outline] $path | $($lines.Count) lines`n")
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($shownEntries -ge $maxEntries) { break }
            $l = $lines[$i]
            foreach ($p in $pats) {
                if ($l -match $p) {
                    $t = $l.Trim()
                    if ($t.Length -gt 120) { $t = $t.Substring(0, 120) + ' ...' }
                    $chunk = "$($i + 1): $t"
                    if ($used + $chunk.Length + 1 -gt $maxChars) { $shownEntries = $maxEntries; break }
                    [void]$sb.Append($chunk + "`n")
                    $used += $chunk.Length + 1
                    $shownEntries++
                    break
                }
            }
        }
        if ($shownEntries -eq 0) { [void]$sb.Append("(no definitions matched)`n") }
        return $sb.ToString().TrimEnd()
    }

    if (-not [System.IO.Directory]::Exists($path)) { throw "path not found: $path" }
    [void]$sb.Append("[zops:outline] $path (directory scan)`n")
    $skip = @('node_modules', '.git', 'dist', 'target', '__pycache__', '.venv', 'venv', '.zcode')
    $stack = New-Object System.Collections.Stack
    $stack.Push($path)
    $filesScanned = 0
    while ($stack.Count -gt 0 -and $shownEntries -lt $maxEntries -and $filesScanned -lt 400) {
        $dir = $stack.Pop()
        try { $subs = @(Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 500) } catch { continue }
        foreach ($e in $subs) {
            if ($shownEntries -ge $maxEntries) { break }
            if ($e.PSIsContainer) {
                if ($skip -notcontains $e.Name.ToLowerInvariant()) { $stack.Push($e.FullName) }
                continue
            }
            $ext = [System.IO.Path]::GetExtension($e.Name).ToLowerInvariant()
            $pats = Get-OutlinePatterns $ext
            if ($null -eq $pats) { continue }
            if ($e.Length -gt 2MB) { continue }
            $filesScanned++
            $lines = $null
            try { $lines = Split-TextLines (Read-FileTextSmart $e.FullName) } catch { continue }
            $fileHeaderDone = $false
            $fileDefs = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($shownEntries -ge $maxEntries) { break }
                $l = $lines[$i]
                $isDef = $false
                foreach ($p in $pats) { if ($l -match $p) { $isDef = $true; break } }
                if (-not $isDef) { continue }
                if (-not $fileHeaderDone) {
                    $rel = Get-DisplayPath $e.FullName
                    $chunk = "== $rel"
                    if ($used + $chunk.Length + 1 -gt $maxChars) { break }
                    [void]$sb.Append($chunk + "`n")
                    $used += $chunk.Length + 1
                    $fileHeaderDone = $true
                }
                $t = $l.Trim()
                if ($t.Length -gt 120) { $t = $t.Substring(0, 120) + ' ...' }
                $chunk = "$($i + 1): $t"
                if ($used + $chunk.Length + 1 -gt $maxChars) { break }
                [void]$sb.Append($chunk + "`n")
                $used += $chunk.Length + 1
                $shownEntries++
                $fileDefs++
                if ($fileDefs -ge 60) { break }
            }
        }
    }
    [void]$sb.Append("[zops] $filesScanned files scanned, $shownEntries definitions (budget $maxEntries)`n")
    return $sb.ToString().TrimEnd()
}

# ---------- tool: status ----------
function Invoke-ToolStatus($toolArgs) {
    $cwd = Expand-ToolPath (Get-ArgString $toolArgs 'path')
    if (-not [System.IO.Directory]::Exists($cwd)) { $cwd = (Get-Location).Path }
    $maxChars = Get-ArgInt $toolArgs 'max_chars' 6000
    if ($maxChars -lt 500) { $maxChars = 500 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[zops:status] $(Get-DisplayPath $cwd)`n")

    # git snapshot: one porcelain call for branch+dirty, one for last commit
    $git = Find-GitExe
    if ($git) {
        $gs = ''
        try { $gs = (& $git -C $cwd status --porcelain -b 2>&1 | Out-String).TrimEnd() } catch { $gs = '' }
        if ($gs -ne '') {
            $gl = @(($gs -replace "`r`n", "`n") -split "`n")
            $branch = $gl[0] -replace '^##\s*', ''
            $dirty = 0; $staged = 0
            for ($i = 1; $i -lt $gl.Count; $i++) {
                if ($gl[$i].Trim() -eq '') { continue }
                $dirty++
                $st = $gl[$i].Substring(0, [Math]::Min(2, $gl[$i].Length))
                if ($st -match '[MARTCMD]') { $staged++ }
            }
            [void]$sb.Append("git: $branch | dirty $dirty file(s) ($staged staged)`n")
            $log = ''
            # quoted single token: an unquoted %s gets arg-split by git and dies;
            # stdout only - CRLF warnings on stderr would pollute the line
            try { $log = (& $git -C $cwd log -1 '--pretty=format:%h %s' | Out-String).TrimEnd() } catch { $log = '' }
            if ($log -ne '') {
                if ($log.Length -gt 110) { $log = $log.Substring(0, 110) + ' ...' }
                [void]$sb.Append("last: $log`n")
            }
        } else {
            [void]$sb.Append("git: not a repository`n")
        }
    } else {
        [void]$sb.Append("git: git.exe not found`n")
    }

    # single capped walk: totals, largest files, big logs
    $skip = @('node_modules', '.git', 'dist', 'target', '__pycache__', '.venv', 'venv', '.zcode')
    $totalFiles = 0; $totalBytes = [long]0
    $largest = New-Object System.Collections.ArrayList
    $logs = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($cwd)
    $scanned = 0
    while ($stack.Count -gt 0 -and $scanned -lt 8000) {
        $dir = $stack.Pop()
        try { $subs = @(Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 800) } catch { continue }
        foreach ($e in $subs) {
            if ($scanned -ge 8000) { break }
            if ($e.PSIsContainer) {
                if ($skip -notcontains $e.Name.ToLowerInvariant()) { $stack.Push($e.FullName) }
                continue
            }
            $scanned++; $totalFiles++; $totalBytes += $e.Length
            if ($e.Length -gt 0) {
                # pscustomobject survives pipeline unrolling; raw arrays do not
                $largest.Add([pscustomobject]@{ size = $e.Length; path = $e.FullName }) | Out-Null
            }
            if ($e.Extension -match '^\.(log|etl)$' -and $e.Length -gt 1MB) {
                $logs.Add([pscustomobject]@{ size = $e.Length; path = $e.FullName }) | Out-Null
            }
        }
    }
    [void]$sb.Append("files: $totalFiles scanned (cap 8000), total $([Math]::Round($totalBytes / 1MB, 1)) MB`n")
    $top = @($largest | Sort-Object size -Descending | Select-Object -First 8)
    if ($top.Count -gt 0) {
        [void]$sb.Append("largest:`n")
        foreach ($p in $top) {
            [void]$sb.Append("  $([Math]::Round($p.size / 1MB, 2)) MB  $(Get-DisplayPath $p.path)`n")
        }
    }
    $topLogs = @($logs | Sort-Object size -Descending | Select-Object -First 5)
    if ($topLogs.Count -gt 0) {
        [void]$sb.Append("big logs (>1MB, tail with read):`n")
        foreach ($p in $topLogs) {
            [void]$sb.Append("  $([Math]::Round($p.size / 1MB, 2)) MB  $(Get-DisplayPath $p.path)`n")
        }
    }
    # P3-4 (round7): report the scanned path's drive, not the process cwd's - and
    # DriveInfo.Name already ends in '\', so no extra ':' after it
    try {
        $driveSrc = $cwd
        if (-not $driveSrc -or $driveSrc.Trim().Length -lt 3) { $driveSrc = (Get-Location).Path }
        $drv = [System.IO.DriveInfo]::new($driveSrc.Substring(0, 3))
        [void]$sb.Append("disk $($drv.Name) free $([Math]::Round($drv.AvailableFreeSpace / 1GB, 1)) GB of $([Math]::Round($drv.TotalSize / 1GB, 1)) GB`n")
    } catch {}
    [void]$sb.Append((Get-ZopsCheatSheet))
    return $sb.ToString().TrimEnd()
}

# ---------- tool: doctor ----------
function Invoke-ToolDoctor($toolArgs) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[zops:doctor]`n")

    foreach ($want in @('cmd', 'powershell', 'pwsh', 'bash')) {
        $r = Find-ShellProgram $want
        if ($r) {
            $label = $r.shell
            if ($label.Length -gt 60) { $label = $label.Substring(0, 60) }
            [void]$sb.Append("OK    shell $want -> $label`n")
        } else {
            [void]$sb.Append("WARN  shell $want not available`n")
        }
    }

    foreach ($exe in @('python.exe', 'git.exe', 'node.exe')) {
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if ($cmd) {
            $src = $cmd.Source
            $ver = '?'
            try {
                $vi = (Get-Item $src).VersionInfo
                if ($vi.ProductVersion) { $ver = $vi.ProductVersion }
            } catch {}
            if ($ver.Length -gt 30) { $ver = $ver.Substring(0, 30) }
            [void]$sb.Append("OK    $exe $ver ($src)`n")
        } else {
            $cands = @()
            if ($exe -eq 'git.exe') { $cands += @(Find-GitExe) }
            if ($cands.Count -gt 0 -and $cands[0]) {
                [void]$sb.Append("WARN  $exe not on PATH but found at $($cands[0])`n")
            } else {
                [void]$sb.Append("WARN  $exe not found`n")
            }
        }
    }

    try {
        $drv = [System.IO.DriveInfo]::new((Get-Location).Path.Substring(0, 3))
        $freeGB = [Math]::Round($drv.AvailableFreeSpace / 1GB, 1)
        $lvl = 'OK'
        if ($freeGB -lt 1) { $lvl = 'FAIL' } elseif ($freeGB -lt 10) { $lvl = 'WARN' }
        [void]$sb.Append("$lvl    disk $($drv.Name) free $freeGB GB`n")
    } catch {}

    try {
        $t = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('zops-doctor-' + [Guid]::NewGuid().ToString('N')))
        [System.IO.File]::WriteAllText($t, 'x')
        [System.IO.File]::Delete($t)
        [void]$sb.Append("OK    temp writable`n")
    } catch {
        [void]$sb.Append('FAIL  temp not writable`n')
    }
    [void]$sb.Append("INFO  host MCP call cap ~30s: long tasks use run with care or the session's background shell`n")
    [void]$sb.Append("INFO  console encoding is GBK on cmd; zops read/grep auto-detect UTF-8/UTF-16/GB18030`n")
    [void]$sb.Append((Get-ZopsCheatSheet))
    return $sb.ToString().TrimEnd()
}

# ---------- tool: notes ----------
function Get-NotesFile {
    $cwd = (Get-Location).Path
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hb = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cwd.ToLowerInvariant()))
    $hex = ([BitConverter]::ToString($hb) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    $dir = Join-Path (Get-ZopsDataDir) 'notes'
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    return (Join-Path $dir ($hex + '.json'))
}

function Invoke-ToolNotes($toolArgs) {
    $action = (Get-ArgString $toolArgs 'action').ToLowerInvariant()
    if ($action -eq '') { $action = 'list' }
    $key = Get-ArgString $toolArgs 'key'
    $value = Get-ArgString $toolArgs 'value'
    $file = Get-NotesFile
    $isWriter = ($action -in @('set', 'delete', 'clear'))

    # P2-3 (round7): writers serialize on an exclusive lock file and load the store
    # INSIDE the lock, so parallel zops processes can never lose each other's
    # updates (the old read-modify-write had no lock and one shared tmp name). The
    # .lock file stays behind (0 bytes) on purpose - deleting it would re-open the
    # race between two waiters.
    $lockFs = $null
    $corruptNote = ''
    try {
        if ($isWriter) {
            $tries = 0
            while ($true) {
                try {
                    $lockFs = [System.IO.File]::Open(($file + '.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                    break
                } catch {
                    $tries++
                    # F5 (round8): 8x60ms occasionally ran out under 4+ concurrent
                    # writers - 20 tries (~1.2s worst case) keeps the cost negligible
                    # and the busy error rare
                    if ($tries -ge 20) { throw 'notes: store busy (another zops process holds it) - retry shortly' }
                    Start-Sleep -Milliseconds 60
                }
            }
        }
        $notes = @{}
        if ([System.IO.File]::Exists($file)) {
            $doc = $null
            try { $doc = ConvertFrom-Json (Read-FileTextSmart $file) } catch { $doc = $null }
            if ($null -eq $doc -or $null -eq $doc.notes) {
                # P2-3 (round7): a transient parse failure (read racing a concurrent
                # atomic replace) must not quarantine healthy data - re-read once;
                # only a second consecutive failure counts as corrupt
                Start-Sleep -Milliseconds 150
                $doc = $null
                try { $doc = ConvertFrom-Json (Read-FileTextSmart $file) } catch { $doc = $null }
            }
            if ($null -ne $doc -and $null -ne $doc.notes) {
                foreach ($p in $doc.notes.PSObject.Properties) { $notes[$p.Name] = [string]$p.Value }
            } else {
                # corrupt store: preserve the broken file for forensics, start fresh
                try {
                    $kept = $file + '.corrupt-' + (Get-Date -Format 'HHmmss')
                    Move-Item $file $kept -Force
                    $corruptNote = 'WARN: notes store was corrupt - previous data moved to ' + $kept
                } catch { $corruptNote = 'WARN: notes store was corrupt and could not be preserved' }
                $notes = @{}
            }
        }
        switch ($action) {
            'set' {
                if ($key -eq '') { throw 'notes set: key is required' }
                if ($key.Length -gt 100) { throw 'notes set: key too long (max 100)' }
                if ($value.Length -gt 2000) { throw 'notes set: value too long (max 2000 chars)' }
                if ($notes.Count -ge 50 -and -not $notes.ContainsKey($key)) { throw 'notes set: 50 notes max, delete some first' }
                $notes[$key] = $value
            }
            'get' {
                if ($key -eq '') { throw 'notes get: key is required' }
                if (-not $notes.ContainsKey($key)) { return "[zops:notes] no note '$key' in this workspace" }
                $v = $notes[$key]
                if ($v.Length -gt 2000) { $v = $v.Substring(0, 2000) + ' ...' }
                return "[zops:notes] $key =`n$v"
            }
            'delete' {
                if ($key -eq '') { throw 'notes delete: key is required' }
                if (-not $notes.ContainsKey($key)) { return "[zops:notes] no note '$key' to delete" }
                [void]$notes.Remove($key)
            }
            'clear' { $notes = @{} }
            'list' { }
            default { throw "notes: unknown action '$action' (set|get|list|delete|clear)" }
        }

        if ($action -eq 'list') {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append("[zops:notes] $($notes.Count) note(s) for $(Get-DisplayPath (Get-Location).Path)`n")
            $keys = @($notes.Keys | Sort-Object)
            foreach ($k in $keys) {
                $v = $notes[$k]
                $prev = $v -replace "`r`n", ' '
                $prev = $prev -replace "`n", ' '
                if ($prev.Length -gt 60) { $prev = $prev.Substring(0, 60) + ' ...' }
                [void]$sb.Append("- $k ($($v.Length)b): $prev`n")
            }
            if ($notes.Count -eq 0) { [void]$sb.Append('(empty - set(key,value) to stash findings so later turns skip re-exploration)') }
            return $sb.ToString().TrimEnd()
        }

        # persist set/delete/clear - unique tmp name + File.Replace (Move fallback)
        # keeps the write atomic; readers always see a complete store and concurrent
        # writers never stomp each other's tmp file (P2-3, round7)
        # P3-3 (round7): was -ge 50, which rejected the 50th note (off-by-one)
        if ($notes.Count -gt 50) { throw 'notes: 50 notes max' }
        $total = 0
        foreach ($v in $notes.Values) { $total += $v.Length }
        if ($total -gt 64KB) { throw 'notes: store over 64KB, delete some notes' }
        $docObj = [ordered]@{ v = 1; notes = $notes }
        $tmpStore = $file + ('.tmp-' + $PID + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            [System.IO.File]::WriteAllText($tmpStore, (ConvertTo-JsonText $docObj), (New-Object System.Text.UTF8Encoding($false)))
            $saved = $false
            for ($attempt = 0; $attempt -lt 3 -and -not $saved; $attempt++) {
                try {
                    if ([System.IO.File]::Exists($file)) {
                        try { [void][System.IO.File]::Replace($tmpStore, $file, $null) }
                        catch { Move-Item $tmpStore $file -Force }  # FAT/network volumes lack Replace
                    } else {
                        Move-Item $tmpStore $file
                    }
                    $saved = $true
                } catch { Start-Sleep -Milliseconds 80 }
            }
            if (-not $saved) { throw 'notes: could not persist store (file busy) - value NOT saved' }
        } finally {
            if ([System.IO.File]::Exists($tmpStore)) { try { Remove-Item $tmpStore -Force -ErrorAction SilentlyContinue } catch {} }
        }
        $warn = ''
        if ($corruptNote -ne '') { $warn = $corruptNote + "`n" }
        return "[zops:notes] $action done | $($notes.Count) note(s) stored for $(Get-DisplayPath (Get-Location).Path)`n$warn".TrimEnd()
    } finally {
        if ($null -ne $lockFs) { try { $lockFs.Dispose() } catch {} }
    }
}

# ---------- tool: write ----------
function Invoke-ToolWrite($toolArgs) {
    $path = Expand-ToolPath (Get-ArgString $toolArgs 'path')
    $content = Get-ArgString $toolArgs 'content'
    if ($content.Length -gt 200000) { throw "content too long ($($content.Length) chars, limit 200000)" }
    $encName = (Get-ArgString $toolArgs 'encoding').ToLowerInvariant()
    if ($encName -eq '') { $encName = 'utf8' }
    $enc = switch ($encName) {
        'utf8' { New-Object System.Text.UTF8Encoding($false) }
        'utf8-bom' { New-Object System.Text.UTF8Encoding($true) }
        'utf16' { [System.Text.Encoding]::Unicode }
        'gb18030' { [System.Text.Encoding]::GetEncoding('GB18030') }
        default { throw "unknown encoding: $encName (utf8|utf8-bom|utf16|gb18030)" }
    }
    $exists = [System.IO.File]::Exists($path)
    # F4 (round8): evaluate the flag unconditionally so a malformed value errors
    # even when the file doesn't exist yet (lazy evaluation used to hide it)
    $overwrite = Get-ArgBool $toolArgs 'overwrite' $false
    if ($exists -and -not $overwrite) { throw "file exists: $path (overwrite:true to replace)" }
    $parent = Split-Path $path -Parent
    if (-not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($path, $content, $enc)
    $lines = (Split-TextLines $content).Count
    $mode = 'created'; if ($exists) { $mode = 'overwritten' }
    return "[zops:write] $path | $mode | $($content.Length) chars, $lines lines, encoding=$encName"
}

# ---------- tool: replace ----------
function Invoke-ToolReplace($toolArgs) {
    $root = Expand-ToolPath (Get-ArgString $toolArgs 'path')
    $pattern = Get-ArgString $toolArgs 'pattern'
    if ($pattern -eq '') { throw 'pattern is required' }
    $replacement = Get-ArgString $toolArgs 'replace'
    $include = Get-ArgString $toolArgs 'include'
    $apply = Get-ArgBool $toolArgs 'apply' $false
    $expectedFiles = Get-ArgInt $toolArgs 'expected_files' 0
    try { $rx = New-Object System.Text.RegularExpressions.Regex($pattern, 'IgnoreCase') } catch { throw "invalid regex: $($_.Exception.Message)" }

    if ([System.IO.File]::Exists($root)) { $files = @($root) }
    elseif ([System.IO.Directory]::Exists($root)) {
        if ($include -eq '') { throw 'include glob is required for a directory scan (safety fence)' }
        $all = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)
        $files = @($all | Where-Object { (Split-Path $_.FullName -Leaf) -like $include } | ForEach-Object { $_.FullName })
    } else { throw "path not found: $root" }
    if ($files.Count -gt 400) { throw "too many candidate files ($($files.Count), limit 400); narrow the path or include" }

    # pass 1: count matches per file (read-only)
    $hits = @()
    foreach ($f in $files) {
        $fi = New-Object System.IO.FileInfo($f)
        if ($fi.Length -gt 2MB) { continue }
        if (Test-BinaryFile $f) { continue }
        $text = $null
        try { $text = Read-FileTextSmart $f } catch { continue }
        $mc = $rx.Matches($text)
        if ($mc.Count -eq 0) { continue }
        $sample = $mc[0].Value
        if ($sample.Length -gt 100) { $sample = $sample.Substring(0, 100) + '...' }
        $hits += ,@($f, $mc.Count, $sample)
    }

    $sb = New-Object System.Text.StringBuilder
    $mode = 'DRY-RUN'; if ($apply) { $mode = 'APPLY' }
    [void]$sb.Append("[zops:replace] /$pattern/ -> replacement in $(Get-DisplayPath $root) | $mode | include=$include`n")
    # index loop, NOT pipeline: $hits elements are sub-arrays and a pipeline would unroll them
    $shown = [Math]::Min($hits.Count, 100)
    for ($hi = 0; $hi -lt $shown; $hi++) {
        $f = $hits[$hi][0]; $nMatches = $hits[$hi][1]; $sample = $hits[$hi][2]
        if ($sample.Length -gt 100) { $sample = $sample.Substring(0, 100) + '...' }
        [void]$sb.Append("  $(Get-DisplayPath $f): $nMatches match(es), sample: $sample`n")
    }
    if ($hits.Count -gt 100) { [void]$sb.Append('  ... (100 files listed, refine path/include)') }
    if ($hits.Count -eq 0) {
        [void]$sb.Append("no matches in $($files.Count) file(s) scanned")
        return $sb.ToString().TrimEnd()
    }
    if ($apply -and $expectedFiles -gt 0 -and $hits.Count -ne $expectedFiles) {
        throw "expected_files=$expectedFiles but $($hits.Count) file(s) matched - nothing was written (inspect the dry-run list above)"
    }
    if ($apply) {
        $written = 0; $totalHits = 0
        foreach ($h in $hits) {
            $f = $h[0]
            $totalHits += $h[1]
            try {
                # F1 (round8): decode with the SAME shared decoder pass 1 used, and
                # re-encode with the encoding it selected - the old inline BOM/UTF-8/
                # GB18030 chain disagreed with Read-FileTextSmart on BOM-less UTF-16
                # and silently rewrote binary content as garbage
                $rawBytes = [System.IO.File]::ReadAllBytes($f)
                $d = Read-SmartDecode $rawBytes
                # F3 (round9): a truncated odd-length BOM-less UTF-16 file would grow
                # a U+FFFD replacement char on rewrite - refuse instead of writing
                # bytes the user never asked to change
                if ((($rawBytes.Length - $d.Skip) % 2 -eq 1) -and ($d.Enc -eq [System.Text.Encoding]::Unicode -or $d.Enc -eq [System.Text.Encoding]::BigEndianUnicode)) {
                    [void]$sb.Append("  SKIP $(Get-DisplayPath $f): odd-length BOM-less UTF-16 (truncated file) - not rewritten`n")
                    continue
                }
                $text = $d.Text; $enc = $d.Enc; $skip = $d.Skip
                $newText = $rx.Replace($text, $replacement)
                if ([string]::Compare($newText, $text, [StringComparison]::Ordinal) -eq 0) { continue }
                $newBytes = $enc.GetBytes($newText)
                if ($skip -gt 0) {
                    $allB = New-Object byte[] ($skip + $newBytes.Length)
                    [Array]::Copy($rawBytes, 0, $allB, 0, $skip)
                    [Array]::Copy($newBytes, 0, $allB, $skip, $newBytes.Length)
                    $newBytes = $allB
                }
                [System.IO.File]::WriteAllBytes($f, $newBytes)
                $written++
            } catch {
                [void]$sb.Append("  SKIP $(Get-DisplayPath $f): $($_.Exception.Message)`n")
            }
        }
        [void]$sb.Append("summary: $($hits.Count) file(s) / $totalHits match(es) identified, $written file(s) WRITTEN")
        return $sb.ToString().TrimEnd()
    }
    $totalHits = 0
    foreach ($h in $hits) { $totalHits += $h[1] }
    [void]$sb.Append("summary: $($hits.Count) file(s), $totalHits match(es) (dry-run; re-run with apply:true to write)")
    return $sb.ToString().TrimEnd()
}

# ---------- tool: json ----------
function Invoke-ToolJson($toolArgs) {
    $path = Expand-ToolPath (Get-ArgString $toolArgs 'path')
    if (-not [System.IO.File]::Exists($path)) { throw "file not found: $path" }
    $fi = New-Object System.IO.FileInfo($path)
    if ($fi.Length -gt $script:MaxFileBytes) { throw "file too large: $path" }
    $text = (Read-FileTextSmart $path).TrimStart()
    if ($text.Length -eq 0) { throw 'file is empty' }
    $maxChars = Get-ArgInt $toolArgs 'max_chars' 6000
    if ($maxChars -lt 500) { $maxChars = 500 }
    try { $doc = ConvertFrom-Json $text } catch { throw "invalid JSON: $($_.Exception.Message)" }
    $query = Get-ArgString $toolArgs 'query'
    if ($query -ne '') {
        $node = $doc
        foreach ($seg in ($query -split '\.')) {
            if ($seg -match '^([\w\-]+)\[(\d+)\]$') {
                $prop = $node.PSObject.Properties[$matches[1]]
                if ($null -eq $prop) { throw "query path '$query' broke at segment '$($matches[1])'" }
                $arr = @($prop.Value)
                $idx = $matches[2] -as [int]
                # P3-2 (round7): out-of-range used to return an empty string
                # silently, indistinguishable from a real null value
                if ($idx -ge $arr.Count) { throw "query path '$query': index $idx out of range ('$($matches[1])' has $($arr.Count) item(s))" }
                $node = $arr[$idx]
            } elseif ($seg -match '^\[(\d+)\]$') {
                $arr = @($node)
                $idx = $matches[1] -as [int]
                if ($idx -ge $arr.Count) { throw "query path '$query': index $idx out of range (array has $($arr.Count) item(s))" }
                $node = $arr[$idx]
            } else {
                $prop = $node.PSObject.Properties[$seg]
                if ($null -eq $prop) { throw "query path '$query' broke at segment '$seg'" }
                $node = $prop.Value
            }
        }
        $out = ''
        if ($node -is [string] -or $node -is [int] -or $node -is [long] -or $node -is [bool] -or $node -is [double]) { $out = [string]$node }
        else { $out = ConvertTo-Json $node -Depth 64 -Compress }  # P3-1 (round7): depth 6 silently mangled nesting >= 8 into PS hashtable text
        if ($out.Length -gt $maxChars) { $out = $out.Substring(0, $maxChars) + ' ...[truncated, ' + $out.Length + ' chars total]' }
        return "[zops:json] $query =>`n$out"
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[zops:json] $(Get-DisplayPath $path) | valid JSON, $([Math]::Round($fi.Length/1024,1)) KB`n")
    if ($doc -is [System.Array]) {
        $first = @($doc)[0]
        $keys = ''
        if ($null -ne $first -and $first -isnot [string] -and $first -isnot [int]) { $keys = ($first.PSObject.Properties.Name | Select-Object -First 15) -join ', ' }
        [void]$sb.Append('array with ' + @($doc).Count + " item(s); item keys: $keys")
        return $sb.ToString().TrimEnd()
    }
    foreach ($p in $doc.PSObject.Properties) {
        $v = $p.Value; $kind = 'object'; $prev = ''
        if ($v -is [string]) { $kind = 'string(' + $v.Length + ')'; $prev = $v; if ($prev.Length -gt 50) { $prev = $prev.Substring(0, 50) + '...' } }
        elseif ($v -is [System.Array]) { $kind = 'array(' + @($v).Count + ')' }
        elseif ($v -is [bool]) { $kind = 'boolean'; $prev = [string]$v }
        elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { $kind = 'number'; $prev = [string]$v }
        elseif ($null -eq $v) { $kind = 'null' }
        [void]$sb.Append('  ' + $p.Name + ' : ' + $kind + ' ' + $prev + "`n")
        if ($sb.Length -gt $maxChars) { [void]$sb.Append('...'); break }
    }
    return $sb.ToString().TrimEnd()
}

# ---------- tool: port ----------
function Invoke-ToolPort($toolArgs) {
    $port = Get-ArgInt $toolArgs 'port' 0
    if ($port -lt 1 -or $port -gt 65535) { throw 'port must be 1-65535' }
    $kill = Get-ArgBool $toolArgs 'kill' $false
    $confirm = Get-ArgBool $toolArgs 'confirm' $false
    $rows = @()
    try { $rows += @(Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue) } catch {}
    try { $rows += @(Get-NetUDPConnection -LocalPort $port -ErrorAction SilentlyContinue) } catch {}
    if ($rows.Count -eq 0) { return "[zops:port] $port : nothing listening" }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[zops:port] $port :`n")
    $pids = @()
    foreach ($c in $rows) {
        $procId = [int]$c.OwningProcess
        $pids += $procId
        $pname = '?'
        try { $pname = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $pname = '(exited)' }
        $proto = 'TCP'
        if ($null -eq $c.PSObject.Properties['State']) { $proto = 'UDP' }
        $state = ''
        if ($proto -eq 'TCP') { $state = [string]$c.State }
        [void]$sb.Append("  $proto $($c.LocalAddress):$($c.LocalPort) $state pid=$procId ($pname)`n")
    }
    if ($kill) {
        if (-not $confirm) { throw 'kill requires confirm:true (stops the owning process(es))' }
        $stopped = @()
        foreach ($p in ($pids | Select-Object -Unique)) {
            if ($p -le 4) { [void]$sb.Append("  skip pid=$p (system-owned)`n"); continue }
            try { Stop-Process -Id $p -Force -ErrorAction Stop; $stopped += $p } catch { [void]$sb.Append("  kill pid=$p failed: $($_.Exception.Message)`n") }
        }
        [void]$sb.Append('killed: ' + ($stopped -join ', '))
    }
    return $sb.ToString().TrimEnd()
}

# ---------- tool: http ----------
function Invoke-ToolHttp($toolArgs) {
    $url = Get-ArgString $toolArgs 'url'
    if ($url -notmatch '^https?://') { throw "url must start with http:// or https://" }
    $method = (Get-ArgString $toolArgs 'method').ToUpperInvariant()
    if ($method -eq '') { $method = 'GET' }
    $timeoutSec = Get-ArgInt $toolArgs 'timeout_sec' 15
    if ($timeoutSec -lt 2) { $timeoutSec = 2 }
    if ($timeoutSec -gt 25) { $timeoutSec = 25 }
    $maxChars = Get-ArgInt $toolArgs 'max_chars' 4000
    if ($maxChars -lt 300) { $maxChars = 300 }
    $body = Get-ArgString $toolArgs 'body'
    $insecure = Get-ArgBool $toolArgs 'insecure' $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $oldCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        if ($insecure) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = $method
        $req.Timeout = $timeoutSec * 1000
        $req.ReadWriteTimeout = $timeoutSec * 1000
        $req.UserAgent = 'zops-http/0.3'
        $headers = $toolArgs.PSObject.Properties['headers']
        if ($null -ne $headers -and $null -ne $headers.Value) {
            foreach ($p in $headers.Value.PSObject.Properties) {
                if ($p.Name -ieq 'content-type') { $req.ContentType = [string]$p.Value; continue }
                if ($p.Name -ieq 'accept') { $req.Accept = [string]$p.Value; continue }
                if ($p.Name -ieq 'user-agent') { $req.UserAgent = [string]$p.Value; continue }
                try { $req.Headers.Add($p.Name, [string]$p.Value) } catch {}
            }
        }
        if ($body -ne '' -and $method -ne 'GET' -and $method -ne 'HEAD') {
            $bBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $req.ContentLength = $bBytes.Length
            $rs = $req.GetRequestStream()
            $rs.Write($bBytes, 0, $bBytes.Length)
            $rs.Close()
        }
        $resp = $null
        $errMsg = ''
        try { $resp = $req.GetResponse() } catch [System.Net.WebException] { $resp = $_.Exception.Response; $errMsg = $_.Exception.Message }
        if ($null -eq $resp) {
            # $_ is out of scope here - the message must be captured inside catch
            return "[zops:http] $method $url`nERROR: $errMsg (elapsed $([Math]::Round($sw.Elapsed.TotalMilliseconds)) ms)"
        }
        $code = [int]$resp.StatusCode
        $hs = @()
        foreach ($k in $resp.Headers.AllKeys) { $hs += ("$k=$($resp.Headers[$k])") }
        $ms = New-Object System.IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        $bodyBytes = $ms.ToArray()
        $size = $bodyBytes.Length
        $bodyText = (Read-BytesTextSmart $bodyBytes).TrimEnd()
        $elapsed = [Math]::Round($sw.Elapsed.TotalMilliseconds)
        if ($bodyText.Length -gt $maxChars) { $bodyText = $bodyText.Substring(0, $maxChars) + " ...[truncated, full $size bytes]" }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("[zops:http] $method $url`nstatus: $code $($resp.StatusDescription) | ${elapsed}ms | $size bytes`n")
        foreach ($h in @($hs | Select-Object -First 10)) {
            if ($h.Length -gt 200) { $h = $h.Substring(0, 200) + '...' }
            [void]$sb.Append('  ' + $h + "`n")
        }
        [void]$sb.Append('body:' + "`n" + $bodyText)
        return $sb.ToString().TrimEnd()
    } finally {
        $sw.Stop()
        if ($insecure) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCb }
    }
}

# ---------- tool: stats ----------
function Invoke-ToolStats($toolArgs) {
    $dir = Join-Path (Get-ZopsDataDir) 'stats'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[zops:stats] ledger in $(Get-DisplayPath $dir)`n")
    if (-not [System.IO.Directory]::Exists($dir)) { [void]$sb.Append('(empty - no calls recorded yet)'); return $sb.ToString() }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 14)
    $byTool = @{}
    $byDay = @{}
    $totalCalls = 0; $totalChars = 0; $totalMs = 0
    foreach ($f in $files) {
        $day = $f.BaseName
        $dayCalls = 0; $dayChars = 0
        foreach ($ln in @((Read-FileTextSmart $f.FullName) -split "`n")) {
            if ($ln.Trim() -eq '') { continue }
            try { $r = ConvertFrom-Json $ln } catch { continue }
            $totalCalls++; $dayCalls++
            $ch = [long]$r.chars; $totalChars += $ch; $dayChars += $ch
            $totalMs += [long]$r.ms
            if (-not $byTool.ContainsKey($r.tool)) { $byTool[$r.tool] = @(0, 0) }
            $byTool[$r.tool][0]++; $byTool[$r.tool][1] += $ch
        }
        $byDay[$day] = @($dayCalls, $dayChars)
    }
    [void]$sb.Append("total: $totalCalls call(s), $totalChars chars out (~$([Math]::Round($totalChars/4)) tokens est), $([Math]::Round($totalMs/1000,1))s in tools`n")
    [void]$sb.Append('by tool:' + "`n")
    foreach ($k in ($byTool.Keys | Sort-Object { -$byTool[$_][1] })) {
        [void]$sb.Append('  ' + $k + ': ' + $byTool[$k][0] + ' calls, ' + $byTool[$k][1] + " chars`n")
    }
    $parts = @()
    foreach ($d in (@($byDay.Keys | Sort-Object) | Select-Object -Last 7)) { $parts += ($d + ': ' + $byDay[$d][0] + ' calls, ' + $byDay[$d][1] + ' chars') }
    [void]$sb.Append('by day: ' + ($parts -join ' | '))
    return $sb.ToString().TrimEnd()
}

# ---------- tool registry ----------
function Build-InputSchema {
    param([string[]]$Required, [hashtable]$Props)
    $orderedProps = [ordered]@{}
    foreach ($k in $Props.Keys) { $orderedProps[$k] = $Props[$k] }
    return [ordered]@{
        type       = 'object'
        properties = $orderedProps
        required   = $Required
    }
}

$script:Tools = @(
    @{
        name        = 'read'
        description = 'Read a text file with line numbers under a char budget. Supports paging via offset/limit and tail mode for logs. Use this instead of dumping whole files: grep first to locate, then read the relevant page. Handles UTF-8 (with or without BOM), UTF-16 and GB18030 files.'
        inputSchema = Build-InputSchema -Required @('path') -Props ([ordered]@{
                'path'         = [ordered]@{ type = 'string'; description = 'File path (absolute, or relative to the session cwd). ~ expands to home.' }
                'offset'       = [ordered]@{ type = 'number'; description = '1-based first line to show. Default 1.' }
                'limit'        = [ordered]@{ type = 'number'; description = 'Max lines to show. Default 400.' }
                'tail'         = [ordered]@{ type = 'number'; description = 'If > 0, show only the last N lines (overrides offset/limit). Good for logs.' }
                'max_chars'    = [ordered]@{ type = 'number'; description = 'Output char budget. Default 12000. When reached, stops at a line boundary and reports the next offset.' }
                'line_numbers' = [ordered]@{ type = 'boolean'; description = 'Prefix lines with line numbers. Default true.' }
            })
    },
    @{
        name        = 'grep'
        description = 'Regex search inside one file or a directory tree. Returns capped path:line:text matches, skipping binaries and files over 20MB; files whose first bytes look like a known binary signature (MZ/PK/PNG/RIFF/PDF/GIF/JPEG/gzip/7z/ELF) are always treated as binary. Secret-looking strings in matches are masked as [REDACTED:*] unless raw:true. Use to locate code before reading. plain=true for literal text search.'
        inputSchema = Build-InputSchema -Required @('pattern') -Props ([ordered]@{
                'pattern'     = [ordered]@{ type = 'string'; description = '.NET regular expression.' }
                'path'        = [ordered]@{ type = 'string'; description = 'File or directory to search. Default: session cwd.' }
                'include'     = [ordered]@{ type = 'string'; description = 'Filename glob filter for directory search, e.g. "*.ts" or "*.py".' }
                'ignore_case' = [ordered]@{ type = 'boolean'; description = 'Case-insensitive match. Default false.' }
                'max_results' = [ordered]@{ type = 'number'; description = 'Result cap. Default 100.' }
                'plain'       = [ordered]@{ type = 'boolean'; description = 'Treat pattern as literal text, not regex. Default false.' }
            })
    },
    @{
        name        = 'tree'
        description = 'List a directory tree with depth and entry caps. Skips node_modules/.git/dist/target/.venv/.zcode by default. Cheaper and safer than recursive shell dir listings.'
        inputSchema = Build-InputSchema -Required @() -Props ([ordered]@{
                'path'        = [ordered]@{ type = 'string'; description = 'Directory to list. Default: session cwd.' }
                'depth'       = [ordered]@{ type = 'number'; description = 'Max depth, 1-8. Default 2.' }
                'max_entries' = [ordered]@{ type = 'number'; description = 'Entry cap. Default 400.' }
                'include'     = [ordered]@{ type = 'string'; description = 'Filename glob filter, e.g. "*.md". Directories are always shown.' }
                'skip_dirs'   = [ordered]@{ type = 'string'; description = 'Comma-separated directory names to skip, or "none" to disable skipping.' }
                'show_hidden' = [ordered]@{ type = 'boolean'; description = 'Include hidden entries. Default false.' }
            })
    },
    @{
        name        = 'run'
        description = 'Run a command with a timeout and capped output (head+tail kept, middle omitted). shell=cmd by default (matches the session shell); shell=powershell, shell=pwsh (PowerShell 7, if installed) and shell=bash (Git Bash, if installed) run via temp scripts. smart:true compresses known command families rtk-style (tests -> failures only, git, installs; full output kept in a temp file). Dangerous commands (rm -rf, del /s, git reset --hard...) are refused unless confirm:true. Secrets (API keys, tokens, JWTs) are masked as [REDACTED:*] unless raw:true.'
        inputSchema = Build-InputSchema -Required @('command') -Props ([ordered]@{
                'command'     = [ordered]@{ type = 'string'; description = 'The command to run.' }
                'shell'       = [ordered]@{ type = 'string'; description = 'auto (cmd) | cmd | powershell | pwsh | bash. Default auto=cmd.' }
                'timeout_sec' = [ordered]@{ type = 'number'; description = 'Kill the process after N seconds, 1-600. Default 60.' }
                'max_chars'   = [ordered]@{ type = 'number'; description = 'Output char budget. Default 6000.' }
                'cwd'         = [ordered]@{ type = 'string'; description = 'Working directory. Default: session cwd.' }
                'smart'       = [ordered]@{ type = 'boolean'; description = 'Compress known command families rtk-style (tests -> failures only, git, installs, lint, build). Default false.' }
                'confirm'     = [ordered]@{ type = 'boolean'; description = 'Pass true to allow a dangerous command (rm -rf, del /s, git reset --hard...).' }
                'raw'         = [ordered]@{ type = 'boolean'; description = 'Skip secret masking on the output. Default false.' }
            })
    },
    @{
        name        = 'edit'
        description = 'Atomic find/replace edit with encoding preservation (UTF-8/BOM/UTF-16/GB18030). Throws without writing when 0 occurrences or when expected_count mismatches, so failed edits cost nothing. Returns applied count, byte/line delta and a short before/after preview. Replaces the read-whole-file-then-rewrite loop. Line endings are normalized to the dominant EOL style of the file (mixed-EOL files get rewritten consistently).'
        inputSchema = Build-InputSchema -Required @('path', 'find') -Props ([ordered]@{
                'path'           = [ordered]@{ type = 'string'; description = 'File to edit (absolute, or relative to the session cwd).' }
                'find'           = [ordered]@{ type = 'string'; description = 'Exact text to locate (copy it from read/grep output; multi-line ok). Max 20000 chars.' }
                'replace'        = [ordered]@{ type = 'string'; description = 'Replacement text (empty string deletes). Max 40000 chars.' }
                'expected_count' = [ordered]@{ type = 'number'; description = 'If > 0, abort without writing unless the file contains exactly this many occurrences. Guard against wrong-spot edits.' }
                'occurrence'     = [ordered]@{ type = 'string'; description = 'first | all (default all).' }
            })
    },
    @{
        name        = 'diff'
        description = 'Capped line diff between two files (or a file vs its backup) via git diff --no-index when git is available, coarse prefix/suffix fallback otherwise. Verify an edit without re-reading whole files.'
        inputSchema = Build-InputSchema -Required @('a', 'b') -Props ([ordered]@{
                'a'        = [ordered]@{ type = 'string'; description = 'First file path.' }
                'b'        = [ordered]@{ type = 'string'; description = 'Second file path.' }
                'context'  = [ordered]@{ type = 'number'; description = 'Context lines per change block, 0-10. Default 3.' }
                'max_chars' = [ordered]@{ type = 'number'; description = 'Output char budget. Default 6000.' }
            })
    },
    @{
        name        = 'outline'
        description = 'Code skeleton scan: definitions (def/class/function/interface/struct/fn/impl, markdown headers) with line numbers, for one file or a directory tree. Read the skeleton first, then read only the lines you need.'
        inputSchema = Build-InputSchema -Required @('path') -Props ([ordered]@{
                'path'        = [ordered]@{ type = 'string'; description = 'File or directory. Default: session cwd (directory scan).' }
                'max_entries' = [ordered]@{ type = 'number'; description = 'Definition cap, 10-2000. Default 300.' }
                'max_chars'   = [ordered]@{ type = 'number'; description = 'Output char budget. Default 6000.' }
            })
    },
    @{
        name        = 'status'
        description = 'One-call workspace snapshot: git branch/dirty/last commit, file totals, largest files, big logs (>1MB, use read tail on them), disk free. Replaces a pile of dir/du/git calls at task start.'
        inputSchema = Build-InputSchema -Required @() -Props ([ordered]@{
                'path'      = [ordered]@{ type = 'string'; description = 'Workspace root. Default: session cwd.' }
                'max_chars' = [ordered]@{ type = 'number'; description = 'Output char budget. Default 6000.' }
            })
    },
    @{
        name        = 'doctor'
        description = 'Environment health check: available shells (cmd/powershell/pwsh/bash with versions), python/git/node presence, disk free, temp writability, plus host-cap and encoding notes. OK/WARN/FAIL lines with hints.'
        inputSchema = Build-InputSchema -Required @() -Props ([ordered]@{})
    },
    @{
        name        = 'notes'
        description = 'Persistent per-workspace scratchpad (survives context compaction and sessions): stash key findings so later turns skip re-exploration. 50 notes max, value max 2000 chars.'
        inputSchema = Build-InputSchema -Required @() -Props ([ordered]@{
                'action' = [ordered]@{ type = 'string'; description = 'list (default) | set | get | delete | clear' }
                'key'    = [ordered]@{ type = 'string'; description = 'Note key (max 100 chars).' }
                'value'  = [ordered]@{ type = 'string'; description = 'Note value for set (max 2000 chars).' }
            })
    },
    @{
        name        = 'write'
        description = 'Create a new file (or overwrite with overwrite:true) with explicit encoding (utf8 default, utf8-bom/utf16/gb18030). Creates parent directories automatically. Complements edit, which only modifies existing files.'
        inputSchema = Build-InputSchema -Required @('path', 'content') -Props ([ordered]@{
                'path'      = [ordered]@{ type = 'string'; description = 'File to create. Parent dirs are created as needed.' }
                'content'   = [ordered]@{ type = 'string'; description = 'Full file content. Max 200000 chars.' }
                'overwrite' = [ordered]@{ type = 'boolean'; description = 'Allow replacing an existing file. Default false (error if exists).' }
                'encoding'  = [ordered]@{ type = 'string'; description = 'utf8 (default, no BOM) | utf8-bom | utf16 | gb18030.' }
            })
    },
    @{
        name        = 'replace'
        description = 'Multi-file regex find/replace. DRY-RUN by default (per-file match counts + samples); apply:true writes, expected_files guards the blast radius. Encoding-preserving like edit. Requires include glob when scanning a directory.'
        inputSchema = Build-InputSchema -Required @('path', 'pattern') -Props ([ordered]@{
                'path'           = [ordered]@{ type = 'string'; description = 'File or directory to scan (directory requires include).' }
                'pattern'        = [ordered]@{ type = 'string'; description = '.NET regular expression.' }
                'replace'        = [ordered]@{ type = 'string'; description = 'Replacement text (empty deletes matches).' }
                'include'        = [ordered]@{ type = 'string'; description = 'Filename glob filter, e.g. "*.ts". Required for directory scans.' }
                'apply'          = [ordered]@{ type = 'boolean'; description = 'Default false = dry-run listing matches. true writes the files.' }
                'expected_files' = [ordered]@{ type = 'number'; description = 'In apply mode, abort without writing unless exactly this many files match.' }
            })
    },
    @{
        name        = 'json'
        description = 'Validate/inspect a JSON file: structure summary with per-key types, or dot-path query (data.items[0].name) returning just that value. Capped output.'
        inputSchema = Build-InputSchema -Required @('path') -Props ([ordered]@{
                'path'      = [ordered]@{ type = 'string'; description = 'JSON file to inspect.' }
                'query'     = [ordered]@{ type = 'string'; description = 'Optional dot-path into the document, e.g. data.items[0].name.' }
                'max_chars' = [ordered]@{ type = 'number'; description = 'Output char budget. Default 6000.' }
            })
    },
    @{
        name        = 'port'
        description = 'Who is listening on a TCP/UDP port: connections with owning PID and process name. kill:true + confirm:true stops the owning processes (system PIDs skipped).'
        inputSchema = Build-InputSchema -Required @('port') -Props ([ordered]@{
                'port'    = [ordered]@{ type = 'number'; description = 'Port number 1-65535.' }
                'kill'    = [ordered]@{ type = 'boolean'; description = 'Stop the owning process(es).' }
                'confirm' = [ordered]@{ type = 'boolean'; description = 'Required true when kill:true.' }
            })
    },
    @{
        name        = 'http'
        description = 'Structured HTTP request from this machine (works for localhost, unlike WebFetch): status, duration, size, selected headers and capped body. Basic auth via headers; insecure:true skips TLS validation.'
        inputSchema = Build-InputSchema -Required @('url') -Props ([ordered]@{
                'url'         = [ordered]@{ type = 'string'; description = 'http:// or https:// URL.' }
                'method'      = [ordered]@{ type = 'string'; description = 'GET (default) | POST | PUT | DELETE | HEAD | PATCH.' }
                'headers'     = [ordered]@{ type = 'object'; description = 'Request headers, e.g. {"Authorization": "Bearer x"}.' }
                'body'        = [ordered]@{ type = 'string'; description = 'Request body (sent as UTF-8).' }
                'timeout_sec' = [ordered]@{ type = 'number'; description = '2-25s. Default 15.' }
                'max_chars'   = [ordered]@{ type = 'number'; description = 'Body char budget. Default 4000.' }
                'insecure'    = [ordered]@{ type = 'boolean'; description = 'Skip TLS certificate validation (for MITM proxies). Default false.' }
            })
    },
    @{
        name        = 'stats'
        description = 'Token-saving ledger: per-tool call counts and output chars (last 14 days), estimated tokens (~chars/4), per-day breakdown. Proves how much zops saves.'
        inputSchema = Build-InputSchema -Required @() -Props ([ordered]@{})
    }
)

function Get-ToolsJson {
    $arr = @()
    foreach ($t in $script:Tools) {
        $arr += [ordered]@{
            name        = $t.name
            description = $t.description
            inputSchema = $t.inputSchema
        }
    }
    return [ordered]@{ tools = $arr }
}

# ---------- dispatch ----------
function Send-Response([object]$id, [object]$result) {
    $body = ConvertTo-JsonText $result
    # ConvertTo-JsonText handles numbers, strings (quoted) and null - the spec
    # allows string ids, ConvertTo-JsonNumber would emit them unquoted (invalid JSON)
    $script:StdOut.WriteLine('{"jsonrpc":"2.0","id":' + (ConvertTo-JsonText $id) + ',"result":' + $body + '}')
}

function Send-Error([object]$id, [int]$code, [string]$message) {
    $body = [ordered]@{ code = $code; message = $message }
    $script:StdOut.WriteLine('{"jsonrpc":"2.0","id":' + (ConvertTo-JsonText $id) + ',"error":' + (ConvertTo-JsonText $body) + '}')
}

function Invoke-ToolCall([string]$toolName, $toolArgs) {
    switch ($toolName) {
        'read' { return (Invoke-ToolRead $toolArgs) }
        'grep' { return (Invoke-ToolGrep $toolArgs) }
        'tree' { return (Invoke-ToolTree $toolArgs) }
        'run' { return (Invoke-ToolRun $toolArgs) }
        'edit' { return (Invoke-ToolEdit $toolArgs) }
        'diff' { return (Invoke-ToolDiff $toolArgs) }
        'outline' { return (Invoke-ToolOutline $toolArgs) }
        'status' { return (Invoke-ToolStatus $toolArgs) }
        'doctor' { return (Invoke-ToolDoctor $toolArgs) }
        'notes' { return (Invoke-ToolNotes $toolArgs) }
        'write' { return (Invoke-ToolWrite $toolArgs) }
        'replace' { return (Invoke-ToolReplace $toolArgs) }
        'json' { return (Invoke-ToolJson $toolArgs) }
        'port' { return (Invoke-ToolPort $toolArgs) }
        'http' { return (Invoke-ToolHttp $toolArgs) }
        'stats' { return (Invoke-ToolStats $toolArgs) }
        default { throw "unknown tool: $toolName" }
    }
}

[Console]::Error.WriteLine("[zops] MCP server ready (pid $PID, version $($script:ServerVersion))")

# age out stale smart-filter full-output logs (24h lifecycle; masked, but not kept forever)
try {
    Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'zops-smart-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-24) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}

# Make our stdio handles non-inheritable: when a `run` child is killed, orphaned
# grandchildren would otherwise hold the MCP transport file open and block the host.
try {
    if (-not ('ZopsNative' -as [type])) {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class ZopsNative { [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle); [DllImport("kernel32.dll")] public static extern bool SetHandleInformation(IntPtr hObject, int dwMask, int dwFlags); }'
    }
    foreach ($h in @(-11, -10, -12)) { [void][ZopsNative]::SetHandleInformation([ZopsNative]::GetStdHandle($h), 1, 0) }  # clear HANDLE_FLAG_INHERIT
} catch {}

while ($true) {
    $line = $script:StdIn.ReadLine()
    if ($null -eq $line) { break }
    if ($line.Trim() -eq '') { continue }

    $msg = $null
    try { $msg = ConvertFrom-Json $line } catch {
        # JSON-RPC: unparseable request must still get a parse error reply
        $script:StdOut.WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}')
        continue
    }
    # P3-5 (round7): a JSON-RPC batch array got no reply at all (its id lookup
    # failed and it fell through the notification path). MCP never sends batches -
    # answer with the spec's invalid-request error instead of silence.
    if ($msg -is [System.Array]) {
        $script:StdOut.WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request: batch arrays are not supported"}}')
        continue
    }

    $hasId = $false
    $id = 0
    try {
        $idProp = $msg.PSObject.Properties['id']
        if ($idProp -and $null -ne $idProp.Value) { $id = $idProp.Value; $hasId = $true }
    } catch {}
    $method = ''
    try { $method = [string]$msg.method } catch {}

    if (-not $hasId) { continue }

    switch ($method) {
        'initialize' {
            $proto = $script:DefaultProtocol
            try {
                $pv = $msg.params.PSObject.Properties['protocolVersion']
                if ($pv -and $pv.Value) { $proto = [string]$pv.Value }
            } catch {}
            $result = [ordered]@{
                protocolVersion = $proto
                capabilities    = [ordered]@{ tools = [ordered]@{} }
                serverInfo      = [ordered]@{ name = $script:ServerName; version = $script:ServerVersion }
            }
            Send-Response $id $result
        }
        'ping' {
            Send-Response $id ([ordered]@{})
        }
        'tools/list' {
            Send-Response $id (Get-ToolsJson)
        }
        'tools/call' {
            $toolName = ''
            $toolArgs = $null
            try {
                $toolName = [string]$msg.params.name
                $aProp = $msg.params.PSObject.Properties['arguments']
                if ($aProp) { $toolArgs = $aProp.Value }
            } catch {}
            if ($null -eq $toolArgs) { $toolArgs = New-Object psobject }
            try {
                $t0 = [System.Diagnostics.Stopwatch]::StartNew()
                $text = Invoke-ToolCall $toolName $toolArgs
                $t0.Stop()
                Write-ZopsLedger $toolName ([string]$text).Length $t0.Elapsed.TotalMilliseconds
                $result = [ordered]@{
                    content = @([ordered]@{ type = 'text'; text = [string]$text })
                    isError = $false
                }
                Send-Response $id $result
            } catch {
                $result = [ordered]@{
                    content = @([ordered]@{ type = 'text'; text = ('ERROR: ' + $_.Exception.Message) })
                    isError = $true
                }
                Send-Response $id $result
            }
        }
        default {
            Send-Error $id -32601 "method not found: $method"
        }
    }
}
exit 0
