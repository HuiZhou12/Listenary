[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceData,

    [Parameter(Mandatory = $true)]
    [string]$DestinationData
)

#Requires -Version 5.1
$ErrorActionPreference = "Stop"

function Test-ProcessFromDirectory([string]$directory) {
    $prefix = [System.IO.Path]::GetFullPath($directory).TrimEnd('\') + '\'
    foreach ($processName in @("Listenary", "pure_music")) {
        foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            try {
                $processPath = [System.IO.Path]::GetFullPath($process.Path)
                if ($processPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
            catch {}
        }
    }
    return $false
}

$source = [System.IO.Path]::GetFullPath($SourceData)
$destination = [System.IO.Path]::GetFullPath($DestinationData).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($destination) -or
    $destination -eq [System.IO.Path]::GetPathRoot($destination) -or
    [System.IO.Path]::GetFileName($destination) -ne "Listenary") {
    throw "安装版数据目录无效：$destination"
}
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "所选目录不是有效的便携版数据目录。"
}
if (Test-ProcessFromDirectory (Split-Path $source -Parent)) {
    throw "导入数据前请先关闭正在运行的便携版 Listenary。"
}
if (Test-Path -LiteralPath $destination) {
    $existing = @(Get-ChildItem -LiteralPath $destination -Force)
    if ($existing.Count -gt 0) {
        throw "安装版数据目录不是空目录，已停止导入以避免覆盖现有数据。"
    }
}

$durableEntries = @(
    "settings",
    "db",
    "index.json",
    "library.sqlite",
    "library.sqlite-wal",
    "library.sqlite-shm",
    "playlists.json",
    "lyric_source.json"
)
$entries = @($durableEntries | ForEach-Object {
    $entry = Join-Path $source $_
    if (Test-Path -LiteralPath $entry) { Get-Item -LiteralPath $entry }
})
if ($entries.Count -eq 0) {
    throw "所选便携版中没有可迁移的用户数据。"
}

$destinationParent = Split-Path $destination -Parent
New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
$staging = Join-Path $destinationParent (".listenary-import-{0}" -f [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    foreach ($entry in $entries) {
        Copy-Item -LiteralPath $entry.FullName -Destination $staging -Recurse -Force
    }
    Get-ChildItem -LiteralPath $staging -Recurse -File -Filter "*.tmp.*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination
    }
    Move-Item -LiteralPath $staging -Destination $destination
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output "已导入 $($entries.Count) 项持久化数据。"
