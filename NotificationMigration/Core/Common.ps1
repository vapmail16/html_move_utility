# Shared helpers. Must stay compatible with Windows PowerShell 5.1 (no ternary, no ??, no -AsHashtable).

function ConvertTo-MigHashtable {
    <# Recursively converts PSCustomObject (from ConvertFrom-Json) into ordered hashtables / arrays. #>
    param([Parameter(ValueFromPipeline = $true)] $InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $h = [ordered]@{}
            foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-MigHashtable $InputObject[$k] }
            return $h
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $h = [ordered]@{}
            foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-MigHashtable $p.Value }
            return $h
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $list = @()
            foreach ($i in $InputObject) { $list += , (ConvertTo-MigHashtable $i) }
            return , $list
        }
        return $InputObject
    }
}

function ConvertFrom-MigJson {
    param([Parameter(Mandatory = $true)][string] $Json)
    return ConvertTo-MigHashtable (ConvertFrom-Json -InputObject $Json)
}

function ConvertTo-MigJsonLine {
    <# Single-line JSON for JSONL files. #>
    param([Parameter(Mandatory = $true)] $InputObject)
    return (ConvertTo-Json -InputObject $InputObject -Compress -Depth 20)
}

function Merge-MigHashtable {
    <# Deep-merges $Override into a copy of $Base. Arrays and scalars in $Override replace; dictionaries merge. #>
    param([System.Collections.IDictionary] $Base, [System.Collections.IDictionary] $Override)
    $result = [ordered]@{}
    if ($Base) { foreach ($k in $Base.Keys) { $result[$k] = $Base[$k] } }
    if ($Override) {
        foreach ($k in $Override.Keys) {
            $o = $Override[$k]
            if ($result.Contains($k) -and $result[$k] -is [System.Collections.IDictionary] -and $o -is [System.Collections.IDictionary]) {
                $result[$k] = Merge-MigHashtable -Base $result[$k] -Override $o
            } else {
                $result[$k] = $o
            }
        }
    }
    return $result
}

function Get-MigUtcNow {
    return [DateTime]::UtcNow.ToString('o')
}

function Get-MigStringHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text, [string] $Algorithm = 'SHA256')
    $alg = New-MigHashAlgorithm -Algorithm $Algorithm
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($alg.ComputeHash($bytes))).Replace('-', '')
    } finally { $alg.Dispose() }
}

function New-MigHashAlgorithm {
    param([Parameter(Mandatory = $true)][string] $Algorithm)
    switch ($Algorithm.ToUpperInvariant()) {
        'SHA256' { return [System.Security.Cryptography.SHA256]::Create() }
        'SHA384' { return [System.Security.Cryptography.SHA384]::Create() }
        'SHA512' { return [System.Security.Cryptography.SHA512]::Create() }
        default  { throw "Unsupported hash algorithm '$Algorithm'. Allowed: SHA256, SHA384, SHA512." }
    }
}

function Get-MigFileHash {
    <# Hashes a file on disk (used for manifests of our own outputs, e.g. log checksums). #>
    param([Parameter(Mandatory = $true)][string] $Path, [string] $Algorithm = 'SHA256')
    $alg = New-MigHashAlgorithm -Algorithm $Algorithm
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { return ([BitConverter]::ToString($alg.ComputeHash($fs))).Replace('-', '') }
    finally { $fs.Dispose(); $alg.Dispose() }
}

function Get-MigOperator {
    <# Identity of the person running the command (maker or checker). #>
    # On Windows use the token identity (environment variables can be changed by the user, which would
    # defeat maker-checker). Elsewhere (dev/test only) fall back to the environment.
    if (Test-MigIsWindows) { return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
    if ($env:USERDOMAIN) { return ('{0}\{1}' -f $env:USERDOMAIN, [Environment]::UserName) }
    return [Environment]::UserName
}

function Test-MigIsWindows {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool]$IsWindows
}

function Get-MigValue {
    <# StrictMode-safe read of an optional key from a dictionary (config sections, records). #>
    param($Dictionary, [Parameter(Mandatory = $true)][string] $Key, $Default = $null)
    if ($null -eq $Dictionary -or $Dictionary -isnot [System.Collections.IDictionary]) { return $Default }
    if (([System.Collections.IDictionary]$Dictionary).Contains($Key) -and $null -ne $Dictionary[$Key]) { return $Dictionary[$Key] }
    return $Default
}
