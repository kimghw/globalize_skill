"""Claude Fable 5.2 를 Anthropic API 키로 부른다 — /fable 스킬의 실행부.

묻기:
    python -X utf8 fable.py (-p "질문" | --prompt-file 질문.md | 표준 입력) [--file 경로 …] [--system 글] [--effort high] [--max-tokens 64000] [--out 답.md] [--no-fallback]
키 설정:
    python -X utf8 fable.py key set [--no-test]   ← 키는 표준 입력으로(명령 줄에 안 남게)
    python -X utf8 fable.py key status | key test | key remove

- 키를 찾는 차례: env FABLE_API_KEY → 저장한 키(~/.claude/fable/config.json — `key set`) → env ANTHROPIC_API_KEY → ~/.claude/settings.json 의 env.ANTHROPIC_API_KEY.
  저장 파일은 스킬 폴더 밖(홈)에 둔다 — 스킬 원본은 git 저장소라 키가 커밋되면 안 된다. 키 글은 어디에도 찍지 않는다(끝 네 글자만).
- 모델 claude-fable-5-2 · 스트리밍(긴 답도 시간 초과 없이) · thinking 은 안 보냄(Fable 은 늘 켜짐) · effort 기본 high.
- 거절(refusal) 대비: 서버 쪽 대체(beta server-side-fallback-2026-07-01, fallbacks="default") — 거절되면 같은 요청을 다른 모델이 이어 받는다. --no-fallback 으로 끔.
- 첨부(--file): 글 파일은 <file path="…"> 로 감싸 질문 앞에, 그림(png·jpg·gif·webp)은 image 블록, PDF 는 document 블록.
- 답 글은 표준 출력(받는 대로), 쓰인 모델·토큰·대략 비용은 표준 오류 끝 줄에. --out 이면 답을 그 파일에도 쓴다.
종료 코드: 0 성공 · 1 키 없음·인자 오류 · 2 API 오류(키 거절 포함) · 3 거절(대체 모델까지)."""
import argparse
import base64
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
SETTINGS = Path.home() / ".claude" / "settings.json"


# ---- 키 ------------------------------------------------------------------------------------------

def _saved():
    try:
        return (json.loads(STORE.read_text(encoding="utf-8")).get("api_key") or "").strip()
    except (OSError, ValueError):
        return ""


def _settings():
    try:
        return ((json.loads(SETTINGS.read_text(encoding="utf-8")).get("env") or {}).get("ANTHROPIC_API_KEY") or "").strip()
    except (OSError, ValueError):
        return ""


def resolve():
    """(키, 출처 이름) — 차례는 모듈 설명. 없으면 ("", "")."""
    for src, get in (("env FABLE_API_KEY", lambda: os.environ.get("FABLE_API_KEY", "").strip()), (f"저장한 키 {STORE}", _saved),
                     ("env ANTHROPIC_API_KEY", lambda: os.environ.get("ANTHROPIC_API_KEY", "").strip()), (f"{SETTINGS} 의 env", _settings)):
        k = get()
        if k:
            return k, src
    return "", ""


def mask(k):
    return f"{k[:7]}…{k[-4:]}" if len(k) > 12 else "…"


def ping(k):
    """작은 호출 한 번으로 키를 확인 → (됨, 글). 비용은 토큰 수백 개."""
    import anthropic
    try:
        r = anthropic.Anthropic(api_key=k, timeout=120.0, max_retries=1).messages.create(
            model=MODEL, max_tokens=256, output_config={"effort": "low"}, messages=[{"role": "user", "content": "Reply with the single word: ok"}])
        return True, f"응답 받음({r.model} · 입력 {r.usage.input_tokens} · 출력 {r.usage.output_tokens} 토큰)"
    except anthropic.AuthenticationError:
        return False, "키가 거절됨(401 — 잘못되었거나 지운 키)"
    except anthropic.PermissionDeniedError as e:
        return False, f"권한 없음(403): {e.message}"
    except anthropic.APIStatusError as e:
        return False, f"API 오류 {e.status_code}: {e.message}"
    except anthropic.APIConnectionError as e:
        return False, f"연결 오류: {e}"


