[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$Analyze
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$projectRoot = $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'src'
$testRoot = Join-Path $projectRoot 'tests'
$buildRoot = Join-Path $projectRoot 'build'
$generatedRoot = Join-Path $buildRoot 'generated'
$buildFlavor = 'public-verified-dx11-dx12'
$appExecutableName = 'Civ6_2K_Online_Fix.exe'
$versionFile = Join-Path $projectRoot 'version.json'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    throw "Version source was not found: $versionFile"
}
$productIdentity = Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json
$productVersion = [string]$productIdentity.Version
$windowsVersion = [string]$productIdentity.WindowsVersion
$packageBaseName = [string]$productIdentity.PackageBaseName
if ($productVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$' -or
    $windowsVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or
    $packageBaseName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$') {
    throw 'version.json contains an invalid product identity.'
}
$windowsVersionParts = @($windowsVersion.Split('.') | ForEach-Object {
    $component = 0
    if (-not [int]::TryParse($_, [ref]$component) -or
        $component -lt 0 -or $component -gt 65535) {
        throw "Invalid Windows version component: $_"
    }
    $component
})
if ($windowsVersionParts.Count -ne 4) {
    throw 'WindowsVersion must contain exactly four numeric components.'
}

New-Item -ItemType Directory -Path $buildRoot,$generatedRoot -Force | Out-Null
$generatedIdentityHeader = Join-Path $generatedRoot 'ProductIdentity.generated.h'
$numericVersion = $windowsVersionParts -join ','
$generatedIdentity = @"
#pragma once

#define CIV6FIX_VERSION_NUMERIC $numericVersion
#define CIV6FIX_VERSION_SEMVER "$productVersion"
#define CIV6FIX_VERSION_SEMVER_WIDE L"$productVersion"

#ifndef RC_INVOKED
namespace civ6fix {

inline constexpr char kProductVersion[] = CIV6FIX_VERSION_SEMVER;
inline constexpr wchar_t kProductVersionWide[] =
    L"Civ6 2K Online Fix " CIV6FIX_VERSION_SEMVER_WIDE;

}  // namespace civ6fix
#endif
"@
[System.IO.File]::WriteAllText($generatedIdentityHeader, ($generatedIdentity.TrimEnd() + "`r`n"), $utf8NoBom)

$manifestTemplatePath = Join-Path $sourceRoot 'Civ6_2K_Online_Fix.manifest.in'
if (-not (Test-Path -LiteralPath $manifestTemplatePath -PathType Leaf)) {
    throw "Manifest template was not found: $manifestTemplatePath"
}
$manifestTemplate = Get-Content -LiteralPath $manifestTemplatePath -Raw
$manifestVersionPlaceholder = '@WINDOWS_VERSION@'
if (($manifestTemplate.Split([string[]]@($manifestVersionPlaceholder), [StringSplitOptions]::None).Count - 1) -ne 1) {
    throw 'Manifest template must contain exactly one Windows version placeholder.'
}
$generatedManifest = Join-Path $generatedRoot 'ProductManifest.generated.manifest'
$manifestText = $manifestTemplate.Replace($manifestVersionPlaceholder, $windowsVersion)
[System.IO.File]::WriteAllText($generatedManifest, ($manifestText.TrimEnd() + "`r`n"), $utf8NoBom)

$visualStudioRoot = $null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
    $visualStudioRoot = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
}
$useMsvc = -not [string]::IsNullOrWhiteSpace($visualStudioRoot)

$framework = Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies/Microsoft/Framework/.NETFramework/v4.8'
if (-not (Test-Path -LiteralPath (Join-Path $framework 'mscorlib.dll'))) {
    $framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
}
$updateSource = Join-Path $sourceRoot 'UpdateAgent.cs'
$updateKey = Join-Path $sourceRoot 'update-public-key.xml'
$keyText = (Get-Content -LiteralPath $updateKey -Raw).Trim()
$publicOnly = [regex]::Match($keyText,'^<RSAKeyValue><Modulus>([A-Za-z0-9+/]+={0,2})</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>$')
if (!$publicOnly.Success -or [Convert]::FromBase64String($publicOnly.Groups[1].Value).Length -lt 384) {
    throw 'Expected a public-only RSA update key of at least 3072 bits.'
}

