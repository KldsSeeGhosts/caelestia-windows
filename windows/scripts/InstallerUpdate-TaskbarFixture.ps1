param([string]$Common, [string]$SourcePath, [string]$CaseRoot, [string]$KeyName)
$ErrorActionPreference = 'Stop'
. $Common
[Environment]::CurrentDirectory = $CaseRoot
Set-Content -LiteralPath (Join-Path $CaseRoot 'fixture-mm-taskbar') -Value '1' -Encoding ASCII
$source = [IO.File]::ReadAllText($SourcePath).Replace("`r`n", "`n")
function Replace-One([string]$Text, [string]$Old, [string]$New) {
    # Here-strings keep the checkout's line endings; the source is LF-normalized.
    $Old = $Old.Replace("`r`n", "`n"); $New = $New.Replace("`r`n", "`n")
    if ([regex]::Matches($Text, [regex]::Escape($Old)).Count -ne 1) { throw 'fixture boundary changed' }
    return $Text.Replace($Old, $New)
}
$readOld = @'
            using (var key = Registry.CurrentUser.OpenSubKey(ExplorerAdvanced)) {
                var value = key == null ? null : key.GetValue("MMTaskbarEnabled");
                return value is int ? (int?)(int)value : null;
            }
'@
$readNew = @'
            string path = Path.Combine(Environment.CurrentDirectory, "fixture-mm-taskbar");
            return File.Exists(path) ? (int?)Int32.Parse(File.ReadAllText(path)) : null;
'@
$writeOld = @'
            using (var key = Registry.CurrentUser.CreateSubKey(ExplorerAdvanced)) {
                if (value.HasValue) key.SetValue("MMTaskbarEnabled", value.Value, RegistryValueKind.DWord);
                else key.DeleteValue("MMTaskbarEnabled", false);
            }
            // Preserve Settings' notification semantics, outside the message pump.
            NotifyTraySettings();
'@
$writeNew = @'
            string path = Path.Combine(Environment.CurrentDirectory, "fixture-mm-taskbar");
            if (value.HasValue) File.WriteAllText(path, value.Value.ToString());
            else File.Delete(path);
'@
$source = Replace-One $source $readOld $readNew
$source = Replace-One $source $writeOld $writeNew
$keyOld = 'const string TaskbarCoordinationKey = @"Software\Caelestia\Windows\TaskbarSuppression";'
$keyNew = 'const string TaskbarCoordinationKey = @"' + $KeyName.Replace('\', '\\') + '";'
$source = Replace-One $source $keyOld $keyNew
$mutexToken = ($KeyName -replace '[^A-Za-z0-9]', '')
$mutexOld = 'return @"Global\CaelestiaTaskbarPreference-" + id.Replace'
$mutexNew = 'return @"Global\CaelestiaTestTaskbarPreference-' + $mutexToken + '-" + id.Replace'
$source = Replace-One $source $mutexOld $mutexNew
$modified = Join-Path $CaseRoot 'DesktopTakeoverFixture.cs'
[IO.File]::WriteAllText($modified, $source, [Text.UTF8Encoding]::new($false))
Add-Type -Path $modified -ReferencedAssemblies (Get-CaelestiaDesktopTakeoverReferences) -ErrorAction Stop
$snapshot = [Caelestia.Takeover.Snapshot]::new()
$persist = [Action]{}
[Caelestia.Takeover.Native]::SuppressSecondaryTaskbars($snapshot, $persist)
if ((Get-Content -LiteralPath (Join-Path $CaseRoot 'fixture-mm-taskbar') -Raw).Trim() -ne '0') { throw 'suppression did not write zero' }
if (-not $snapshot.MultiMonitorTaskbarSaved -or $snapshot.MultiMonitorTaskbar -ne 1) { throw 'baseline snapshot was not preserved' }
$keyPath = 'HKCU:\' + $KeyName
$baseline = Get-ItemProperty -LiteralPath $keyPath
if ($baseline.Baseline -cne 'dword:1' -or $baseline.PSObject.Properties['BaselinePresent'] -or
    $baseline.PSObject.Properties['BaselineValue']) { throw 'shared DWORD baseline was not stored in one value' }
$ownersPath = Join-Path $keyPath 'Owners'
$current = [Diagnostics.Process]::GetCurrentProcess()
$ownerText = $current.SessionId.ToString() + ':' + $current.Id.ToString() + ':' + $current.StartTime.ToUniversalTime().Ticks.ToString()
Set-ItemProperty -LiteralPath $ownersPath -Name 'other-live-owner' -Value $ownerText
Set-ItemProperty -LiteralPath $ownersPath -Name 'dead-owner' -Value '999999:999999:1'
$restore = [Caelestia.Takeover.Native].GetMethod('RestoreSecondaryTaskbars', [Reflection.BindingFlags]'NonPublic,Static')
if ($null -eq $restore) { throw 'restore method missing' }
$restore.Invoke($null, @($snapshot)) | Out-Null
if ((Get-Content -LiteralPath (Join-Path $CaseRoot 'fixture-mm-taskbar') -Raw).Trim() -ne '0') { throw 'a live second owner did not block restoration' }
if (-not (Get-ItemProperty -LiteralPath $keyPath -Name Baseline -ErrorAction SilentlyContinue)) { throw 'live-owner restore cleared the shared baseline' }
if (Get-ItemProperty -LiteralPath $ownersPath -Name 'dead-owner' -ErrorAction SilentlyContinue) { throw 'dead owner identity was not pruned' }
Remove-ItemProperty -LiteralPath $ownersPath -Name 'other-live-owner'
$restore.Invoke($null, @($snapshot)) | Out-Null
if ((Get-Content -LiteralPath (Join-Path $CaseRoot 'fixture-mm-taskbar') -Raw).Trim() -ne '1') { throw 'last owner did not restore the original preference' }
if (Get-ItemProperty -LiteralPath $keyPath -Name Baseline -ErrorAction SilentlyContinue) { throw 'last-owner restore left a stale baseline' }
$preference = Join-Path $CaseRoot 'fixture-mm-taskbar'
[IO.File]::Delete($preference)
$snapshot = [Caelestia.Takeover.Snapshot]::new()
[Caelestia.Takeover.Native]::SuppressSecondaryTaskbars($snapshot, $persist)
if ((Get-ItemPropertyValue -LiteralPath $keyPath -Name Baseline) -cne 'missing' -or
    -not $snapshot.MultiMonitorTaskbarSaved -or $null -ne $snapshot.MultiMonitorTaskbar) { throw 'the missing baseline was not encoded atomically' }
$restore.Invoke($null, @($snapshot)) | Out-Null
if ([IO.File]::Exists($preference)) { throw 'restoring a missing baseline left a DWORD' }

New-ItemProperty -LiteralPath $keyPath -Name BaselinePresent -Value 1 -PropertyType DWord | Out-Null
New-ItemProperty -LiteralPath $keyPath -Name BaselineValue -Value 7 -PropertyType DWord | Out-Null
[IO.File]::WriteAllText($preference, '0')
$snapshot = [Caelestia.Takeover.Snapshot]::new()
[Caelestia.Takeover.Native]::SuppressSecondaryTaskbars($snapshot, $persist)
$restore.Invoke($null, @($snapshot)) | Out-Null
if ([IO.File]::ReadAllText($preference) -cne '7') { throw 'legacy DWORD baseline was not restored' }
'TASKBAR-MULTISESSION-PASS'
