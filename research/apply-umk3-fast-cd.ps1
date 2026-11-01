$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$path = Join-Path $repoRoot 'libs\ymir-core\src\ymir\hw\cdblock\cdblock.cpp'

if (-not (Test-Path $path)) {
    throw "Could not find cdblock.cpp at: $path"
}

$text = [System.IO.File]::ReadAllText($path)

$marker = '// UMK3 fast-load experiment: skip the one-drive-tick BUSY delay after End Data Transfer.'
if ($text.Contains($marker)) {
    Write-Host 'UMK3 fast-load patch is already applied.'
    exit 0
}

$pattern = '(?m)^    if \(m_busyDelay == 0\) \{\r?\n        m_busyDelay = 1;\r?\n    \}\r?\n'
$replacement = "    $marker`n"

$patched = [regex]::Replace($text, $pattern, $replacement, 1)
if ($patched -eq $text) {
    throw 'Expected m_busyDelay block was not found. The upstream source may have changed.'
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($path, $patched, $utf8NoBom)

Write-Host 'Applied UMK3 fast-load experiment to:'
Write-Host "  $path"
Write-Host ''
Write-Host 'Changed behavior:'
Write-Host '  CmdEndDataTransfer() no longer forces m_busyDelay = 1.'
Write-Host ''
Write-Host 'To revert locally:'
Write-Host '  git restore libs/ymir-core/src/ymir/hw/cdblock/cdblock.cpp'
