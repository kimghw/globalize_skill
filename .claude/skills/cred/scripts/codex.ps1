# codex.ps1 - Codex CLI 계정 자격증명(~/.codex/auth.json) 프로필 관리
# 주의: 이 스크립트는 토큰 값을 절대 출력하지 않는다 (메타데이터만 표시).
#
# cred.ps1(Claude)과 같은 액션 체계를 쓰되 대상 파일과 저장소만 다르다:
#   대상 파일 : ~/.codex/auth.json                       (CODEX_AUTH_FILE 환경변수로 재정의 가능)
#   저장소    : <Claude 프로필 저장소>\_codex\<이름>\      (CRED_CODEX_STORE 환경변수로 재정의 가능)
#               cred.ps1 은 '_'로 시작하는 폴더를 프로필로 보지 않으므로 두 저장소가 섞이지 않는다.
#
# 액션:
#   (인자 없음)            프로필 목록을 번호 메뉴로 보여주고 선택한 계정으로 전환 (대화형)
#   list                   현재 활성 계정과 프로필 목록
#   save <이름>            현재 활성 auth.json → 프로필 저장
#   use <이름>             프로필 → 활성 auth.json (계정 전환)
#   export <이름> [폴더]   프로필 → 이동용 패키지(zip) 추출 (다른 PC로 가져가기)
#   import <파일> [이름]   패키지(zip)/폴더/auth.json 파일 → 프로필 등록 (add 는 별칭)
#   backup                 현재 auth.json 백업
#   whoami [이름]          토큰 안의 계정(이메일/플랜)을 로컬에서 해독해 표시 (API 호출 없음)
#   _status                (내부용) cred.ps1 의 통합 메뉴·list 가 쓰는 상태 객체 — 문구 출력 없음
# cred.ps1 이 'codex <액션>' 으로 이 스크립트를 부르므로 사용자는 cred.ps1 하나만 써도 된다.
#
# 프로필 구조:  <이름>\auth.json     - ~/.codex/auth.json 사본 (토큰 포함)
#               <이름>\account.json  - 계정 정보(이메일/플랜, 토큰 없음) - 토큰(JWT)에서 해독해 기록
#               <이름>\<이메일>       - 계정 표시용 빈 마커 파일 (탐색기 확인용, 자동 관리)
# Claude 와 달리 계정 식별 정보(이메일·플랜)가 토큰(id_token/access_token JWT) 안에 들어 있어
# 별도 캐시 파일 복원이나 API 조회 없이 로컬 해독만으로 계정을 알 수 있다.
# auth_mode 가 apikey(OPENAI_API_KEY 만 있음)인 파일도 프로필로 다룰 수 있으나 이메일은 없다.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'save', 'use', 'export', 'import', 'add', 'backup', 'whoami', '_status')]
    [string]$Action = '',

    [Parameter(Position = 1)]
    [string]$Name,

    [Parameter(Position = 2)]
    [string]$Name2,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# 기본 경로 (테스트용으로 환경변수 재정의 가능)
if ([string]::IsNullOrEmpty($env:CODEX_AUTH_FILE)) { $AuthFile = Join-Path $env:USERPROFILE '.codex\auth.json' }
else                                               { $AuthFile = $env:CODEX_AUTH_FILE }
# 저장소: Claude 프로필 저장소(cred.ps1 의 $Store, CRED_STORE 로 재정의)의 _codex 하위.
if ([string]::IsNullOrEmpty($env:CRED_CODEX_STORE)) {
    if ([string]::IsNullOrEmpty($env:CRED_STORE)) { $ClaudeStore = 'E:\dev\globalize_skill\.claude\skills\cred\profiles' }
    else                                          { $ClaudeStore = $env:CRED_STORE }
    $Store = Join-Path $ClaudeStore '_codex'
} else {
    $Store = $env:CRED_CODEX_STORE
}
$BackupDir = Join-Path $Store '_backups'

if (-not (Test-Path $Store))     { New-Item -ItemType Directory -Path $Store -Force | Out-Null }
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Web.Extensions
$Ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Ser.MaxJsonLength = [int]::MaxValue

