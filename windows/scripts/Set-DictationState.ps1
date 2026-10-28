[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('idle', 'listening', 'processing', 'done', 'error')]
    [string]$State,
    [string]$RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'caelestia-windows\runtime'),
    [string]$Screen = '',
    # Unix seconds. A producer can carry the recording start through processing.
    [ValidateRange(0, [double]::MaxValue)][double]$StartedAt = 0
)
# Publish status only. Never pass speech, prompts, transcripts or error details.
# Does not start/stop recording, launch the shell or change its configuration.
$ErrorActionPreference = 'Stop'
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
if ($StartedAt -gt $now) { throw 'StartedAt must not be in the future.' }
if ($State -eq 'listening' -and $StartedAt -eq 0) { $StartedAt = $now }
$data = [ordered]@{
    state = $State
    screen = $Screen
    startedAt = $StartedAt
    updatedAt = $now
}
$target = Join-Path $RuntimeRoot 'dictation-state.json'
$temporary = Join-Path $RuntimeRoot ("dictation-state-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($temporary, ($data | ConvertTo-Json -Compress),
        (New-Object Text.UTF8Encoding($false)))
    if ([IO.File]::Exists($target)) {
        [IO.File]::Replace($temporary, $target, [NullString]::Value)
    } else {
        [IO.File]::Move($temporary, $target)
    }
} finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}
