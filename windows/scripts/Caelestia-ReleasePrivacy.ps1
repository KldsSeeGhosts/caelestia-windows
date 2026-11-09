#requires -Version 5.1
# Invoke only the caller's reviewed scanner definition, never artifact code.
function Invoke-CaelestiaReleasePrivacyScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][IO.FileInfo[]]$Files,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PrivateRoots,
        [Parameter(Mandatory)][string]$ScannerDefinition,
        [ValidateRange(1, 4)][int]$Jobs = 2
    )
    $ErrorActionPreference = 'Stop'
    if (-not $Files.Count) { return }
    $state = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $state.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new(
        'Get-ReleaseFilePrivacy', $ScannerDefinition))
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $Jobs, $state, $Host)
    $pending = [Collections.Generic.List[object]]::new()
    $results = New-Object object[] $Files.Count
    $next = 0
    $culture = [Threading.Thread]::CurrentThread.CurrentCulture.Name
    $uiCulture = [Threading.Thread]::CurrentThread.CurrentUICulture.Name
    $worker = {
        param($Path, $Extension, [string[]]$Roots, $Culture, $UiCulture)
        $ErrorActionPreference = 'Stop'
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
        [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo($UiCulture)
        Get-ReleaseFilePrivacy ([IO.File]::ReadAllBytes($Path)) $Extension $Roots
    }
    try {
        $pool.Open()
        while ($next -lt $Files.Count -or $pending.Count) {
            while ($next -lt $Files.Count -and $pending.Count -lt $Jobs) {
                $pipeline = [PowerShell]::Create()
                try {
                    $pipeline.RunspacePool = $pool
                    $null = $pipeline.AddScript($worker.ToString()).AddArgument($Files[$next].FullName).
                        AddArgument($Files[$next].Extension).AddArgument($PrivateRoots).
                        AddArgument($culture).AddArgument($uiCulture)
                    $handle = $pipeline.BeginInvoke()
                    $pending.Add([pscustomobject]@{ Index = $next; Pipeline = $pipeline; Handle = $handle })
                    $next++
                } catch {
                    $pipeline.Dispose()
                    throw
                }
            }
            $completed = @($pending | Where-Object { $_.Handle.IsCompleted })
            if (-not $completed.Count) {
                $handles = [Threading.WaitHandle[]]@($pending | ForEach-Object { $_.Handle.AsyncWaitHandle })
                $null = [Threading.WaitHandle]::WaitAny($handles, 100)
                continue
            }
            foreach ($item in $completed) {
                $output = @($item.Pipeline.EndInvoke($item.Handle))
                if ($item.Pipeline.HadErrors -or $output.Count -ne 1 -or
                    $output[0].Sensitive -isnot [bool] -or $output[0].GenericPath -isnot [bool]) {
                    throw 'Release privacy worker did not return exactly one complete verdict.'
                }
                $results[$item.Index] = [pscustomobject]@{
                    FullName = $Files[$item.Index].FullName
                    Sensitive = $output[0].Sensitive
                    GenericPath = $output[0].GenericPath
                }
                $item.Pipeline.Dispose()
                $null = $pending.Remove($item)
            }
        }
        if (@($results | Where-Object { $null -eq $_ }).Count) {
            throw 'Release privacy scan did not cover every file.'
        }
        # Return nothing until all workers and the complete input inventory pass.
        # Sensitive verdicts are data for the caller's unchanged vendor policy.
        $results
    } finally {
        try {
            foreach ($item in $pending) {
                try { $item.Pipeline.Stop() }
                catch { Write-Verbose 'Privacy worker cleanup reported an error after scan failure.' }
                finally { $item.Pipeline.Dispose() }
            }
        } finally { $pool.Dispose() }
    }
}
