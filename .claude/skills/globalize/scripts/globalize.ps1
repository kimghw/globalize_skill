# globalize.ps1 - 프로젝트 스킬을 전역(~/.claude/skills)에 복사/동기화하는 관리 도구
#
# 원칙: 원본(source of truth)은 항상 프로젝트 쪽 스킬 폴더. 전역에는 복사본만 둔다.
#       전역 복사본 안의 .globalize.json 사이드카에 원본 경로/제외 목록을 기록해두고,
#       sync 시 그 기록대로 원본 → 전역을 다시 복사(미러링)한다.
#
# 사이드카(.globalize.json): { name, origin, exclude, syncedAt }
#  - 사이드카가 있는 전역 스킬만 이 도구의 관리 대상이다. 없는 전역 스킬은 건드리지 않는다.
#  - exclude 에 지정된 이름과 일치하는 경로 세그먼트(폴더/파일)는 복사하지 않고,
#    전역 쪽에 이미 있어도 삭제하지 않는다 (데이터/자격증명 보호).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('list', 'add', 'sync', 'update', 'remove')]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Target,

    [string[]]$Exclude = @(),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# update = sync 별칭 (원본과 동일한지 해시 비교 후 다른 파일만 반영)
if ($Action -eq 'update') { $Action = 'sync' }

if ([string]::IsNullOrEmpty($env:GLOBALIZE_ROOT)) { $GlobalRoot = Join-Path $env:USERPROFILE '.claude\skills' }
else                                              { $GlobalRoot = $env:GLOBALIZE_ROOT }   # 테스트용 재정의
$SidecarName = '.globalize.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $GlobalRoot)) { New-Item -ItemType Directory -Path $GlobalRoot -Force | Out-Null }

function Assert-ValidName([string]$n) {
    if ([string]::IsNullOrEmpty($n) -or $n -notmatch '^[A-Za-z0-9._-]+$') {
        throw "스킬 이름은 영문/숫자/._- 만 사용할 수 있습니다: '$n'"
    }
}

# 스킬 폴더 아래의 파일 상대경로 목록 (제외 목록/사이드카 제외)
function Get-SkillFiles([string]$Root, [string[]]$Ex) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $out = @()
    foreach ($f in @(Get-ChildItem $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\')
        $segs = $rel -split '\\'
        if ($segs[-1] -ieq $SidecarName) { continue }
        $skip = $false
        foreach ($e in $Ex) { if ($segs -contains $e) { $skip = $true; break } }
        if (-not $skip) { $out += $rel }
    }
    return $out
}

