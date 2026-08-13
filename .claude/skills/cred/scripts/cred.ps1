# cred.ps1 - Claude Code 계정 자격증명(.credentials.json) 프로필 관리
# 주의: 이 스크립트는 토큰 값을 절대 출력하지 않는다 (메타데이터만 표시).
#
# 액션 체계 (기준은 프로필 저장소):
#   (인자 없음)            프로필 목록을 번호 메뉴로 보여주고 선택한 계정으로 전환 (대화형)
#   save <이름>            현재 활성 자격증명 → 프로필 저장 (구 export)
#   use <이름>             프로필 → 활성 자격증명 (계정 전환, 구 import)
#   export <이름> [폴더]   프로필 → 이동용 패키지(zip) 추출 (다른 PC로 가져가기)
#   import <파일> [이름]   패키지(zip)/폴더/credentials 파일 → 프로필 등록 (add는 별칭)
#
# 프로필 구조:  <이름>\credentials.json - .credentials.json 사본 (토큰 포함, 계정 식별정보는 없음)
#               <이름>\account.json     - 계정(로그인) 정보: 이메일/조직, 토큰 없음
#               <이름>\<이메일>          - 계정 표시용 빈 마커 파일 (탐색기에서 한눈에 확인용, 자동 관리)
# 구버전 flat 파일(<이름>.json / <이름>.account.json)은 실행 시 자동으로 폴더 구조로 이전된다.
#   source 종류: cache(로그인 시 캐시 사본) / api(fixcache로 조회 API 확인) / manual(이메일만 수동 기록)
#   save 시 캐시 사본을 함께 저장하고, use 시 cache/api 기록을 ~/.claude.json에 복원해
#   화면에 표시되는 계정(이메일)도 프로필에 맞게 바뀌도록 한다.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'save', 'use', 'export', 'import', 'add', 'backup', 'setaccount', 'whoami', 'fixcache')]
    [string]$Action = '',

    [Parameter(Position = 1)]
    [string]$Name,

    [Parameter(Position = 2)]
    [string]$Name2,

    [switch]$Force,
    [switch]$FromCache
)

$ErrorActionPreference = 'Stop'

# 기본 경로 (테스트용으로 환경변수 재정의 가능)
if ([string]::IsNullOrEmpty($env:CRED_FILE))   { $CredFile   = Join-Path $env:USERPROFILE '.claude\.credentials.json' }
else                                           { $CredFile   = $env:CRED_FILE }
if ([string]::IsNullOrEmpty($env:CRED_CONFIG)) { $ConfigFile = Join-Path $env:USERPROFILE '.claude.json' }
else                                           { $ConfigFile = $env:CRED_CONFIG }
# 전역 스킬 위치 (전역 복사본은 globalize 스킬이 동기화한다. 구버전 저장소 이전 경로 계산에만 사용)
$GlobalSkillDir = Join-Path $env:USERPROFILE '.claude\skills\cred'
# 프로필 저장소(vault): globalize_skill 프로젝트의 스킬 폴더 안 profiles.
# 어느 사본(프로젝트/전역)으로 실행하든 항상 이 저장소 하나만 사용한다. CRED_STORE 환경변수로 재정의 가능.
# 주의: 프로젝트 .gitignore에 이 폴더가 제외되어 있어야 한다 (스킬 폴더의 .gitignore로도 이중 방어).
if ([string]::IsNullOrEmpty($env:CRED_STORE))  { $Store      = 'E:\dev\globalize_skill\.claude\skills\cred\profiles' }
else                                           { $Store      = $env:CRED_STORE }
$BackupDir = Join-Path $Store '_backups'
# 구버전 저장소 위치들 (발견되면 내용을 새 저장소로 자동 이전)
$LegacyStores = @('E:\dev\accredential\.claude\skills\cred\profiles', 'E:\dev\accredential\profiles', (Join-Path $GlobalSkillDir 'profiles'))

if (-not (Test-Path $Store))     { New-Item -ItemType Directory -Path $Store -Force | Out-Null }
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# JSON 처리는 전부 C# 안에서 수행한다.
#  - PS 5.1의 ConvertFrom-Json은 2MB 제한이 있어 ~/.claude.json이 커지면 실패한다.
#  - PowerShell로 객체 그래프를 다루면 PSObject 래핑 때문에 재직렬화가 깨진다.
#  → PowerShell 쪽에는 JSON "문자열"만 오간다.
Add-Type -ReferencedAssemblies 'System.Web.Extensions' -TypeDefinition @'
using System.Collections.Generic;
using System.Web.Script.Serialization;

