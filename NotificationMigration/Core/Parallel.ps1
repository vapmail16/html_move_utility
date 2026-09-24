# Parallel execution on a .NET runspace pool (works on Windows PowerShell 5.1 and PowerShell 7).
# The scriptblock runs in a fresh runspace: it cannot see module functions, so it must be self-contained.
# It receives ($Item, $Arguments) and its output is collected. Results come back in input order.

function Invoke-MigParallel {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Items,
        [Parameter(Mandatory = $true)][scriptblock] $ScriptBlock,
        [int] $Threads = 4,
        $Arguments = $null
    )
    if ($Items.Count -eq 0) { return @() }
    if ($Threads -lt 1) { $Threads = 1 }
    $pool = [runspacefactory]::CreateRunspacePool(1, $Threads)
    $pool.Open()
    $jobs = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($item in $Items) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($ScriptBlock.ToString()).AddArgument($item).AddArgument($Arguments)
            $jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }
        $results = New-Object System.Collections.Generic.List[object]
        foreach ($j in $jobs) {
            try {
                foreach ($o in $j.PS.EndInvoke($j.Handle)) { $results.Add($o) }
                foreach ($e in $j.PS.Streams.Error) { Write-Warning "Parallel worker error: $e" }
            } finally { $j.PS.Dispose() }
        }
        return $results.ToArray()
    } finally {
        $pool.Close(); $pool.Dispose()
    }
}