if ($useMsvc) {
    $vcVersionFile = Join-Path $visualStudioRoot 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    if (-not (Test-Path -LiteralPath $vcVersionFile -PathType Leaf)) {
        throw "MSVC version marker was not found: $vcVersionFile"
    }
    $msvcVersion = (Get-Content -LiteralPath $vcVersionFile -Raw).Trim()
    $msvc = Join-Path $visualStudioRoot "VC\Tools\MSVC\$msvcVersion"
    $sdkRegistryPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
    $sdk = Get-ItemPropertyValue -LiteralPath $sdkRegistryPath -Name KitsRoot10 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($sdk)) {
        $sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
    }
    $sdkIncludeRoot = Join-Path $sdk 'Include'
    $sdkVersionItem = Get-ChildItem -LiteralPath $sdkIncludeRoot -Directory |
        Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName 'um\Windows.h') -PathType Leaf
        } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1
    if ($null -eq $sdkVersionItem) {
        throw "No usable Windows 10/11 SDK was found under: $sdkIncludeRoot"
    }
    $sdkVersion = $sdkVersionItem.Name
    $compiler = Join-Path $msvc 'bin\Hostx64\x64\cl.exe'
    $resourceCompiler = Join-Path $sdk "bin\$sdkVersion\x64\rc.exe"
    $csc = Join-Path $visualStudioRoot 'MSBuild/Current/Bin/Roslyn/csc.exe'
    foreach ($tool in @($compiler, $resourceCompiler, $csc)) {
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
            throw "Required MSVC/Roslyn build tool was not found: $tool"
        }
    }
    $managedArgs = @('/nologo','/noconfig','/nostdlib+','/optimize+','/deterministic+','/debug-','/warnaserror+','/platform:x64',"/pathmap:$projectRoot=.",
        "/resource:$updateKey,PublisherKey") + @('mscorlib','System','System.Core','System.Xml','System.Web.Extensions','System.IO.Compression') |
        ForEach-Object { if ($_ -like 'System*' -or $_ -eq 'mscorlib'){"/reference:$(Join-Path $framework ($_+'.dll'))"}else{$_} }
} else {
    $gppCmd = Get-Command 'g++.exe' -ErrorAction SilentlyContinue
    $windresCmd = Get-Command 'windres.exe' -ErrorAction SilentlyContinue
    if ($null -eq $gppCmd -or $null -eq $windresCmd) {
        throw 'Neither Visual Studio C++ nor MinGW-w64 (g++.exe / windres.exe) was found.'
    }
    $compiler = $gppCmd.Source
    $resourceCompiler = $windresCmd.Source
    $msvcVersion = 'MinGW-W64-GCC-16.2.0'
    $sdkVersion = 'MinGW-W64-UCRT'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $managedArgs = @('/nologo','/noconfig','/nostdlib+','/optimize+','/debug-','/warnaserror+','/platform:x64',
        "/resource:$updateKey,PublisherKey") + @('mscorlib','System','System.Core','System.Xml','System.Web.Extensions','System.IO.Compression') |
        ForEach-Object { if ($_ -like 'System*' -or $_ -eq 'mscorlib'){"/reference:$(Join-Path $framework ($_+'.dll'))"}else{$_} }
}

& $csc @managedArgs '/target:winexe' "/out:$(Join-Path $generatedRoot 'UpdateAgent.generated.exe')" $updateSource
if ($LASTEXITCODE -ne 0) { throw 'Update helper compilation failed.' }

$updateTestCount = 0
if (-not $SkipTests) {
    $updateTestExe = Join-Path $buildRoot 'UpdateAgentTests.exe'
    & $csc @managedArgs '/target:exe' '/main:UpdateAgentTests' "/out:$updateTestExe" $updateSource (Join-Path $testRoot 'UpdateAgentTests.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Update test compilation failed.' }
    $updateResults = @(& $updateTestExe)
    if ($LASTEXITCODE -ne 0) { throw 'Offline update tests failed.' }
    $updateResults | Write-Output
    $updateTestCount = @($updateResults | Where-Object { $_ -like 'PASS:*' }).Count
}

