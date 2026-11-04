# Apps reload regression

This offscreen QtTest loads the production `NativeAppCatalog.qml` and
`AppsService.qml` into two overlapping `QQmlEngine`s. Only the native
`Quickshell.DesktopEntries` boundary is replaced: each engine owns its facade,
and both facades read one process-owned model. The test never enumerates or
launches installed applications.

From a Visual Studio developer PowerShell, with the Qt, LLVM and CMake/Ninja
tool directories on `PATH`:

```powershell
$qt = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$mt = Join-Path $env:WindowsSdkDir "bin\$($env:WindowsSDKVersion.TrimEnd('\'))\x64\mt.exe"
cmake -S windows/tests/apps-reload -B C:/b-83b/apps-reload -G Ninja `
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang-cl `
    -DCMAKE_LINKER_TYPE=MSVC "-DCMAKE_MT:FILEPATH=$mt" `
    "-DSDK_MT:FILEPATH=$mt" "-DCMAKE_PREFIX_PATH=$qt"
cmake --build C:/b-83b/apps-reload
$run = Join-Path $env:TEMP ("apps-reload-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
Push-Location $run
try {
    $env:QT_QPA_PLATFORM = 'offscreen'
    & C:/b-83b/apps-reload/apps_reload_test.exe -o -,txt
} finally {
    Pop-Location
}
```

Before the fix, `overlappingGenerations` fails because generation 2 reports
zero applications instead of three. It must expose all three before another
scan or event-loop turn, then release generation 1's facade and subscription
when its root and engine are destroyed.
