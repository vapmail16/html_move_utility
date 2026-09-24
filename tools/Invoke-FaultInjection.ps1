<#
.SYNOPSIS
Applies one deliberate fault to a copied TARGET tree so tests can prove Reconcile detects it.

.DESCRIPTION
Test tool for NotificationMigration (spec test plan: "corrupt a target file, delete one, add an extra").
It only ever touches files under -TargetRoot. If -SourceRoot is given and the two roots are the same or one
contains the other, the script refuses to run. Windows PowerShell 5.1 compatible; also runs on PowerShell 7.

Faults (expected Reconcile category in brackets):
  Corrupt     flips one byte in place; size and timestamps are preserved     [hash_mismatch]
  Delete      deletes the file                                                [missing]
  Extra       creates a new file that does not exist on the source            [extra]
  Timestamp   shifts LastWriteTimeUtc by -ShiftSeconds (content untouched)    [metadata_mismatch]
  Attributes  toggles the ReadOnly attribute (content/timestamps untouched)   [metadata_mismatch]

Without -RelPath a file is picked deterministically from -Seed (ordinal sort of canonical rel paths).
Zero-byte files are never picked for Corrupt.

.EXAMPLE
./tools/Invoke-FaultInjection.ps1 -TargetRoot ./.dev/target -SourceRoot ./.dev/source -Fault Corrupt -Seed 3
./tools/Invoke-FaultInjection.ps1 -TargetRoot ./.dev/target -Fault Delete -RelPath '2019\01\05\notification_20190105_00003.html'

