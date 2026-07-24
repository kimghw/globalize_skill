# globalize.ps1 - 프로젝트 스킬을 전역(~/.claude/skills)에 복사/동기화하는 관리 도구
#
# 원칙: 원본(source of truth)은 항상 프로젝트 쪽 스킬 폴더. 전역에는 복사본만 둔다.
#       전역 복사본 안의 .globalize.json 사이드카에 원본 경로/제외 목록을 기록해두고,
#       sync 시 그 기록대로 원본 → 전역을 다시 복사(미러링)한다.
#
# 사이드카(.globalize.json): { name, origin, repo, repoPath, exclude, syncedAt }
#  - 사이드카가 있는 전역 스킬만 이 도구의 관리 대상이다. 없는 전역 스킬은 건드리지 않는다.
#  - repo/repoPath: 원본이 git 저장소 안에 있으면 원격 URL과 저장소 내 상대경로를 자동 기록
#    (다른 PC로 이전할 때 clone 안내에 사용).
#  - exclude 에 지정된 이름과 일치하는 경로 세그먼트(폴더/파일)는 복사하지 않고,
#    전역 쪽에 이미 있어도 삭제하지 않는다 (데이터/자격증명 보호).
#
# 레지스트리(registry.json): 관리 대상 전체 목록. globalize "원본" 폴더에 기록되므로
#   프로젝트 저장소에 커밋되어 다른 PC로 함께 이동한다. restore 가 이 파일로 복원한다.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('list', 'add', 'sync', 'update', 'remove', 'autosync', 'restore', 'install-hook')]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Target,

    [string[]]$Exclude = @(),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# update = sync 별칭 (원본과 동일한지 해시 비교 후 다른 파일만 반영)
if ($Action -eq 'update') { $Action = 'sync' }

