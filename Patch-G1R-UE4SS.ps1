$ErrorActionPreference = 'Stop'

$ExpectedFileName = 'G1R-Win64-Shipping.exe'
$ExpectedFileSize = [int64]175029760
$ExpectedImageBase = [uint64]0x140000000
$backupPath = $null
$writeStarted = $false

function Read-PeInfo {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 256) { throw 'Invalid executable.' }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 24)) { throw 'Invalid executable.' }

        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Invalid executable.' }

        $stream.Position = $peOffset + 6
        $sectionCount = $reader.ReadUInt16()
        $stream.Position = $peOffset + 20
        $optionalHeaderSize = $reader.ReadUInt16()
        $optionalHeaderOffset = $peOffset + 24

        $stream.Position = $optionalHeaderOffset
        $magic = $reader.ReadUInt16()
        if ($magic -ne 0x20B) { throw 'Unsupported executable.' }

        $stream.Position = $optionalHeaderOffset + 24
        $imageBase = $reader.ReadUInt64()
        $sectionTableOffset = $optionalHeaderOffset + $optionalHeaderSize
        $sections = @()

        for ($i = 0; $i -lt $sectionCount; $i++) {
            $stream.Position = $sectionTableOffset + (40 * $i)
            [void]$reader.ReadBytes(8)
            $virtualSize = $reader.ReadUInt32()
            $virtualAddress = $reader.ReadUInt32()
            $rawSize = $reader.ReadUInt32()
            $rawPointer = $reader.ReadUInt32()
            $sections += [pscustomobject]@{
                VirtualAddress = [uint64]$virtualAddress
                RawSize = [uint64]$rawSize
                RawPointer = [uint64]$rawPointer
            }
        }

        return [pscustomobject]@{
            ImageBase = [uint64]$imageBase
            Sections = $sections
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-FileOffsetForAddress {
    param(
        [Parameter(Mandatory)]$PeInfo,
        [Parameter(Mandatory)][uint64]$Address,
        [Parameter(Mandatory)][int]$Length
    )

    if ($Address -lt $PeInfo.ImageBase) { throw 'Unsupported executable.' }
    $rva = [uint64]($Address - $PeInfo.ImageBase)

    foreach ($section in $PeInfo.Sections) {
        $sectionStart = [uint64]$section.VirtualAddress
        $sectionRawEnd = $sectionStart + [uint64]$section.RawSize
        $targetEnd = $rva + [uint64]$Length
        if ($rva -ge $sectionStart -and $targetEnd -le $sectionRawEnd) {
            return [int64]([uint64]$section.RawPointer + ($rva - $sectionStart))
        }
    }

    throw 'Unsupported executable.'
}

function Test-ByteSequence {
    param([byte[]]$Actual, [byte[]]$Expected)
    if ($Actual.Length -ne $Expected.Length) { return $false }
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        if ($Actual[$i] -ne $Expected[$i]) { return $false }
    }
    return $true
}

function Find-GameExecutable {
    $searchRoots = @()
    foreach ($start in @($PSScriptRoot, (Get-Location).Path)) {
        if ([string]::IsNullOrWhiteSpace($start)) { continue }
        try {
            $current = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($start))
        }
        catch { continue }

        for ($depth = 0; $null -ne $current -and $depth -le 5; $depth++) {
            if ($searchRoots -notcontains $current.FullName) { $searchRoots += $current.FullName }
            $current = $current.Parent
        }
    }

    foreach ($root in $searchRoots) {
        $candidates = @(
            [System.IO.Path]::Combine($root, 'G1R', 'Binaries', 'Win64', $ExpectedFileName),
            [System.IO.Path]::Combine($root, 'Binaries', 'Win64', $ExpectedFileName),
            [System.IO.Path]::Combine($root, $ExpectedFileName)
        )
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }
    return $null
}

function Show-UnsupportedVersion {
    Write-Host ''
    Write-Host 'This game version is not supported by this patcher.' -ForegroundColor Red
    Write-Host 'No changes have been made. Please check for an updated patcher.' -ForegroundColor Yellow
}

Clear-Host
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '  Gothic 1 Remake - UE4SS Compatibility Patch' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Checking your game...' -ForegroundColor Gray
Write-Host 'Please make sure the game is closed.' -ForegroundColor Gray