.OUTPUTS
PSCustomObject: Fault, RelPath (canonical, '\'-separated), FullPath, ExpectedCategory, Before, After, Detail.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string] $TargetRoot,
    [Parameter(Mandatory = $true)][ValidateSet('Corrupt', 'Delete', 'Extra', 'Timestamp', 'Attributes')][string] $Fault,
    [string] $RelPath,
    [string] $SourceRoot,
    [int] $Seed = 1,
    [string] $Filter = '*',
    [int] $ShiftSeconds = 3600
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$isWin = $false
if ($PSVersionTable.PSEdition -eq 'Desktop') { $isWin = $true } else { $isWin = [bool]$IsWindows }
$sep = [System.IO.Path]::DirectorySeparatorChar

function Get-NormalRoot([string] $P) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($P)
    if ($full.StartsWith('\\?\UNC\')) { $full = '\\' + $full.Substring(8) }
    elseif ($full.StartsWith('\\?\')) { $full = $full.Substring(4) }
    if ($isWin) { $full = $full.Replace('/', '\') }
    return $full.TrimEnd('\', '/')
}

function Test-Under([string] $Path, [string] $Root) {
    # Case-insensitive on purpose: stricter (refuses more) on case-sensitive file systems.
    $p = $Path.TrimEnd('\', '/') + $sep
    $r = $Root.TrimEnd('\', '/') + $sep
    return $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

function Get-LongPath([string] $Full) {
    if (-not $isWin) { return $Full }
    if ($Full.StartsWith('\\?\')) { return $Full }
    if ($Full.StartsWith('\\')) { return '\\?\UNC\' + $Full.Substring(2) }
    return '\\?\' + $Full
}

$target = Get-NormalRoot $TargetRoot
if (-not [System.IO.Directory]::Exists((Get-LongPath $target))) { throw "TargetRoot '$target' does not exist." }

if ($SourceRoot) {
    $source = Get-NormalRoot $SourceRoot
    if ((Test-Under $target $source) -or (Test-Under $source $target)) {
        throw "SAFETY: refusing to inject faults: TargetRoot '$target' and SourceRoot '$source' are the same or nested."
    }
}

function Get-FullFromRel([string] $Rel) {
    $canon = $Rel.Replace('/', '\').TrimStart('\')
    foreach ($seg in $canon.Split('\')) {
        if ($seg -eq '..' -or $seg -eq '.') { throw "RelPath '$Rel' must not contain '.' or '..' segments." }
    }
    $full = $target + $sep + $canon.Replace('\', [string]$sep)
    if (-not (Test-Under $full $target)) { throw "RelPath '$Rel' resolves outside TargetRoot." }
    return @{ rel = $canon; full = $full }
}

function Get-CandidateFiles([bool] $NonEmptyOnly) {
    $lp = Get-LongPath $target
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($f in [System.IO.Directory]::EnumerateFiles($lp, $Filter, [System.IO.SearchOption]::AllDirectories)) {
        if ($NonEmptyOnly -and (New-Object System.IO.FileInfo($f)).Length -eq 0) { continue }
        $rel = $f.Substring($lp.Length).TrimStart('\', '/').Replace('/', '\')
        $list.Add($rel)
    }
    $arr = $list.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return , $arr
}

function Get-FileState([string] $Full) {
    $lp = Get-LongPath $Full
    if (-not [System.IO.File]::Exists($lp)) { return $null }
    $fi = New-Object System.IO.FileInfo($lp)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($lp)
    try { $h = ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '') } finally { $fs.Dispose(); $sha.Dispose() }
    return [pscustomobject]@{ size = $fi.Length; modified_utc = $fi.LastWriteTimeUtc.ToString('o'); attributes = $fi.Attributes.ToString(); sha256 = $h }
}

$rng = New-Object System.Random($Seed)
$expected = @{ Corrupt = 'hash_mismatch'; Delete = 'missing'; Extra = 'extra'; Timestamp = 'metadata_mismatch'; Attributes = 'metadata_mismatch' }[$Fault]

# ---------------------------------------------------------------- choose the file
if ($Fault -eq 'Extra') {
    if ($RelPath) { $pick = Get-FullFromRel $RelPath }
    else {
        $files = Get-CandidateFiles $false
        $dirRel = ''
        if ($files.Length -gt 0) {
            $one = $files[$rng.Next(0, $files.Length)]
            $i = $one.LastIndexOf('\')
            if ($i -gt 0) { $dirRel = $one.Substring(0, $i) }
        }
        $name = 'fault_extra_{0}.html' -f $Seed
        if ($dirRel) { $pick = Get-FullFromRel ($dirRel + '\' + $name) } else { $pick = Get-FullFromRel $name }
    }
    if ([System.IO.File]::Exists((Get-LongPath $pick.full))) { throw "Extra: '$($pick.rel)' already exists on the target." }
} else {
    if ($RelPath) { $pick = Get-FullFromRel $RelPath }
    else {
        $files = Get-CandidateFiles ($Fault -eq 'Corrupt')
        if ($files.Length -eq 0) { throw "No candidate files under '$target' for fault '$Fault'." }
        $pick = Get-FullFromRel $files[$rng.Next(0, $files.Length)]
    }
    if (-not [System.IO.File]::Exists((Get-LongPath $pick.full))) { throw "$Fault`: '$($pick.rel)' does not exist on the target." }
}

$lp = Get-LongPath $pick.full
$before = Get-FileState $pick.full
$detail = $null

if (-not $PSCmdlet.ShouldProcess($pick.full, "Inject fault '$Fault'")) { return }

# ---------------------------------------------------------------- apply
switch ($Fault) {
    'Corrupt' {
        $fi = New-Object System.IO.FileInfo($lp)
        if ($fi.Length -eq 0) { throw "Corrupt: '$($pick.rel)' is zero bytes; nothing to flip (use -Fault Extra/Delete or another file)." }
        $wasReadOnly = $fi.IsReadOnly
        if ($wasReadOnly) { $fi.IsReadOnly = $false }
        $created = $fi.CreationTimeUtc; $modified = $fi.LastWriteTimeUtc
        $offset = [long]$rng.Next(0, [int][Math]::Min([long][int]::MaxValue, $fi.Length))
        $fs = New-Object System.IO.FileStream($lp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
        try {
            [void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
            $b = $fs.ReadByte()
            [void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
            $fs.WriteByte([byte](($b -bxor 0xFF) -band 0xFF))
        } finally { $fs.Dispose() }
        try { [System.IO.File]::SetCreationTimeUtc($lp, $created) } catch { }
        [System.IO.File]::SetLastWriteTimeUtc($lp, $modified)
        if ($wasReadOnly) { (New-Object System.IO.FileInfo($lp)).IsReadOnly = $true }
        $detail = "flipped byte at offset $offset"
    }
    'Delete' {
        $fi = New-Object System.IO.FileInfo($lp)
        if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
        [System.IO.File]::Delete($lp)
        $detail = 'deleted'
    }
    'Extra' {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($lp))
        $text = "<!DOCTYPE html>`r`n<html><head><title>fault extra</title></head><body><p>Injected extra file, seed $Seed</p></body></html>`r`n"
        [System.IO.File]::WriteAllBytes($lp, (New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
        $detail = 'created'
    }
    'Timestamp' {
        $fi = New-Object System.IO.FileInfo($lp)
        $wasReadOnly = $fi.IsReadOnly
        if ($wasReadOnly) { $fi.IsReadOnly = $false }
        [System.IO.File]::SetLastWriteTimeUtc($lp, $fi.LastWriteTimeUtc.AddSeconds($ShiftSeconds))
        if ($wasReadOnly) { (New-Object System.IO.FileInfo($lp)).IsReadOnly = $true }
        $detail = "LastWriteTimeUtc shifted by $ShiftSeconds s"
    }
    'Attributes' {
        $fi = New-Object System.IO.FileInfo($lp)
        $modified = $fi.LastWriteTimeUtc
        $fi.IsReadOnly = -not $fi.IsReadOnly
        $detail = 'ReadOnly toggled to ' + (New-Object System.IO.FileInfo($lp)).IsReadOnly
        try { if (-not (New-Object System.IO.FileInfo($lp)).IsReadOnly) { [System.IO.File]::SetLastWriteTimeUtc($lp, $modified) } } catch { }
    }
}

[pscustomobject]@{
    Fault            = $Fault
    RelPath          = $pick.rel
    FullPath         = $pick.full
    ExpectedCategory = $expected
    Before           = $before
    After            = Get-FileState $pick.full
    Detail           = $detail
}
