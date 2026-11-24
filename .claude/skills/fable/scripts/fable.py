"""Claude Fable 5.2 를 Anthropic API 키로 부른다 — /fable 스킬의 실행부.

묻기:
    python -X utf8 fable.py (-p "질문" | --prompt-file 질문.md | 표준 입력) [--file 경로 …] [--system 글] [--effort high] [--max-tokens 64000] [--out 답.md] [--no-fallback]
키 관리(키는 여러 개 — 차례대로 쓰고, 쓸 수 없으면 다음 키로):
    python -X utf8 fable.py key add [--name 이름] [--first] [--no-test]   ← 키는 표준 입력으로(명령 줄에 안 남게 · 공백·줄로 여럿) · `key set` 도 같다
    python -X utf8 fable.py key list | key test [선택] | key first <선택> | key remove <선택>|--all     (선택 = 번호 · 끝 네 글자 이상 · 이름)

- 키 목록(「등록한 키」): env FABLE_API_KEY(있으면 맨 앞) → 저장한 키들(~/.claude/fable/config.json — `key add` 한 차례 · `key first` 로 앞으로).
  등록한 키가 하나도 없을 때만 전처럼 env ANTHROPIC_API_KEY → ~/.claude/settings.json 의 env.ANTHROPIC_API_KEY 의 첫 키 하나를 쓴다
  (등록한 키끼리만 돌려 쓴다 — 등록하지 않은 다른 계정의 키로 넘어가 청구되지 않게).
- 다음 키로 넘어가는 때 = 키를 바꾸면 나을 수 있는 오류(`problem`): 키 거절(401) · 크레딧 부족 · 권한 없음(403) · 사용 한도(429).
  서버 과부하(529)·서버 오류·연결 오류·요청 자체의 오류는 키 탓이 아니라 넘어가지 않는다. 답을 받기 시작한 뒤의 오류도 넘어가지 않는다(답이 두 번 섞이지 않게).
- 쓸 수 없던 키는 잠시 차례를 뒤로 미룬다(~/.claude/fable/key_state.json — 키 글이 아니라 지문만 · 키 거절·권한 24시간 · 크레딧 1시간 · 한도 retry-after(없으면 60초)).
  빼는 것이 아니라 뒤로 미룰 뿐이고, 그 키로 다시 되면 기록을 지운다.
  저장 파일은 스킬 폴더 밖(홈)에 둔다 — 스킬 원본은 git 저장소라 키가 커밋되면 안 된다. 키 글은 어디에도 찍지 않는다(끝 네 글자만).
- 모델 claude-fable-5-2 · 스트리밍(긴 답도 시간 초과 없이) · thinking 은 안 보냄(Fable 은 늘 켜짐) · effort 기본 high.
- 거절(refusal) 대비: 서버 쪽 대체(beta server-side-fallback-2026-07-01, fallbacks="default") — 거절되면 같은 요청을 다른 모델이 이어 받는다. --no-fallback 으로 끔.
- 첨부(--file): 글 파일은 <file path="…"> 로 감싸 질문 앞에, 그림(png·jpg·gif·webp)은 image 블록, PDF 는 document 블록.
- 답 글은 표준 출력(받는 대로), 쓰인 모델·키·토큰·대략 비용은 표준 오류 끝 줄에. --out 이면 답을 그 파일에도 쓴다.
종료 코드: 0 성공 · 1 키 없음·인자 오류 · 2 API 오류(쓸 수 있는 키가 없음 포함) · 3 거절(대체 모델까지).
에이전트 방식(/fable agent <일> — Fable 을 도구 가진 하위 에이전트로 띄움)은 이 스크립트를 쓰지 않는다: API 키로 청구되는 키 에이전트 = 같은 폴더의 fable_agent.py
(키 차례 · 넘어가기는 이 모듈의 candidates · problem · mark), 이 세션의 계정으로 청구되는 세션 에이전트 = Agent 도구 — SKILL.md 「키 에이전트로 맡기기」·「세션 에이전트로 맡기기」."""
import argparse
import base64
import hashlib
import json
import mimetypes
import os
import sys
import time
from pathlib import Path

