# Append-only, hash-chained audit log (controls C-07 and C-08 evidence).
# One JSONL file per run: <logDir>/run-<utc>-<runId>.jsonl
# Every line carries prev_hash and hash = H(prev_hash + body), so any edit, deletion or reorder
# breaks the chain and is detected by Test-MigAuditChain. On close, a .sha256 sidecar is written.

function New-MigAuditLog {
    <#
    Creates the run's log. A <log>.lock file is held open exclusively for the life of the run, so
    Invoke-MigAuditSealOrphans can tell a live run from one that was killed (lock file present but openable).
    #>
    param([Parameter(Mandatory = $true)][string] $LogDir, [Parameter(Mandatory = $true)][string] $RunId,
          [string] $Algorithm = 'SHA256', [bool] $HashChain = $true)
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $name = 'run-{0}-{1}.jsonl' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), $RunId
    $path = Join-Path $LogDir $name
    $lock = [System.IO.File]::Open($path + '.lock', [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    return [pscustomobject]@{
        Path      = $path
        RunId     = $RunId
        Algorithm = $Algorithm
        HashChain = $HashChain
        Seq       = 0
        PrevHash  = ('0' * 64)
        Closed    = $false
        Lock      = $lock
        LastRef   = $null     # @{ log; seq; hash } of the most recent line, for cross-referencing from the store
    }
}

function Write-MigAudit {
    param([Parameter(Mandatory = $true)] $Audit, [Parameter(Mandatory = $true)][string] $Event,
          [System.Collections.IDictionary] $Data, [ValidateSet('info', 'warn', 'error')][string] $Level = 'info', [string] $Operator)
    if ($Audit.Closed) { throw 'Audit log is closed.' }
    $Audit.Seq++
    if (-not $Operator) { $Operator = Get-MigOperator }
    $rec = [ordered]@{
        seq = $Audit.Seq; ts_utc = Get-MigUtcNow; run_id = $Audit.RunId; level = $Level
        operator = $Operator; host = [Environment]::MachineName; event = $Event; data = $Data
        prev_hash = $Audit.PrevHash
    }
    $body = ConvertTo-MigJsonLine $rec
    $line = $body
    if ($Audit.HashChain) {
        $hash = Get-MigStringHash -Text ($Audit.PrevHash + $body) -Algorithm $Audit.Algorithm
        $line = $body.Substring(0, $body.Length - 1) + ',"hash":"' + $hash + '"}'
        $Audit.PrevHash = $hash
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line + "`n")
    $fs = [System.IO.File]::Open($Audit.Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    $Audit.LastRef = [ordered]@{ log = [System.IO.Path]::GetFileName($Audit.Path); seq = $Audit.Seq; hash = $Audit.PrevHash }
    if ($Level -eq 'error') { Write-Warning "[$Event] $(ConvertTo-MigJsonLine $Data)" }
    else { Write-Verbose "[$Event] $(ConvertTo-MigJsonLine $Data)" }
}

function Close-MigAuditLog {
    <# Writes <log>.sha256 so the finished file can be checksummed independently of the chain. #>
    param([Parameter(Mandatory = $true)] $Audit)
    if ($Audit.Closed) { return }
    Write-MigAudit -Audit $Audit -Event 'audit.closed' -Data @{ lines = $Audit.Seq + 1 }
    $Audit.Closed = $true
    Write-MigAuditSidecar -Path $Audit.Path -Algorithm $Audit.Algorithm
    if ($Audit.Lock) { $Audit.Lock.Dispose(); Remove-Item -LiteralPath ($Audit.Path + '.lock') -Force -ErrorAction SilentlyContinue }
}

function Write-MigAuditSidecar {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Algorithm)
    $h = Get-MigFileHash -Path $Path -Algorithm $Algorithm
    [System.IO.File]::WriteAllText($Path + '.' + $Algorithm.ToLowerInvariant(), ('{0}  {1}' -f $h, [System.IO.Path]::GetFileName($Path)) + "`n")
}

function Invoke-MigAuditSealOrphans {
    <#
    Seals logs left unclosed by a killed run: verifies the chain, appends an 'audit.sealed_after_interruption'
    line that continues the chain, writes the checksum sidecar, and records the action in the current run's log.
    Logs whose .lock is still held by a live process are left alone.
    #>
    param([Parameter(Mandatory = $true)] $Audit, [string] $Operator)
    $dir = [System.IO.Path]::GetDirectoryName($Audit.Path)
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'run-*.jsonl' -File)) {
        if ($f.FullName -eq $Audit.Path) { continue }
        $hasSidecar = @('sha256', 'sha384', 'sha512' | Where-Object { Test-Path -LiteralPath ($f.FullName + '.' + $_) }).Count -gt 0
        if ($hasSidecar) { continue }
        $lockPath = $f.FullName + '.lock'
        if (Test-Path -LiteralPath $lockPath) {
            try { $probe = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None); $probe.Dispose() }
            catch { continue }   # still held by a running process
        }
        $check = Test-MigAuditChain -Path $f.FullName -Algorithm $Audit.Algorithm
        $lines = @([System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $prev = ('0' * 64); $seq = 0
        if ($lines.Count -gt 0) {
            $m = [regex]::Match($lines[-1], ',"hash":"([0-9A-Fa-f]+)"\}$'); if ($m.Success) { $prev = $m.Groups[1].Value }
            $s = [regex]::Match($lines[-1], '^\{"seq":(\d+)'); if ($s.Success) { $seq = [int]$s.Groups[1].Value }
        }
        $orphan = [pscustomobject]@{ Path = $f.FullName; RunId = 'sealer:' + $Audit.RunId; Algorithm = $Audit.Algorithm; HashChain = [bool]$check.chained
                                     Seq = $seq; PrevHash = $prev; Closed = $false; Lock = $null; LastRef = $null }
        Write-MigAudit -Audit $orphan -Operator $Operator -Level warn -Event 'audit.sealed_after_interruption' -Data ([ordered]@{
            sealed_by_run = $Audit.RunId; chain_valid_before_seal = [bool]$check.valid; chain_error = $check.error; lines_before_seal = $lines.Count })
        Write-MigAuditSidecar -Path $f.FullName -Algorithm $Audit.Algorithm
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        Write-MigAudit -Audit $Audit -Operator $Operator -Level warn -Event 'audit.orphan_sealed' -Data ([ordered]@{
            log = $f.Name; chain_valid_before_seal = [bool]$check.valid; chain_error = $check.error; lines_before_seal = $lines.Count })
    }
}

