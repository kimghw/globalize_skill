#!/usr/bin/env bash
# port_ops.sh — port_manager 스킬의 저수준 유틸리티
#
# 사용법:
#   port_ops.sh list <project>                       # 프로젝트의 행 출력 (TSV: 포트\t서비스\t시작명령\t작업디렉토리)
#   port_ops.sh list_all                             # port_list.md 전체 표 출력
#   port_ops.sh has   <project> <port>               # 행 존재 시 exit 0, 없으면 exit 1
#   port_ops.sh add   <project> <port> <service> <cmd> <cwd>   # 행 추가 (존재하면 오류)
#   port_ops.sh update <project> <port> <service> <cmd> <cwd>  # 같은 (project,port) 행 갱신 (없으면 오류)
#   port_ops.sh remove <project> <port>              # 행 삭제 (없으면 NOT_FOUND)
#   port_ops.sh suggest <project> [<start>-<end>]    # 빈 포트 추천: 표 미사용 + 미LISTEN 인 첫 포트. "SUGGEST <port> (range s-e)"
#                                                    #   대역 우선순위: 인자 > range 등록값 > 기본 8000-8999
#   port_ops.sh range  <project>                     # 프로젝트 대역 조회. "RANGE <s>-<e>" 또는 "NOT_SET"
#   port_ops.sh range  <project> <start>-<end>       # 프로젝트 대역 등록/갱신. "RANGE_SET <project> <s>-<e>"
#   port_ops.sh status <port>                        # "RUNNING <pid>" 또는 "STOPPED"
#   port_ops.sh kill <port>                          # 포트의 LISTEN 프로세스 종료. "KILLED <pid>" 또는 "NOT_RUNNING"
#   port_ops.sh start <port> <cwd> <cmd...>          # cwd로 cd 후 cmd를 백그라운드 실행, 로그파일 경로 출력
#   port_ops.sh restart <port> <cwd> <cmd...>        # kill + start
#   port_ops.sh discover [project_root]              # 현재 프로젝트에 속한 LISTEN 서버 자동발견. TSV: 포트\tPID\t시작명령\t작업디렉토리
#   port_ops.sh inspect  [project_root]              # 프로젝트 내부 설정 파일에서 선언된 서버 추출 (실행 여부 무관). TSV: source\t이름\t포트\t시작명령\t작업디렉토리. 미상 필드는 "—"
#
# NSSM (Windows 서비스 — Windows 전용, 관리자 권한 필요):
#   port_ops.sh nssm check                                # NSSM 가용성 확인. "OK <path>" 또는 non-zero exit
#   port_ops.sh nssm install   <project> <port>           # port_list.md 행을 Windows 서비스로 등록 (자동 시작)
#   port_ops.sh nssm uninstall <project> <port>           # 서비스 제거 (먼저 stop)
#   port_ops.sh nssm start     <project> <port>           # 서비스 시작
#   port_ops.sh nssm stop      <project> <port>           # 서비스 중지
#   port_ops.sh nssm restart   <project> <port>           # 서비스 재시작
#   port_ops.sh nssm status    <project> <port>           # "SERVICE_RUNNING" | "SERVICE_STOPPED" | "SERVICE_NOT_INSTALLED" ...
#   port_ops.sh nssm list      [project]                  # 등록된 pm_* 서비스 나열. TSV: 서비스명\t상태\t포트
#
# 환경변수:
#   PORT_LIST   port_list.md 경로 (기본: 스크립트와 같은 폴더의 port_list.md)
#   PROJECT_ROOT  start 시 cwd 기준 루트 (기본: $PWD)
#   LOG_DIR     백그라운드 로그 디렉토리 (기본: /tmp/port_manager)
#   NSSM        nssm 실행 파일 경로 override (기본: PATH 에서 nssm.exe / nssm 탐색)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PORT_LIST="${PORT_LIST:-$SCRIPT_DIR/port_list.md}"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
LOG_DIR="${LOG_DIR:-/tmp/port_manager}"
mkdir -p "$LOG_DIR"

die() { echo "port_ops: $*" >&2; exit 2; }

list_rows() {
  local project="$1"
  [ -f "$PORT_LIST" ] || die "port_list.md not found: $PORT_LIST"
  awk -F'|' -v proj="$project" '
    /^\|/ {
      f1=$2; gsub(/^[ \t]+|[ \t]+$/,"",f1)
      if (f1 == proj) {
        for (i=2; i<=NF; i++) gsub(/^[ \t]+|[ \t]+$/,"",$i)
        # 출력: 포트\t서비스\t시작명령\t작업디렉토리
        print $3 "\t" $4 "\t" $5 "\t" $6
      }
    }
  ' "$PORT_LIST"
}

list_all_rows() {
  [ -f "$PORT_LIST" ] || die "port_list.md not found: $PORT_LIST"
  cat "$PORT_LIST"
}