MODEL = "claude-fable-5-2"
PRICE = (8.0, 40.0)   # 입력·출력 $ / 1M 토큰(claude-fable-5-2 — 2026-11 기준)
IMAGE = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp"}
TEXT_MAX = 2_000_000   # 글 파일 하나의 글자 상한(넘으면 멈춤 — 잘라 보내지 않는다)
STORE = Path(os.environ.get("FABLE_CONFIG") or Path.home() / ".claude" / "fable" / "config.json")
STATE = STORE.parent / "key_state.json"   # 키마다 마지막 실패(차례를 뒤로 미룸) — 키 글 없이 지문으로
SETTINGS = Path.home() / ".claude" / "settings.json"
REST = {"auth": 24 * 3600, "perm": 24 * 3600, "billing": 3600}   # 쓸 수 없던 키를 뒤로 미루는 시간(초) — 한도(429)는 retry-after


# ---- 저장 ----------------------------------------------------------------------------------------

def _write(path, data):
    """json 을 통째로 바꿔 쓴다(쓰다 끊겨도 앞 파일이 남게)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)   # Windows 에서는 읽기 전용 표시만 — 사용자 폴더 권한에 기댄다
    except OSError:
        pass


def _load():
    """저장한 키 [{key, name, saved}] — 옛 꼴 {"api_key": …} 도 읽는다(다음 저장 때 새 꼴로 바뀐다)."""
    try:
        d = json.loads(STORE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(d, dict):
        return []
    rows = d.get("keys")
    if rows is None and d.get("api_key"):
        rows = [{"key": d["api_key"], "saved": d.get("saved", "")}]
    out = []
    for e in rows or []:
        k = (e.get("key") or "").strip() if isinstance(e, dict) else ""
        if k and all(k != o["key"] for o in out):
            out.append({"key": k, "name": (e.get("name") or "").strip(), "saved": e.get("saved", "")})
    return out


def _store(rows):
    if rows:
        _write(STORE, {"keys": rows})
    elif STORE.is_file():
        STORE.unlink()


def _settings():
    try:
        return ((json.loads(SETTINGS.read_text(encoding="utf-8")).get("env") or {}).get("ANTHROPIC_API_KEY") or "").strip()
    except (OSError, ValueError):
        return ""


def fp(k):
    """키의 지문 — 기록 파일에 키 글 대신 쓴다."""
    return hashlib.sha256(k.encode("utf-8")).hexdigest()[:16]


def _state():
    try:
        d = json.loads(STATE.read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def mark(k, reason=None, wait=0):
    """키의 마지막 결과 — reason 이 있으면 쓸 수 없었음(wait 초 동안 차례를 뒤로), 없으면 됨(기록을 지움). 기록을 못 써도 넘어간다(차례만의 일)."""
    st = _state()
    if reason:
        now = int(time.time())
        st[fp(k)] = {"reason": reason, "at": now, "until": now + int(wait)}
    elif st.pop(fp(k), None) is None:
        return
    try:
        _write(STATE, st)
    except OSError:
        pass


# ---- 키 차례 -------------------------------------------------------------------------------------

def registered():
    """등록한 키 [(키, 출처)] — env FABLE_API_KEY(있으면 맨 앞) → 저장한 키들(저장 차례)."""
    out = []
    env = os.environ.get("FABLE_API_KEY", "").strip()
    if env:
        out.append((env, "env FABLE_API_KEY"))
    for i, e in enumerate(_load(), 1):
        if all(e["key"] != k for k, _ in out):
            out.append((e["key"], f"저장한 키 {i}" + (f" 「{e['name']}」" if e["name"] else "")))
    return out


def ambient():
    """등록하지 않은 키 [(키, 출처)] — 등록한 키가 없을 때만 그 첫 키 하나를 쓴다(옛 차례)."""
    out = []
    for k, src in ((os.environ.get("ANTHROPIC_API_KEY", "").strip(), "env ANTHROPIC_API_KEY"), (_settings(), "~/.claude/settings.json 의 env")):
        if k and all(k != o for o, _ in out):
            out.append((k, src))
    return out


def candidates():
    """이번 호출에 차례로 쓸 키 [(키, 출처)] — 등록한 키(쉬는 중인 키는 뒤로, 일찍 풀리는 것부터). 등록한 키가 없으면 ambient 의 첫 키 하나."""
    reg = registered()
    if not reg:
        return ambient()[:1]
    st, now = _state(), time.time()

    def until(c):
        return (st.get(fp(c[0])) or {}).get("until", 0)
    return [c for c in reg if until(c) <= now] + sorted((c for c in reg if until(c) > now), key=until)


def resolve():
    """(키, 출처) — candidates 의 첫 키. 없으면 ("", "")."""
    c = candidates()
    return c[0] if c else ("", "")


def mask(k):
    return f"{k[:7]}…{k[-4:]}" if len(k) > 12 else "…"


def problem(status, kind="", message="", retry_after=None):
    """키를 바꾸면 나을 수 있는 오류인가 → (까닭, 뒤로 미룰 초) 또는 None.
    status = HTTP 상태 · kind = 오류 종류(API 의 error.type 또는 Claude CLI 의 error — authentication_failed · billing_error · rate_limit).
    서버 과부하(529)·서버 오류(5xx)·요청 자체의 오류(400)는 키 탓이 아니다 — 400 은 크레딧 부족 글일 때만."""
    m, kind = (message or "").lower(), kind or ""
    if status == 401 or kind in ("authentication_error", "authentication_failed"):
        return "키 거절(401)", REST["auth"]
    if status == 402 or kind == "billing_error" or "credit balance" in m:
        return "크레딧 부족", REST["billing"]
    if status == 403 or kind == "permission_error":
        return "권한 없음(403)", REST["perm"]
    if status == 429 or kind in ("rate_limit_error", "rate_limit"):
        try:
            wait = float(retry_after)
        except (TypeError, ValueError):
            wait = 60
        return "사용 한도(429)", min(max(wait, 30), 3600)
    return None


def _sdk_err(e):
    body = e.body if isinstance(getattr(e, "body", None), dict) else {}
    return body.get("error") if isinstance(body.get("error"), dict) else {}


def sdk_message(e):
    """anthropic.APIStatusError 의 짧은 글 — 본문의 error.message(없으면 SDK 의 글)."""
    return _sdk_err(e).get("message") or e.message


def sdk_problem(e):
    """anthropic.APIStatusError → problem(…)."""
    try:
        ra = e.response.headers.get("retry-after")
    except AttributeError:
        ra = None
    return problem(e.status_code, _sdk_err(e).get("type", ""), sdk_message(e), ra)


def ping(k):
    """작은 호출 한 번으로 키를 확인 → (됨, 글). 비용은 토큰 수백 개. 결과를 차례 기록(mark)에도 남긴다."""
    import anthropic
    try:
        r = anthropic.Anthropic(api_key=k, timeout=120.0, max_retries=1).messages.create(
            model=MODEL, max_tokens=256, output_config={"effort": "low"}, messages=[{"role": "user", "content": "Reply with the single word: ok"}])
    except anthropic.APIStatusError as e:
        p = sdk_problem(e)
        if p:
            mark(k, *p)
        return False, f"{p[0] if p else f'API 오류 {e.status_code}'}: {sdk_message(e)}"
    except anthropic.APIConnectionError as e:
        return False, f"연결 오류: {e}"
    mark(k)
    return True, f"응답 받음({r.model} · 입력 {r.usage.input_tokens} · 출력 {r.usage.output_tokens} 토큰)"


# ---- 키 관리 -------------------------------------------------------------------------------------

def _pick(rows, sel):
    """저장한 키 하나의 자리 — 번호(1부터) · 끝 네 글자 이상 · 이름. 못 고르면 멈춘다."""
    sel = (sel or "").strip()
    if sel.isdigit() and 1 <= int(sel) <= len(rows):
        return int(sel) - 1
    hits = [i for i, e in enumerate(rows) if (len(sel) >= 4 and e["key"].endswith(sel)) or (e["name"] and e["name"] == sel)]
    if len(hits) == 1:
        return hits[0]
    sys.exit(f"[fable] 「{sel}」 에 맞는 저장한 키가 {'여럿입니다' if hits else '없습니다'} — `key list` 의 번호로 고르세요")


def _ago(t):
    s = int(abs(time.time() - t))
    return f"{s // 3600}시간" if s >= 3600 else f"{s // 60}분" if s >= 60 else f"{s}초"


def _show():
    """등록한 키 목록과 다음 호출의 차례를 찍는다 → 쓸 키가 있나."""
    reg, st, now = registered(), _state(), time.time()
    saved = {e["key"]: e for e in _load()}
    if not reg:
        amb = ambient()
        if not amb:
            print("[fable] 쓸 키가 없습니다 — `/fable key <API 키>` 로 등록하세요")
            return False
        print(f"[fable] 등록한 키 없음 — 전처럼 {amb[0][1]} 의 키 {mask(amb[0][0])} 하나를 씁니다(넘어갈 다른 키 없음)")
        return True
    print(f"[fable] 등록한 키 {len(reg)}개 — 차례대로 쓰고, 쓸 수 없으면(키 거절 · 크레딧 부족 · 권한 · 사용 한도) 다음 키로:")
    for k, src in reg:
        r, e = st.get(fp(k)) or {}, saved.get(k) or {}
        note = ""
        if r:
            note = (f" · 쉬는 중: {r.get('reason')}({_ago(r.get('at', now))} 전 · {_ago(r['until'])} 뒤 제 차례로)" if r.get("until", 0) > now
                    else f" · 마지막 실패: {r.get('reason')}({_ago(r.get('at', now))} 전)")
        print(f"  {src} — {mask(k)}{' · 저장 ' + e['saved'] if e.get('saved') else ''}{note}")
    print(f"[fable] 다음 호출의 차례: {' → '.join(mask(k) for k, _ in candidates())}")
    rest = [s for k, s in ambient() if all(k != o for o, _ in reg)]
    if rest:
        print(f"[fable] 다른 곳의 키(등록하지 않아 안 씀): {', '.join(rest)}")
    return True


def _add(a):
    toks = list(dict.fromkeys(sys.stdin.read().split()))
    if not toks:
        sys.exit("[fable] 키를 표준 입력으로 주세요(명령 줄 인자로 받지 않습니다)")
    if any(not t.startswith("sk-ant-") for t in toks):
        sys.exit("[fable] Anthropic API 키 꼴(sk-ant-…)이 아닌 것이 있습니다 — 아무것도 저장하지 않았습니다")
    if a.name and len(toks) > 1:
        sys.exit("[fable] --name 은 키 하나를 더할 때만 씁니다 — 키마다 따로 더하세요")
    rows, picked, failed = _load(), [], False
    for k in toks:
        at = next((i for i, e in enumerate(rows) if e["key"] == k), None)
        if at is not None:
            if a.name:
                rows[at]["name"] = a.name
            print(f"[fable] 이미 등록된 키 {mask(k)}(저장한 키 {at + 1}){' — 이름을 「' + a.name + '」 로' if a.name else ''}")
        else:
            if not a.no_test:
                ok, note = ping(k)
                print(f"[fable] 키 {mask(k)} 확인: {note}")
                if not ok:
                    print(f"[fable] 키 {mask(k)} 는 저장하지 않았습니다 — 확인 없이 넣으려면 --no-test", file=sys.stderr)
                    failed = True
                    continue
            rows.append({"key": k, "name": a.name or "", "saved": time.strftime("%Y-%m-%d %H:%M:%S")})
            print(f"[fable] 저장함 {mask(k)}")
        picked.append(k)
    if a.first and picked:
        rows = [e for k in picked for e in rows if e["key"] == k] + [e for e in rows if e["key"] not in picked]
    _store(rows)
    _show()
    if failed:
        sys.exit(2)


def key_cmd(argv):
    ap = argparse.ArgumentParser(prog="fable.py key")
    ap.add_argument("action", nargs="?", default="list", choices=("add", "set", "list", "status", "test", "first", "remove"))
    ap.add_argument("sel", nargs="?", help="저장한 키 고르기 — 번호(1부터) · 끝 네 글자 이상 · 이름")
    ap.add_argument("--name", help="add: 키에 붙일 이름(목록·고르기에 씀)")
    ap.add_argument("--first", action="store_true", help="add: 더한 키를 맨 앞 차례로")
    ap.add_argument("--no-test", action="store_true", help="add: 저장 전에 작은 호출로 확인하지 않음")
    ap.add_argument("--all", action="store_true", help="remove: 저장한 키를 모두 지움")
    a = ap.parse_args(argv)
    if a.action in ("add", "set"):
        return _add(a)
    if a.action in ("list", "status"):
        if not _show():
            sys.exit(1)
        return
    if a.action == "first":
        rows = _load()
        if not a.sel:
            sys.exit("[fable] 맨 앞으로 올릴 키를 고르세요(번호 · 끝 네 글자 · 이름)")
        i = _pick(rows, a.sel)
        rows.insert(0, rows.pop(i))
        _store(rows)
        print(f"[fable] {mask(rows[0]['key'])} 를 저장한 키 1 로 올림")
        _show()
        return
    if a.action == "remove":
        rows = _load()
        if not rows:
            print("[fable] 저장한 키가 없습니다")
        elif a.all or (not a.sel and len(rows) == 1):
            gone, rows = rows, []
        elif not a.sel:
            _show()
            sys.exit("[fable] 저장한 키가 여럿입니다 — 지울 키를 고르세요(번호 · 끝 네 글자 · 이름) 또는 --all")
        else:
            gone = [rows.pop(_pick(rows, a.sel))]
        if _load() != rows:
            _store(rows)
            for e in gone:
                mark(e["key"])
            print(f"[fable] 저장한 키를 지움: {', '.join(mask(e['key']) for e in gone)}")
        _show()
        return
    # test — 고른 키 하나, 아니면 이번 호출에 쓸 수 있는 키 모두
    if a.sel:
        rows = _load()
        i = _pick(rows, a.sel)
        targets = [(rows[i]["key"], f"저장한 키 {i + 1}")]
    else:
        targets = registered() or ambient()[:1]
    if not targets:
        sys.exit("[fable] 쓸 키가 없습니다 — `/fable key <API 키>` 로 등록하세요")
    oks = 0
    for k, src in targets:
        ok, note = ping(k)
        oks += ok
        print(f"[fable] {src} {mask(k)} 확인: {note}")
    print(f"[fable] 다음 호출의 차례: {' → '.join(mask(k) for k, _ in candidates())}")
    if not oks:
        sys.exit(2)


# ---- 묻기 ----------------------------------------------------------------------------------------

def blocks(files, prompt):
    out = []
    for f in files:
        p = Path(f)
        if not p.is_file():
            sys.exit(f"[fable] 파일 없음: {f}")
        ext = p.suffix.lower()
        if ext in IMAGE:
            out.append({"type": "image", "source": {"type": "base64", "media_type": IMAGE[ext], "data": base64.standard_b64encode(p.read_bytes()).decode()}})
        elif ext == ".pdf":
            out.append({"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": base64.standard_b64encode(p.read_bytes()).decode()}})
        else:
            text = p.read_text(encoding="utf-8", errors="replace")
            if len(text) > TEXT_MAX:
                sys.exit(f"[fable] 파일이 너무 큼({len(text):,}자): {f} — 필요한 부분만 골라 보내세요")
            out.append({"type": "text", "text": f'<file path="{p.as_posix()}" type="{mimetypes.guess_type(p.name)[0] or "text/plain"}">\n{text}\n</file>'})
    out.append({"type": "text", "text": prompt})
    return out


def ask(argv):
    ap = argparse.ArgumentParser(prog="fable.py", description="Claude Fable 5.2 를 API 키로 부른다")
    ap.add_argument("-p", "--prompt")
    ap.add_argument("--prompt-file")
    ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--system")
    ap.add_argument("--effort", default="high", choices=("low", "medium", "high", "xhigh", "max"))
    ap.add_argument("--max-tokens", type=int, default=64000)
    ap.add_argument("--out")
    ap.add_argument("--no-fallback", action="store_true")
    a = ap.parse_args(argv)
    prompt = a.prompt if a.prompt is not None else Path(a.prompt_file).read_text(encoding="utf-8") if a.prompt_file else sys.stdin.read()
    if not prompt.strip():
        sys.exit("[fable] 질문이 비었습니다(-p · --prompt-file · 표준 입력)")
    cands = candidates()
    if not cands:
        sys.exit("[fable] API 키가 없습니다 — `/fable key <API 키>` 로 등록하세요")

    import anthropic
    kw = {"model": MODEL, "max_tokens": a.max_tokens, "messages": [{"role": "user", "content": blocks(a.file, prompt)}], "output_config": {"effort": a.effort}}
    if a.system:
        kw["system"] = a.system
    if not a.no_fallback:
        kw.update(betas=["server-side-fallback-2026-07-01"], fallbacks="default")
    skipped = []
    for i, (k, src) in enumerate(cands):
        parts = []
        try:
            with anthropic.Anthropic(api_key=k, timeout=1800.0).beta.messages.stream(**kw) as stream:
                for text in stream.text_stream:
                    parts.append(text)
                    sys.stdout.write(text)
                    sys.stdout.flush()
                msg = stream.get_final_message()
        except anthropic.APIStatusError as e:
            p = None if parts else sdk_problem(e)   # 답을 받기 시작했으면 넘어가지 않는다(답이 섞이지 않게)
            if not p:
                print(f"\n[fable] API 오류 {e.status_code}: {sdk_message(e)} — 키 {mask(k)}({src})", file=sys.stderr)
                sys.exit(2)
            mark(k, *p)
            skipped.append(f"{mask(k)} {p[0]}")
            if i + 1 < len(cands):
                print(f"[fable] 키 {mask(k)}({src}) 쓸 수 없음 — {p[0]}: {sdk_message(e)} · 다음 키 {mask(cands[i + 1][0])} 로", file=sys.stderr)
                continue
            print(f"[fable] 쓸 수 있는 키가 없습니다 — {' · '.join(skipped)}. 크레딧을 채우거나 `/fable key <API 키>` 로 키를 더하세요", file=sys.stderr)
            sys.exit(2)
        except anthropic.APIConnectionError as e:
            print(f"\n[fable] 연결 오류: {e}", file=sys.stderr)
            sys.exit(2)
        mark(k)
        break
    answer = "".join(parts)
    if a.out:
        Path(a.out).write_text(answer, encoding="utf-8")
    u = msg.usage
    fell = [b for b in msg.content if b.type == "fallback"]
    cost = (u.input_tokens * PRICE[0] + u.output_tokens * PRICE[1]) / 1e6
    note = f" · 대체: {', '.join(f'{b.from_.model}→{b.to.model}' for b in fell)}" if fell else ""
    note += f" · 넘어간 키: {' · '.join(skipped)}" if skipped else ""
    print(f"\n\n[fable] 모델 {msg.model}{note} · 키 {mask(k)}({src}) · effort {a.effort} · 입력 {u.input_tokens:,} · 출력 {u.output_tokens:,} 토큰 · 약 ${cost:.4f}(Fable 단가) · stop {msg.stop_reason}", file=sys.stderr)
    if msg.stop_reason == "refusal":
        d = msg.stop_details
        print(f"[fable] 거절됨 — {getattr(d, 'category', None)}: {getattr(d, 'explanation', '')}", file=sys.stderr)
        sys.exit(3)
    if msg.stop_reason == "max_tokens":
        print(f"[fable] 답이 --max-tokens {a.max_tokens} 에서 잘렸습니다", file=sys.stderr)


def main():
    for s in (sys.stdout, sys.stderr):
        s.reconfigure(encoding="utf-8")
    if sys.argv[1:2] == ["key"]:
        key_cmd(sys.argv[2:])
    else:
        ask(sys.argv[1:])


if __name__ == "__main__":
    main()