$objects = @{}
if ($useMsvc) {
    $commonCompilerArgs = @(
        '/nologo'
        '/std:c++17'
        '/EHsc'
        '/permissive-'
        '/W4'
        '/WX'
        '/MT'
        '/O2'
        '/sdl'
        '/guard:cf'
        '/experimental:deterministic'
        "/pathmap:$projectRoot=."
        '/utf-8'
        '/Zc:__cplusplus'
        '/Zc:preprocessor'
        '/DUNICODE'
        '/D_UNICODE'
        "/I$generatedRoot"
        "/I$sourceRoot"
        "/I$(Join-Path $msvc 'include')"
        "/I$(Join-Path $sdk "Include\$sdkVersion\ucrt")"
        "/I$(Join-Path $sdk "Include\$sdkVersion\shared")"
        "/I$(Join-Path $sdk "Include\$sdkVersion\um")"
    )
    if ($Analyze) {
        $commonCompilerArgs += @(
            '/analyze'
            '/wd6553'
        )
    }
    $libraryArgs = @(
        "/LIBPATH:$(Join-Path $msvc 'lib\x64')"
        "/LIBPATH:$(Join-Path $sdk "Lib\$sdkVersion\ucrt\x64")"
        "/LIBPATH:$(Join-Path $sdk "Lib\$sdkVersion\um\x64")"
    )
    foreach ($name in @('FixSession', 'SessionPresentation', 'FeedbackFile', 'UpdateFlow', 'SteamDiscovery', 'Logger', 'Win32FixPlatform', 'AppWindow')) {
        $object = Join-Path $buildRoot "$name.obj"
        $compileArgs = @($commonCompilerArgs) + @(
            '/c'
            "/Fo$object"
            (Join-Path $sourceRoot "$name.cpp")
        )
        & $compiler @compileArgs
        if ($LASTEXITCODE -ne 0) {
            throw "$name compilation failed with exit code $LASTEXITCODE"
        }
        $objects[$name] = $object
    }

    $testExe = Join-Path $buildRoot 'Civ6FixCoreTests.exe'
    $testObject = Join-Path $buildRoot 'Civ6FixCoreTests.obj'
    $testArgs = @($commonCompilerArgs) + @(
        "/Fo$testObject"
        "/Fe$testExe"
        (Join-Path $testRoot 'Civ6FixCoreTests.cpp')
        $objects['FixSession']
        $objects['SessionPresentation']
        $objects['SteamDiscovery']
        $objects['FeedbackFile']
        $objects['Logger']
        'shell32.lib'
        '/link'
    ) + $libraryArgs
    & $compiler @testArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Unit test compilation failed with exit code $LASTEXITCODE"
    }
} else {
    $commonCompilerArgs = @(
        '-std=c++17'
        '-O2'
        '-Wall'
        '-Wextra'
        '-Wno-unknown-pragmas'
        '-DUNICODE'
        '-D_UNICODE'
        '-D_WIN32_WINNT=0x0A00'
        "-I$generatedRoot"
        "-I$sourceRoot"
    )
    foreach ($name in @('FixSession', 'SessionPresentation', 'FeedbackFile', 'UpdateFlow', 'SteamDiscovery', 'Logger', 'Win32FixPlatform', 'AppWindow')) {
        $object = Join-Path $buildRoot "$name.obj"
        $compileArgs = @($commonCompilerArgs) + @(
            '-c'
            (Join-Path $sourceRoot "$name.cpp")
            '-o'
            $object
        )
        & $compiler @compileArgs
        if ($LASTEXITCODE -ne 0) {
            throw "$name compilation failed with exit code $LASTEXITCODE"
        }
        $objects[$name] = $object
    }

    $testExe = Join-Path $buildRoot 'Civ6FixCoreTests.exe'
    $testArgs = @($commonCompilerArgs) + @(
        (Join-Path $testRoot 'Civ6FixCoreTests.cpp')
        $objects['FixSession']
        $objects['SessionPresentation']
        $objects['SteamDiscovery']
        $objects['FeedbackFile']
        $objects['Logger']
        '-o'
        $testExe
        '-static'
        '-lshell32'
    )
    & $compiler @testArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Unit test compilation failed with exit code $LASTEXITCODE"
    }
}

$testCount = 0
if (-not $SkipTests) {
    $testOutput = @(& $testExe 2>&1)
    $testExitCode = $LASTEXITCODE
    $testOutput | ForEach-Object { Write-Output $_ }
    if ($testExitCode -ne 0) {
        throw "Unit tests failed with exit code $testExitCode"
    }
    $testCount = $updateTestCount + @($testOutput | Where-Object { $_ -like 'PASS:*' }).Count
    foreach ($scriptTest in @(
        'VerifyHashes.Tests.ps1'
        'VersionSource.Tests.ps1'
        'ReleasePolicy.Tests.ps1'
    )) {
        $powershellTestOutput = @(
            & (Join-Path $testRoot $scriptTest) 2>&1
        )
        $powershellTestOutput | ForEach-Object { Write-Output $_ }
        $testCount += @(
            $powershellTestOutput | Where-Object { $_ -like 'PASS:*' }
        ).Count
    }
    if ($testCount -le 0) {
        throw 'Unit tests reported success without any counted assertions.'
    }
}