ensure_list() {
  if [ ! -f "$PORT_LIST" ]; then
    mkdir -p "$(dirname "$PORT_LIST")"
    {
      echo "# 프로젝트 서버·포트·실행명령 할당"
      echo
      echo "본 표는 \`/port_manager\` 가 읽는 단일 출처(SSOT)다. 한 행 = 한 서버 정의."
      echo
      echo "## 프로젝트 대역 예약"
      echo
      echo "## 등록 표"
      echo
      echo "| 프로젝트 | 포트 | 서비스 | 시작명령 | 작업디렉토리 |"
      echo "|---------|------|-------|---------|------------|"
    } > "$PORT_LIST"
  fi
  # 구버전 파일 자동 이관: 대역 예약 절이 없으면 표 바로 위에 삽입
  if ! grep -q '^## 프로젝트 대역 예약' "$PORT_LIST"; then
    local tmp; tmp="$(mktemp)"
    awk '!done && /^\| 프로젝트 \|/ { print "## 프로젝트 대역 예약"; print ""; print "## 등록 표"; print ""; done=1 } { print }' \
      "$PORT_LIST" > "$tmp" && mv "$tmp" "$PORT_LIST"
  fi
}

has_row() {
  local project="$1" port="$2"
  [ -f "$PORT_LIST" ] || return 1
  awk -F'|' -v proj="$project" -v p="$port" '
    /^\|/ {
      f1=$2; gsub(/^[ \t]+|[ \t]+$/,"",f1)
      f2=$3; gsub(/^[ \t]+|[ \t]+$/,"",f2)
      if (f1 == proj && f2 == p) { found=1; exit }
    }
    END { exit (found ? 0 : 1) }
  ' "$PORT_LIST"
}

# 셀 안에서 파이프(|)와 백슬래시는 마크다운 표를 깨므로 이스케이프한다.
# (실제 사용에서는 거의 발생하지 않지만 방어용)
sanitize_cell() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//|/\\|}"
  if [ -z "$v" ]; then v="—"; fi
  printf '%s' "$v"
}

# ---- 대역 예약: port_list.md 의 "## 프로젝트 대역 예약" 절, "- <프로젝트>: <s>-<e>" 불릿 ----

range_get() {
  local project="$1"
  [ -f "$PORT_LIST" ] || return 0
  awk -v proj="$project" '
    /^- / {
      line=substr($0,3); i=index(line,": ")
      if (i>0 && substr(line,1,i-1)==proj) { print substr(line,i+2); exit }
    }' "$PORT_LIST"
}

range_owner_of_port() {  # $1=제외할 프로젝트, $2=포트 → 그 포트를 대역에 포함하는 다른 프로젝트
  local project="$1" port="$2"
  [ -f "$PORT_LIST" ] || return 0
  awk -v proj="$project" -v p="$port" '
    /^- / {
      line=substr($0,3); i=index(line,": ")
      if (i<=0) next
      pr=substr(line,1,i-1); rg=substr(line,i+2); j=index(rg,"-")
      if (j<=0) next
      s=substr(rg,1,j-1)+0; e=substr(rg,j+1)+0
      if (pr!=proj && p+0>=s && p+0<=e) { print pr; exit }
    }' "$PORT_LIST"
}

cmd_range() {
  local project="$1" range="${2:-}"
  ensure_list
  if [ -z "$range" ]; then
    local cur; cur="$(range_get "$project")"
    if [ -n "$cur" ]; then echo "RANGE $cur"; return 0; fi
    echo "NOT_SET"; return 1
  fi
  [[ "$range" =~ ^[0-9]+-[0-9]+$ ]] || die "range: <start>-<end> 형식이어야 함: $range"
  local start="${range%-*}" end="${range#*-}"
  [ "$start" -le "$end" ] || die "range: start > end: $range"
  local tmp; tmp="$(mktemp)"
  if [ -n "$(range_get "$project")" ]; then
    awk -v proj="$project" -v rg="$range" '
      /^- / {
        line=substr($0,3); i=index(line,": ")
        if (i>0 && substr(line,1,i-1)==proj) { print "- " proj ": " rg; next }
      }
      { print }
    ' "$PORT_LIST" > "$tmp" && mv "$tmp" "$PORT_LIST"
  else
    grep -q '^## 프로젝트 대역 예약' "$PORT_LIST" \
      || { rm -f "$tmp"; die "range: '## 프로젝트 대역 예약' 절이 없음"; }
    awk -v proj="$project" -v rg="$range" '
      { print }
      /^## 프로젝트 대역 예약/ && !done { print ""; print "- " proj ": " rg; done=1 }
    ' "$PORT_LIST" > "$tmp" && mv "$tmp" "$PORT_LIST"
  fi
  echo "RANGE_SET $project $range"
}