# powershell -File 로 호출하면 "-Exclude a,b"가 배열로 분리되지 않고 문자열 하나로 들어온다 → 콤마 분리
$Exclude = @($Exclude | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ([string]::IsNullOrEmpty($env:GLOBALIZE_ROOT)) { $GlobalRoot = Join-Path $env:USERPROFILE '.claude\skills' }
else                                              { $GlobalRoot = $env:GLOBALIZE_ROOT }   # 테스트용 재정의
$SidecarName = '.globalize.json'
$RegistryName = 'registry.json'
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

# 원본이 git 저장소 안이면 원격 URL과 저장소 루트 기준 상대경로를 얻는다 (이전/clone 안내용)
function Get-RepoInfo([string]$Path) {
    $repo = ''; $repoPath = ''
    if ((Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path $Path)) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $top = git -C $Path rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $top) {
                $url = git -C $Path config --get remote.origin.url 2>$null
                if ($LASTEXITCODE -eq 0 -and $url) { $repo = ([string]$url).Trim() }
                $topFull = [System.IO.Path]::GetFullPath((([string]$top).Trim() -replace '/', '\')).TrimEnd('\')
                $pFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
                if ($pFull.Length -gt $topFull.Length) {
                    $repoPath = $pFull.Substring($topFull.Length).TrimStart('\') -replace '\\', '/'
                }
            }
        } finally { $ErrorActionPreference = $prevEap }
    }
    return @{ repo = $repo; repoPath = $repoPath }
}

function Write-Sidecar([string]$Dir, [string]$SkillName, [string]$Origin, [string[]]$Ex) {
    $ri = Get-RepoInfo $Origin
    $obj = [ordered]@{
        name     = $SkillName
        origin   = $Origin
        repo     = $ri.repo
        repoPath = $ri.repoPath
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
    $ex = @(@($side.exclude) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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

    # 안전망: 자격증명으로 의심되는 파일이 복사되었으면 경고 (제외 목록 누락 방지)
    $suspect = @($copied | Where-Object { $_ -match '(?i)(credential|secret|token|\.env$|password)' })
    if ($suspect.Count -gt 0) {
        Write-Output "!! 경고: 자격증명으로 의심되는 파일이 전역으로 복사되었습니다. 의도한 것이 아니면 -Exclude로 제외 후 다시 등록하세요:"
        foreach ($r in $suspect) { Write-Output "   $r" }
    }
}

# 전역 스킬 폴더에서 globalize 관리 대상(사이드카 보유) 목록
function Get-LinkedSkills {
    @(Get-ChildItem $GlobalRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName $SidecarName) })
}

# 레지스트리를 기록할 globalize "원본" 폴더 (전역 복사본은 sync 때 덮어써지므로 항상 원본에 쓴다)
function Get-GlobalizeOrigin {
    $side = Read-Sidecar (Join-Path $GlobalRoot 'globalize')
    if ($null -ne $side -and (Test-Path ([string]$side.origin))) { return [string]$side.origin }
    # 아직 전역화 전이면, 프로젝트 쪽에서 실행 중인 자기 자신의 스킬 폴더를 사용
    $selfSkill = Split-Path $PSScriptRoot -Parent
    $globalFull = [System.IO.Path]::GetFullPath($GlobalRoot).TrimEnd('\')
    if (-not ([System.IO.Path]::GetFullPath($selfSkill)).StartsWith($globalFull, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path (Join-Path $selfSkill 'SKILL.md'))) { return $selfSkill }
    return $null
}

# 관리 대상 전체 목록을 registry.json(globalize 원본)에 반영. 내용이 바뀌었으면 $true.
function Update-Registry {
    $originDir = Get-GlobalizeOrigin
    if ($null -eq $originDir) { return $false }
    $items = @()
    foreach ($d in @(Get-LinkedSkills | Sort-Object Name)) {
        $side = Read-Sidecar $d.FullName
        if ($null -eq $side) { continue }
        $items += [ordered]@{
            name     = [string]$side.name
            origin   = [string]$side.origin
            repo     = [string]$side.repo
            repoPath = [string]$side.repoPath
            exclude  = @(@($side.exclude) | Where-Object { $_ })
        }
    }
    $json = ConvertTo-Json ([ordered]@{ skills = $items }) -Depth 8
    $regPath = Join-Path $originDir $RegistryName
    $old = ''
    if (Test-Path $regPath) { $old = [System.IO.File]::ReadAllText($regPath) }
    if ($old -eq $json) { return $false }
    [System.IO.File]::WriteAllText($regPath, $json, $Utf8NoBom)
    return $true
}

# 레지스트리 갱신 후, 바뀌었으면 globalize 전역 복사본에도 즉시 반영 (restore 가 전역 복사본의 레지스트리를 읽으므로)
function Sync-Registry {
    $changed = Update-Registry
    if ($changed) {
        $g = Join-Path $GlobalRoot 'globalize'
        if (Test-Path (Join-Path $g $SidecarName)) { $null = Sync-One $g }
    }
    return $changed
}

# PC에서 .claude\skills\<이름> 폴더 검색 (restore 용, 원본 경로가 사라졌을 때)
# 기본: 모든 고정 드라이브의 최상위 폴더(시스템 폴더 제외)에서 3단계 깊이까지.
# GLOBALIZE_SEARCH_ROOTS 환경변수(세미콜론 구분)로 검색 루트를 직접 지정할 수 있다.
function Find-SkillOnPc([string]$Name) {
    $roots = @()
    if (-not [string]::IsNullOrEmpty($env:GLOBALIZE_SEARCH_ROOTS)) {
        $roots = @($env:GLOBALIZE_SEARCH_ROOTS -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else {
        $skipTop = '^(Windows|Program Files|Program Files \(x86\)|ProgramData|\$Recycle\.Bin|System Volume Information|Recovery|PerfLogs)$'
        foreach ($drv in @(Get-PSDrive -PSProvider FileSystem | Where-Object { $null -eq $_.DisplayRoot })) {
            foreach ($d in @(Get-ChildItem $drv.Root -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($d.Name -notmatch $skipTop) { $roots += $d.FullName }
            }
        }
    }
    $globalFull = [System.IO.Path]::GetFullPath($GlobalRoot).TrimEnd('\')
    $hits = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($cd in @(Get-ChildItem $root -Directory -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue -Filter '.claude')) {
            if ($cd.FullName -match '\\(node_modules|AppData|\.git)\\') { continue }
            $skill = Join-Path $cd.FullName "skills\$Name"
            if ((Test-Path (Join-Path $skill 'SKILL.md')) -and
                -not ([System.IO.Path]::GetFullPath($skill)).StartsWith($globalFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                $hits += $skill
            }
        }
    }
    return @($hits | Select-Object -Unique)
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
            $ex = @(@($side.exclude) | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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
            $extra = ''
            if ($ex.Count -gt 0) { $extra += "  제외: $($ex -join ', ')" }
            if ($side.PSObject.Properties['repo'] -and $side.repo) { $extra += "  repo: $($side.repo)" }
            Write-Output "  $($d.Name)  [$status]"
            Write-Output "    원본: $origin$extra  (마지막 동기화: $($side.syncedAt))"
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
        $null = Sync-Registry
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
        if (Sync-Registry) { Write-Output "registry.json 갱신됨 (관리 목록/저장소 정보 변경)" }
    }

    'autosync' {
        # 세션 시작 훅용: 전체 동기화 + 레지스트리 갱신. 변경/문제가 있을 때만 출력하고, 절대 실패로 끝나지 않는다.
        $msgs = @()
        foreach ($t in @(Get-LinkedSkills)) {
            try {
                $msgs += @(@(Sync-One $t.FullName) | Where-Object { $_ -and $_ -notmatch '이미 최신 상태' })
            } catch { $msgs += "!! $($t.Name): $($_.Exception.Message)" }
        }
        try { if (Sync-Registry) { $msgs += "registry.json 갱신됨" } }
        catch { $msgs += "!! registry: $($_.Exception.Message)" }
        $msgs = @($msgs | Where-Object { $_ })
        if ($msgs.Count -gt 0) {
            Write-Output "[globalize] 세션 시작 동기화:"
            foreach ($m in $msgs) { Write-Output "  $m" }
        }
        exit 0
    }

    'restore' {
        # restore [레지스트리경로] : 새 PC 이전 시 registry.json 기반으로 전역 스킬 일괄 복원.
        # 원본 경로 확인 → 없으면 PC 검색 → 그래도 없으면 git clone 안내.
        $regPath = $Target
        if ([string]::IsNullOrEmpty($regPath)) { $regPath = Join-Path (Split-Path $PSScriptRoot -Parent) $RegistryName }
        if (-not (Test-Path $regPath)) { throw "레지스트리 파일이 없습니다: $regPath ('add'로 스킬을 등록하면 자동 생성됩니다)" }
        $reg = Get-Content $regPath -Raw | ConvertFrom-Json
        $entries = @($reg.skills)
        if ($entries.Count -eq 0) { Write-Output "레지스트리에 등록된 스킬이 없습니다."; break }
        foreach ($e in $entries) {
            $name = [string]$e.name
            Assert-ValidName $name
            $ex = @(@($e.exclude) | Where-Object { $_ })
            $dst = Join-Path $GlobalRoot $name
            if (Test-Path (Join-Path $dst $SidecarName)) { Write-Output "'$name': 이미 전역에 등록되어 있습니다."; continue }
            if (Test-Path $dst) { Write-Output "!! '$name': 전역에 같은 이름의 비관리 스킬이 있습니다. 확인 후 'add <경로> -Force'로 직접 등록하세요."; continue }
            $src = $null
            if ($e.origin -and (Test-Path ([System.IO.Path]::Combine([string]$e.origin, 'SKILL.md')))) { $src = [string]$e.origin }
            else {
                Write-Output "'$name': 원본($($e.origin))이 없어 PC에서 검색합니다..."
                $cands = @(Find-SkillOnPc $name)
                if ($cands.Count -eq 1) { $src = $cands[0]; Write-Output "'$name': 발견 → $src" }
                elseif ($cands.Count -gt 1) {
                    Write-Output "!! '$name': 후보가 여러 개입니다. 원하는 경로로 'add <경로>'를 직접 실행하세요:"
                    foreach ($c in $cands) { Write-Output "   $c" }
                    continue
                }
            }
            if ($null -eq $src) {
                if ($e.repo) {
                    Write-Output "!! '$name': PC에서 찾지 못했습니다. 저장소를 복제한 뒤 등록하세요:"
                    Write-Output "   git clone $($e.repo)  →  add <클론경로>/$($e.repoPath)"
                } else {
                    Write-Output "!! '$name': PC에서 찾지 못했고 저장소 정보도 없습니다. 'add <경로>'로 직접 등록하세요."
                }
                continue
            }
            New-Item -ItemType Directory -Path $dst -Force | Out-Null
            Write-Sidecar $dst $name $src $ex
            $null = Sync-One $dst
            Write-Output "'$name' 복원 완료: $src → $dst"
        }
        $null = Sync-Registry
        Write-Output "(전역 스킬은 새 세션부터 인식됩니다. 'install-hook'으로 세션 시작 자동 동기화도 설정하세요.)"
    }

    'install-hook' {
        # install-hook : 사용자 전역 settings.json 에 SessionStart 훅(autosync) 등록.
        # 기존 globalize 훅이 있으면 최신 형태로 교체한다 (멱등).
        $scriptPath = Join-Path $GlobalRoot 'globalize\scripts\globalize.ps1'
        if (-not (Test-Path $scriptPath)) { throw "globalize가 전역에 등록되어 있지 않습니다. 먼저 'add globalize'로 전역 등록하세요." }
        $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
        if ($null -ne $env:GLOBALIZE_SETTINGS) { $settingsPath = $env:GLOBALIZE_SETTINGS }   # 테스트용 재정의

        $settings = $null
        if (Test-Path $settingsPath) { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json }
        if ($null -eq $settings) { $settings = [pscustomobject]@{} }

        $newHook = [pscustomobject]@{
            type          = 'command'
            command       = 'powershell'
            args          = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, 'autosync')
            timeout       = 60
            async         = $true
            statusMessage = '전역 스킬 동기화 중...'
        }

        # 기존 SessionStart 항목에서 globalize 훅만 걷어내고 나머지는 보존
        $kept = @()
        if ($settings.PSObject.Properties['hooks'] -and $settings.hooks.PSObject.Properties['SessionStart']) {
            foreach ($m in @($settings.hooks.SessionStart)) {
                $rest = @(@($m.hooks) | Where-Object { "$($_.command) $($_.args -join ' ')" -notmatch 'globalize\.ps1' })
                if ($rest.Count -gt 0) { $m.hooks = $rest; $kept += $m }
            }
        }
        $kept += [pscustomobject]@{ hooks = @($newHook) }

        if (-not $settings.PSObject.Properties['hooks']) {
            $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
        }
        if (-not $settings.hooks.PSObject.Properties['SessionStart']) {
            $settings.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue @()
        }
        $settings.hooks.SessionStart = $kept

        $json = $settings | ConvertTo-Json -Depth 32
        [System.IO.File]::WriteAllText($settingsPath, $json, $Utf8NoBom)
        Write-Output "SessionStart 훅 등록 완료: $settingsPath"
        Write-Output "  실행 명령: powershell -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" autosync"
        Write-Output "(새 세션 시작마다 원본 → 전역 자동 동기화. 다음 세션부터 적용됩니다.)"
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
        $null = Sync-Registry
        Write-Output "'$Target' 전역 복사본을 제거했습니다. 원본($($side.origin))은 그대로 남아 있습니다."
    }
}