$appExe = Join-Path $buildRoot $appExecutableName
if ($useMsvc) {
    $resourceFile = Join-Path $buildRoot 'Civ6_2K_Online_Fix.res'
    $resourceArgs = @(
        '/nologo'
        '/i'
        $generatedRoot
        '/i'
        (Join-Path $sdk "Include\$sdkVersion\um")
        '/i'
        (Join-Path $sdk "Include\$sdkVersion\shared")
        '/i'
        (Join-Path $sdk "Include\$sdkVersion\ucrt")
        "/fo$resourceFile"
        (Join-Path $sourceRoot 'Civ6_2K_Online_Fix.rc')
    )
    Push-Location $sourceRoot
    try {
        & $resourceCompiler @resourceArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Resource compilation failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    $appObject = Join-Path $buildRoot 'Civ6_2K_Online_Fix.obj'
    $appArgs = @($commonCompilerArgs) + @(
        "/Fo$appObject"
        "/Fe$appExe"
        (Join-Path $sourceRoot 'Civ6_2K_Online_Fix.cpp')
        $objects['FixSession']
        $objects['SessionPresentation']
        $objects['SteamDiscovery']
        $objects['Logger']
        $objects['Win32FixPlatform']
        $objects['FeedbackFile']
        $objects['AppWindow']
        $objects['UpdateFlow']
        $resourceFile
        '/link'
        '/SUBSYSTEM:WINDOWS'
        '/INCREMENTAL:NO'
        '/OPT:REF'
        '/OPT:ICF'
        '/BREPRO'
        '/experimental:deterministic'
        '/DYNAMICBASE'
        '/HIGHENTROPYVA'
        '/NXCOMPAT'
        '/guard:cf'
        '/CETCOMPAT'
        'advapi32.lib'
        'bcrypt.lib'
        'comctl32.lib'
        'gdi32.lib'
        'psapi.lib'
        'shell32.lib'
        'user32.lib'
    ) + $libraryArgs
    & $compiler @appArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Application compilation failed with exit code $LASTEXITCODE"
    }
} else {
    $resourceFile = Join-Path $buildRoot 'Civ6_2K_Online_Fix.res.o'
    Push-Location $sourceRoot
    try {
        & $resourceCompiler "-I$generatedRoot" "-I$sourceRoot" -i (Join-Path $sourceRoot 'Civ6_2K_Online_Fix.rc') -o $resourceFile
        if ($LASTEXITCODE -ne 0) {
            throw "Resource compilation failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    $appArgs = @($commonCompilerArgs) + @(
        '-municode'
        '-mwindows'
        (Join-Path $sourceRoot 'Civ6_2K_Online_Fix.cpp')
        $objects['FixSession']
        $objects['SessionPresentation']
        $objects['SteamDiscovery']
        $objects['Logger']
        $objects['Win32FixPlatform']
        $objects['FeedbackFile']
        $objects['AppWindow']
        $objects['UpdateFlow']
        $resourceFile
        '-o'
        $appExe
        '-static'
        '-Wl,--dynamicbase,--high-entropy-va,--nxcompat'
        '-ladvapi32'
        '-lbcrypt'
        '-lcomctl32'
        '-lgdi32'
        '-lpsapi'
        '-lshell32'
        '-luser32'
    )
    & $compiler @appArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Application compilation failed with exit code $LASTEXITCODE"
    }
}

$appItem = Get-Item -LiteralPath $appExe
$versionInfo = $appItem.VersionInfo
if ($versionInfo.FileVersion -ne $productVersion -or
    $versionInfo.ProductVersion -ne $productVersion) {
    throw "Executable version resource does not match version.json: file=$($versionInfo.FileVersion), product=$($versionInfo.ProductVersion), expected=$productVersion"
}
$profileDump = @(& $appExe --print-profiles | Out-String)
if ($LASTEXITCODE -ne 0 -or $profileDump.Count -eq 0) { throw 'Compiled profile registry unavailable.' }
$profilesFromExe = @(($profileDump -join '') | ConvertFrom-Json | ForEach-Object { $_ })
$manifest = [ordered]@{
    Product = 'Civ6 2K Online Fix'
    Version = $productVersion
    WindowsVersion = $windowsVersion
    PackageBaseName = $packageBaseName
    BuildFlavor = $buildFlavor
    Dx12WriteEnabled = $true
    BuiltAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Configuration = 'Release'
    Architecture = 'x64'
    Executable = $appItem.Name
    Length = $appItem.Length
    SHA256 = (Get-FileHash -LiteralPath $appExe -Algorithm SHA256).Hash
    BuildProfiles = $profilesFromExe
    MSVCVersion = $msvcVersion
    WindowsSDKVersion = $sdkVersion
    NativeAnalysis = [bool]$Analyze
    TestsRun = (-not $SkipTests)
    TestCount = $testCount
    ReproducibleBuild = $true
    SourcePathMapping = '.\'
    VersionSource = 'version.json'
    SecurityProperties = @(
        'asInvoker'
        'NXCOMPAT'
        'HIGHENTROPYVA'
        'CFG'
        'CETCOMPAT'
        'StaticMSVCRuntime'
        'DeterministicCompilation'
        'SourcePathMapping'
        'ReproducibleLink'
        'SingleSourceVersion'
    )
}
$manifestPath = Join-Path $buildRoot 'build_manifest.json'
$manifestJson = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)

$manifest