public static class CredJson
{
    static JavaScriptSerializer S()
    {
        return new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 1000 };
    }

    // json(객체)의 최상위 key 값을 다시 JSON 문자열로 반환. 없으면 null.
    public static string Extract(string json, string key)
    {
        var ser = S();
        var d = ser.DeserializeObject(json) as Dictionary<string, object>;
        if (d == null) return null;
        object v;
        if (!d.TryGetValue(key, out v) || v == null) return null;
        return ser.Serialize(v);
    }

    // json(객체)의 최상위 key가 문자열이면 그 값을 반환. 아니면 null.
    public static string GetString(string json, string key)
    {
        var ser = S();
        var d = ser.DeserializeObject(json) as Dictionary<string, object>;
        if (d == null) return null;
        object v;
        if (!d.TryGetValue(key, out v)) return null;
        return v as string;
    }

    public static int TopKeyCount(string json)
    {
        var d = S().DeserializeObject(json) as Dictionary<string, object>;
        return d == null ? -1 : d.Count;
    }

    // configJson의 oauthAccount를 accountJson(객체)으로 교체한 전체 JSON을 반환.
    public static string MergeAccount(string configJson, string accountJson)
    {
        var ser = S();
        var cfg = (Dictionary<string, object>)ser.DeserializeObject(configJson);
        cfg["oauthAccount"] = ser.DeserializeObject(accountJson);
        return ser.Serialize(cfg);
    }

    // 사이드카 JSON 생성: { source, savedAt, oauthAccount }
    public static string BuildSidecar(string source, string savedAt, string accountJson)
    {
        var ser = S();
        var d = new Dictionary<string, object>();
        d["source"] = source;
        d["savedAt"] = savedAt;
        d["oauthAccount"] = ser.DeserializeObject(accountJson);
        return ser.Serialize(d);
    }
}
'@

function Test-CredStructure([string]$Path) {
    try {
        $j = Get-Content $Path -Raw | ConvertFrom-Json
        return ($null -ne $j.claudeAiOauth -and
                -not [string]::IsNullOrEmpty($j.claudeAiOauth.accessToken) -and
                -not [string]::IsNullOrEmpty($j.claudeAiOauth.refreshToken))
    } catch { return $false }
}

function Convert-Epoch([long]$v) {
    if ($v -gt 1000000000000) { return [DateTimeOffset]::FromUnixTimeMilliseconds($v).ToLocalTime() }
    else                      { return [DateTimeOffset]::FromUnixTimeSeconds($v).ToLocalTime() }
}

# 토큰 값은 제외하고 메타데이터만 요약
function Get-CredMeta([string]$Path) {
    $j = Get-Content $Path -Raw | ConvertFrom-Json
    $o = $j.claudeAiOauth
    $refreshExp = Convert-Epoch $o.refreshTokenExpiresAt
    $expired = ''
    if ($refreshExp -lt (Get-Date)) { $expired = ' [만료됨!]' }
    return "$($o.subscriptionType)/$($o.rateLimitTier), refresh토큰 만료 $($refreshExp.ToString('yyyy-MM-dd'))$expired"
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
    if (-not (Test-Path $CredFile)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $BackupDir "$stamp-$Reason.json"
    Copy-Item $CredFile $dest -Force
    return $dest
}

function Get-ProfileDir([string]$ProfileName)      { Join-Path $Store $ProfileName }
function Get-ProfileCredPath([string]$ProfileName) { Join-Path (Get-ProfileDir $ProfileName) 'credentials.json' }
function Get-SidecarPath([string]$ProfileName)     { Join-Path (Get-ProfileDir $ProfileName) 'account.json' }

# 프로필 폴더 안에 계정 이메일을 파일명으로 하는 빈 마커 파일을 유지한다 (탐색기 확인용).
# credentials.json / account.json 외의 파일은 마커로 간주하고 갱신 시 삭제한다.
function Update-EmailMarker([string]$ProfileName) {
    $dir = Get-ProfileDir $ProfileName
    if (-not (Test-Path $dir)) { return }
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('credentials.json', 'account.json') } |
        ForEach-Object { try { Remove-Item $_.FullName -Force } catch {} }
    $side = Read-Sidecar $ProfileName
    if ($null -ne $side -and $side.email -and $side.email -notmatch '[\\/:*?"<>|\s]') {
        $marker = Join-Path $dir $side.email
        [System.IO.File]::WriteAllText($marker, '', $Utf8NoBom)
    }
}

