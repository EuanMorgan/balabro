<#
.SYNOPSIS
Builds dist\Balabro-<version>-windows-x64.zip: the Windows app, balabro-engine.exe, the Swift runtime it needs and the bot.

.DESCRIPTION
Run it from a shell where `swift` works (on CI, after compnerd/gha-setup-swift) and `dotnet` is the .NET 8 SDK.
It ships the Visual C++ runtime beside the engine, from Visual Studio's redist folder. It checks the zip by unzipping
it to a fresh folder, checking with dumpbin that every DLL its binaries need is in it or part of Windows, and printing
a fixture save's prompt there with PATH cut down to System32, so a DLL the zip lacks shows up here and not on a
player's PC. (System32 has the C++ runtime on any PC with Visual Studio, which is why the dumpbin check is needed.)

.EXAMPLE
pwsh scripts/make-windows.ps1 1.4.0
#>
param(
    [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$name = "Balabro-$Version-windows-x64"
$dist = Join-Path $root 'dist'
$out = Join-Path $dist $name
$zip = Join-Path $dist "$name.zip"

function Run([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe $($arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

function Dependents([string]$file) {
    $lines = & $dumpbin /nologo /dependents $file
    if ($LASTEXITCODE -ne 0) { throw "dumpbin couldn't read $file" }
    $lines | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim() }
}

# DLLs every Windows 10 and 11 PC has. Anything a shipped binary needs must be shipped or be one of these.
$windowsDlls = @(
    'advapi32.dll', 'bcrypt.dll', 'comctl32.dll', 'comdlg32.dll', 'crypt32.dll', 'dbghelp.dll', 'dwmapi.dll', 'gdi32.dll',
    'imm32.dll', 'iphlpapi.dll', 'kernel32.dll', 'kernelbase.dll', 'mswsock.dll', 'ncrypt.dll', 'netapi32.dll', 'normaliz.dll', 'ntdll.dll',
    'ole32.dll', 'oleaut32.dll', 'powrprof.dll', 'psapi.dll', 'rpcrt4.dll', 'secur32.dll', 'setupapi.dll', 'shell32.dll',
    'shlwapi.dll', 'ucrtbase.dll', 'user32.dll', 'userenv.dll', 'uxtheme.dll', 'version.dll', 'winmm.dll', 'wintrust.dll', 'ws2_32.dll'
)

function Assert-SelfContained([string]$folder) {
    $binaries = Get-ChildItem $folder -File | Where-Object { $_.Extension -in '.exe', '.dll' }
    $shipped = [System.Collections.Generic.HashSet[string]]::new([string[]]$binaries.Name, [StringComparer]::OrdinalIgnoreCase)
    $missing = foreach ($binary in $binaries) {
        foreach ($dll in Dependents $binary.FullName) {
            # api-ms-win-* and ext-ms-* name Windows' API sets, which the loader maps to its own DLLs.
            if ($shipped.Contains($dll) -or $windowsDlls -contains $dll -or $dll -match '^(api|ext)-ms-') { continue }
            "$($binary.Name) needs $dll"
        }
    }
    if ($missing) { throw "The zip lacks DLLs that aren't part of Windows:`n  $($missing -join "`n  ")" }
    Write-Host "Every DLL the zip's $($binaries.Count) binaries need is in the zip or part of Windows"
}

Push-Location $root
try {
    Write-Host "Building balabro-engine $Version"
    # The same build system as CI's Windows job; see .github/workflows/ci.yml.
    Run swift @('build', '-c', 'release', '--build-system', 'native', '--product', 'balabro-engine')
    $bin = (& swift build -c release --build-system native --show-bin-path).Trim()
    $engine = Join-Path $bin 'balabro-engine.exe'

    Write-Host "Publishing Balabro.exe"
    $publish = Join-Path $root 'windows\Balabro.Windows\bin\publish'
    if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
    Run dotnet @('publish', 'windows\Balabro.Windows\Balabro.Windows.csproj', '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true',
        '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true', '-p:EnableCompressionInSingleFile=true',
        '-p:DebugType=none', "-p:InformationalVersion=$Version", '-o', $publish)

    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    if (Test-Path $zip) { Remove-Item -Force $zip }
    New-Item -ItemType Directory -Force $out | Out-Null
    Copy-Item (Join-Path $publish '*') $out -Recurse
    Copy-Item $engine $out
    Copy-Item (Join-Path $root 'bot') (Join-Path $out 'bot') -Recurse
    # Read by the app and by the engine's Platform.version, so both say this version rather than "dev".
    Set-Content -Path (Join-Path $out 'version.txt') -Value $Version -Encoding ascii -NoNewline

    # The Swift runtime folder is the one on PATH that holds swiftCore.dll.
    $runtime = $env:PATH.Split(';') | Where-Object { $_ -and (Test-Path (Join-Path $_ 'swiftCore.dll')) } | Select-Object -First 1
    if (-not $runtime) { throw 'No folder on PATH holds swiftCore.dll; run this where swift works' }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $dumpbin = (Get-Command dumpbin.exe -ErrorAction SilentlyContinue).Source
    if (-not $dumpbin -and (Test-Path $vswhere)) {
        $dumpbin = & $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1
    }
    if (-not $dumpbin) { throw 'No dumpbin.exe on PATH or in Visual Studio, so the DLLs the engine needs are unknown' }
    # The Visual C++ runtime. Windows doesn't include it, and its licence allows shipping it beside the program.
    $redist = $env:VCToolsRedistDir
    if (-not $redist -and (Test-Path $vswhere)) {
        $vs = & $vswhere -latest -products * -property installationPath | Select-Object -First 1
        $redist = Get-ChildItem (Join-Path $vs 'VC\Redist\MSVC') -Directory | Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
            Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    $crt = if ($redist) { Get-ChildItem (Join-Path $redist 'x64') -Directory -Filter 'Microsoft.VC14*.CRT' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    if (-not $crt) { throw "No Visual C++ runtime under '$redist'; install Visual Studio's C++ tools" }

    # Every DLL a shipped binary needs that the C++ runtime or the Swift runtime has, and theirs in turn. Swift's runtime
    # folder may hold an older C++ runtime of its own, so Visual Studio's comes first.
    $queue = [System.Collections.Generic.Queue[string]]::new()
    Get-ChildItem $out -File | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object { $queue.Enqueue($_.FullName) }
    $copied = [System.Collections.Generic.List[string]]::new()
    while ($queue.Count -gt 0) {
        foreach ($dll in Dependents $queue.Dequeue()) {
            if (Test-Path (Join-Path $out $dll)) { continue }
            $source = @($crt, $runtime) | ForEach-Object { Join-Path $_ $dll } | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $source) { continue }
            Copy-Item $source $out
            $copied.Add("$dll (from $(Split-Path -Parent $source))")
            $queue.Enqueue((Join-Path $out $dll))
        }
    }
    Write-Host "Copied $($copied.Count) DLLs:"
    $copied | Sort-Object | ForEach-Object { Write-Host "  $_" }

    Write-Host "Zipping $zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($out, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)

    Write-Host "Checking the zip runs on its own"
    $check = Join-Path ([System.IO.Path]::GetTempPath()) ("balabro-zip-check-" + [guid]::NewGuid().ToString('N'))
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $check)
    $savedPath = $env:PATH
    try {
        Assert-SelfContained (Join-Path $check $name)
        $env:PATH = Join-Path $env:SystemRoot 'System32'
        $prompt = & (Join-Path $check "$name\balabro-engine.exe") --print-prompt (Join-Path $root 'Tests\BalabroCoreTests\Fixtures\saves\02-hand.jkr')
        if ($LASTEXITCODE -ne 0 -or -not ($prompt -match '^Kind: play hand')) { throw "The unzipped engine couldn't print a prompt (exit code $LASTEXITCODE)" }
    } finally {
        $env:PATH = $savedPath
        Remove-Item -Recurse -Force $check
    }

    $size = (Get-Item $zip).Length / 1MB
    Write-Host ("Made {0} ({1:N1} MB)" -f $zip, $size)
} finally {
    Pop-Location
}
