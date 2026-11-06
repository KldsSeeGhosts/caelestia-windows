[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$serviceSource = Join-Path $repoRoot 'windows\services\notifications\NotificationsService.qml'
$recordSource = Join-Path $repoRoot 'windows\services\notifications\NotifData.qml'
$facadeSource = Join-Path $repoRoot 'windows\services\notifications\Notifs.qml'
$backendSource = Join-Path $repoRoot 'windows\services\notifications\NativeNotificationBackend.qml'
$serviceText = Get-Content -LiteralPath $serviceSource -Raw
$recordText = Get-Content -LiteralPath $recordSource -Raw
$facadeText = Get-Content -LiteralPath $facadeSource -Raw
$backendText = Get-Content -LiteralPath $backendSource -Raw
$servicePathFallbacks = @(Select-String -LiteralPath $serviceSource -CaseSensitive -Pattern 'Quickshell\.env\(\s*["''](?:HOME|XDG_)|Paths\.(state|cache|notifimagecache)|Quickshell\.(stateDir|cacheDir)')
$recordPathFallbacks = @(Select-String -LiteralPath $recordSource -CaseSensitive -Pattern 'Quickshell\.env\(\s*["''](?:HOME|XDG_)|Paths\.(state|cache|notifimagecache)|Hypr|CUtils|saveItem')
$facadePathFallbacks = @(Select-String -LiteralPath $facadeSource -CaseSensitive -Pattern 'Quickshell\.env\(\s*["''](?:HOME|XDG_)|Paths\.(state|cache|notifimagecache)')
$serviceImageCache = @(Select-String -LiteralPath $serviceSource -CaseSensitive -Pattern 'notifimagecache')
# The image cache was removed entirely: no cache pool, queue, prune, quota,
# listing or file copy/deletion may remain in the staged service, record or
# facade, and the writer component must stay deleted.
$cacheCode = @(Select-String -LiteralPath $serviceSource, $recordSource, $facadeSource -CaseSensitive -Pattern 'imageCache|ImageCache|copyFile|deleteFile|FolderListModel|CUtils')
$cacheWriterExists = Test-Path -LiteralPath (Join-Path $repoRoot 'windows\services\notifications\NotifImageCache.qml')
# The wrapper must set mirroring false at construction and must not enable it in
# a declaration. Consent goes through exactly one explicit function, and only
# the pure service may call the backend's request function (from its own
# explicit requestAccess). No component, timer, enabled/binding hook or facade
# may call the native access request. Comments are stripped so prose cannot
# satisfy or break the counts.
$stripComments = { param($text) (($text -split "`n") | ForEach-Object { $_ -replace '//.*$', '' }) -join "`n" }
$serviceCode = & $stripComments $serviceText
$recordCode = & $stripComments $recordText
$facadeCode = & $stripComments $facadeText
$backendCode = & $stripComments $backendText
$mirrorSetting = @(Select-String -LiteralPath $backendSource -Pattern 'mirrorSystemNotifications:\s*false')
$mirrorEnabled = @(Select-String -LiteralPath $backendSource -Pattern 'mirrorSystemNotifications:\s*true')
$nativeAccessRequest = @([regex]::Matches($backendCode, 'requestSystemNotificationAccess'))
$otherAccessRequest = @([regex]::Matches("$serviceCode`n$recordCode`n$facadeCode", 'requestSystemNotificationAccess'))
$serviceRequestFunction = @([regex]::Matches($serviceCode, 'function requestAccess\(\): bool'))
$serviceRequestCalls = @([regex]::Matches($serviceCode, 'requestAccess\('))
$backendRequestCall = @([regex]::Matches($serviceCode, 'backend\.requestAccess\(\)'))
# The facade must expose the user action, and the consent button in the
# original notification center must call it (the only UI entry point).
$facadeUserAction = @([regex]::Matches($facadeCode, 'function requestMirrorAccess\(\)'))
$dockConsent = @(Select-String -LiteralPath (Join-Path $repoRoot 'modules\sidebar\NotifDock.qml') `
    -Pattern 'requestMirrorAccess\(\)')
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name notifications `
    -Sources @('windows/services/notifications/NotificationsService.qml',
        'windows/services/notifications/NotifData.qml',
        'windows/services/notifications/NotificationsServiceTest.qml') `
    -FixtureFile 'windows/services/notifications/NotificationsServiceTest.qml' -Marker CAELESTIA_NOTIFICATIONS_FIXTURE -MinimumAssertions 180 -TimeoutMs 20000
$result.staticChecks = [ordered]@{
        serviceImportsNoPaths = $servicePathFallbacks.Count -eq 0
        recordIsPure = $recordPathFallbacks.Count -eq 0
        recordNeverConstructsServer = $recordText -notmatch 'NotificationServer'
        facadeImportsNoPaths = $facadePathFallbacks.Count -eq 0
        serviceUsesNoUpstreamImageCache = $serviceImageCache.Count -eq 0
        noNotificationImageCacheCode = $cacheCode.Count -eq 0
        imageCacheWriterRemoved = -not $cacheWriterExists
        serviceNeverConstructsServer = $serviceText -notmatch 'NotificationServer'
        wrapperMirroringFalseAtConstruction = $mirrorSetting.Count -eq 1
        wrapperNeverEnablesMirroringAtConstruction = $mirrorEnabled.Count -eq 0
        singleNativeAccessRequestFunction = $nativeAccessRequest.Count -eq 1
        noFacadeRecordAccessRequest = $otherAccessRequest.Count -eq 0
        serviceHasOneExplicitRequestFunction = $serviceRequestFunction.Count -eq 1
        serviceCallsBackendRequestOnce = $backendRequestCall.Count -eq 1
        serviceHasNoOtherRequestCallSites = $serviceRequestCalls.Count -eq 2
        facadeExposesOneUserAction = $facadeUserAction.Count -eq 1
        originalCenterIsTheOnlyConsentButton = $dockConsent.Count -eq 1
    }
$result.passed = $result.passed -and @($result.staticChecks.Values | Where-Object { -not $_ }).Count -eq 0
$result.servicePathFallbacks = @($servicePathFallbacks)
$result.recordPathFallbacks = @($recordPathFallbacks)
$result.facadePathFallbacks = @($facadePathFallbacks)
$result.serviceImageCacheReferences = @($serviceImageCache)
$result.cacheCodeReferences = @($cacheCode)
$result.cacheWriterExists = $cacheWriterExists
$result.mirrorSetting = @($mirrorSetting)
$result.mirrorEnabled = @($mirrorEnabled)
$result.nativeAccessRequests = @($nativeAccessRequest)
$result.otherAccessRequests = @($otherAccessRequest)
$result.serviceRequestCalls = @($serviceRequestCalls)
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Service fixture failed. See $($result.stdout) and $($result.stderr)." }