cmd_suggest() {
  local project="$1" range="${2:-}"
  ensure_list
  if [ -z "$range" ]; then range="$(range_get "$project")"; fi
  [ -z "$range" ] && range="8000-8999"
  [[ "$range" =~ ^[0-9]+-[0-9]+$ ]] || die "suggest: bad range: $range"
  local start="${range%-*}" end="${range#*-}"
  [ "$start" -le "$end" ] || die "suggest: start > end: $range"
  declare -A used=()
  local p
  # 표에 등록된 포트 (모든 프로젝트)
  while IFS= read -r p; do [ -n "$p" ] && used[$p]=1; done < <(
    awk -F'|' '/^\|/ { f=$3; gsub(/^[ \t]+|[ \t]+$/,"",f); if (f ~ /^[0-9]+$/) print f }' "$PORT_LIST"
  )
  # 실제 LISTEN 중인 포트
  while IFS= read -r p; do [ -n "$p" ] && used[$p]=1; done < <(listening_ports)
  for ((p=start; p<=end; p++)); do
    if [ -z "${used[$p]:-}" ]; then
      # 다른 프로젝트 예약 대역 안의 포트는 추천하지 않음
      [ -n "$(range_owner_of_port "$project" "$p")" ] && continue
      echo "SUGGEST $p (range $start-$end)"
      return 0
    fi
  done
  die "suggest: $start-$end 안에 빈 포트 없음"
}

cmd_add() {
  local project="$1" port="$2" service="$3" cmd_="$4" cwd_="$5" force="${6:-}"
  [ -n "$project" ] && [ -n "$port" ] || die "add: project and port required"
  [[ "$port" =~ ^[0-9]+$ ]] || die "add: port must be numeric: $port"
  ensure_list
  if has_row "$project" "$port"; then
    die "row already exists: $project:$port (use 'update')"
  fi
  # 프로젝트 간 충돌 차단: 같은 포트의 타 프로젝트 행 / 타 프로젝트 예약 대역 (--force 로 무시)
  local owner
  owner="$(awk -F'|' -v proj="$project" -v p="$port" '
    /^\|/ {
      f1=$2; gsub(/^[ \t]+|[ \t]+$/,"",f1)
      f2=$3; gsub(/^[ \t]+|[ \t]+$/,"",f2)
      if (f2 == p && f1 != proj && f1 != "프로젝트") { print f1; exit }
    }' "$PORT_LIST")"
  if [ -n "$owner" ] && [ "$force" != "--force" ]; then
    die "CONFLICT: port $port already registered to '$owner' (무시하려면 add ... --force)"
  fi
  local rowner; rowner="$(range_owner_of_port "$project" "$port")"
  if [ -n "$rowner" ] && [ "$force" != "--force" ]; then
    die "CONFLICT: port $port is in reserved range of '$rowner' (다른 포트를 쓰거나 add ... --force)"
  fi
  local myrange; myrange="$(range_get "$project")"
  if [ -n "$myrange" ]; then
    local rs="${myrange%-*}" re="${myrange#*-}"
    if [ "$port" -lt "$rs" ] || [ "$port" -gt "$re" ]; then
      echo "WARN: port $port is outside $project reserved range $myrange"
    fi
  fi
  printf '| %s | %s | %s | %s | %s |\n' \
    "$(sanitize_cell "$project")" \
    "$(sanitize_cell "$port")" \
    "$(sanitize_cell "$service")" \
    "$(sanitize_cell "$cmd_")" \
    "$(sanitize_cell "$cwd_")" \
    >> "$PORT_LIST"
  echo "ADDED $project $port"
}

cmd_update() {
  local project="$1" port="$2" service="$3" cmd_="$4" cwd_="$5"
  [ -n "$project" ] && [ -n "$port" ] || die "update: project and port required"
  has_row "$project" "$port" || die "no such row: $project:$port (use 'add')"
  local tmp; tmp="$(mktemp)"
  awk -F'|' -v proj="$project" -v p="$port" \
      -v s="$(sanitize_cell "$service")" \
      -v c="$(sanitize_cell "$cmd_")" \
      -v w="$(sanitize_cell "$cwd_")" '
    /^\|/ {
      f1=$2; gsub(/^[ \t]+|[ \t]+$/,"",f1)
      f2=$3; gsub(/^[ \t]+|[ \t]+$/,"",f2)
      if (f1 == proj && f2 == p) {
        printf "| %s | %s | %s | %s | %s |\n", proj, p, s, c, w
        next
      }
    }
    { print }
  ' "$PORT_LIST" > "$tmp" && mv "$tmp" "$PORT_LIST"
  echo "UPDATED $project $port"
}

cmd_remove() {
  local project="$1" port="$2"
  [ -n "$project" ] && [ -n "$port" ] || die "remove: project and port required"
  if ! has_row "$project" "$port"; then
    echo "NOT_FOUND $project $port"; return 0
  fi
  local tmp; tmp="$(mktemp)"
  awk -F'|' -v proj="$project" -v p="$port" '
    /^\|/ {
      f1=$2; gsub(/^[ \t]+|[ \t]+$/,"",f1)
      f2=$3; gsub(/^[ \t]+|[ \t]+$/,"",f2)
      if (f1 == proj && f2 == p) next
    }
    { print }
  ' "$PORT_LIST" > "$tmp" && mv "$tmp" "$PORT_LIST"
  echo "REMOVED $project $port"
}