# 구버전 flat 구조(<이름>.json / <이름>.account.json)를 폴더 구조로 자동 이전
function Invoke-StoreMigration {
    # 구버전 저장소 위치에 남은 프로필/백업을 새 저장소로 이전
    foreach ($legacy in $LegacyStores) {
        if (-not (Test-Path $legacy)) { continue }
        if ([System.IO.Path]::GetFullPath($legacy) -ieq [System.IO.Path]::GetFullPath($Store)) { continue }
        $moved = $false
        foreach ($item in @(Get-ChildItem $legacy -Force -ErrorAction SilentlyContinue)) {
            $dest = Join-Path $Store $item.Name
            if ($item.Name -eq '_backups' -and (Test-Path $dest)) {
                # 백업 폴더가 양쪽에 있으면 내용물만 합친다
                Get-ChildItem $item.FullName -File | Move-Item -Destination $dest -Force
                Remove-Item $item.FullName -Force -Recurse -ErrorAction SilentlyContinue
                $moved = $true
            } elseif (-not (Test-Path $dest)) {
                Move-Item $item.FullName $dest -Force
                $moved = $true
            } else {
                Write-Output "!! 구버전 저장소의 '$($item.Name)'이 새 저장소에 이미 있어 이전하지 않았습니다: $($item.FullName)"
            }
        }
        if (@(Get-ChildItem $legacy -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $legacy -Force -ErrorAction SilentlyContinue
        }
        if ($moved) { Write-Output "(구버전 저장소($legacy)를 새 저장소로 이전했습니다: $Store)" }
    }
    $flat = @(Get-ChildItem $Store -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $mains = @($flat | Where-Object { $_.Name -notlike '*.account.json' })
    foreach ($f in $mains) {
        $n = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $dir = Get-ProfileDir $n
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Move-Item $f.FullName (Join-Path $dir 'credentials.json') -Force
        $oldSide = Join-Path $Store "$n.account.json"
        if (Test-Path $oldSide) { Move-Item $oldSide (Join-Path $dir 'account.json') -Force }
        Update-EmailMarker $n
        Write-Output "(구버전 프로필 '$n'을 폴더 구조로 이전했습니다: $dir)"
    }
    # 짝 없는 사이드카만 남은 경우도 폴더로 이전
    foreach ($s in @(Get-ChildItem $Store -Filter '*.account.json' -File -ErrorAction SilentlyContinue)) {
        $n = $s.Name -replace '\.account\.json$', ''
        $dir = Get-ProfileDir $n
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Move-Item $s.FullName (Join-Path $dir 'account.json') -Force
        Update-EmailMarker $n
        Write-Output "(구버전 계정 기록 '$n'을 폴더 구조로 이전했습니다: $dir)"
    }
}

# ~/.claude.json에 캐시된 oauthAccount 블록을 JSON 문자열로 반환 (없으면 $null)
function Get-CachedAccountJson {
    if (-not (Test-Path $ConfigFile)) { return $null }
    return [CredJson]::Extract([System.IO.File]::ReadAllText($ConfigFile), 'oauthAccount')
}

# 사이드카 읽기: @{ email; source; accountJson } 또는 $null (모든 값은 문자열)
function Read-Sidecar([string]$ProfileName) {
    $p = Get-SidecarPath $ProfileName
    if (-not (Test-Path $p)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($p)
        $acctJson = [CredJson]::Extract($raw, 'oauthAccount')
        $email = $null
        if ($acctJson) { $email = [CredJson]::GetString($acctJson, 'emailAddress') }
        return @{
            email       = $email
            source      = [CredJson]::GetString($raw, 'source')
            accountJson = $acctJson
        }
    } catch { return $null }
}

function Write-Sidecar([string]$ProfileName, [string]$Source, [string]$AccountJson) {
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $json = [CredJson]::BuildSidecar($Source, $now, $AccountJson)
    $dir = Get-ProfileDir $ProfileName
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText((Get-SidecarPath $ProfileName), $json, $Utf8NoBom)
    Update-EmailMarker $ProfileName
}

# 현재 캐시된 oauthAccount를 사이드카로 저장. 성공 시 이메일 반환, 캐시 없으면 $null
function Save-AccountFromCache([string]$ProfileName) {
    $acctJson = Get-CachedAccountJson
    if ($null -eq $acctJson) { return $null }
    Write-Sidecar $ProfileName 'cache' $acctJson
    $email = [CredJson]::GetString($acctJson, 'emailAddress')
    if ($email) { return $email }
    return '(이메일 없음)'
}

# 사이드카의 oauthAccount를 ~/.claude.json에 복원 (source가 'cache'인 완전한 블록만)
function Restore-AccountToConfig($Sidecar) {
    if ($null -eq $Sidecar -or $null -eq $Sidecar.accountJson) {
        Write-Output "이 프로필에는 계정 정보가 기록되어 있지 않습니다. 화면에 표시되는 계정은 바뀌지 않습니다."
        return
    }
    if ($Sidecar.source -notin @('cache', 'api')) {
        Write-Output "이 프로필의 계정 정보는 수동 입력(이메일만)이라 화면 표시 계정은 갱신하지 않습니다. ('fixcache <이름>'으로 API 확인 기록을 만들 수 있습니다.)"
        return
    }
    if (-not (Test-Path $ConfigFile)) {
        Write-Output "~/.claude.json이 없어 계정 표시 정보를 복원하지 못했습니다 (로그인 시 자동 생성됨)."
        return
    }
    $configRaw = [System.IO.File]::ReadAllText($ConfigFile)
    $curAcctJson = [CredJson]::Extract($configRaw, 'oauthAccount')
    if ($curAcctJson -eq $Sidecar.accountJson) {
        Write-Output "화면 표시 계정($($Sidecar.email))은 이미 일치합니다."
        return
    }

    $newJson = [CredJson]::MergeAccount($configRaw, $Sidecar.accountJson)

    # 쓰기 전 검증: 키 개수가 줄지 않았고 oauthAccount가 반영되었는지 확인
    $origKeys = [CredJson]::TopKeyCount($configRaw)
    $newKeys  = [CredJson]::TopKeyCount($newJson)
    $applied  = [CredJson]::Extract($newJson, 'oauthAccount')
    if ($newKeys -lt $origKeys -or $null -eq $applied) {
        throw "~/.claude.json 재직렬화 검증 실패. 파일을 변경하지 않았습니다."
    }

    # 수정 전 원본 백업 후 원자적 교체
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $ConfigFile (Join-Path $BackupDir "$stamp-claude-config.json") -Force
    $tmp = "$ConfigFile.cred-tmp"
    [System.IO.File]::WriteAllText($tmp, $newJson, $Utf8NoBom)
    Move-Item $tmp $ConfigFile -Force
    Write-Output "화면 표시 계정 정보를 '$($Sidecar.email)'(으)로 복원했습니다."
}

# use/export 전 자동 동기화: 현재 활성 토큰을 그 계정의 프로필에 저장해 스냅샷을 최신으로 유지한다.
# refresh 토큰은 갱신 시마다 회전(구버전 무효화)되므로, 마지막 사용 시점의 토큰을
# 프로필에 보관해둬야 다음에 그 계정으로 돌아올 때 재로그인이 필요 없다.
function Sync-ActiveToProfile {
    if (-not (Test-Path $CredFile) -or -not (Test-CredStructure $CredFile)) { return }
    $cachedAcctJson = Get-CachedAccountJson
    $cachedEmail = $null
    if ($cachedAcctJson) { $cachedEmail = [CredJson]::GetString($cachedAcctJson, 'emailAddress') }
    if ([string]::IsNullOrEmpty($cachedEmail)) {
        Write-Output "(자동 동기화 건너뜀: 화면 표시 계정 캐시가 없어 현재 토큰이 어느 프로필인지 알 수 없습니다.)"
        return
    }
    $found = @()
    foreach ($p in @(Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notlike '_*' })) {
        $side = Read-Sidecar $p.Name
        if ($null -ne $side -and $side.email -eq $cachedEmail) { $found += $p.Name }
    }
    if ($found.Count -eq 0) {
        Write-Output "(자동 동기화 건너뜀: 현재 계정($cachedEmail)에 해당하는 프로필이 없습니다. 'save <이름>'으로 저장해두면 다음 전환 때 재로그인이 줄어듭니다.)"
        return
    }
    if ($found.Count -gt 1) {
        Write-Output "(자동 동기화 건너뜀: 계정 $cachedEmail 이 여러 프로필($($found -join ', '))에 기록되어 있어 대상을 정할 수 없습니다.)"
        return
    }
    $syncName = $found[0]
    $dest = Get-ProfileCredPath $syncName
    if ((Test-Path $dest) -and (Get-Sha $dest) -eq (Get-Sha $CredFile)) { return }   # 이미 최신
    if (Test-Path $dest) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item $dest (Join-Path $BackupDir "$stamp-autosync-$syncName.json") -Force
    }
    $destDir = Get-ProfileDir $syncName
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item $CredFile $dest -Force
    Write-Output "자동 동기화: 현재 토큰(계정 $cachedEmail)을 프로필 '$syncName'에 저장했습니다 (이전 토큰은 _backups에 백업)."
}