$exePath = Find-GameExecutable
if (-not $exePath) {
    Write-Host ''
    Write-Host 'The game executable could not be found automatically.' -ForegroundColor Yellow
    $exePath = Read-Host 'Enter the full path to G1R-Win64-Shipping.exe (or press Enter to cancel)'
    $exePath = $exePath.Trim()
    if ($exePath.StartsWith('"') -and $exePath.EndsWith('"') -and $exePath.Length -ge 2) {
        $exePath = $exePath.Substring(1, $exePath.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($exePath)) {
        Write-Host 'Cancelled. No changes were made.' -ForegroundColor Yellow
        exit 0
    }
}

try {
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw 'Unsupported executable.' }
    $file = Get-Item -LiteralPath $exePath
    if ($file.Name -ine $ExpectedFileName -or [int64]$file.Length -ne $ExpectedFileSize) { throw 'Unsupported executable.' }

    $peInfo = Read-PeInfo -Path $exePath
    if ([uint64]$peInfo.ImageBase -ne $ExpectedImageBase) { throw 'Unsupported executable.' }

    $patches = @(
        [pscustomobject]@{
            Name = 'Compatibility check'
            Address = [uint64]0x14449653C
            Expected = [byte[]](0x0F, 0x85, 0x09, 0x03, 0x00, 0x00)
            Replacement = [byte[]](0x0F, 0x80, 0x09, 0x03, 0x00, 0x00)
        },
        [pscustomobject]@{
            Name = 'Warning display'
            Address = [uint64]0x145EB59DC
            Expected = [byte[]](0x74, 0x45)
            Replacement = [byte[]](0xEB, 0x45)
        }
    )

    $stream = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        foreach ($patch in $patches) {
            $fileOffset = Get-FileOffsetForAddress -PeInfo $peInfo -Address $patch.Address -Length $patch.Expected.Length
            $stream.Position = $fileOffset
            $actual = $reader.ReadBytes($patch.Expected.Length)
            if (Test-ByteSequence -Actual $actual -Expected $patch.Expected) {
                $state = 'Original'
            }
            elseif (Test-ByteSequence -Actual $actual -Expected $patch.Replacement) {
                $state = 'Patched'
            }
            else {
                throw 'Unsupported executable.'
            }
            $patch | Add-Member -NotePropertyName FileOffset -NotePropertyValue $fileOffset -Force
            $patch | Add-Member -NotePropertyName State -NotePropertyValue $state -Force
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }

    $toApply = @($patches | Where-Object { $_.State -eq 'Original' })
    if ($toApply.Count -eq 0) {
        Write-Host ''
        Write-Host 'No patch needed - your game is already patched.' -ForegroundColor Green
        exit 0
    }

    Write-Host ''
    Write-Host 'A compatibility patch is needed for your game.' -ForegroundColor Yellow
    $answer = Read-Host 'Apply the patch now? [Y/N]'
    if ($answer -notmatch '^(Y|YES)$') {
        Write-Host 'Cancelled. No changes were made.' -ForegroundColor Yellow
        exit 0
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$exePath.backup-before-UE4SS-patch-$stamp"
    Copy-Item -LiteralPath $exePath -Destination $backupPath

    $writeStream = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writeStarted = $true
        foreach ($patch in $toApply) {
            $writeStream.Position = [int64]$patch.FileOffset
            $writeStream.Write($patch.Replacement, 0, $patch.Replacement.Length)
        }
        $writeStream.Flush($true)
    }
    finally {
        $writeStream.Dispose()
    }

    $verifyStream = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $verifyReader = [System.IO.BinaryReader]::new($verifyStream)
    try {
        foreach ($patch in $patches) {
            $verifyStream.Position = [int64]$patch.FileOffset
            $actual = $verifyReader.ReadBytes($patch.Replacement.Length)
            if (-not (Test-ByteSequence -Actual $actual -Expected $patch.Replacement)) { throw 'Verification failed.' }
        }
    }
    finally {
        $verifyReader.Dispose()
        $verifyStream.Dispose()
    }

    Write-Host ''
    Write-Host 'Patch applied successfully!' -ForegroundColor Green
    Write-Host 'A backup of the original game file was created.' -ForegroundColor Green
    Write-Host 'You can now launch the game.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Note: UE4SS, its mods, and the game-specific configuration must be installed separately.' -ForegroundColor Gray
}
catch {
    if ($backupPath -and $writeStarted) {
        try {
            Copy-Item -LiteralPath $backupPath -Destination $exePath -Force
            Write-Host ''
            Write-Host 'The patch could not be completed. The original game file has been restored.' -ForegroundColor Red
            Write-Host 'Please try again with the game closed.' -ForegroundColor Yellow
        }
        catch {
            Write-Host ''
            Write-Host 'The patch failed and automatic recovery was unsuccessful.' -ForegroundColor Red
            Write-Host 'Do not launch the game. Restore the backup file from the game folder.' -ForegroundColor Yellow
        }
    }
    elseif ($_.Exception.Message -eq 'Unsupported executable.') {
        Show-UnsupportedVersion
    }
    else {
        Write-Host ''
        Write-Host 'The patcher could not safely check or update the game file.' -ForegroundColor Red
        Write-Host 'No changes were made. Close the game and try again.' -ForegroundColor Yellow
    }
    exit 1
}
