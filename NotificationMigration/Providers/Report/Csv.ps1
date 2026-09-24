# Report provider 'csv': one CSV per table (<base>.<table>.csv, or the table's csv_name), UTF-8 with BOM (opens
# correctly in Excel). Rows are streamed to disk with a StreamWriter; CSV files are never capped (full detail).
# Always writes summary, issues, exceptions and html_findings when the report has them (headers even when empty);
# other tables when non-empty. Tables marked external_csv are written by the stage itself (e.g. evidence.manifest.csv).
# Cells that would be read as a spreadsheet formula (= + - @ at the start of a non-numeric value) are prefixed with '.

function ConvertTo-MigCsvCell {
    param([AllowNull()][AllowEmptyString()][string] $Value)
    if ($null -eq $Value) { $Value = '' }
    $num = 0.0
    if ($Value.Length -gt 0 -and '=+-@'.IndexOf($Value[0]) -ge 0 -and -not [double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)) {
        $Value = "'" + $Value
    }
    if ($Value.Length -gt 0 -and "`t`r".IndexOf($Value[0]) -ge 0) { $Value = "'" + $Value }
    return '"' + $Value.Replace('"', '""') + '"'
}

function Write-MigCsvRows {
    <# Writes header + rows of a flat table to a TextWriter. #>
    param([Parameter(Mandatory = $true)] $Table, [Parameter(Mandatory = $true)][System.IO.TextWriter] $Writer)
    $cols = @($Table.columns)
    $head = foreach ($c in $cols) { ConvertTo-MigCsvCell ([string]$c) }
    $Writer.Write((@($head) -join ',')); $Writer.Write("`r`n")
    foreach ($row in @($Table.rows)) {
        $cells = foreach ($c in $cols) { ConvertTo-MigCsvCell ([string]$row[$c]) }
        $Writer.Write((@($cells) -join ',')); $Writer.Write("`r`n")
    }
}

function Write-MigCsvTable {
    <# Streams one table to $Path (UTF-8 with BOM). #>
    param([Parameter(Mandatory = $true)] $Table, [Parameter(Mandatory = $true)][string] $Path)
    $w = New-Object System.IO.StreamWriter($Path, $false, (New-Object System.Text.UTF8Encoding($true)))
    try { Write-MigCsvRows -Table $Table -Writer $w } finally { $w.Dispose() }
}

function ConvertTo-MigCsvText {
    param([Parameter(Mandatory = $true)] $Table)
    $sw = New-Object System.IO.StringWriter
    try { Write-MigCsvRows -Table $Table -Writer $sw; return $sw.ToString() } finally { $sw.Dispose() }
}

function Get-MigCsvFileName {
    <# File name the csv provider uses for a table (the HTML provider points to it for capped tables). #>
    param([Parameter(Mandatory = $true)] $Table, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $BaseName)
    $custom = Get-MigRptValue $Table 'csv_name'
    if ($custom) { return [string]$custom }
    return ('{0}.{1}.csv' -f $BaseName, $Name)
}

Register-MigProvider -Kind Report -Name 'csv' -ScriptBlock {
    param($Ctx, $Report, $OutDir, $BaseName)
    $always = @('summary', 'issues', 'exceptions', 'html_findings')
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Report.tables.Keys)) {
        $t = $Report.tables[$name]
        if (Get-MigRptValue $t 'external_csv' $false) { continue }
        if ($always -notcontains $name -and @($t.rows).Count -eq 0) { continue }
        $path = Join-Path $OutDir (Get-MigCsvFileName -Table $t -Name $name -BaseName $BaseName)
        Write-MigCsvTable -Table $t -Path $path
        $files.Add($path)
    }
    return $files.ToArray()
}