Invoke-StoreMigration

# 인자 없이 실행: 프로필 목록을 번호 메뉴로 보여주고 선택한 계정으로 전환한다 (대화형).
if ([string]::IsNullOrEmpty($Action)) {
    $menuProfiles = @(Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -notlike '_*' })
    if ($menuProfiles.Count -eq 0) {
        Write-Output "저장된 프로필이 없습니다. 'save <이름>'으로 현재 계정을 먼저 저장하세요."
        exit 0
    }
    $menuActiveHash = $null
    if ((Test-Path $CredFile) -and (Test-CredStructure $CredFile)) { $menuActiveHash = Get-Sha $CredFile }
    Write-Output "전환할 계정을 선택하세요:"
    for ($i = 0; $i -lt $menuProfiles.Count; $i++) {
        $pname = $menuProfiles[$i].Name
        $credPath = Get-ProfileCredPath $pname
        $mark = '  '
        if ($menuActiveHash -and (Test-Path $credPath) -and (Get-Sha $credPath) -eq $menuActiveHash) { $mark = '* ' }
        $side = Read-Sidecar $pname
        $email = '(계정 미기록)'
        if ($null -ne $side -and $side.email) { $email = $side.email }
        if ((Test-Path $credPath) -and (Test-CredStructure $credPath)) { $meta = Get-CredMeta $credPath }
        else                                                           { $meta = '(토큰 없음/형식 오류)' }
        Write-Output ("  {0}) {1}{2}  {3}  -  {4}" -f ($i + 1), $mark, $pname, $email, $meta)
    }
    Write-Output "  (* = 현재 활성 토큰과 동일)"
    try { $sel = Read-Host "번호 입력 (Enter=취소)" }
    catch { throw "대화형 입력을 사용할 수 없는 환경입니다. 'cred.ps1 use <이름>'처럼 액션을 지정해 실행하세요." }
    if ([string]::IsNullOrWhiteSpace($sel)) { Write-Output "취소했습니다."; exit 0 }
    $selNum = 0
    if (-not [int]::TryParse($sel.Trim(), [ref]$selNum) -or $selNum -lt 1 -or $selNum -gt $menuProfiles.Count) {
        throw "1~$($menuProfiles.Count) 범위의 번호를 입력하세요: '$sel'"
    }
    $Action = 'use'
    $Name = $menuProfiles[$selNum - 1].Name
    Write-Output ""
    Write-Output "→ 'use $Name' 실행"
}

