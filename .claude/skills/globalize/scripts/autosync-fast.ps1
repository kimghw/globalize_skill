# autosync-fast.ps1 — SessionStart 훅 전용 초경량 진입점 (세션 기동 지연 최소화)
#
# 전역 스킬(사이드카 보유)의 원본·전역 트리 지문(파일수|총크기|최신mtime)을 캐시
# ($GlobalRoot\.globalize-autosync.json — globalize.ps1 autosync 가 기록)와 대조해,
# 변화가 없으면 본체 파싱 없이 즉시 종료한다(수백 ms). 변화가 있을 때만
# globalize.ps1 autosync(해시 동기화·registry 갱신·캐시 재기록)를 호출한다.
# 훅 등록은 globalize.ps1 install-hook 이 담당(이 파일을 가리킨다).

$ErrorActionPreference = 'SilentlyContinue'

if ([string]::IsNullOrEmpty($env:GLOBALIZE_ROOT)) { $GlobalRoot = Join-Path $env:USERPROFILE '.claude\skills' }
else                                              { $GlobalRoot = $env:GLOBALIZE_ROOT }
$SidecarName = '.globalize.json'
$fpPath = Join-Path $GlobalRoot '.globalize-autosync.json'

function Get-Fp([string]$Root, $Ex) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $n = 0; $size = [long]0; $max = [long]0
    foreach ($f in @(Get-ChildItem $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\')
        $segs = $rel -split '\\'
        if ($segs[-1] -ieq $SidecarName) { continue }
        $skip = $false
        foreach ($e in @($Ex)) { if ($e -and $segs -contains $e) { $skip = $true; break } }
        if ($skip) { continue }
        $n++; $size += $f.Length
        if ($f.LastWriteTimeUtc.Ticks -gt $max) { $max = $f.LastWriteTimeUtc.Ticks }
    }
    return "$n|$size|$max"
}

$dirty = $false
$cache = $null
if (Test-Path $fpPath) { try { $cache = [System.IO.File]::ReadAllText($fpPath) | ConvertFrom-Json } catch {} }
if ($null -eq $cache) { $dirty = $true }
else {
    $names = @()
    foreach ($d in @(Get-ChildItem $GlobalRoot -Directory -ErrorAction SilentlyContinue)) {
        $sp = Join-Path $d.FullName $SidecarName
        if (-not (Test-Path $sp)) { continue }
        $names += $d.Name
        $side = $null
        try { $side = [System.IO.File]::ReadAllText($sp) | ConvertFrom-Json } catch {}
        if ($null -eq $side -or -not (Test-Path ([string]$side.origin))) { $dirty = $true; break }
        $ex = @(@($side.exclude) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $fp = (Get-Fp ([string]$side.origin) $ex) + '/' + (Get-Fp $d.FullName $ex)
        $cv = $cache.PSObject.Properties[$d.Name]
        if ($null -eq $cv -or [string]$cv.Value -ne $fp) { $dirty = $true; break }
    }
    if (-not $dirty) {   # 캐시에는 있는데 전역에서 사라진 스킬(remove 후) → registry 갱신 필요
        foreach ($p in @($cache.PSObject.Properties)) {
            if ($names -notcontains $p.Name) { $dirty = $true; break }
        }
    }
}

if ($dirty) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'globalize.ps1') autosync
}
exit 0
