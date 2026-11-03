[CmdletBinding()]
param()
# The native merge lives in the Quickshell backend (hotkeys.cpp: mergeDefaults).
# This checks the shipped data contract and the documented decision rule for a
# legacy user file that is not extended: new default binds marked `since` are
# added only when their chord or shortcut name is not already taken. It never
# starts a shell, so no physical hotkey is registered.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$defaults = Get-Content -LiteralPath (Join-Path $repo 'defaults\windows\keybinds.json') -Raw | ConvertFrom-Json
$introduced = @($defaults.binds | Where-Object { $_.PSObject.Properties.Name -contains 'since' } |
    ForEach-Object { $_.name })

function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Merge([object[]]$UserBinds) {
    $merged = [Collections.Generic.List[object]]::new()
    foreach ($bind in $UserBinds) { $merged.Add($bind) }
    foreach ($bind in $defaults.binds) {
        if ($bind.action -ne 'global' -or $introduced -notcontains $bind.name) { continue }
        $taken = $false
        foreach ($existing in $merged) {
            if ($existing.keys -eq $bind.keys) { $taken = $true; break }
            if ($existing.action -in @('global', 'native') -and $existing.name -eq $bind.name -and
                $existing.appid -eq $bind.appid) { $taken = $true; break }
        }
        if (-not $taken) { $merged.Add($bind) }
    }
    return @($merged)
}
function Keys([object[]]$Binds) { return @($Binds | ForEach-Object { $_.keys }) }
function CountKey([object[]]$Binds, [string]$Key) { return @($Binds | Where-Object { $_.keys -eq $Key }).Count }
function Assert-Unique([object[]]$Binds) {
    $seen = @{}
    foreach ($key in Keys $Binds) {
        Assert (-not $seen.ContainsKey($key)) "Duplicate chord in merged profile: $key"
        $seen[$key] = $true
    }
}

foreach ($bind in @($defaults.binds | Where-Object { $_.keys -in @('PrintScreen', 'Win+Shift+S', 'Win+Shift+R') })) {
    Assert ($bind.since -and $bind.name -in @('caelestia:screenshot', 'caelestia:screenshotFreeze', 'caelestia:record')) `
        "New default bind $($bind.keys) has no since marker or owner."
}

# A legacy profile that already uses PrintScreen for something else keeps that
# binding; the other two new defaults arrive, and no chord is duplicated.
$legacy = @(
    [pscustomobject]@{ keys = 'Super+K'; action = 'global'; name = 'caelestia:showall' },
    [pscustomobject]@{ keys = 'PrintScreen'; action = 'global'; name = 'caelestia:launcher' }
)
$merged = Merge $legacy
Assert ((Keys $merged) -contains 'Win+Shift+S') 'A legacy profile did not receive Win+Shift+S.'
Assert ((Keys $merged) -contains 'Win+Shift+R') 'A legacy profile did not receive Win+Shift+R.'
Assert ((CountKey $merged 'PrintScreen') -eq 1) 'PrintScreen was duplicated or removed.'
Assert ((CountKey $merged 'Win+Shift+S') -eq 1) 'Win+Shift+S was duplicated.'
Assert ((CountKey $merged 'Win+Shift+R') -eq 1) 'Win+Shift+R was duplicated.'
Assert (@($merged | Where-Object { $_.name -eq 'caelestia:launcher' -and $_.keys -eq 'PrintScreen' }).Count -eq 1) `
    'The user binding was not preserved.'
Assert-Unique $merged

# A legacy profile with no conflict receives all three exactly once.
$merged = Merge @([pscustomobject]@{ keys = 'Super+K'; action = 'global'; name = 'caelestia:showall' })
foreach ($chord in @('PrintScreen', 'Win+Shift+S', 'Win+Shift+R')) {
    Assert ((CountKey $merged $chord) -eq 1) "$chord was not added exactly once."
}
foreach ($name in @('caelestia:screenshot', 'caelestia:record')) {
    Assert (@($merged | Where-Object { $_.name -eq $name }).Count -ge 1) "$name is not present."
}
Assert-Unique $merged

# An existing screenshot binding under another chord suppresses the
# same-named PrintScreen default; the second screenshot chord uses its own
# shortcut name, so it still arrives without duplicating any chord.
$merged = Merge @([pscustomobject]@{ keys = 'Ctrl+Alt+S'; action = 'global'; name = 'caelestia:screenshot' })
Assert ((CountKey $merged 'Ctrl+Alt+S') -eq 1) 'The user screenshot chord was removed.'
Assert ((CountKey $merged 'PrintScreen') -eq 0) 'The same-named screenshot default was duplicated.'
Assert ((CountKey $merged 'Win+Shift+S') -eq 1) 'The second screenshot chord was not added.'
Assert ((CountKey $merged 'Win+Shift+R') -eq 1) 'Recording was not added.'
Assert-Unique $merged

Write-Output 'KEYBIND_MERGE_PASS'