find_pid() {
  local port="$1" pid=""
  if command -v ss >/dev/null 2>&1; then
    pid="$(ss -tlnpH "sport = :$port" 2>/dev/null \
      | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
  fi
  if [ -z "$pid" ] && command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -ti tcp:"$port" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$pid" ] && command -v fuser >/dev/null 2>&1; then
    pid="$(fuser -n tcp "$port" 2>/dev/null | tr -s ' \t' '\n' | grep -E '^[0-9]+$' | head -1 || true)"
  fi
  # Windows (Git Bash): ss/lsof/fuser 가 없으므로 netstat -ano 로 폴백.
  # 필드 형태($1=TCP, $4=LISTENING, $5=PID)가 Windows 전용이라 리눅스 netstat 과 오매칭되지 않는다.
  if [ -z "$pid" ] && command -v netstat >/dev/null 2>&1; then
    pid="$(netstat -ano 2>/dev/null | awk -v p="$port" '
      $1=="TCP" && $4=="LISTENING" {
        n=split($2,a,":"); if (a[n]==p) { print $5; exit }
      }' || true)"
  fi
  printf '%s' "$pid"
}

# LISTEN 중인 모든 TCP 포트 (중복 제거 없이 출력 — 호출측에서 집합으로 사용)
listening_ports() {
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | awk '{n=split($4,a,":"); if (a[n] ~ /^[0-9]+$/) print a[n]}' || true
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ano 2>/dev/null | awk '$1=="TCP" && $4=="LISTENING" {n=split($2,a,":"); if (a[n] ~ /^[0-9]+$/) print a[n]}' || true
  fi
  return 0
}

cmd_status() {
  local port="$1"
  local pid; pid="$(find_pid "$port")"
  if [ -n "$pid" ]; then
    echo "RUNNING $pid"
  else
    echo "STOPPED"
  fi
}

cmd_kill() {
  local port="$1"
  local pid; pid="$(find_pid "$port")"
  if [ -z "$pid" ]; then
    echo "NOT_RUNNING"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    sleep 0.4
    [ -z "$(find_pid "$port")" ] && { echo "KILLED $pid"; return 0; }
  done
  kill -9 "$pid" 2>/dev/null || true
  # Windows PID 는 Git Bash 의 kill 이 못 죽이는 경우가 있어 taskkill 로 재시도
  if command -v taskkill >/dev/null 2>&1; then
    taskkill //F //PID "$pid" >/dev/null 2>&1 || true
  fi
  sleep 0.4
  if [ -z "$(find_pid "$port")" ]; then
    echo "KILLED $pid"
  else
    echo "KILL_FAILED $pid"
    return 1
  fi
}

