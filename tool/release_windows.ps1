# Builds Meshenger for Windows and zips it into build\dist\<Name>-Windows-x64.zip.
#
#   powershell -ExecutionPolicy Bypass -File tool\release_windows.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

$release = 'build\windows\x64\runner\Release'
$name = (Select-String -Path 'windows\runner\Runner.rc' `
    -Pattern 'VALUE "ProductName", "([^"]+)"').Matches[0].Groups[1].Value

# Ship the Visual C++ runtime next to the exe so the app starts on PCs
# that don't have it installed.
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
    Copy-Item (Join-Path $env:WINDIR "System32\$dll") $release -Force
}

New-Item -ItemType Directory -Force 'build\dist' | Out-Null
$zip = "build\dist\$name-Windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip }

# Zip a named folder so "Extract all" produces one tidy folder.
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory $stage | Out-Null
try {
    Copy-Item $release (Join-Path $stage $name) -Recurse
    Compress-Archive -Path (Join-Path $stage $name) -DestinationPath $zip
} finally {
    Remove-Item $stage -Recurse -Force
}

Get-Item $zip | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
