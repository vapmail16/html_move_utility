# Report provider 'json': the whole report object as one JSON document (<base>.json, UTF-8 without BOM).

Register-MigProvider -Kind Report -Name 'json' -ScriptBlock {
    param($Ctx, $Report, $OutDir, $BaseName)
    $path = Join-Path $OutDir ('{0}.json' -f $BaseName)
    $json = ConvertTo-Json -InputObject $Report -Depth 20
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return @($path)
}