cmd_start() {
  local port="$1"; shift
  local cwd_rel="$1"; shift
  local cmd=("$@")
  local cwd
  if [ "$cwd_rel" = "—" ] || [ -z "$cwd_rel" ]; then
    cwd="$PROJECT_ROOT"
  elif [[ "$cwd_rel" = /* ]]; then
    cwd="$cwd_rel"
  else
    cwd="$PROJECT_ROOT/$cwd_rel"
  fi
  [ -d "$cwd" ] || die "cwd not found: $cwd"
  local proj_slug; proj_slug="$(basename "$PROJECT_ROOT" | tr -c 'A-Za-z0-9_-' '_')"
  local log="$LOG_DIR/${proj_slug}-${port}.log"
  : > "$log"
  ( cd "$cwd" && nohup bash -lc "${cmd[*]}" >>"$log" 2>&1 & echo $! >"$LOG_DIR/${proj_slug}-${port}.pid" ) &
  wait
  local launched_pid; launched_pid="$(cat "$LOG_DIR/${proj_slug}-${port}.pid" 2>/dev/null || true)"
  echo "STARTED pid=${launched_pid:-?} log=$log"
}

cmd_restart() {
  local port="$1"; shift
  local cwd_rel="$1"; shift
  local cmd=("$@")
  cmd_kill "$port" || true
  cmd_start "$port" "$cwd_rel" "${cmd[@]}"
}

# 주어진 pid가 project_root 안의 프로세스인지(또는 그 부모가) 검사.
# 매치 시 stdout 에 "<cwd>\t<cmdline>" 을 출력하고 0, 아니면 1.
# 최대 4 hop 까지 부모로 올라가며 (npm run dev → next-server 같은 자식 spawn 처리).
proc_belongs_to_project() {
  local pid="$1" root="$2"
  local hops=0 max_hops=4
  local cwd cmd ppid
  while [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null && [ "$hops" -lt "$max_hops" ] && [ -d "/proc/$pid" ]; do
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    if [ -n "$cwd" ] && { [ "$cwd" = "$root" ] || [ "${cwd#$root/}" != "$cwd" ]; }; then
      printf '%s\t%s\n' "$cwd" "$cmd"
      return 0
    fi
    case "$cmd" in
      *"$root"*) printf '%s\t%s\n' "${cwd:-$root}" "$cmd"; return 0 ;;
    esac
    ppid="$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)"
    [ -z "$ppid" ] && return 1
    [ "$ppid" = "$pid" ] && return 1
    pid="$ppid"
    hops=$((hops+1))
  done
  return 1
}

cmd_discover() {
  local root="${1:-$PROJECT_ROOT}"
  [ -n "$root" ] || die "discover: project_root required (or set PROJECT_ROOT)"
  if [ -d "$root" ]; then
    root="$(cd "$root" && pwd -P)"
  fi
  command -v ss >/dev/null 2>&1 || die "ss not available (install iproute2)"

  # ss -tlnpH: state recv send local_addr peer_addr "users:((..,pid=PID,fd=..))"
  # 한 줄씩 처리. pipe-while 안에서 stdout 만 사용해 누적.
  local seen=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local laddr port pids pid match_out cwd cmd cwd_rel
    laddr="$(awk '{print $4}' <<<"$line")"
    port="${laddr##*:}"
    case "$port" in ''|*[!0-9]*) continue ;; esac

    # 한 LISTEN 소켓에 pid 가 여러 개 나올 수 있음 (worker fork). 모두 검사.
    pids="$(grep -oE 'pid=[0-9]+' <<<"$line" 2>/dev/null | awk -F= '{print $2}' | sort -u || true)"
    [ -z "$pids" ] && continue

    for pid in $pids; do
      # 이미 보고한 (port,pid) 조합이면 skip
      case " $seen " in *" ${port}:${pid} "*) continue ;; esac
      if match_out="$(proc_belongs_to_project "$pid" "$root")"; then
        cwd="${match_out%%	*}"
        cmd="${match_out#*	}"
        if [ "$cwd" = "$root" ]; then
          cwd_rel="—"
        elif [ "${cwd#$root/}" != "$cwd" ]; then
          cwd_rel="${cwd#$root/}"
        else
          cwd_rel="$cwd"
        fi
        printf '%s\t%s\t%s\t%s\n' "$port" "$pid" "$cmd" "$cwd_rel"
        seen="$seen ${port}:${pid}"
        break
      fi
    done
  done < <(ss -tlnpH 2>/dev/null)
  return 0
}

# inspect <project_root>
# 프로젝트 루트 내부의 알려진 설정 파일을 스캔해 "선언된 서버"를 출력한다.
# 출력 TSV: source\tname\tport\tcommand\tcwd_rel
# 미상 필드는 "—".
cmd_inspect() {
  local root="${1:-$PROJECT_ROOT}"
  [ -n "$root" ] || die "inspect: project_root required (or set PROJECT_ROOT)"
  [ -d "$root" ] || die "inspect: directory not found: $root"
  root="$(cd "$root" && pwd -P)"
  command -v python3 >/dev/null 2>&1 || die "python3 not available"

  python3 - "$root" <<'PYEOF'
import json, os, re, sys, urllib.parse

root = sys.argv[1]
results = []  # (source, name, port, cmd, cwd_rel)

def rel(cwd):
    if not cwd or cwd == "—":
        return "—"
    abs_cwd = os.path.abspath(os.path.join(root, cwd)) if not os.path.isabs(cwd) else cwd
    if abs_cwd == root:
        return "—"
    if abs_cwd.startswith(root + os.sep):
        return abs_cwd[len(root) + 1:]
    return cwd  # 외부 경로 그대로

def port_from_url(url):
    try:
        p = urllib.parse.urlsplit(url)
        if p.port:
            return str(p.port)
    except Exception:
        pass
    m = re.search(r":(\d{2,5})(?:/|$)", url or "")
    return m.group(1) if m else "—"

def scan_mcp_like(path, source):
    if not os.path.isfile(path):
        return
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        return
    servers = data.get("servers") or data.get("mcpServers") or {}
    if not isinstance(servers, dict):
        return
    for name, sv in servers.items():
        if not isinstance(sv, dict):
            continue
        port = "—"
        if sv.get("url"):
            port = port_from_url(sv["url"])
        elif sv.get("port"):
            port = str(sv["port"])
        parts = []
        if sv.get("command"):
            parts.append(sv["command"])
        for a in sv.get("args") or []:
            parts.append(str(a))
        cmd = " ".join(parts) if parts else "—"
        cwd = rel(sv.get("cwd"))
        results.append((source, name, port, cmd, cwd))

def scan_launchers(path, source):
    if not os.path.isfile(path):
        return
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        return
    launchers = data.get("launchers") or {}
    if not isinstance(launchers, dict):
        return
    for name, cfg in launchers.items():
        if not isinstance(cfg, dict):
            continue
        parts = []
        if cfg.get("command"):
            parts.append(cfg["command"])
        for a in cfg.get("args") or []:
            parts.append(str(a))
        cmd = " ".join(parts) if parts else "—"
        cwd = rel(cfg.get("cwd"))
        port = str(cfg["port"]) if cfg.get("port") else "—"
        results.append((source, name, port, cmd, cwd))

scan_mcp_like(os.path.join(root, ".vscode", "mcp.json"),  "vscode-mcp")
scan_mcp_like(os.path.join(root, ".cursor", "mcp.json"),  "cursor-mcp")
scan_mcp_like(os.path.join(root, ".mcp.json"),            "mcp-json")
scan_mcp_like(os.path.join(root, "mcp.json"),             "mcp-json")
scan_mcp_like(os.path.join(root, "claude_desktop_config.json"), "claude-desktop")
scan_launchers(os.path.join(root, ".taskpilot", "mcp-launchers.json"), "taskpilot-launcher")

# Deep inspect: 포트가 미상(—)인 행에 대해 cmd 에서 스크립트 파일을 찾아 그 안에서 포트 리터럴을 grep 한다.
SCRIPT_EXT = re.compile(r"\.(py|js|ts|mjs|cjs|sh)$", re.I)
PORT_PATTERNS = [
    re.compile(r"uvicorn\.run\([^)]*port\s*=\s*(\d{2,5})"),
    re.compile(r"app\.run\([^)]*port\s*=\s*(\d{2,5})"),
    re.compile(r"\.listen\(\s*(\d{2,5})"),
    re.compile(r"createServer\([^)]*\)\.listen\(\s*(\d{2,5})"),
    re.compile(r"_PORT[\"']?\s*,\s*(\d{2,5})"),  # env var default like os.environ.get("MCP_SERVER_PORT", 8091)
    re.compile(r"--port[=\s]+(\d{2,5})"),
    re.compile(r"\bPORT\s*[:=]\s*(?:int\s*\(\s*)?(\d{2,5})"),
    re.compile(r"\bport\s*[:=]\s*(?:int\s*\(\s*)?(\d{2,5})"),
]

def deep_port_lookup(cwd_rel, cmd):
    if not cmd or cmd == "—":
        return None
    # cmd 토큰에서 스크립트로 보이는 파일 찾기
    script = None
    for tok in cmd.split():
        if SCRIPT_EXT.search(tok):
            script = tok
            break
    if not script:
        return None
    # cwd 해석: 상대면 root + cwd_rel + script, 절대면 그대로
    if os.path.isabs(script):
        candidates = [script]
    else:
        bases = []
        if cwd_rel and cwd_rel != "—":
            bases.append(cwd_rel if os.path.isabs(cwd_rel) else os.path.join(root, cwd_rel))
        bases.append(root)
        candidates = [os.path.join(b, script) for b in bases]
    for path in candidates:
        if not os.path.isfile(path):
            continue
        try:
            text = open(path, "r", encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        for pat in PORT_PATTERNS:
            m = pat.search(text)
            if m:
                p = int(m.group(1))
                if 1024 <= p <= 65535:
                    return str(p)
    return None

deep_resolved = []
for src, name, port, cmd, cwd in results:
    if port == "—":
        found = deep_port_lookup(cwd, cmd)
        if found:
            port = found
            src = src + "+deep"
    deep_resolved.append((src, name, port, cmd, cwd))

for r in deep_resolved:
    print("\t".join(str(x) for x in r))
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# NSSM (Non-Sucking Service Manager) — Windows 서비스 등록
# ─────────────────────────────────────────────────────────────────────────────

nssm_path() {
  if [ -n "${NSSM:-}" ] && [ -x "$NSSM" ]; then
    printf '%s' "$NSSM"; return 0
  fi
  command -v nssm.exe 2>/dev/null && return 0
  command -v nssm 2>/dev/null && return 0
  return 1
}

# 서비스명: pm_<project>_<port> — project 의 비안전 문자는 _ 로
service_name_for() {
  local project="$1" port="$2"
  local safe; safe="$(printf '%s' "$project" | tr -c 'A-Za-z0-9_' '_')"
  printf 'pm_%s_%s' "$safe" "$port"
}

# 경로를 Windows 형식으로 변환 (cygpath 가 있으면 사용)
to_winpath() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# cmd 문자열에 셸 메타문자가 있는지 (있으면 cmd.exe /c 로 래핑 필요)
cmd_needs_shell() {
  local c="$1"
  case "$c" in
    *'|'*|*'>'*|*'<'*|*'&'*|*';'*|*'$('*|*'`'*|*'&&'*|*'||'*) return 0 ;;
  esac
  return 1
}

cmd_nssm_check() {
  local p
  if p="$(nssm_path)"; then
    echo "OK $p"
    return 0
  fi
  cat >&2 <<'EOF'
NSSM_NOT_FOUND
nssm.exe 가 PATH 에 없습니다. 설치 방법:
  scoop install nssm
  choco install nssm
  또는 https://nssm.cc 에서 직접 다운로드 후 PATH 에 추가
EOF
  return 1
}

# port_list.md 의 행을 읽어 NSSM 서비스로 등록.
# 1) 시작명령 → exe + args 분리 (셸 메타문자 있으면 cmd.exe /c 로 래핑)
# 2) cwd → AppDirectory
# 3) 로그 → AppStdout/AppStderr
# 4) 자동 시작
cmd_nssm_install() {
  local project="$1" port="$2"
  local nssm; nssm="$(nssm_path)" || die "nssm not found (port_ops.sh nssm check)"

  has_row "$project" "$port" || die "no such row: $project:$port — /port_manager 로 먼저 등록"

  # port_list.md 에서 해당 행 추출
  local row; row="$(list_rows "$project" | awk -F'\t' -v p="$port" '$1==p{print; exit}')"
  [ -n "$row" ] || die "row not found: $project:$port"
  local service cmd cwd
  service="$(awk -F'\t' '{print $2}' <<<"$row")"
  cmd="$(awk -F'\t' '{print $3}' <<<"$row")"
  cwd="$(awk -F'\t' '{print $4}' <<<"$row")"

  # cwd 절대화
  local abs_cwd
  if [ "$cwd" = "—" ] || [ -z "$cwd" ]; then
    abs_cwd="$PROJECT_ROOT"
  elif [[ "$cwd" = /* ]] || [[ "$cwd" =~ ^[A-Za-z]:[\\/] ]]; then
    abs_cwd="$cwd"
  else
    abs_cwd="$PROJECT_ROOT/$cwd"
  fi
  [ -d "$abs_cwd" ] || die "cwd not found: $abs_cwd"

  # exe / args 분리
  local exe args
  if cmd_needs_shell "$cmd"; then
    exe="$(command -v cmd.exe 2>/dev/null || echo cmd.exe)"
    args="/c $cmd"
  else
    exe="$(awk '{print $1}' <<<"$cmd")"
    args="${cmd#$exe}"; args="${args# }"
    # exe 절대화 (상대경로면 PROJECT_ROOT 기준)
    if [[ "$exe" != /* ]] && [[ ! "$exe" =~ ^[A-Za-z]:[\\/] ]]; then
      # cwd 안에 있나? 없으면 PROJECT_ROOT 기준
      if [ -e "$abs_cwd/$exe" ]; then
        exe="$abs_cwd/$exe"
      elif [ -e "$PROJECT_ROOT/$exe" ]; then
        exe="$PROJECT_ROOT/$exe"
      else
        # PATH 에서 찾기 (이름만 주어진 경우, 예: npm, uvicorn)
        local found; found="$(command -v "$exe" 2>/dev/null || true)"
        [ -n "$found" ] && exe="$found"
      fi
    fi
  fi

  # Windows 경로로 변환
  local exe_win cwd_win
  exe_win="$(to_winpath "$exe")"
  cwd_win="$(to_winpath "$abs_cwd")"

  # 로그 경로
  local svc; svc="$(service_name_for "$project" "$port")"
  mkdir -p "$LOG_DIR"
  local log_out="$LOG_DIR/${svc}.log"
  : > "$log_out"
  local log_win; log_win="$(to_winpath "$log_out")"

  # 이미 등록되어 있으면 중단
  if "$nssm" status "$svc" >/dev/null 2>&1; then
    die "service already exists: $svc (먼저 nssm uninstall)"
  fi

  # nssm install (args 가 비어 있어도 OK)
  if [ -n "$args" ]; then
    "$nssm" install "$svc" "$exe_win" "$args" >/dev/null \
      || die "nssm install failed (관리자 권한 필요할 수 있음)"
  else
    "$nssm" install "$svc" "$exe_win" >/dev/null \
      || die "nssm install failed (관리자 권한 필요할 수 있음)"
  fi
  "$nssm" set "$svc" AppDirectory "$cwd_win" >/dev/null || true
  "$nssm" set "$svc" AppStdout    "$log_win" >/dev/null || true
  "$nssm" set "$svc" AppStderr    "$log_win" >/dev/null || true
  "$nssm" set "$svc" AppStdoutCreationDisposition 4 >/dev/null || true
  "$nssm" set "$svc" AppStderrCreationDisposition 4 >/dev/null || true
  "$nssm" set "$svc" Start        SERVICE_AUTO_START >/dev/null || true
  "$nssm" set "$svc" DisplayName  "port_manager: $service ($project :$port)" >/dev/null || true
  "$nssm" set "$svc" Description  "Auto-registered by /port_manager. cmd: $cmd" >/dev/null || true
  "$nssm" set "$svc" AppExit Default Restart >/dev/null || true

  echo "NSSM_INSTALLED $svc"
  echo "  exe: $exe_win"
  echo "  args: $args"
  echo "  cwd: $cwd_win"
  echo "  log: $log_win"
}

cmd_nssm_uninstall() {
  local project="$1" port="$2"
  local nssm; nssm="$(nssm_path)" || die "nssm not found"
  local svc; svc="$(service_name_for "$project" "$port")"
  if ! "$nssm" status "$svc" >/dev/null 2>&1; then
    echo "NSSM_NOT_INSTALLED $svc"
    return 0
  fi
  "$nssm" stop "$svc" >/dev/null 2>&1 || true
  "$nssm" remove "$svc" confirm >/dev/null \
    || die "nssm remove failed (관리자 권한 필요할 수 있음)"
  echo "NSSM_REMOVED $svc"
}

cmd_nssm_start() {
  local project="$1" port="$2"
  local nssm; nssm="$(nssm_path)" || die "nssm not found"
  local svc; svc="$(service_name_for "$project" "$port")"
  "$nssm" status "$svc" >/dev/null 2>&1 || die "service not installed: $svc"
  "$nssm" start "$svc" >/dev/null \
    || die "nssm start failed (관리자 권한 필요할 수 있음)"
  echo "NSSM_STARTED $svc"
}

cmd_nssm_stop() {
  local project="$1" port="$2"
  local nssm; nssm="$(nssm_path)" || die "nssm not found"
  local svc; svc="$(service_name_for "$project" "$port")"
  "$nssm" status "$svc" >/dev/null 2>&1 || die "service not installed: $svc"
  "$nssm" stop "$svc" >/dev/null \
    || die "nssm stop failed (관리자 권한 필요할 수 있음)"
  echo "NSSM_STOPPED $svc"
}

cmd_nssm_restart() {
  local project="$1" port="$2"
  local nssm; nssm="$(nssm_path)" || die "nssm not found"
  local svc; svc="$(service_name_for "$project" "$port")"
  "$nssm" status "$svc" >/dev/null 2>&1 || die "service not installed: $svc"
  "$nssm" restart "$svc" >/dev/null \
    || die "nssm restart failed (관리자 권한 필요할 수 있음)"
  echo "NSSM_RESTARTED $svc"
}

cmd_nssm_status() {
  local project="$1" port="$2"
  local nssm; nssm="$(nssm_path)" || die "nssm not found"
  local svc; svc="$(service_name_for "$project" "$port")"
  local s
  if s="$("$nssm" status "$svc" 2>/dev/null)"; then
    # nssm status 출력은 끝에 \r 가 붙을 수 있어 정리
    s="${s%$'\r'}"
    echo "$s $svc"
  else
    echo "SERVICE_NOT_INSTALLED $svc"
  fi
}

# 등록된 pm_* 서비스 목록 — TSV: 서비스명\t상태\t포트
cmd_nssm_list() {
  local project="${1:-}"
  local nssm; nssm="$(nssm_path)" || die "nssm not found"
  # PowerShell 로 pm_* 서비스 조회 (sc 보다 안정적). prefix 매칭으로 빠르게.
  local prefix="pm_"
  if [ -n "$project" ]; then
    local safe; safe="$(printf '%s' "$project" | tr -c 'A-Za-z0-9_' '_')"
    prefix="pm_${safe}_"
  fi
  powershell.exe -NoProfile -Command "Get-Service -Name '${prefix}*' -ErrorAction SilentlyContinue | ForEach-Object { '{0}\`t{1}' -f \$_.Name, \$_.Status }" 2>/dev/null \
    | tr -d '\r' \
    | awk -F'\t' '
        {
          # 서비스명에서 포트 추출: 마지막 _ 뒤
          n=split($1, parts, "_")
          port=parts[n]
          print $1 "\t" $2 "\t" port
        }
      '
}

# nssm 서브커맨드 디스패처
cmd_nssm() {
  local op="${1:-}"; shift || true
  case "$op" in
    check)     cmd_nssm_check ;;
    install)   [ $# -ge 2 ] || die "usage: nssm install <project> <port>";    cmd_nssm_install   "$@" ;;
    uninstall) [ $# -ge 2 ] || die "usage: nssm uninstall <project> <port>";  cmd_nssm_uninstall "$@" ;;
    start)     [ $# -ge 2 ] || die "usage: nssm start <project> <port>";      cmd_nssm_start     "$@" ;;
    stop)      [ $# -ge 2 ] || die "usage: nssm stop <project> <port>";       cmd_nssm_stop      "$@" ;;
    restart)   [ $# -ge 2 ] || die "usage: nssm restart <project> <port>";    cmd_nssm_restart   "$@" ;;
    status)    [ $# -ge 2 ] || die "usage: nssm status <project> <port>";     cmd_nssm_status    "$@" ;;
    list)      cmd_nssm_list "${1:-}" ;;
    "")        die "usage: nssm {check|install|uninstall|start|stop|restart|status|list}" ;;
    *)         die "unknown nssm op: $op" ;;
  esac
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)     [ $# -ge 1 ] || die "usage: list <project>";     list_rows "$1" ;;
    list_all) list_all_rows ;;
    has)      [ $# -ge 2 ] || die "usage: has <project> <port>";    has_row "$1" "$2" && echo "YES" || { echo "NO"; exit 1; } ;;
    add)      [ $# -ge 5 ] || die "usage: add <project> <port> <service> <cmd> <cwd> [--force]";    cmd_add "$@" ;;
    update)   [ $# -ge 5 ] || die "usage: update <project> <port> <service> <cmd> <cwd>"; cmd_update "$@" ;;
    remove)   [ $# -ge 2 ] || die "usage: remove <project> <port>";  cmd_remove "$@" ;;
    suggest)  [ $# -ge 1 ] || die "usage: suggest <project> [<start>-<end>]"; cmd_suggest "$@" ;;
    range)    [ $# -ge 1 ] || die "usage: range <project> [<start>-<end>]";   cmd_range "$@" ;;
    status)   [ $# -ge 1 ] || die "usage: status <port>";      cmd_status "$1" ;;
    kill)     [ $# -ge 1 ] || die "usage: kill <port>";        cmd_kill "$1" ;;
    start)    [ $# -ge 3 ] || die "usage: start <port> <cwd> <cmd...>";   cmd_start "$@" ;;
    restart)  [ $# -ge 3 ] || die "usage: restart <port> <cwd> <cmd...>"; cmd_restart "$@" ;;
    discover) cmd_discover "${1:-}" ;;
    inspect)  cmd_inspect "${1:-}" ;;
    nssm)     cmd_nssm "$@" ;;
    ""|help|-h|--help)
      awk 'NR==1 {next} /^#/ || /^[[:space:]]*$/ {print; next} {exit}' "$0"
      ;;
    *) die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
