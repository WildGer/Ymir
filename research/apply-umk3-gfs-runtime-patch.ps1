param(
    [ValidateRange(2, 32)]
    [int]$TransferSectors = 4
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$path = Join-Path $repoRoot 'libs\ymir-core\src\ymir\hw\sh2\sh2.cpp'

if (-not (Test-Path $path)) {
    throw "Could not find sh2.cpp at: $path"
}

$text = [System.IO.File]::ReadAllText($path)
$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }

$configMarker = '// UMK3 USA T-9701H V1.006 research-only GFS transfer experiment.'
$advanceMarker = '// UMK3 GFS runtime experiment (Advance): force the tested transfer unit at the service loop.'
$stepMarker = '// UMK3 GFS runtime experiment (Step): keep debugger stepping behavior identical.'

# If the hook is already installed, only update the compile-time transfer size.
if ($text.Contains($advanceMarker) -and $text.Contains($stepMarker)) {
    $pattern = '(?m)(inline constexpr uint32 umk3GfsTransferSectors = )\d+(;)'
    if (-not [regex]::IsMatch($text, $pattern)) {
        throw 'Runtime hook is present, but the UMK3 transfer-size constant was not found.'
    }

    $text = [regex]::Replace($text, $pattern, "`${1}$TransferSectors`${2}", 1)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)

    Write-Host "UMK3 GFS runtime patch already installed; transfer size set to $TransferSectors sectors."
    exit 0
}

if ($text.Contains($advanceMarker) -or $text.Contains($stepMarker) -or $text.Contains($configMarker)) {
    throw 'A partial UMK3 runtime patch was found. Restore sh2.cpp and rerun this script.'
}

# Keep the experimental value in one obvious place so 4/8/16-sector tests only require rerunning this script.
$configNeedle = '    inline constexpr uint32 sysExecDumpAddress = 0x186C;'
if (-not $text.Contains($configNeedle)) {
    throw 'Could not find the SH2 config insertion point. Upstream source may have changed.'
}
$configInsert = $configNeedle + $nl +
    "    $configMarker" + $nl +
    "    inline constexpr uint32 umk3GfsTransferSectors = $TransferSectors;"
$text = $text.Replace($configNeedle, $configInsert)

# The signature is deliberately version-specific. The hook only fires on the master SH-2 at
# UMK3's GFS service loop. At PC 0607E61A the original MOV.L at 0607E618 has just loaded the
# one-sector transfer limit into R1. Replacing both the handle field and R1 reproduces the
# manual debugger experiment that reduced Shang Tsung's morph pause dramatically.
$advanceNeedle = '        // TODO: choose between interpreter (cached or uncached) and JIT recompiler'
if (-not $text.Contains($advanceNeedle)) {
    throw 'Could not find the SH2::Advance insertion point. Upstream source may have changed.'
}

$advanceHook = @(
    "        $advanceMarker",
    '        if (IsMaster() && PC == 0x0607E61A &&',
    '            MemPeekWord<false>(0x0607E600) == 0x2F86 &&',
    '            MemPeekWord<false>(0x0607E602) == 0x2F96 &&',
    '            MemPeekWord<false>(0x0607E604) == 0x2FA6 &&',
    '            MemPeekWord<false>(0x0607E606) == 0x2FE6 &&',
    '            MemPeekWord<false>(0x0607E618) == 0x5185 &&',
    '            MemPeekWord<false>(0x0607E61A) == 0x3917 &&',
    '            MemPeekWord<false>(0x0607E61C) == 0x8F01 &&',
    '            MemPeekWord<false>(0x0607E620) == 0x6913) [[unlikely]] {',
    '            MemPokeLong<emulateCache>(0x060FF158, config::umk3GfsTransferSectors);',
    '            R[1] = config::umk3GfsTransferSectors;',
    '        }',
    ''
) -join $nl
$text = $text.Replace($advanceNeedle, $advanceHook + $advanceNeedle)

$stepNeedle = '    m_cyclesExecuted = InterpretNext<debug, emulateCache>();'
$stepIndex = $text.IndexOf($stepNeedle)
if ($stepIndex -lt 0) {
    throw 'Could not find the SH2::Step insertion point. Upstream source may have changed.'
}

$stepHook = @(
    "    $stepMarker",
    '    if (IsMaster() && PC == 0x0607E61A &&',
    '        MemPeekWord<false>(0x0607E600) == 0x2F86 &&',
    '        MemPeekWord<false>(0x0607E602) == 0x2F96 &&',
    '        MemPeekWord<false>(0x0607E604) == 0x2FA6 &&',
    '        MemPeekWord<false>(0x0607E606) == 0x2FE6 &&',
    '        MemPeekWord<false>(0x0607E618) == 0x5185 &&',
    '        MemPeekWord<false>(0x0607E61A) == 0x3917 &&',
    '        MemPeekWord<false>(0x0607E61C) == 0x8F01 &&',
    '        MemPeekWord<false>(0x0607E620) == 0x6913) [[unlikely]] {',
    '        MemPokeLong<emulateCache>(0x060FF158, config::umk3GfsTransferSectors);',
    '        R[1] = config::umk3GfsTransferSectors;',
    '    }',
    ''
) -join $nl

# The first exact occurrence is inside SH2::Step; SH2::Advance uses a += expression instead.
$text = $text.Remove($stepIndex, $stepNeedle.Length).Insert($stepIndex, $stepHook + $stepNeedle)

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($path, $text, $utf8NoBom)

Write-Host 'Applied UMK3 USA GFS runtime experiment to:'
Write-Host "  $path"
Write-Host ''
Write-Host "Transfer unit: $TransferSectors sectors"
Write-Host 'Trigger: master SH-2 PC 0607E61A plus UMK3 V1.006 opcode signature'
Write-Host 'Action : force [060FF158] and R1 to the configured transfer unit before CMP/GT'
Write-Host ''
Write-Host 'The patch is runtime-only: the Saturn disc image is not modified.'
Write-Host 'It also reapplies after loading a save state because the hook executes every time the GFS loop is reached.'
Write-Host ''
Write-Host 'To change the test value, rerun for example:'
Write-Host '  .\research\apply-umk3-gfs-runtime-patch.ps1 -TransferSectors 8'
Write-Host ''
Write-Host 'To revert locally:'
Write-Host '  git restore libs/ymir-core/src/ymir/hw/sh2/sh2.cpp'