function Get-Sha([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash }

function Read-Sidecar([string]$Dir) {
    $p = Join-Path $Dir $SidecarName
    if (-not (Test-Path $p)) { return $null }
    try { return Get-Content $p -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-Sidecar([string]$Dir, [string]$SkillName, [string]$Origin, [string[]]$Ex) {
    $obj = [ordered]@{
        name     = $SkillName
        origin   = $Origin
        exclude  = @($Ex)
        syncedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    $json = $obj | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $Dir $SidecarName), $json, $Utf8NoBom)
}

# 원본 → 전역 미러 동기화 (진행 메시지를 직접 출력)
function Sync-One([string]$Dst) {
    $side = Read-Sidecar $Dst
    if ($null -eq $side) { throw "'$Dst'에 사이드카($SidecarName)가 없습니다. globalize로 등록된 스킬이 아닙니다." }
    $origin = [string]$side.origin
    $ex = @($side.exclude)
    $skillName = Split-Path $Dst -Leaf
    if (-not (Test-Path $origin)) {
        Write-Output "!! '$skillName': 원본($origin)이 없습니다. 프로젝트가 이동/삭제되었으면 'add <새 경로>'로 다시 등록하세요."
        return
    }
    if (-not (Test-Path (Join-Path $origin 'SKILL.md'))) {
        Write-Output "!! '$skillName': 원본($origin)에 SKILL.md가 없습니다. 동기화를 건너뜁니다."
        return
    }

    $srcFiles = @(Get-SkillFiles $origin $ex)
    $copied = @(); $removed = @()

    foreach ($rel in $srcFiles) {
        $s = Join-Path $origin $rel
        $d = Join-Path $Dst $rel
        if (-not (Test-Path $d) -or (Get-Sha $s) -ne (Get-Sha $d)) {
            $dDir = Split-Path $d -Parent
            if (-not (Test-Path $dDir)) { New-Item -ItemType Directory -Path $dDir -Force | Out-Null }
            Copy-Item $s $d -Force
            $copied += $rel
        }
    }
    # 원본에서 사라진 파일은 전역에서도 제거 (제외 목록에 걸리는 경로는 보호)
    foreach ($rel in @(Get-SkillFiles $Dst $ex)) {
        if ($srcFiles -notcontains $rel) {
            Remove-Item (Join-Path $Dst $rel) -Force
            $removed += $rel
        }
    }
    # 빈 폴더 정리
    Get-ChildItem $Dst -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { @(Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0 } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

    Write-Sidecar $Dst ([string]$side.name) $origin $ex

    if ($copied.Count -eq 0 -and $removed.Count -eq 0) {
        Write-Output "'$skillName': 이미 최신 상태입니다 (원본과 동일)."
        return
    }
    Write-Output "'$skillName' 동기화 완료: 복사 $($copied.Count)개, 삭제 $($removed.Count)개"
    foreach ($r in $copied)  { Write-Output "  + $r" }
    foreach ($r in $removed) { Write-Output "  - $r" }
}

# 전역 스킬 폴더에서 globalize 관리 대상(사이드카 보유) 목록
function Get-LinkedSkills {
    @(Get-ChildItem $GlobalRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName $SidecarName) })
}

switch ($Action) {

    'list' {
        $dirs = @(Get-ChildItem $GlobalRoot -Directory -ErrorAction SilentlyContinue)
        if ($dirs.Count -eq 0) { Write-Output "전역 스킬 없음 ($GlobalRoot)"; break }
        Write-Output "전역 스킬 목록 ($GlobalRoot):"
        foreach ($d in $dirs) {
            $side = Read-Sidecar $d.FullName
            if ($null -eq $side) {
                Write-Output "  $($d.Name)  [전역 전용 - globalize 관리 대상 아님]"
                continue
            }
            $origin = [string]$side.origin
            $ex = @($side.exclude)
            $status = '동기화됨'
            if (-not (Test-Path $origin)) {
                $status = '!! 원본 없음'
            } else {
                $srcFiles = @(Get-SkillFiles $origin $ex)
                $dstFiles = @(Get-SkillFiles $d.FullName $ex)
                $stale = $false
                if ($srcFiles.Count -ne $dstFiles.Count) { $stale = $true }
                else {
                    foreach ($rel in $srcFiles) {
                        $dp = Join-Path $d.FullName $rel
                        if (-not (Test-Path $dp) -or (Get-Sha (Join-Path $origin $rel)) -ne (Get-Sha $dp)) { $stale = $true; break }
                    }
                }
                if ($stale) { $status = "원본과 다름 - 'sync $($d.Name)' 필요" }
            }
            $exMsg = ''
            if ($ex.Count -gt 0) { $exMsg = "  제외: $($ex -join ', ')" }
            Write-Output "  $($d.Name)  [$status]"
            Write-Output "    원본: $origin$exMsg  (마지막 동기화: $($side.syncedAt))"
        }
    }

    'add' {
        # add <스킬폴더경로 | 스킬이름> [-Exclude a,b] : 프로젝트 스킬을 전역에 등록
        # 이름만 주면 현재 작업 폴더의 .claude\skills\<이름> 에서 찾는다.
        if ([string]::IsNullOrEmpty($Target)) { throw "등록할 스킬 폴더 경로(또는 현재 프로젝트의 스킬 이름)를 지정하세요." }
        $src = $null
        if (Test-Path $Target -PathType Container) { $src = [System.IO.Path]::GetFullPath($Target) }
        else {
            $cand = Join-Path (Get-Location) ".claude\skills\$Target"
            if (Test-Path $cand -PathType Container) { $src = [System.IO.Path]::GetFullPath($cand) }
            else { throw "스킬 폴더를 찾을 수 없습니다: '$Target' (폴더 경로 또는 현재 프로젝트의 스킬 이름)" }
        }
        if (-not (Test-Path (Join-Path $src 'SKILL.md'))) { throw "'$src'에 SKILL.md가 없습니다. 스킬 폴더가 맞는지 확인하세요." }
        $skillName = Split-Path $src -Leaf
        Assert-ValidName $skillName
        $dst = Join-Path $GlobalRoot $skillName

        if ([System.IO.Path]::GetFullPath($dst).TrimEnd('\') -ieq $src.TrimEnd('\')) {
            throw "'$src'는 이미 전역 위치의 스킬입니다. 원본은 프로젝트 쪽에 두어야 합니다."
        }
        $existing = $null
        if (Test-Path $dst) { $existing = Read-Sidecar $dst }
        if ((Test-Path $dst) -and $null -eq $existing -and -not $Force) {
            throw "전역에 같은 이름의 스킬('$skillName')이 이미 있습니다 (globalize 관리 대상 아님). 덮어써서 관리 대상으로 만들려면 -Force 를 추가하세요."
        }
        if ($null -ne $existing -and [string]$existing.origin -ne $src) {
            Write-Output "기존 원본($($existing.origin)) → 새 원본($src)으로 변경합니다."
        }
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        Write-Sidecar $dst $skillName $src $Exclude
        Sync-One $dst
        Write-Output "'$skillName' 전역 등록 완료: $dst"
        Write-Output "(새 세션부터 어떤 프로젝트에서든 /$skillName 사용 가능. 원본 수정 후에는 'sync'로 재동기화하세요.)"
    }

    'sync' {
        # sync [이름] : 이름이 없으면 관리 대상 전체 동기화
        $targets = @()
        if ([string]::IsNullOrEmpty($Target)) { $targets = Get-LinkedSkills }
        else {
            Assert-ValidName $Target
            $d = Join-Path $GlobalRoot $Target
            if (-not (Test-Path $d)) { throw "전역 스킬 '$Target'을 찾을 수 없습니다. (list로 확인)" }
            $targets = @(Get-Item $d)
        }
        if ($targets.Count -eq 0) { Write-Output "globalize로 등록된 전역 스킬이 없습니다. ('add'로 등록)"; break }
        foreach ($t in $targets) { Sync-One $t.FullName }
    }

    'remove' {
        # remove <이름> : 전역 복사본만 제거 (원본은 그대로)
        if ([string]::IsNullOrEmpty($Target)) { throw "제거할 전역 스킬 이름을 지정하세요. (list로 확인)" }
        Assert-ValidName $Target
        $dst = Join-Path $GlobalRoot $Target
        if (-not (Test-Path $dst)) { throw "전역 스킬 '$Target'을 찾을 수 없습니다." }
        $side = Read-Sidecar $dst
        if ($null -eq $side) {
            throw "'$Target'은 globalize로 등록된 스킬이 아닙니다 (사이드카 없음). 실수로 다른 전역 스킬을 지우지 않도록 이 도구로는 제거하지 않습니다."
        }
        Remove-Item $dst -Recurse -Force
        Write-Output "'$Target' 전역 복사본을 제거했습니다. 원본($($side.origin))은 그대로 남아 있습니다."
    }
}