function Convert-Epoch([long]$v) {
    if ($v -gt 1000000000000) { return [DateTimeOffset]::FromUnixTimeMilliseconds($v).ToLocalTime() }
    else                      { return [DateTimeOffset]::FromUnixTimeSeconds($v).ToLocalTime() }
}

# JWT 의 payload(두 번째 조각)만 해독해 객체로 반환. 서명 검증은 하지 않는다(로컬 표시용). 실패하면 $null.
function ConvertFrom-JwtPayload([string]$Token) {
    if ([string]::IsNullOrEmpty($Token)) { return $null }
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $p = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

# auth.json 을 읽어 토큰을 제외한 요약을 반환.
#   @{ valid; mode('chatgpt'|'apikey'); email; plan; accessExp; refreshExp; lastRefresh }
# 파일이 없거나 JSON 이 아니면 $null, 형식이 맞지 않으면 valid=$false.
function Get-AuthInfo([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { $j = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if ($null -eq $j) { return $null }
    $info = @{ valid = $false; mode = $null; email = $null; plan = $null; accessExp = $null; refreshExp = $null; lastRefresh = $null }
    $t = $j.tokens
    if ($null -ne $t -and -not [string]::IsNullOrEmpty($t.access_token) -and -not [string]::IsNullOrEmpty($t.refresh_token)) {
        $info.valid = $true
        $info.mode = 'chatgpt'
        $idc = ConvertFrom-JwtPayload $t.id_token
        $acc = ConvertFrom-JwtPayload $t.access_token
        $email = $null
        if ($null -ne $idc -and $idc.email) { $email = [string]$idc.email }
        if (-not $email -and $null -ne $acc) {
            $prof = $acc.'https://api.openai.com/profile'
            if ($null -ne $prof -and $prof.email) { $email = [string]$prof.email }
        }
        $info.email = $email
        foreach ($c in @($acc, $idc)) {
            if ($null -eq $c) { continue }
            $a = $c.'https://api.openai.com/auth'
            if ($null -ne $a -and $a.chatgpt_plan_type) { $info.plan = [string]$a.chatgpt_plan_type; break }
        }
        if ($null -ne $acc -and $acc.exp) { $info.accessExp = Convert-Epoch ([long]$acc.exp) }
        $ref = ConvertFrom-JwtPayload $t.refresh_token
        if ($null -ne $ref -and $ref.exp) { $info.refreshExp = Convert-Epoch ([long]$ref.exp) }
    } elseif (-not [string]::IsNullOrEmpty($j.OPENAI_API_KEY)) {
        $info.valid = $true
        $info.mode = 'apikey'
    }
    if ($j.last_refresh) { $info.lastRefresh = [string]$j.last_refresh }
    return $info
}

function Test-AuthStructure([string]$Path) {
    $i = Get-AuthInfo $Path
    return ($null -ne $i -and $i.valid)
}

# 토큰 값은 제외하고 메타데이터만 요약
function Get-AuthMeta($Info) {
    if ($null -eq $Info -or -not $Info.valid) { return '(토큰 없음/형식 오류)' }
    if ($Info.mode -eq 'apikey') { return 'API 키 모드 (계정 이메일 없음)' }
    $plan = '?'
    if ($Info.plan) { $plan = $Info.plan }
    $s = "ChatGPT/$plan"
    if ($null -ne $Info.refreshExp) {
        $expired = ''
        if ($Info.refreshExp -lt (Get-Date)) { $expired = ' [만료됨!]' }
        $s += ", refresh토큰 만료 $($Info.refreshExp.ToString('yyyy-MM-dd'))$expired"
    } elseif ($null -ne $Info.accessExp) {
        $expired = ''
        if ($Info.accessExp -lt (Get-Date)) { $expired = ' [만료됨 - 다음 실행 때 자동 갱신 시도]' }
        $s += ", access토큰 만료 $($Info.accessExp.ToString('yyyy-MM-dd'))$expired"
    }
    if ($Info.lastRefresh) {
        try {
            $lrStr = $Info.lastRefresh -replace '(\.\d{1,7})\d*', '$1'
            $lr = [DateTimeOffset]::Parse($lrStr, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime()
            $s += ", 마지막 갱신 $($lr.ToString('yyyy-MM-dd'))"
        } catch {}
    }
    return $s
}

function Get-Sha([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash }

function Assert-ValidName([string]$n) {
    if ([string]::IsNullOrEmpty($n) -or $n -notmatch '^[A-Za-z0-9._-]+$') {
        throw "프로필 이름은 영문/숫자/._- 만 사용할 수 있습니다: '$n'"
    }
    if ($n -like '_*') { throw "'_'로 시작하는 이름은 예약되어 있습니다 (_backups, _exports 등 내부용)." }
    if ($n -match '^\.+$') { throw "'.'만으로 된 이름은 사용할 수 없습니다: '$n'" }
}

function Backup-Current([string]$Reason) {
    if (-not (Test-Path $AuthFile)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $BackupDir "$stamp-$Reason.json"
    Copy-Item $AuthFile $dest -Force
    return $dest
}

function Get-ProfileDir([string]$ProfileName)      { Join-Path $Store $ProfileName }
function Get-ProfileAuthPath([string]$ProfileName) { Join-Path (Get-ProfileDir $ProfileName) 'auth.json' }
function Get-SidecarPath([string]$ProfileName)     { Join-Path (Get-ProfileDir $ProfileName) 'account.json' }

# 사이드카 읽기: @{ email; plan; mode; source } 또는 $null
function Read-Sidecar([string]$ProfileName) {
    $p = Get-SidecarPath $ProfileName
    if (-not (Test-Path $p)) { return $null }
    try {
        $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{ email = [string]$j.email; plan = [string]$j.plan; mode = [string]$j.mode; source = [string]$j.source }
    } catch { return $null }
}

# 프로필 폴더 안에 계정 이메일을 파일명으로 하는 빈 마커 파일을 유지한다 (탐색기 확인용).
# auth.json / account.json 외의 파일은 마커로 간주하고 갱신 시 삭제한다.
function Update-EmailMarker([string]$ProfileName) {
    $dir = Get-ProfileDir $ProfileName
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('auth.json', 'account.json') } |
        ForEach-Object { try { Remove-Item $_.FullName -Force } catch {} }
    $side = Read-Sidecar $ProfileName
    if ($null -ne $side -and $side.email -and $side.email -notmatch '[\\/:*?"<>|\s]') {
        $marker = Join-Path $dir $side.email
        [System.IO.File]::WriteAllText($marker, '', $Utf8NoBom)
    }
}

# 프로필의 auth.json 을 해독해 사이드카(account.json)를 (재)생성한다. 이메일 없으면(API 키 모드) 그 사실을 기록.
function Write-SidecarFromAuth([string]$ProfileName) {
    $info = Get-AuthInfo (Get-ProfileAuthPath $ProfileName)
    if ($null -eq $info -or -not $info.valid) { return $null }
    $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $d['source']  = [string]'jwt'
    $d['savedAt'] = [string](Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $d['mode']    = [string]$info.mode
    if ($info.email) { $d['email'] = [string]$info.email }
    if ($info.plan)  { $d['plan']  = [string]$info.plan }
    [System.IO.File]::WriteAllText((Get-SidecarPath $ProfileName), $Ser.Serialize($d), $Utf8NoBom)
    Update-EmailMarker $ProfileName
    return $info
}

# 프로필의 계정 이메일: 사이드카 우선, 없으면 auth.json 해독
function Get-ProfileEmail([string]$ProfileName) {
    $side = Read-Sidecar $ProfileName
    if ($null -ne $side -and $side.email) { return $side.email }
    $info = Get-AuthInfo (Get-ProfileAuthPath $ProfileName)
    if ($null -ne $info -and $info.email) { return $info.email }
    return $null
}

function Get-ProfileNames {
    return @(Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notlike '_*' } | ForEach-Object { $_.Name })
}

# use/export 전 자동 동기화: 현재 활성 토큰을 그 계정(이메일)의 프로필에 저장해 스냅샷을 최신으로 유지한다.
# Codex 도 refresh 시 토큰이 갱신(last_refresh)되므로, 마지막 사용 시점의 토큰을 프로필에 보관해둬야
# 다음에 그 계정으로 돌아올 때 재로그인이 필요 없다.
function Sync-ActiveToProfile {
    $cur = Get-AuthInfo $AuthFile
    if ($null -eq $cur -or -not $cur.valid) { return }
    if ([string]::IsNullOrEmpty($cur.email)) {
        Write-Output "(자동 동기화 건너뜀: 현재 토큰에 계정 이메일이 없어(API 키 모드 등) 어느 프로필인지 알 수 없습니다.)"
        return
    }
    $found = @()
    foreach ($n in (Get-ProfileNames)) {
        if ((Get-ProfileEmail $n) -eq $cur.email) { $found += $n }
    }
    if ($found.Count -eq 0) {
        Write-Output "(자동 동기화 건너뜀: 현재 계정($($cur.email))에 해당하는 프로필이 없습니다. 'save <이름>'으로 저장해두면 다음 전환 때 재로그인이 줄어듭니다.)"
        return
    }
    if ($found.Count -gt 1) {
        Write-Output "(자동 동기화 건너뜀: 계정 $($cur.email) 이 여러 프로필($($found -join ', '))에 기록되어 있어 대상을 정할 수 없습니다.)"
        return
    }
    $syncName = $found[0]
    $dest = Get-ProfileAuthPath $syncName
    if ((Test-Path $dest) -and (Get-Sha $dest) -eq (Get-Sha $AuthFile)) { return }   # 이미 최신
    if (Test-Path $dest) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item $dest (Join-Path $BackupDir "$stamp-autosync-$syncName.json") -Force
    }
    $destDir = Get-ProfileDir $syncName
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item $AuthFile $dest -Force
    Write-SidecarFromAuth $syncName | Out-Null
    Write-Output "자동 동기화: 현재 토큰(계정 $($cur.email))을 프로필 '$syncName'에 저장했습니다 (이전 토큰은 _backups에 백업)."
}

function Write-RestartNotice {
    Write-Output ""
    Write-Output "!! 적용하려면 실행 중인 codex 세션(CLI · VS Code 확장 · Codex 앱)을 재시작해야 합니다. 확인: codex login status"
    Write-Output "   (실행 중인 프로세스가 토큰을 갱신하면서 교체한 파일을 되돌릴 수 있으니, 전환 전에 닫아 두는 것이 안전합니다.)"
}

# 인자 없이 실행: 프로필 목록을 번호 메뉴로 보여주고 선택한 계정으로 전환한다 (대화형).
if ([string]::IsNullOrEmpty($Action)) {
    $menuProfiles = @(Get-ProfileNames)
    if ($menuProfiles.Count -eq 0) {
        Write-Output "저장된 codex 프로필이 없습니다. 'save <이름>'으로 현재 계정을 먼저 저장하세요."
        exit 0
    }
    $menuActiveHash = $null
    if (Test-AuthStructure $AuthFile) { $menuActiveHash = Get-Sha $AuthFile }
    Write-Output "전환할 codex 계정을 선택하세요:"
    for ($i = 0; $i -lt $menuProfiles.Count; $i++) {
        $pname = $menuProfiles[$i]
        $authPath = Get-ProfileAuthPath $pname
        $mark = '  '
        if ($menuActiveHash -and (Test-Path $authPath) -and (Get-Sha $authPath) -eq $menuActiveHash) { $mark = '* ' }
        $email = Get-ProfileEmail $pname
        if (-not $email) { $email = '(계정 미기록)' }
        $meta = Get-AuthMeta (Get-AuthInfo $authPath)
        Write-Output ("  {0}) {1}{2}  {3}  -  {4}" -f ($i + 1), $mark, $pname, $email, $meta)
    }
    Write-Output "  (* = 현재 활성 토큰과 동일)"
    try { $sel = Read-Host "번호 입력 (Enter=취소)" }
    catch { throw "대화형 입력을 사용할 수 없는 환경입니다. 'codex.ps1 use <이름>'처럼 액션을 지정해 실행하세요." }
    if ([string]::IsNullOrWhiteSpace($sel)) { Write-Output "취소했습니다."; exit 0 }
    $selNum = 0
    if (-not [int]::TryParse($sel.Trim(), [ref]$selNum) -or $selNum -lt 1 -or $selNum -gt $menuProfiles.Count) {
        throw "1~$($menuProfiles.Count) 범위의 번호를 입력하세요: '$sel'"
    }
    $Action = 'use'
    $Name = $menuProfiles[$selNum - 1]
    Write-Output ""
    Write-Output "→ 'use $Name' 실행"
}

switch ($Action) {

    'list' {
        Write-Output "[토큰] = 인증키(<프로필>\auth.json) - 실제 인증과 사용량이 이 계정으로 나감"
        Write-Output "[계정] = 토큰(JWT)에서 해독한 이메일/플랜(<프로필>\account.json) - 표시용, 토큰 없음"
        Write-Output ""
        $activeHash = $null
        Write-Output "현재 활성 ($AuthFile):"
        $cur = Get-AuthInfo $AuthFile
        if ($null -eq $cur) {
            if (Test-Path $AuthFile) { Write-Output "  토큰: (파일이 있으나 JSON 형식이 아님)" }
            else                     { Write-Output "  토큰: (없음 - 로그아웃 상태)" }
        } elseif (-not $cur.valid) {
            Write-Output "  토큰: (파일이 있으나 형식이 올바르지 않음)"
        } else {
            $activeHash = Get-Sha $AuthFile
            Write-Output ("  토큰: " + (Get-AuthMeta $cur))
            if ($cur.email) { Write-Output "  계정: $($cur.email)" }
            else            { Write-Output "  계정: (이메일 없음 - API 키 모드)" }
        }
        Write-Output ""
        $profiles = @(Get-ProfileNames)
        if ($profiles.Count -eq 0) {
            Write-Output "저장된 codex 프로필 없음. 'save <이름>'으로 현재 계정을 저장하세요."
        } else {
            Write-Output "codex 프로필 목록 ($Store):"
            foreach ($pname in $profiles) {
                $authPath = Get-ProfileAuthPath $pname
                $hasAuth = Test-Path $authPath
                $isActive = ($activeHash -and $hasAuth -and (Get-Sha $authPath) -eq $activeHash)
                $mark = '  '
                if ($isActive) { $mark = '* ' }
                Write-Output "$mark$pname"
                $info = Get-AuthInfo $authPath
                if ($hasAuth -and $null -ne $info -and $info.valid) {
                    Write-Output ("    토큰: " + (Get-AuthMeta $info))
                } elseif ($hasAuth) {
                    Write-Output "    토큰: (형식 오류)"
                } else {
                    Write-Output "    토큰: (없음 - auth.json 누락)"
                }
                $email = Get-ProfileEmail $pname
                if ($email) {
                    $side = Read-Sidecar $pname
                    if ($null -ne $side -and $side.email) { Write-Output "    계정: $email" }
                    else { Write-Output "    계정: $email (토큰에서 해독 - account.json 없음, save/import 시 자동 생성)" }
                } elseif ($null -ne $info -and $info.valid -and $info.mode -eq 'apikey') {
                    Write-Output "    계정: (API 키 모드 - 이메일 없음)"
                } else {
                    Write-Output "    계정: (미확인 - 토큰에서 이메일을 읽지 못함)"
                }
            }
            Write-Output ""
            Write-Output "(* = 현재 활성 토큰과 동일)"
        }
    }

    'save' {
        # save <이름> : 현재 활성 auth.json 을 프로필로 저장
        Assert-ValidName $Name
        if (-not (Test-Path $AuthFile)) { throw "현재 codex 자격증명 파일이 없습니다: $AuthFile (codex login 으로 먼저 로그인하세요)" }
        if (-not (Test-AuthStructure $AuthFile)) { throw "현재 codex 자격증명 파일의 형식이 올바르지 않습니다." }
        $dest = Get-ProfileAuthPath $Name
        if (Test-Path $dest) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item $dest (Join-Path $BackupDir "$stamp-profile-$Name.json") -Force
            Write-Output "기존 프로필 '$Name'을 덮어씁니다 (이전 토큰은 _backups에 백업됨)."
        }
        $destDir = Get-ProfileDir $Name
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $AuthFile $dest -Force
        $info = Write-SidecarFromAuth $Name
        $acctMsg = '계정: (이메일 없음 - API 키 모드)'
        if ($null -ne $info -and $info.email) { $acctMsg = "계정: $($info.email)" }
        Write-Output ("codex 프로필 '$Name' 저장 완료  -  $acctMsg  -  " + (Get-AuthMeta $info))
    }

    'use' {
        # use <이름> : 프로필로 codex 계정 전환
        if ([string]::IsNullOrEmpty($Name)) { throw "전환할 프로필 이름을 지정하세요. (list로 확인)" }
        try { Assert-ValidName $Name } catch {
            if (Test-Path $Name) { throw "use는 저장된 프로필만 전환합니다. 외부 파일/패키지는 먼저 'import $Name <이름>'으로 등록한 뒤 use 하세요." }
            throw
        }
        $src = Get-ProfileAuthPath $Name
        if (-not (Test-Path $src)) { throw "codex 프로필 '$Name'을 찾을 수 없습니다. (list로 확인)" }
        if (-not (Test-AuthStructure $src)) { throw "'$src' 파일이 올바른 auth.json 형식이 아닙니다." }

        # 교체 전에 현재 토큰을 그 계정의 프로필에 자동 저장 (토큰 갱신 대비)
        Sync-ActiveToProfile

        $alreadyActive = $false
        if (Test-AuthStructure $AuthFile) {
            if ((Get-Sha $AuthFile) -eq (Get-Sha $src)) { $alreadyActive = $true }
        }

        if (-not $alreadyActive) {
            $bak = Backup-Current 'pre-use'
            $authDir = Split-Path $AuthFile -Parent
            if (-not (Test-Path $authDir)) { New-Item -ItemType Directory -Path $authDir -Force | Out-Null }
            Copy-Item $src $AuthFile -Force
            if ($bak) { Write-Output "기존 자격증명 백업: $bak" }
            $info = Get-AuthInfo $AuthFile
            $acct = '(이메일 없음)'
            if ($null -ne $info -and $info.email) { $acct = $info.email }
            Write-Output ("교체 완료  -  계정: $acct  -  " + (Get-AuthMeta $info))
            Write-RestartNotice
        } else {
            Write-Output "이미 해당 프로필의 토큰이 활성 상태입니다."
        }
    }

    'export' {
        # export <이름> [대상폴더] : 프로필을 다른 PC로 옮길 수 있는 패키지(zip)로 추출
        Assert-ValidName $Name
        $srcAuth = Get-ProfileAuthPath $Name
        if (-not (Test-Path $srcAuth)) {
            if (Test-AuthStructure $AuthFile) {
                throw "codex 프로필 '$Name'이 없습니다. 현재 계정을 프로필로 저장하려면 'save $Name'을 사용하세요. (export는 저장된 프로필을 이동용 패키지로 추출합니다)"
            }
            throw "codex 프로필 '$Name'을 찾을 수 없습니다. (list로 확인)"
        }
        if (-not (Test-AuthStructure $srcAuth)) { throw "codex 프로필 '$Name'의 auth.json 형식이 올바르지 않습니다." }

        # 이 프로필이 현재 활성 계정이면 최신 토큰이 패키지에 담기도록 먼저 동기화
        Sync-ActiveToProfile

        $emailTag = 'noaccount'
        $email = Get-ProfileEmail $Name
        if ($email -and $email -notmatch '[\\/:*?"<>|\s]') { $emailTag = $email }
        $destDir = $Name2
        if ([string]::IsNullOrEmpty($destDir)) { $destDir = Join-Path $Store '_exports' }
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $zipPath = Join-Path $destDir "codex-package-$Name-$emailTag-$stamp.zip"

        $man = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        $man['format']     = [string]'codex-cred-package/1'
        $man['name']       = [string]$Name
        $man['email']      = [string]$emailTag
        $man['exportedAt'] = [string](Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

        $tmpDir = Join-Path $env:TEMP ("codex-export-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            Copy-Item $srcAuth (Join-Path $tmpDir 'auth.json') -Force
            $sidePath = Get-SidecarPath $Name
            if (Test-Path $sidePath) { Copy-Item $sidePath (Join-Path $tmpDir 'account.json') -Force }
            [System.IO.File]::WriteAllText((Join-Path $tmpDir 'package.json'), $Ser.Serialize($man), $Utf8NoBom)
            Compress-Archive -Path (Join-Path $tmpDir '*') -DestinationPath $zipPath -Force
        } finally {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Output "패키지 생성 완료: $zipPath"
        Write-Output ("  계정: $emailTag  -  " + (Get-AuthMeta (Get-AuthInfo $srcAuth)))
        Write-Output "받는 PC에서 'codex.ps1 import <패키지파일>'로 등록하면 계정 정보까지 복원됩니다."
        Write-Output "!! 이 파일에는 로그인 토큰이 들어 있습니다. 클라우드 동기화 폴더에 두지 말고, 옮긴 뒤 양쪽에서 삭제하세요."
        Write-Output "!! 토큰은 사용 중 갱신됩니다. 이 PC에서 이 계정을 계속 쓰면 패키지 속 토큰이 낡으니, 만든 뒤 바로 옮겨 등록하세요."
    }

    { $_ -in 'import', 'add' } {
        # import <패키지zip|폴더|auth.json> [이름] : 외부 자격증명을 프로필로 등록 (add는 별칭)
        if ([string]::IsNullOrEmpty($Name)) { throw "등록할 패키지(zip)나 auth.json 파일 경로를 지정하세요: import <파일> [이름]" }
        if (-not (Test-Path $Name)) {
            if (Test-Path (Get-ProfileAuthPath $Name)) {
                throw "계정 전환은 'use $Name'을 사용하세요. (import는 패키지/외부 파일을 저장소에 등록합니다)"
            }
            throw "등록할 파일을 찾을 수 없습니다: '$Name'"
        }

        $srcItem = Get-Item $Name
        $srcAuth = $null; $srcSide = $null; $pkgName = $null; $tmpDir = $null
        try {
            if ($srcItem.PSIsContainer -or $srcItem.Extension -ieq '.zip') {
                $baseDir = $srcItem.FullName
                if (-not $srcItem.PSIsContainer) {
                    $tmpDir = Join-Path $env:TEMP ("codex-import-" + [Guid]::NewGuid().ToString('N'))
                    Expand-Archive -Path $srcItem.FullName -DestinationPath $tmpDir -Force
                    $baseDir = $tmpDir
                }
                $srcAuth = Join-Path $baseDir 'auth.json'
                if (-not (Test-Path $srcAuth)) {
                    if (Test-Path (Join-Path $baseDir 'credentials.json')) {
                        throw "'$Name' 은 Claude 계정 패키지입니다. Claude 계정은 'cred.ps1 import' 로 등록하세요."
                    }
                    throw "'$Name' 안에 auth.json이 없습니다 (codex 패키지가 아닙니다)."
                }
                $p = Join-Path $baseDir 'account.json'
                if (Test-Path $p) { $srcSide = $p }
                $p = Join-Path $baseDir 'package.json'
                if (Test-Path $p) {
                    try { $pkgName = [string]((Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).name) } catch {}
                }
            } else {
                $srcAuth = $srcItem.FullName   # 단일 auth.json 파일
            }
            if (-not (Test-AuthStructure $srcAuth)) {
                if ($srcItem.Name -ieq 'credentials.json' -or $srcItem.Name -ieq '.credentials.json') {
                    throw "'$Name' 은 Claude 자격증명 파일로 보입니다. Claude 계정은 'cred.ps1 import' 로 등록하세요."
                }
                throw "'$Name'의 내용이 올바른 codex auth.json 형식이 아닙니다."
            }

            $newName = $Name2
            if ([string]::IsNullOrEmpty($newName)) { $newName = $pkgName }
            if ([string]::IsNullOrEmpty($newName)) { throw "프로필 이름을 지정하세요: import <파일> <이름>" }
            Assert-ValidName $newName

            $dest = Get-ProfileAuthPath $newName
            if ((Test-Path $dest) -and -not $Force) {
                throw "codex 프로필 '$newName'이 이미 있습니다. 덮어쓰려면 -Force 를 추가하세요."
            }
            $destDir = Get-ProfileDir $newName
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            if (Test-Path $dest) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                Copy-Item $dest (Join-Path $BackupDir "$stamp-profile-$newName.json") -Force
            }
            Copy-Item $srcAuth $dest -Force
            # 계정 정보는 항상 새 토큰에서 다시 해독한다 (패키지의 account.json 은 참고용 — 토큰과 어긋날 수 없도록)
            $info = Write-SidecarFromAuth $newName
            Write-Output ("codex 프로필 '$newName' 등록 완료  -  " + (Get-AuthMeta $info))
            if ($null -ne $info -and $info.email) { Write-Output "계정: $($info.email) (토큰에서 해독해 기록)" }
            else                                   { Write-Output "계정(이메일) 정보가 없습니다 (API 키 모드)." }
            Write-Output "원본($Name)은 더 이상 필요 없으면 삭제하는 것을 권장합니다 (토큰 유출 위험)."
            Write-Output "이 계정으로 전환하려면 'use $newName'을 실행하세요."
        } finally {
            if ($tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    'backup' {
        if (-not (Test-Path $AuthFile)) { throw "현재 codex 자격증명 파일이 없습니다: $AuthFile" }
        $bak = Backup-Current 'manual'
        Write-Output "백업 완료: $bak"
    }

    'whoami' {
        # whoami [프로필이름] : 토큰(JWT) 안의 계정 정보를 로컬에서 해독해 표시. API 호출 없음, 토큰 출력 없음.
        $target = $AuthFile; $label = '현재 활성 토큰'
        if (-not [string]::IsNullOrEmpty($Name)) {
            Assert-ValidName $Name
            $target = Get-ProfileAuthPath $Name
            if (-not (Test-Path $target)) { throw "codex 프로필 '$Name'을 찾을 수 없습니다. (list로 확인)" }
            $label = "codex 프로필 '$Name'"
        }
        if (-not (Test-Path $target)) { throw "자격증명 파일이 없습니다: $target" }
        $info = Get-AuthInfo $target
        if ($null -eq $info -or -not $info.valid) { throw "'$target' 파일이 올바른 auth.json 형식이 아닙니다." }
        if ($info.mode -eq 'apikey') {
            Write-Output "$label : API 키 모드 (ChatGPT 계정 로그인이 아니라 이메일이 없습니다)"
        } else {
            $email = $info.email
            if (-not $email) { $email = '(토큰에서 이메일을 읽지 못함)' }
            Write-Output "$label 계정: $email"
            if ($info.plan) { Write-Output "$label 플랜: $($info.plan)" }
            Write-Output ("$label 상태: " + (Get-AuthMeta $info))
        }
    }
    '_status' {
        # 내부용: cred.ps1 의 통합 메뉴·list 가 쓰는 기계용 상태 객체. 문구를 출력하지 않는다 (토큰 값도 없음).
        $cur = Get-AuthInfo $AuthFile
        $curValid = ($null -ne $cur -and $cur.valid)
        $curEmail = $null
        if ($curValid) {
            if ($cur.email) { $curEmail = $cur.email } else { $curEmail = '(이메일 없음 - API 키 모드)' }
        }
        $activeHash = $null
        if ($curValid) { $activeHash = Get-Sha $AuthFile }
        $items = @()
        foreach ($pname in (Get-ProfileNames)) {
            $authPath = Get-ProfileAuthPath $pname
            $info = Get-AuthInfo $authPath
            $email = Get-ProfileEmail $pname
            if (-not $email) {
                if ($null -ne $info -and $info.valid -and $info.mode -eq 'apikey') { $email = '(API 키 모드)' }
                else { $email = '(계정 미기록)' }
            }
            $items += [pscustomobject]@{
                Name   = $pname
                Active = [bool]($activeHash -and (Test-Path $authPath) -and (Get-Sha $authPath) -eq $activeHash)
                Email  = $email
                Meta   = (Get-AuthMeta $info)
            }
        }
        [pscustomobject]@{
            Current  = [pscustomobject]@{ Valid = $curValid; Email = $curEmail; Meta = (Get-AuthMeta $cur) }
            Profiles = $items
        }
    }
}
