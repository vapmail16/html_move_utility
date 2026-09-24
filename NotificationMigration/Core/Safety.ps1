# Path handling and safety guards (control C-02: source is never modified).
# rel_path values are canonical: always '\'-separated, no leading separator, regardless of OS.

function ConvertTo-MigCanonicalRelPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $RelPath)
    return $RelPath.Replace('/', '\').TrimStart('\')
}

function ConvertTo-MigNativePath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Path)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($sep -eq '\') { return $Path.Replace('/', '\') }
    return $Path.Replace('\', '/')
}

function Join-MigPath {
    <# Joins a root and a canonical rel_path into a native full path. #>
    param([Parameter(Mandatory = $true)][string] $Root, [AllowEmptyString()][string] $RelPath)
    $r = (ConvertTo-MigNativePath $Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrEmpty($RelPath)) { return $r }
    return $r + [System.IO.Path]::DirectorySeparatorChar + (ConvertTo-MigNativePath $RelPath)
}

function Get-MigRelativePath {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $FullPath)
    $r = Remove-MigLongPathPrefix (ConvertTo-MigNativePath $Root)
    $f = Remove-MigLongPathPrefix (ConvertTo-MigNativePath $FullPath)
    $r = $r.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if (-not $f.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$FullPath' is not under root '$Root'."
    }
    return ConvertTo-MigCanonicalRelPath ($f.Substring($r.Length))
}

function Get-MigLongPath {
    <# Adds the \\?\ prefix on Windows so paths over 260 chars work. No-op elsewhere or when disabled. #>
    param([Parameter(Mandatory = $true)][string] $Path, [bool] $Enabled = $true)
    if (-not $Enabled -or -not (Test-MigIsWindows)) { return $Path }
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function Remove-MigLongPathPrefix {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Path)
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Test-MigPathUnder {
    <#
    True when $Path equals or is inside $Root (case-insensitive, separator-normalised, '..' collapsed,
    relative paths resolved against the PowerShell location). It cannot detect the same share reached
    under two names (e.g. \\SRV vs \\SRV.fqdn or a mapped drive) - use one canonical name in config.
    #>
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $p = (Get-MigNormalizedFullPath $Path).TrimEnd($sep) + $sep
    $r = (Get-MigNormalizedFullPath $Root).TrimEnd($sep) + $sep
    return $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

function Get-MigNormalizedFullPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $native = Remove-MigLongPathPrefix (ConvertTo-MigNativePath $Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($native)
    return [System.IO.Path]::GetFullPath($full)
}

function Assert-MigPathNotUnderSource {
    <# Every write (store, logs, reports, copy target) must go through this guard. #>
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $SourceRoot)
    if (Test-MigPathUnder -Path $Path -Root $SourceRoot) {
        throw "SAFETY: refusing to write to '$Path' because it is under sourceRoot '$SourceRoot'."
    }
}

# Flags that can move/delete data, load options from an unchecked file, or break per-batch isolation.
# Config can add to this list but never remove from it.
$script:MigAlwaysForbiddenFlags = @('/MOV', '/MOVE', '/MIR', '/PURGE', '/JOB', '/SAVE', '/S', '/E', '/LEV', '/XX', '/SECFIX', '/CREATE', '/A+', '/A-', '/IA', '/FFT')

function Assert-MigCopyFlagsSafe {
    <#
    Rejects any argument that is a forbidden flag (built-in floor + config), and any flag argument containing
    whitespace (e.g. "/E /PURGE" in one config entry). Non-flag arguments (paths, file names) are ignored.
    #>
    param([string[]] $Flags, [string[]] $ForbiddenFlags)
    $forbidden = @(@($ForbiddenFlags) + $script:MigAlwaysForbiddenFlags | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Select-Object -Unique)
    foreach ($raw in $Flags) {
        if ($null -eq $raw) { continue }
        $flag = $raw.Trim()
        if (-not $flag.StartsWith('/')) { continue }
        if ($flag -match '\s') { throw "SAFETY: copy flag '$raw' contains whitespace; give each flag as its own entry." }
        $upper = $flag.ToUpperInvariant()
        $name = ($upper -split ':')[0]
        if ($forbidden -contains $upper -or $forbidden -contains $name) { throw "SAFETY: copy flag '$raw' is forbidden." }
    }
}

function Assert-MigCopyFlagsAllowed {
    <# Allow-list for the flags an operator configures (copy.robocopy.flags). Tool-managed flags are added later. #>
    param([string[]] $Flags, [string[]] $AllowedFlags)
    $allowed = @($AllowedFlags | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpperInvariant() })
    foreach ($raw in $Flags) {
        $flag = ([string]$raw).Trim()
        if (-not $flag.StartsWith('/')) { throw "copy.robocopy.flags: '$raw' is not a flag." }
        $name = ($flag.ToUpperInvariant() -split ':')[0]
        if ($allowed -notcontains $name) { throw "copy.robocopy.flags: '$raw' is not in copy.robocopy.allowedFlags ($($allowed -join ' '))." }
    }
}