function Test-MigAuditReference {
    <#
    True when <logDir>/<Ref.log> has a chain-valid line number Ref.seq with hash Ref.hash and the given event.
    Used to prove a store record (gate decision, stage completion) was also written to the tamper-evident log.
    #>
    param([Parameter(Mandatory = $true)][string] $LogDir, $Ref, [Parameter(Mandatory = $true)][string] $Event)
    if ($null -eq $Ref -or -not $Ref['log'] -or -not $Ref['seq']) { return $false }
    $path = Join-Path $LogDir ([System.IO.Path]::GetFileName([string]$Ref['log']))
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $prev = ('0' * 64); $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $n++
        $m = [regex]::Match($line, ',"hash":"([0-9A-Fa-f]+)"\}$')
        if (-not $m.Success) { return $false }
        $body = $line.Substring(0, $m.Index) + '}'
        if ((Get-MigStringHash -Text ($prev + $body) -Algorithm (Get-MigAuditAlgorithmFor $path)) -ne $m.Groups[1].Value) { return $false }
        if ($n -eq [int]$Ref['seq']) {
            return ($m.Groups[1].Value -eq [string]$Ref['hash'] -and $body -match ('"event":"' + [regex]::Escape($Event) + '"'))
        }
        $prev = $m.Groups[1].Value
    }
    return $false
}

function Get-MigAuditAlgorithmFor {
    param([Parameter(Mandatory = $true)][string] $Path)
    foreach ($a in @('sha384', 'sha512')) { if (Test-Path -LiteralPath ($Path + '.' + $a)) { return $a.ToUpperInvariant() } }
    $hex = [regex]::Match(([System.IO.File]::ReadAllLines($Path) | Select-Object -First 1), ',"hash":"([0-9A-Fa-f]+)"\}$').Groups[1].Value.Length
    switch ($hex) { 96 { return 'SHA384' } 128 { return 'SHA512' } default { return 'SHA256' } }
}

function Test-MigAuditChain {
    <#
    Verifies the hash chain (and sidecar checksum if present). Returns @{ valid; chained; lines; error }.
    The algorithm is taken from the sidecar extension (<log>.sha384 etc.) unless given. A log written with
    audit.hashChain = false has no per-line hashes; only its sidecar checksum is verified (chained = false).
    #>
    param([Parameter(Mandatory = $true)][string] $Path, [string] $Algorithm)
    $side = $null
    foreach ($alg in @('sha256', 'sha384', 'sha512')) {
        if ((-not $Algorithm -or $Algorithm -eq $alg) -and (Test-Path -LiteralPath ($Path + '.' + $alg))) { $side = $Path + '.' + $alg; $Algorithm = $alg; break }
    }
    if (-not $Algorithm) { $Algorithm = 'SHA256' }
    $lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $chained = ($lines.Count -gt 0 -and $lines[0] -match ',"hash":"[0-9A-Fa-f]+"\}$')
    $prev = ('0' * 64)
    $n = 0
    foreach ($line in $lines) {
        if (-not $chained) { $n = $lines.Count; break }
        $n++
        $m = [regex]::Match($line, ',"hash":"([0-9A-Fa-f]+)"\}$')
        if (-not $m.Success) { return @{ valid = $false; chained = $true; lines = $n; error = "line ${n}: no hash" } }
        $body = $line.Substring(0, $m.Index) + '}'
        if ($body -notmatch ('"prev_hash":"' + $prev + '"')) { return @{ valid = $false; chained = $true; lines = $n; error = "line ${n}: prev_hash does not link to previous line" } }
        $expected = Get-MigStringHash -Text ($prev + $body) -Algorithm $Algorithm
        if ($expected -ne $m.Groups[1].Value) { return @{ valid = $false; chained = $true; lines = $n; error = "line ${n}: hash mismatch (line altered)" } }
        $prev = $expected
    }
    if ($side) {
        $want = ([System.IO.File]::ReadAllText($side).Trim() -split '\s+')[0]
        if ($want -ne (Get-MigFileHash -Path $Path -Algorithm $Algorithm)) { return @{ valid = $false; chained = $chained; lines = $n; error = 'file checksum does not match sidecar' } }
    } elseif (-not $chained) {
        return @{ valid = $false; chained = $false; lines = $n; error = 'log has no hash chain and no checksum sidecar (not closed?)' }
    }
    return @{ valid = $true; chained = $chained; lines = $n; error = $null }
}
