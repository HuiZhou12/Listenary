# Capture real NetEase responses as Dart fixtures for
#   test/services/music_platform/netease_binding_recipes_test.dart
#
# Why: the EIGHT paste-ready bindings handed over for manual acceptance must be verified against
# BOTH hand-written samples and real responses. The two catch different bugs:
#   - hand-written samples prove "if you read the wrong field, you will notice";
#   - real responses prove "the path exists and yields the right value in the real shape".
# The real-response fixtures are therefore a GENERATED artifact; this script is how they are made.
#
# Usage (requires the local NetEase service to be running):
#     powershell -NoProfile -File tool/capture_netease_fixtures.ps1
#
# Rules:
#   - only the LISTS are trimmed (shape and values stay exactly as returned; nothing is invented);
#   - output is UTF-8 WITHOUT BOM, and this file is pure ASCII on purpose: Windows PowerShell 5.1
#     reads BOM-less files as ANSI, so non-ASCII comments here would break the parser.
#     Never use Set-Content for these files either: it re-encodes via the system code page and once
#     turned 466 characters of a UTF-8 doc into '?'.

param(
  [string]$BaseUrl = 'http://127.0.0.1:3000',
  [int]$Trim = 2,
  [string]$OutFile = 'test/services/music_platform/live_response_fixtures.g.dart'
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Upstream risk control sometimes answers 502 / "read ECONNRESET" for a burst of requests;
# retrying a few times with a growing pause is the known workaround (observed 2026-10-12).
# Nothing is invented: a failure that survives every retry still aborts the capture.
function Get-Json([string]$uri) {
  $attempts = 6
  for ($i = 1; $i -lt $attempts; $i++) {
    try {
      return Invoke-RestMethod -Uri $uri -TimeoutSec 25
    } catch {
      $wait = [Math]::Min(2 * $i, 8)
      Write-Host ("    retry {0}/{1} in {2}s: {3}" -f $i, ($attempts - 1), $wait, $_.Exception.Message.Trim())
      Start-Sleep -Seconds $wait
    }
  }
  return Invoke-RestMethod -Uri $uri -TimeoutSec 25
}

function Take($list, [int]$n) {
  if ($null -eq $list) { return @() }
  $count = [Math]::Min($n, @($list).Count)
  if ($count -le 0) { return @() }
  return @($list[0..($count - 1)])
}

Write-Host "capturing from $BaseUrl ..."
$search = Get-Json "$BaseUrl/search?keywords=%E6%B5%B7%E9%98%94%E5%A4%A9%E7%A9%BA&limit=$Trim"
$pl     = Get-Json "$BaseUrl/playlist/detail?id=19723756"
$top    = Get-Json "$BaseUrl/toplist"
$cat    = Get-Json "$BaseUrl/playlist/catlist"
$news   = Get-Json "$BaseUrl/personalized/newsong?limit=$Trim"
$col    = Get-Json "$BaseUrl/top/playlist?limit=$Trim"
# artist（2026-10-12 新增）：用搜索结果里的真实艺人 id 抓 /artists（形状 = artist + hotSongs）。
$artistId = $search.result.songs[0].artists[0].id
$artist   = Get-Json "$BaseUrl/artists?id=$artistId"
# album（2026-10-12 新增）：用同一首歌的专辑 id 抓 /album（形状 = album + 顶层 songs）。
$albumId  = $search.result.songs[0].album.id
$album    = Get-Json "$BaseUrl/album?id=$albumId"
# artistAlbums（2026-10-12 新增）：同一个艺人的专辑列表（形状 = hotAlbums 数组）。
$artistAlbums = Get-Json "$BaseUrl/artist/album?id=$artistId&limit=$Trim"
# artistSongs（2026-10-12 新增）：同一个艺人的单曲列表（形状 = songs 数组）。
$artistSongs = Get-Json "$BaseUrl/artist/songs?id=$artistId&limit=$Trim"
# newAlbums（2026-10-12 新增）：平台最近发布的专辑（形状 = albums 数组；实测认 limit ✓）。
$newAlbums = Get-Json "$BaseUrl/album/new?limit=$Trim"
# searchAlbums（2026-10-12 新增）：按关键词搜专辑（形状 = result.albums；type=10 是固定值 ✓）。
# 关键词沿用上面那次搜索用的同一个（%E6%B5%B7%E9%98%94%E5%A4%A9%E7%A9%BA = 海阔天空 ✓）。
$searchAlbums = Get-Json "$BaseUrl/cloudsearch?keywords=%E6%B5%B7%E9%98%94%E5%A4%A9%E7%A9%BA&type=10&limit=$Trim"
# searchArtists（2026-10-12 新增）：按关键词搜艺人（形状 = result.artists；type=100 是固定值 ✓）。
$searchArtists = Get-Json "$BaseUrl/cloudsearch?keywords=%E6%B5%B7%E9%98%94%E5%A4%A9%E7%A9%BA&type=100&limit=$Trim"

$blocks = [ordered]@{
  rawSearch = ([ordered]@{
      code   = $search.code
      result = [ordered]@{
        songs     = Take $search.result.songs $Trim
        hasMore   = $search.result.hasMore
        songCount = $search.result.songCount
      }
    } | ConvertTo-Json -Depth 30 -Compress)

  rawPlaylist = ([ordered]@{
      code     = $pl.code
      playlist = [ordered]@{
        id          = $pl.playlist.id
        name        = $pl.playlist.name
        coverImgUrl = $pl.playlist.coverImgUrl
        trackCount  = $pl.playlist.trackCount
        creator     = [ordered]@{ nickname = $pl.playlist.creator.nickname }
        tracks      = Take $pl.playlist.tracks $Trim
      }
    } | ConvertTo-Json -Depth 30 -Compress)

  rawChartList = ([ordered]@{
      code = $top.code
      list = Take $top.list $Trim
    } | ConvertTo-Json -Depth 30 -Compress)

  rawCategories = ([ordered]@{
      code = $cat.code
      sub  = Take $cat.sub ($Trim + 1)
    } | ConvertTo-Json -Depth 30 -Compress)

  rawNewSongs = ([ordered]@{
      code   = $news.code
      result = Take $news.result $Trim
    } | ConvertTo-Json -Depth 30 -Compress)

  rawCollection = ([ordered]@{
      code      = $col.code
      playlists = Take $col.playlists $Trim
      total     = $col.total
      more      = $col.more
    } | ConvertTo-Json -Depth 30 -Compress)

  # artist（2026-10-12）：标量在 artist 下、热门曲目在 hotSongs 下（各裁到 $Trim 条）。
  rawArtist = ([ordered]@{
      code     = $artist.code
      artist   = $artist.artist
      hotSongs = Take $artist.hotSongs $Trim
    } | ConvertTo-Json -Depth 30 -Compress)

  # album（2026-10-12）：标量在 album 下、曲目在**顶层** songs 下（裁到 $Trim 条）。
  rawAlbum = ([ordered]@{
      code  = $album.code
      album = $album.album
      songs = Take $album.songs $Trim
    } | ConvertTo-Json -Depth 30 -Compress)

  # artistAlbums（2026-10-12）：专辑就在 hotAlbums 数组里（裁到 $Trim 条）。
  rawArtistAlbums = ([ordered]@{
      code      = $artistAlbums.code
      hotAlbums = Take $artistAlbums.hotAlbums $Trim
      more      = $artistAlbums.more
    } | ConvertTo-Json -Depth 30 -Compress)

  # artistSongs（2026-10-12）：曲目就在 songs 数组里（裁到 $Trim 条）。
  rawArtistSongs = ([ordered]@{
      code  = $artistSongs.code
      songs = Take $artistSongs.songs $Trim
      total = $artistSongs.total
      more  = $artistSongs.more
    } | ConvertTo-Json -Depth 30 -Compress)

  # newAlbums（2026-10-12）：专辑就在 albums 数组里（裁到 $Trim 条）。
  rawNewAlbums = ([ordered]@{
      code   = $newAlbums.code
      albums = Take $newAlbums.albums $Trim
      total  = $newAlbums.total
    } | ConvertTo-Json -Depth 30 -Compress)

  # searchAlbums（2026-10-12）：专辑就在 result.albums 里（裁到 $Trim 条）。
  rawSearchAlbums = ([ordered]@{
      code   = $searchAlbums.code
      result = [ordered]@{
        albums     = Take $searchAlbums.result.albums $Trim
        albumCount = $searchAlbums.result.albumCount
      }
    } | ConvertTo-Json -Depth 30 -Compress)

  # searchArtists（2026-10-12）：艺人就在 result.artists 里（裁到 $Trim 条）。
  rawSearchArtists = ([ordered]@{
      code   = $searchArtists.code
      result = [ordered]@{
        artists     = Take $searchArtists.result.artists $Trim
        artistCount = $searchArtists.result.artistCount
      }
    } | ConvertTo-Json -Depth 30 -Compress)
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('// GENERATED by tool/capture_netease_fixtures.ps1 from real responses:')
[void]$sb.AppendLine('// shape and values come from the live service; only list lengths are trimmed (see -Trim).')
[void]$sb.AppendLine('// Re-generate with: powershell -NoProfile -File tool/capture_netease_fixtures.ps1')
[void]$sb.AppendLine('// ignore_for_file: prefer_single_quotes')
[void]$sb.AppendLine()
[void]$sb.AppendLine("import 'dart:convert';")
[void]$sb.AppendLine()
foreach ($name in $blocks.Keys) {
  [void]$sb.AppendLine("const _${name}Raw = r'''")
  [void]$sb.AppendLine($blocks[$name])
  [void]$sb.AppendLine("''';")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("Map<String, Object?> get $name => jsonDecode(_${name}Raw) as Map<String, Object?>;")
  [void]$sb.AppendLine()
}

$resolved = Join-Path (Get-Location) $OutFile
$dir = Split-Path $resolved -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
[System.IO.File]::WriteAllText($resolved, $sb.ToString(), $utf8)
Write-Host ("wrote {0} ({1} bytes, UTF-8 no BOM)" -f $OutFile, (Get-Item $resolved).Length)
Write-Host "next: flutter test test/services/music_platform/netease_binding_recipes_test.dart"
