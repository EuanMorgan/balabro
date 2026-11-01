<#
.SYNOPSIS
Builds dist\Balabro-<version>-windows-x64.zip: the Windows app, balabro-engine.exe, the Swift runtime it needs and the bot.

.DESCRIPTION
Run it from a shell where `swift` works (on CI, after compnerd/gha-setup-swift) and `dotnet` is the .NET 8 SDK.
It checks the zip by unzipping it to a fresh folder and printing a fixture save's prompt there with PATH cut down
to System32, so a DLL the zip lacks shows up here and not on a player's PC.

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
    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($dumpbin) {
        # The engine's DLLs and theirs, as far as they come from the runtime folder. Windows supplies the rest.
        $needed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($engine)
        while ($queue.Count -gt 0) {
            $file = $queue.Dequeue()
            $dependents = & $dumpbin.Source /nologo /dependents $file | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim() }
            foreach ($dll in $dependents) {
                $candidate = Join-Path $runtime $dll
                if ((Test-Path $candidate) -and $needed.Add($dll)) { $queue.Enqueue($candidate) }
            }
        }
        Write-Host "Copying $($needed.Count) runtime DLLs from $runtime"
        foreach ($dll in $needed) { Copy-Item (Join-Path $runtime $dll) $out }
    } else {
        Write-Host "No dumpbin, so copying every DLL in $runtime"
        Copy-Item (Join-Path $runtime '*.dll') $out
    }

    Write-Host "Zipping $zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($out, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)

    Write-Host "Checking the zip runs on its own"
    $check = Join-Path ([System.IO.Path]::GetTempPath()) ("balabro-zip-check-" + [guid]::NewGuid().ToString('N'))
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $check)
    $savedPath = $env:PATH
    try {
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