switch ($Action) {

    'list' {
        Write-Output "[토큰] = 인증키(<프로필>\credentials.json) - 실제 인증과 사용량이 이 계정으로 나감"
        Write-Output "[계정] = 로그인 정보(<프로필>\account.json) - 이메일/조직 표시용, 토큰 없음"
        Write-Output ""
        $activeHash = $null
        Write-Output "현재 활성:"
        if (Test-Path $CredFile) {
            if (Test-CredStructure $CredFile) {
                $activeHash = Get-Sha $CredFile
                Write-Output ("  토큰: " + (Get-CredMeta $CredFile))
            } else {
                Write-Output "  토큰: (파일이 있으나 형식이 올바르지 않음)"
            }
        } else {
            Write-Output "  토큰: (없음 - 로그아웃 상태)"
        }
        $cachedEmail = $null
        $cachedAcctJson = Get-CachedAccountJson
        if ($cachedAcctJson) {
            $cachedEmail = [CredJson]::GetString($cachedAcctJson, 'emailAddress')
        }
        if ($cachedEmail) { Write-Output "  계정(화면 표시 캐시): $cachedEmail" }
        else              { Write-Output "  계정(화면 표시 캐시): (없음)" }
        Write-Output ""
        $profiles = @(Get-ChildItem $Store -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -notlike '_*' })
        if ($profiles.Count -eq 0) {
            Write-Output "저장된 프로필 없음. 'save <이름>'으로 현재 계정을 저장하세요."
        } else {
            Write-Output "프로필 목록 ($Store):"
            $activeMismatch = $null
            foreach ($p in $profiles) {
                $pname = $p.Name
                $credPath = Get-ProfileCredPath $pname
                $hasCred = Test-Path $credPath
                $isActive = ($activeHash -and $hasCred -and (Get-Sha $credPath) -eq $activeHash)
                $mark = '  '
                if ($isActive) { $mark = '* ' }
                $side = Read-Sidecar $pname
                Write-Output "$mark$pname"
                if ($hasCred -and (Test-CredStructure $credPath)) {
                    Write-Output ("    토큰: " + (Get-CredMeta $credPath))
                } elseif ($hasCred) {
                    Write-Output "    토큰: (형식 오류)"
                } else {
                    Write-Output "    토큰: (없음 - credentials.json 누락)"
                }
                if ($null -ne $side -and $side.email) {
                    $srcTag = switch ($side.source) {
                        'cache'  { '[로그인 캐시: use 시 화면 표시까지 복원됨]' }
                        'api'    { '[API 확인: use 시 화면 표시까지 복원됨]' }
                        'manual' { '[수동 기록: 이메일만, 화면 표시 복원 안 됨]' }
                        default  { '[기록 방식 불명]' }
                    }
                    Write-Output "    계정: $($side.email) $srcTag"
                } else {
                    Write-Output "    계정: (미기록 - 'fixcache $pname' 또는 'setaccount $pname <이메일>'로 기록 가능)"
                }
                if ($isActive -and $cachedEmail -and $null -ne $side -and $side.email -and $side.email -ne $cachedEmail) {
                    if ($side.source -in @('cache', 'api')) {
                        $activeMismatch = "!! 화면 표시 계정($cachedEmail)이 활성 프로필 '$pname'의 계정($($side.email))과 다릅니다. 'use $pname'을 다시 실행하면 표시가 교정됩니다."
                    } else {
                        $activeMismatch = "!! 화면 표시 계정($cachedEmail)이 활성 프로필 '$pname'의 기록된 계정($($side.email))과 다릅니다. 'fixcache $pname'을 실행하면 API로 실제 계정을 확인해 교정합니다."
                    }
                }
            }
            Write-Output ""
            Write-Output "(* = 현재 활성 토큰과 동일)"
            if ($activeMismatch) { Write-Output $activeMismatch }
        }
    }

    'save' {
        # save <이름> : 현재 활성 자격증명을 프로필로 저장 (구 export)
        Assert-ValidName $Name
        if (-not (Test-Path $CredFile)) { throw "현재 자격증명 파일이 없습니다: $CredFile" }
        if (-not (Test-CredStructure $CredFile)) { throw "현재 자격증명 파일의 형식이 올바르지 않습니다." }
        $dest = Get-ProfileCredPath $Name
        if (Test-Path $dest) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Copy-Item $dest (Join-Path $BackupDir "$stamp-profile-$Name.json") -Force
            Write-Output "기존 프로필 '$Name'을 덮어씁니다 (이전 토큰은 _backups에 백업됨)."
        }
        $destDir = Get-ProfileDir $Name
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $CredFile $dest -Force
        $email = Save-AccountFromCache $Name
        if ($email) {
            $acctMsg = "계정: $email"
        } else {
            $acctMsg = "계정 정보 캐시가 없어 이메일은 기록하지 못했습니다 ('fixcache $Name' 또는 setaccount로 등록 가능)."
            # 캐시가 없는데 옛 계정 기록이 남으면 새 토큰과 신원이 어긋난 채 자동 동기화 대상이 되므로 제거한다
            $stale = Get-SidecarPath $Name
            if (Test-Path $stale) {
                Remove-Item $stale -Force
                Update-EmailMarker $Name
                $acctMsg += " 기존 계정 기록은 새 토큰과 어긋날 수 있어 제거했습니다."
            }
        }
        Write-Output ("프로필 '$Name' 저장 완료  -  $acctMsg  -  " + (Get-CredMeta $dest))
        Write-Output "(계정 정보는 화면에 표시 중인 캐시 기준입니다. 방금 이 계정으로 로그인한 상태가 아니라면 setaccount로 확인/수정하세요.)"
    }

    'use' {
        # use <이름> : 프로필로 계정 전환 (구 import)
        if ([string]::IsNullOrEmpty($Name)) { throw "전환할 프로필 이름을 지정하세요. (list로 확인)" }
        try { Assert-ValidName $Name } catch {
            if (Test-Path $Name) { throw "use는 저장된 프로필만 전환합니다. 외부 파일/패키지는 먼저 'import $Name <이름>'으로 등록한 뒤 use 하세요." }
            throw
        }
        $src = Get-ProfileCredPath $Name
        if (-not (Test-Path $src)) { throw "프로필 '$Name'을 찾을 수 없습니다. (list로 확인)" }
        if (-not (Test-CredStructure $src)) { throw "'$src' 파일이 올바른 credentials 형식이 아닙니다." }

        # 교체 전에 현재 토큰을 그 계정의 프로필에 자동 저장 (refresh 토큰 회전 대비)
        Sync-ActiveToProfile

        $alreadyActive = $false
        if ((Test-Path $CredFile) -and (Test-CredStructure $CredFile)) {
            if ((Get-Sha $CredFile) -eq (Get-Sha $src)) { $alreadyActive = $true }
        }

        if (-not $alreadyActive) {
            $bak = Backup-Current 'pre-use'
            Copy-Item $src $CredFile -Force
            if ($bak) { Write-Output "기존 자격증명 백업: $bak" }
            Write-Output ("교체 완료  -  " + (Get-CredMeta $CredFile))
        } else {
            Write-Output "이미 해당 프로필의 토큰이 활성 상태입니다."
        }

        # 토큰이 이미 같아도 화면 표시 계정이 어긋나 있을 수 있으므로 항상 복원 시도
        Restore-AccountToConfig (Read-Sidecar $Name)

        if (-not $alreadyActive) {
            Write-Output ""
            Write-Output "!! 적용하려면 Claude Code를 재시작(새 세션 시작)해야 합니다."
        }
    }

    'export' {
        # export <이름> [대상폴더] : 프로필을 다른 PC로 옮길 수 있는 패키지(zip)로 추출 (신규)
        Assert-ValidName $Name
        $srcCred = Get-ProfileCredPath $Name
        if (-not (Test-Path $srcCred)) {
            if ((Test-Path $CredFile) -and (Test-CredStructure $CredFile)) {
                throw "프로필 '$Name'이 없습니다. 현재 계정을 프로필로 저장하려면 'save $Name'을 사용하세요. (export는 저장된 프로필을 이동용 패키지로 추출합니다)"
            }
            throw "프로필 '$Name'을 찾을 수 없습니다. (list로 확인)"
        }
        if (-not (Test-CredStructure $srcCred)) { throw "프로필 '$Name'의 credentials 형식이 올바르지 않습니다." }

        # 이 프로필이 현재 활성 계정이면 최신 토큰이 패키지에 담기도록 먼저 동기화
        Sync-ActiveToProfile

        $side = Read-Sidecar $Name
        $emailTag = 'noaccount'
        if ($null -ne $side -and $side.email -and $side.email -notmatch '[\\/:*?"<>|\s]') { $emailTag = $side.email }
        $destDir = $Name2
        if ([string]::IsNullOrEmpty($destDir)) { $destDir = Join-Path $Store '_exports' }
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $zipPath = Join-Path $destDir "cred-package-$Name-$emailTag-$stamp.zip"

        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $man = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        $man['format']     = [string]'cred-package/1'
        $man['name']       = [string]$Name
        $man['email']      = [string]$emailTag
        $man['exportedAt'] = [string](Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

        $tmpDir = Join-Path $env:TEMP ("cred-export-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            Copy-Item $srcCred (Join-Path $tmpDir 'credentials.json') -Force
            $sidePath = Get-SidecarPath $Name
            if (Test-Path $sidePath) { Copy-Item $sidePath (Join-Path $tmpDir 'account.json') -Force }
            [System.IO.File]::WriteAllText((Join-Path $tmpDir 'package.json'), $ser.Serialize($man), $Utf8NoBom)
            Compress-Archive -Path (Join-Path $tmpDir '*') -DestinationPath $zipPath -Force
        } finally {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Output "패키지 생성 완료: $zipPath"
        Write-Output ("  계정: $emailTag  -  " + (Get-CredMeta $srcCred))
        Write-Output "받는 PC에서 'import <패키지파일>'로 등록하면 계정 정보까지 복원됩니다."
        Write-Output "!! 이 파일에는 로그인 토큰이 들어 있습니다. 클라우드 동기화 폴더에 두지 말고, 옮긴 뒤 양쪽에서 삭제하세요."
        Write-Output "!! refresh 토큰은 사용 시마다 회전됩니다. 이 PC에서 이 계정을 계속 쓰면 패키지 속 토큰이 낡으니, 만든 뒤 바로 옮겨 등록하세요."
    }

    { $_ -in 'import', 'add' } {
        # import <패키지zip|폴더|credentials파일> [이름] : 외부 자격증명을 프로필로 등록 (add는 별칭)
        if ([string]::IsNullOrEmpty($Name)) { throw "등록할 패키지(zip)나 credentials 파일 경로를 지정하세요: import <파일> [이름]" }
        if (-not (Test-Path $Name)) {
            if (Test-Path (Get-ProfileCredPath $Name)) {
                throw "계정 전환은 'use $Name'을 사용하세요. (import는 이제 패키지/외부 파일을 저장소에 등록합니다)"
            }
            throw "등록할 파일을 찾을 수 없습니다: '$Name'"
        }

        $srcItem = Get-Item $Name
        $srcCred = $null; $srcSide = $null; $pkgName = $null; $tmpDir = $null
        try {
            if ($srcItem.PSIsContainer -or $srcItem.Extension -ieq '.zip') {
                $baseDir = $srcItem.FullName
                if (-not $srcItem.PSIsContainer) {
                    $tmpDir = Join-Path $env:TEMP ("cred-import-" + [Guid]::NewGuid().ToString('N'))
                    Expand-Archive -Path $srcItem.FullName -DestinationPath $tmpDir -Force
                    $baseDir = $tmpDir
                }
                $srcCred = Join-Path $baseDir 'credentials.json'
                if (-not (Test-Path $srcCred)) { throw "'$Name' 안에 credentials.json이 없습니다 (cred 패키지가 아닙니다)." }
                $p = Join-Path $baseDir 'account.json'
                if (Test-Path $p) { $srcSide = $p }
                $p = Join-Path $baseDir 'package.json'
                if (Test-Path $p) {
                    try { $pkgName = [CredJson]::GetString([System.IO.File]::ReadAllText($p), 'name') } catch {}
                }
            } else {
                $srcCred = $srcItem.FullName   # 단일 credentials 파일 (구 add 용법)
            }
            if (-not (Test-CredStructure $srcCred)) { throw "'$Name'의 credentials가 올바른 형식이 아닙니다." }

            $newName = $Name2
            if ([string]::IsNullOrEmpty($newName)) { $newName = $pkgName }
            if ([string]::IsNullOrEmpty($newName)) { throw "프로필 이름을 지정하세요: import <파일> <이름>" }
            Assert-ValidName $newName

            $dest = Get-ProfileCredPath $newName
            if ((Test-Path $dest) -and -not $Force) {
                throw "프로필 '$newName'이 이미 있습니다. 덮어쓰려면 -Force 를 추가하세요."
            }
            $destDir = Get-ProfileDir $newName
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            if (Test-Path $dest) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                Copy-Item $dest (Join-Path $BackupDir "$stamp-profile-$newName.json") -Force
            }
            Copy-Item $srcCred $dest -Force
            $acctMsg = $null
            if ($srcSide) {
                Copy-Item $srcSide (Get-SidecarPath $newName) -Force
                Update-EmailMarker $newName
                $side = Read-Sidecar $newName
                if ($null -ne $side -and $side.email) { $acctMsg = "계정: $($side.email)" }
            } else {
                # 덮어쓰기인데 새 입력에 계정 정보가 없으면, 옛 계정 기록이 새 토큰과 어긋난 채 남지 않도록 제거한다
                $stale = Get-SidecarPath $newName
                if (Test-Path $stale) { Remove-Item $stale -Force; Update-EmailMarker $newName }
            }
            Write-Output ("프로필 '$newName' 등록 완료  -  " + (Get-CredMeta $dest))
            if ($acctMsg) {
                Write-Output "$acctMsg (패키지의 계정 정보를 함께 복원했습니다)"
            } else {
                Write-Output "계정(이메일) 정보가 없습니다. 'fixcache $newName'(API 확인) 또는 'setaccount $newName <이메일>'로 기록해두는 것을 권장합니다."
            }
            Write-Output "원본($Name)은 더 이상 필요 없으면 삭제하는 것을 권장합니다 (토큰 유출 위험)."
            Write-Output "이 계정으로 전환하려면 'use $newName'을 실행하세요."
        } finally {
            if ($tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    'backup' {
        if (-not (Test-Path $CredFile)) { throw "현재 자격증명 파일이 없습니다: $CredFile" }
        $bak = Backup-Current 'manual'
        Write-Output "백업 완료: $bak"
    }

    'whoami' {
        # whoami [프로필이름] : 토큰이 실제로 어느 계정인지 프로필 조회 API로 확인.
        # 토큰은 Authorization 헤더로만 전송하고 절대 출력하지 않는다.
        $target = $CredFile; $label = '현재 활성 토큰'
        if (-not [string]::IsNullOrEmpty($Name)) {
            Assert-ValidName $Name
            $target = Get-ProfileCredPath $Name
            if (-not (Test-Path $target)) { throw "프로필 '$Name'을 찾을 수 없습니다. (list로 확인)" }
            $label = "프로필 '$Name'"
        }
        if (-not (Test-CredStructure $target)) { throw "'$target' 파일이 올바른 credentials 형식이 아닙니다." }
        $j = Get-Content $target -Raw | ConvertFrom-Json
        $o = $j.claudeAiOauth
        $accessExp = Convert-Epoch $o.expiresAt
        if ($accessExp -lt (Get-Date)) {
            Write-Output "($label 의 access 토큰이 $($accessExp.ToString('yyyy-MM-dd HH:mm'))에 만료됨 - 조회가 실패할 수 있습니다)"
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $headers = @{ Authorization = "Bearer $($o.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20' }
        $resp = $null
        foreach ($url in @('https://api.anthropic.com/api/oauth/profile', 'https://console.anthropic.com/api/oauth/profile')) {
            try { $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 20; break }
            catch {
                $code = $null
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
                if ($code -eq 401 -or $code -eq 403) {
                    throw "$label : 토큰이 만료되었거나 유효하지 않습니다 (HTTP $code). 해당 계정으로 Claude Code 세션을 한 번 사용해 토큰이 갱신된 뒤 다시 시도하세요."
                }
            }
        }
        if ($null -eq $resp) { throw "프로필 조회 API에 연결하지 못했습니다 (네트워크 또는 엔드포인트 문제)." }
        $email = $resp.account.email_address
        if (-not $email) { $email = $resp.account.email }
        if (-not $email) { $email = $resp.account.emailAddress }
        $org = $resp.organization.name
        Write-Output "$label 계정: $email"
        if ($org) { Write-Output "$label 조직: $org" }
    }

    'fixcache' {
        # fixcache [프로필이름] : 토큰의 실제 계정을 조회 API로 확인해, 로그인 없이 계정 정보를 생성한다.
        #  - 프로필 이름을 주면 그 프로필의 사이드카(<이름>.account.json)를 API 확인 결과로 기록 (source: api)
        #  - 대상 토큰이 현재 활성 토큰과 같으면 ~/.claude.json의 화면 표시 계정도 함께 교정
        # 토큰은 Authorization 헤더로만 전송하고 절대 출력하지 않는다.
        $target = $CredFile; $label = '현재 활성 토큰'; $profileName = $null
        if (-not [string]::IsNullOrEmpty($Name)) {
            Assert-ValidName $Name
            $target = Get-ProfileCredPath $Name
            if (-not (Test-Path $target)) { throw "프로필 '$Name'을 찾을 수 없습니다. (list로 확인)" }
            $label = "프로필 '$Name'"; $profileName = $Name
        }
        if (-not (Test-Path $target)) { throw "현재 자격증명 파일이 없습니다: $target" }
        if (-not (Test-CredStructure $target)) { throw "'$target' 파일이 올바른 credentials 형식이 아닙니다." }
        $j = Get-Content $target -Raw | ConvertFrom-Json
        $o = $j.claudeAiOauth
        $accessExp = Convert-Epoch $o.expiresAt
        if ($accessExp -lt (Get-Date)) {
            Write-Output "($label 의 access 토큰이 $($accessExp.ToString('yyyy-MM-dd HH:mm'))에 만료됨 - 조회가 실패할 수 있습니다)"
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $headers = @{ Authorization = "Bearer $($o.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20' }
        $resp = $null
        foreach ($url in @('https://api.anthropic.com/api/oauth/profile', 'https://console.anthropic.com/api/oauth/profile')) {
            try { $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 20; break }
            catch {
                $code = $null
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
                if ($code -eq 401 -or $code -eq 403) {
                    throw "$label : 토큰이 만료되었거나 유효하지 않습니다 (HTTP $code). 해당 계정으로 Claude Code 세션을 한 번 사용해 토큰이 갱신된 뒤 다시 시도하세요."
                }
            }
        }
        if ($null -eq $resp) { throw "프로필 조회 API에 연결하지 못했습니다 (네트워크 또는 엔드포인트 문제)." }

        $email = $resp.account.email_address
        if (-not $email) { $email = $resp.account.email }
        if (-not $email) { $email = $resp.account.emailAddress }
        $acctUuid = $resp.account.uuid
        $orgUuid  = $resp.organization.uuid
        $orgName  = $resp.organization.name
        if (-not $email -or -not $acctUuid) {
            throw "API 응답에 계정 식별 정보(이메일/UUID)가 부족해 계정 정보를 생성할 수 없습니다."
        }
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        $d['accountUuid']  = [string]$acctUuid
        $d['emailAddress'] = [string]$email
        if ($orgUuid) { $d['organizationUuid'] = [string]$orgUuid }
        if ($orgName) { $d['organizationName'] = [string]$orgName }
        $acctJson = $ser.Serialize($d)

        Write-Output "$label 실제 계정 (API 확인): $email"

        if ($profileName) {
            Write-Sidecar $profileName 'api' $acctJson
            Write-Output "프로필 '$profileName'의 계정 정보를 API 확인 결과로 기록했습니다 (source: api)."
        }

        $isActiveToken = $false
        if ($target -eq $CredFile) { $isActiveToken = $true }
        elseif ((Test-Path $CredFile) -and (Test-CredStructure $CredFile)) {
            if ((Get-Sha $CredFile) -eq (Get-Sha $target)) { $isActiveToken = $true }
        }
        if ($isActiveToken) {
            Restore-AccountToConfig @{ email = $email; source = 'api'; accountJson = $acctJson }
            Write-Output "(화면 표시는 새 세션부터 반영됩니다. 실행 중인 세션이 캐시를 도로 덮어쓰면 한 번 더 실행하세요.)"
        } else {
            Write-Output "이 프로필의 토큰은 현재 활성 토큰과 달라 화면 표시(~/.claude.json)는 변경하지 않았습니다."
        }
    }

    'setaccount' {
        # setaccount <이름> <이메일>   : 이메일만 수동 기록 (list 표시용)
        # setaccount <이름> -FromCache : 현재 화면 표시 계정(oauthAccount 캐시 전체)을 이 프로필에 연결
        Assert-ValidName $Name
        if (-not (Test-Path (Get-ProfileCredPath $Name))) { throw "프로필 '$Name'을 찾을 수 없습니다. (list로 확인)" }
        if ($FromCache) {
            $email = Save-AccountFromCache $Name
            if ($null -eq $email) { throw "~/.claude.json에 캐시된 계정 정보가 없습니다." }
            Write-Output "프로필 '$Name'에 현재 화면 표시 계정($email)을 연결했습니다."
        } else {
            if ([string]::IsNullOrEmpty($Name2) -or $Name2 -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                throw "올바른 이메일을 지정하세요: setaccount <이름> <이메일>  (또는 -FromCache)"
            }
            $manualJson = '{"emailAddress":' + ((New-Object System.Web.Script.Serialization.JavaScriptSerializer).Serialize($Name2)) + '}'
            Write-Sidecar $Name 'manual' $manualJson
            Write-Output "프로필 '$Name'의 계정을 '$Name2'(으)로 기록했습니다 (표시용, 화면 캐시 복원에는 사용되지 않음)."
        }
    }
}