def key_cmd(argv):
    ap = argparse.ArgumentParser(prog="fable.py key")
    ap.add_argument("action", choices=("set", "status", "test", "remove"))
    ap.add_argument("--no-test", action="store_true", help="set: 저장 전에 작은 호출로 확인하지 않음")
    a = ap.parse_args(argv)
    if a.action == "set":
        k = sys.stdin.read().strip()
        if not k:
            sys.exit("[fable] 키를 표준 입력으로 주세요(명령 줄 인자로 받지 않습니다)")
        if not k.startswith("sk-ant-") or any(c.isspace() for c in k):
            sys.exit("[fable] Anthropic API 키 꼴(sk-ant-…)이 아닙니다 — 저장하지 않았습니다")
        if not a.no_test:
            ok, note = ping(k)
            print(f"[fable] 키 확인: {note}")
            if not ok:
                sys.exit(2)
        STORE.parent.mkdir(parents=True, exist_ok=True)
        STORE.write_text(json.dumps({"api_key": k, "saved": time.strftime("%Y-%m-%d %H:%M:%S")}, ensure_ascii=False), encoding="utf-8")
        try:
            os.chmod(STORE, 0o600)   # ponytail: Windows 에서는 읽기 전용 표시만 — 사용자 폴더 권한에 기댄다
        except OSError:
            pass
        print(f"[fable] 저장함 {mask(k)} → {STORE}")
        return
    if a.action == "remove":
        if STORE.is_file():
            STORE.unlink()
            print(f"[fable] 저장한 키를 지움({STORE})")
        else:
            print("[fable] 저장한 키가 없습니다")
        k, src = resolve()
        print(f"[fable] 이제 쓰이는 키: {mask(k) + ' — ' + src if k else '없음'}")
        return
    k, src = resolve()
    if not k:
        sys.exit("[fable] 쓸 키가 없습니다 — `/fable key <API 키>` 로 저장하세요")
    print(f"[fable] 쓰이는 키: {mask(k)} — {src}")
    others = [s for s, v in (("저장한 키", _saved()), ("env ANTHROPIC_API_KEY", os.environ.get("ANTHROPIC_API_KEY", "").strip()), ("settings.json env", _settings())) if v and v != k]
    if others:
        print(f"[fable] 다른 곳에도 다른 키가 있음(안 쓰임): {', '.join(others)}")
    if a.action == "test":
        ok, note = ping(k)
        print(f"[fable] 키 확인: {note}")
        if not ok:
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
    k, src = resolve()
    if not k:
        sys.exit("[fable] API 키가 없습니다 — `/fable key <API 키>` 로 저장하세요")

    import anthropic
    client = anthropic.Anthropic(api_key=k, timeout=1800.0)
    kw = {"model": MODEL, "max_tokens": a.max_tokens, "messages": [{"role": "user", "content": blocks(a.file, prompt)}], "output_config": {"effort": a.effort}}
    if a.system:
        kw["system"] = a.system
    if not a.no_fallback:
        kw.update(betas=["server-side-fallback-2026-07-01"], fallbacks="default")
    parts = []
    try:
        with client.beta.messages.stream(**kw) as stream:
            for text in stream.text_stream:
                parts.append(text)
                sys.stdout.write(text)
                sys.stdout.flush()
            msg = stream.get_final_message()
    except anthropic.AuthenticationError:
        print(f"\n[fable] 키가 거절됨(401) — {src} 의 키를 확인하거나 `/fable key <API 키>` 로 새로 저장하세요", file=sys.stderr)
        sys.exit(2)
    except anthropic.APIStatusError as e:
        print(f"\n[fable] API 오류 {e.status_code}: {e.message}", file=sys.stderr)
        sys.exit(2)
    except anthropic.APIConnectionError as e:
        print(f"\n[fable] 연결 오류: {e}", file=sys.stderr)
        sys.exit(2)
    answer = "".join(parts)
    if a.out:
        Path(a.out).write_text(answer, encoding="utf-8")
    u = msg.usage
    fell = [b for b in msg.content if b.type == "fallback"]
    cost = (u.input_tokens * PRICE[0] + u.output_tokens * PRICE[1]) / 1e6
    note = f" · 대체: {', '.join(f'{b.from_.model}→{b.to.model}' for b in fell)}" if fell else ""
    print(f"\n\n[fable] 모델 {msg.model}{note} · effort {a.effort} · 입력 {u.input_tokens:,} · 출력 {u.output_tokens:,} 토큰 · 약 ${cost:.4f}(Fable 단가) · stop {msg.stop_reason}", file=sys.stderr)
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
