# Formats and lints the Swift sources the way CI does.
#
# swift-format on Windows mishandles CRLF line endings: it moves doc comments away from their declarations
# and splits imports apart, and the result still passes lint. So every Swift file is converted to LF first.
#
# Usage: powershell -File scripts/format.ps1 [-LintOnly]

param([switch]$LintOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dirs = 'Packages', 'App', 'Widgets', 'Shared', 'AppTests' |
    ForEach-Object { Join-Path $root $_ } |
    Where-Object { Test-Path $_ }

$utf8 = New-Object System.Text.UTF8Encoding $false
foreach ($file in Get-ChildItem -Path $dirs -Recurse -Filter *.swift -File) {
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($text.Contains("`r")) {
        [IO.File]::WriteAllText($file.FullName, ($text -replace "`r`n?", "`n"), $utf8)
        Write-Host "Converted to LF: $($file.FullName.Substring($root.Length + 1))"
    }
}

if (-not $LintOnly) {
    swift format --in-place --recursive @dirs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
swift format lint --strict --recursive @dirs
exit $LASTEXITCODE