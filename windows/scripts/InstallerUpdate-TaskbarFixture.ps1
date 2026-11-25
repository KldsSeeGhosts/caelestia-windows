param([string]$Common, [string]$SourcePath, [string]$CaseRoot, [string]$KeyName)
$ErrorActionPreference = 'Stop'
. $Common
[Environment]::CurrentDirectory = $CaseRoot
Set-Content -LiteralPath (Join-Path $CaseRoot 'fixture-mm-taskbar') -Value '1' -Encoding ASCII
$source = [IO.File]::ReadAllText($SourcePath).Replace("`r`n", "`n")
function Replace-One([string]$Text, [string]$Old, [string]$New) {
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
            return File.Exists(path) ? Int32.Parse(File.ReadAllText(path)) : 1;
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
$baselinePresent = Get-ItemPropertyValue -LiteralPath $keyPath -Name BaselinePresent
$baselineValue = Get-ItemPropertyValue -LiteralPath $keyPath -Name BaselineValue
if ($baselinePresent -ne 1 -or $baselineValue -ne 1) { throw 'shared baseline was not stored before suppression' }
$ownersPath = Join-Path $keyPath 'Owners'
$current = [Diagnostics.Process]::GetCurrentProcess()
$ownerText = $current.SessionId.ToString() + ':' + $current.Id.ToString() + ':' + $current.StartTime.ToUniversalTime().Ticks.ToString()
Set-ItemProperty -LiteralPath $ownersPath -Name 'other-live-owner' -Value $ownerText
Set-ItemProperty -LiteralPath $ownersPath -Name 'dead-owner' -Value '999999:999999:1'
$restore = [Caelestia.Takeover.Native].GetMethod('RestoreSecondaryTaskbars', [Reflection.BindingFlags]'NonPublic,Static')
if ($null -eq $restore) { throw 'restore method missing' }
$restore.Invoke($null, @($snapshot)) | Out-Null
if ((Get-Content -LiteralPath (Join-Path $CaseRoot 'fixture-mm-taskbar') -Raw).Trim() -ne '0') { throw 'a live second owner did not block restoration' }
if (-not (Get-ItemProperty -LiteralPath $keyPath -Name BaselinePresent -ErrorAction SilentlyContinue)) { throw 'live-owner restore cleared the shared baseline' }
if (Get-ItemProperty -LiteralPath $ownersPath -Name 'dead-owner' -ErrorAction SilentlyContinue) { throw 'dead owner identity was not pruned' }
Remove-ItemProperty -LiteralPath $ownersPath -Name 'other-live-owner'
$restore.Invoke($null, @($snapshot)) | Out-Null
if ((Get-Content -LiteralPath (Join-Path $CaseRoot 'fixture-mm-taskbar') -Raw).Trim() -ne '1') { throw 'last owner did not restore the original preference' }
if (Get-ItemProperty -LiteralPath $keyPath -Name BaselinePresent -ErrorAction SilentlyContinue) { throw 'last-owner restore left a stale baseline' }
'TASKBAR-MULTISESSION-PASS'
