"""Claude Fable 을 **API 키로 청구되는 도구 에이전트**로 띄운다 — /fable 스킬의 「키 에이전트」 실행부.

    python -X utf8 fable_agent.py --prompt-file 일감.md --out 보고.md [--cwd 폴더] [--effort high] [--model claude-fable-5-2]
                                  [--perm edit|plan] [--allow "도구 규칙" …] [--budget 20] [--resume <세션 id>] [--log 기록.jsonl] [--add-dir 폴더 …]

- 하는 일: Claude Code CLI 를 헤드리스로(`claude -p`) 띄운다 — 자식 프로세스의 env 와 플래그 설정(`--settings` 임시 파일 — 사용자 설정 env 의 키가 덮어쓰지 않게: key_settings)에
  `ANTHROPIC_API_KEY` 를 넣어 **그 키로 청구**되게 하고,
  작업 폴더(--cwd — 기본 지금 폴더)에서 일감 글(--prompt-file 또는 표준 입력)을 수행하게 한다. 그 프로젝트의 CLAUDE.md·사용자 설정은 Claude Code 가 평소처럼 읽는다.
- 키(여러 개): 차례·넘어가기는 fable.py 와 같다(`fable.candidates` — 등록한 키 차례, 쉬는 중인 키는 뒤로). 실행이 **키 탓으로**(키 거절 · 크레딧 부족 · 권한 · 사용 한도 —
  CLI 의 assistant 메시지 `error` = authentication_failed · billing_error · rate_limit, 결과의 `api_error_status`) 실패하면 그 키를 뒤로 미루고 다음 키로 다시 띄운다:
    아직 도구를 하나도 안 썼으면 = 같은 일감으로 처음부터(그 실행의 세션은 버림) ·
    일을 하던 중이었으면     = 같은 세션을 다음 키로 `--resume`(끊긴 곳부터 이어서 하라는 글과 함께 — 맥락이 남는다).
  키 탓이 아닌 실패(서버 오류 · 도구 오류 · 비용 상한)는 넘어가지 않는다. 비용 상한은 여러 번 띄운 것을 합쳐 센다.
- 키로 청구되는지 확인: CLI 의 첫 메시지(system/init)의 `apiKeySource` 가 `ANTHROPIC_API_KEY` 가 아니면 **바로 끊는다**(종료 코드 4 — 다른 계정으로 청구되지 않게).
- 권한(--perm): 이 에이전트는 **부른 세션의 권한 검사를 받지 않는 별도 프로세스**다. 그래서 기본은 좁다.
    edit(기본) = 파일 읽기·찾기 + 작업 폴더 안 파일 고치기(`--permission-mode acceptEdits`). 물어야 하는 것(명령 실행 등)은 **자동 거절**(`--permission-prompts none`)되고 끝 줄에 거절 목록이 나온다.
    plan      = 읽기만(계획·조사).
  명령을 돌리게 하려면 사용자가 정한 규칙을 `--allow` 로 준다(예: --allow "Bash(python -X utf8 -m pytest:*)") — 사용자·프로젝트 설정 파일(`permissions.allow`)의 규칙도 그대로 적용된다.
  모든 것을 묻지 않고 하는 방식(bypass·auto)은 넣지 않았다 — 필요하면 사용자가 정해 스킬을 고친다.
- 비용 상한(--budget, 달러 — 기본 20, 0 = 없음): CLI 의 `--max-budget-usd`(키를 바꿔 다시 띄우면 남은 몫만). 넘으면 CLI 가 멈춘다(종료 코드 3 — 어디까지 했는지는 보고·기록에).
- 이어 하기(--resume): 끝 줄에 찍힌 세션 id 를 주면 그 대화에 이어서(맥락 그대로) 새 일감 글을 수행한다.
- 출력: 진행(도구 이름·한 줄 · 키를 바꾼 것)은 표준 출력으로 그때그때, 끝 보고는 --out 파일(없으면 표준 출력), 원문 메시지는 --log(jsonl — 키를 바꾼 곳에 `{"type": "fable_agent", "event": "key_switch"}` 줄),
  끝 줄(모델·쓴 키·턴 수·시간·비용·세션 id·넘어간 키·거절)은 표준 오류.
종료 코드: 0 성공 · 1 키·인자·실행 파일 없음 · 2 CLI 오류(실패 결과 · 쓸 수 있는 키가 없음 포함) · 3 비용 상한 · 4 API 키로 청구되지 않음(끊음).
키 글은 어디에도 찍지 않는다. 한꺼번에 여럿 띄울 때는 4개까지(Windows 에서 `claude -p` 를 많이 띄우면 일부가 죽는다)."""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fable  # noqa: E402 — 키 차례(candidates)·넘어가기(problem·mark)·가리기(mask)는 묻기 쪽과 같은 것

MODEL = fable.MODEL
PERMS = {"edit": "acceptEdits", "plan": "plan"}
BUDGET = 20.0
# 부른 세션에 묶인 env — 자식이 부모 세션의 자식·IDE 연결·메시지 소켓으로 붙지 않게 뺀다. 다른 인증(OAuth 토큰)도 빼서 키만 남긴다
DROP = ("ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_STARTUP_FAILURE_RESULTS", "CLAUDE_CODE_EMIT_STARTUP_TIMING", "CLAUDE_CODE_QUESTION_PREVIEW_FORMAT", "CLAUDE_CODE_ENABLE_TASKS", "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_CHILD_NOTES_DIR")
ROLE = ("너는 다른 Claude Code 세션이 맡긴 일을 혼자 끝까지 하는 하위 에이전트다. 물어볼 사람이 없다 — 막히면 추측으로 넘기지 말고 보고에 적는다. "
        "권한이 없어 거절된 도구(명령 실행 등)는 다른 길로 돌아가려 하지 말고 무엇이 거절됐는지 보고에 적는다. "
        "끝 보고: ① 고친 파일과 무엇을 왜 ② 돌린 검사·명령과 실제 결과(못 돌린 것도 그대로) ③ 못 한 것·판단이 필요한 것. 추측을 사실처럼 쓰지 않는다.")
GOON = ("앞 실행이 API 키 문제({why})로 끊겨, 키를 바꿔 같은 대화를 잇는다. 앞에서 받은 일감을 끊긴 곳부터 이어서 끝까지 하라 — 이미 한 것은 되풀이하지 말고, "
        "끝 보고는 처음 일감이 정한 꼴로 앞에서 한 것까지 함께 적는다.")


def cli():
    """Claude Code 실행 파일 — env FABLE_CLAUDE_CLI 또는 PATH 의 claude."""
    exe = os.environ.get("FABLE_CLAUDE_CLI", "").strip() or shutil.which("claude")
    return exe if exe and Path(exe).is_file() else None


def child_env(key):
    env = {k: v for k, v in os.environ.items() if k not in DROP}
    env["ANTHROPIC_API_KEY"] = key
    return env


def key_settings(key):
    """이번 실행의 키를 담은 플래그 설정 파일(--settings) — 실행이 끝나면 지운다(drop_settings).
    Claude Code 는 사용자 설정(~/.claude/settings.json)의 env 를 제 env 에 얹는다 — 거기 ANTHROPIC_API_KEY 가 있으면 자식 env 로 준 키를 덮어써
    등록한 키가 아니라 그 키로 청구된다(2026-11-24 실측: 어느 키를 줘도 settings 키의 「Credit balance is too low」 · apiKeySource 는 그대로 ANTHROPIC_API_KEY).
    플래그 설정은 사용자 설정보다 먼저라 그 env 가 이긴다(사용자 설정의 다른 것 — permissions.allow 등 — 은 그대로). 키 글이 명령 줄에 안 남게 파일로 준다."""
    p = Path(tempfile.mkdtemp(prefix="fable_agent_")) / "settings.json"
    p.write_text(json.dumps({"env": {"ANTHROPIC_API_KEY": key}}), encoding="utf-8")
    return p


def drop_settings(p):
    for f in (lambda: p.unlink(), lambda: p.parent.rmdir()):
        try:
            f()
        except OSError:
            pass


def command(exe, a, resume=None, budget=None, settings=None):
    """CLI 명령 — resume · budget · settings(key_settings 파일)는 이번 실행의 것(키를 바꿔 다시 띄우면 달라진다). resume · budget 을 안 주면 인자의 것."""
    budget = a.budget if budget is None else budget
    resume = a.resume if resume is None else resume
    args = [exe, "-p", "--model", a.model, "--effort", a.effort, "--output-format", "stream-json", "--verbose",
            "--permission-mode", PERMS[a.perm], "--permission-prompts", "none", "--append-system-prompt", ROLE]
    if settings:
        args += ["--settings", str(settings)]
    if budget and budget > 0:
        args += ["--max-budget-usd", f"{round(budget, 2):g}"]
    if a.allow:
        args += ["--allowedTools", *a.allow]
    for d in a.add_dir or []:
        args += ["--add-dir", d]
    if resume:
        args += ["--resume", resume]
    return args


def brief(name, inp):
    """도구 호출 한 줄 — 이름 + 알아볼 만한 인자 하나."""
    inp = inp if isinstance(inp, dict) else {}
    for k in ("file_path", "path", "pattern", "command", "description", "prompt", "url", "query"):
        if inp.get(k):
            return f"{name} {str(inp[k]).replace(chr(10), ' ')[:110]}"
    return name


def run(exe, a, cwd, key, prompt, resume, budget, log, t0):
    """CLI 를 한 번 띄워 끝까지 읽는다 → {init, result, tools, wrong_key, err, code, errs}.
    err = 마지막 API 오류(CLI 의 assistant 메시지 `error` · `api_error_status` · 글) — 키 탓인지는 key_problem 이 가른다."""
    sp = key_settings(key)
    try:
        return _run(exe, a, cwd, key, prompt, resume, budget, log, t0, sp)
    finally:
        drop_settings(sp)   # 프로세스가 끝난 뒤에 지운다(도는 동안 설정 파일이 없어지지 않게)


def _run(exe, a, cwd, key, prompt, resume, budget, log, t0, sp):
    proc = subprocess.Popen(command(exe, a, resume or "", budget, sp), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd,
                            env=child_env(key), creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    r = {"init": {}, "result": None, "tools": 0, "wrong_key": False, "err": None, "code": None, "errs": []}
    threading.Thread(target=lambda: r["errs"].extend(x.decode("utf-8", "replace").rstrip() for x in proc.stderr), daemon=True).start()
    proc.stdin.write(prompt.encode("utf-8"))
    proc.stdin.close()
    for raw in proc.stdout:
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if log:
            log.write(line + "\n")
            log.flush()
        try:
            m = json.loads(line)
        except ValueError:
            continue
        kind = m.get("type")
        if kind == "system" and m.get("subtype") == "init":
            r["init"] = m
            if m.get("apiKeySource") != "ANTHROPIC_API_KEY":   # 키로 청구되지 않는다 — 더 돌기 전에 끊는다
                r["wrong_key"] = True
                proc.kill()
                break
            print(f"[fable agent] 세션 {m.get('session_id')} · 키 출처 {m.get('apiKeySource')} · 권한 {m.get('permissionMode')} · 도구 {len(m.get('tools') or [])}개", flush=True)
        elif kind == "assistant":
            content = (m.get("message") or {}).get("content") or []
            if m.get("error"):
                r["err"] = (m.get("error"), m.get("api_error_status"), " ".join(b.get("text", "") for b in content if b.get("type") == "text").strip())
            for b in content:
                if b.get("type") == "tool_use":
                    r["tools"] += 1
                    print(f"  {time.time() - t0:5.0f}s  {brief(b.get('name'), b.get('input'))}", flush=True)
        elif kind == "result":
            r["result"] = m
    r["code"] = proc.wait()
    return r


def key_problem(r):
    """이번 실행이 키 탓으로 실패했나 → (까닭, 뒤로 미룰 초) 또는 None — 기준은 fable.problem(키 거절 · 크레딧 · 권한 · 한도).
    결과가 성공이면(중간에 오류가 났다가 CLI 가 다시 해서 된 것 포함) 키 탓이 아니다."""
    res = r["result"] or {}
    if r["result"] is not None and not res.get("is_error"):
        return None
    err = r["err"] or ("", None, "")
    if not r["err"] and res.get("terminal_reason") != "api_error":
        return None
    text = (res.get("result") or err[2] or "").strip()
    p = fable.problem(res.get("api_error_status") or err[1], err[0], text)
    if not p:
        return None
    return (f"{p[0]} — {text[:120]}" if text else p[0]), p[1]


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fable_agent.py", description="Claude Fable 을 API 키로 청구되는 도구 에이전트로 띄운다")
    ap.add_argument("-p", "--prompt")
    ap.add_argument("--prompt-file")
    ap.add_argument("--out")
    ap.add_argument("--log")
    ap.add_argument("--cwd", default=".")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--effort", default="high", choices=("low", "medium", "high", "xhigh", "max"))
    ap.add_argument("--perm", default="edit", choices=sorted(PERMS))
    ap.add_argument("--allow", action="append", default=[], help="명령 등을 허용하는 도구 규칙(여러 번) — 예: \"Bash(python -X utf8 -m pytest:*)\"")
    ap.add_argument("--budget", type=float, default=BUDGET, help="비용 상한(달러 · 0 = 없음)")
    ap.add_argument("--resume", help="이어 할 세션 id(앞 실행의 끝 줄)")
    ap.add_argument("--add-dir", action="append", default=[])
    a = ap.parse_args(argv)

    prompt = a.prompt if a.prompt is not None else Path(a.prompt_file).read_text(encoding="utf-8") if a.prompt_file else sys.stdin.read()
    if not prompt.strip():
        print("[fable agent] 일감 글이 비었습니다(--prompt-file · -p · 표준 입력)", file=sys.stderr)
        return 1
    cands = fable.candidates()
    if not cands:
        print("[fable agent] API 키가 없습니다 — /fable key <API 키> 로 먼저 등록하세요", file=sys.stderr)
        return 1
    exe = cli()
    if not exe:
        print("[fable agent] Claude Code 실행 파일(claude)을 찾지 못했습니다 — PATH 에 두거나 env FABLE_CLAUDE_CLI 에 경로를", file=sys.stderr)
        return 1
    cwd = Path(a.cwd).resolve()
    if not cwd.is_dir():
        print(f"[fable agent] 작업 폴더가 없습니다: {cwd}", file=sys.stderr)
        return 1
    key, src = cands[0]
    print(f"[fable agent] 시작 — 모델 {a.model} · effort {a.effort} · 권한 {a.perm}{' + 허용 ' + str(len(a.allow)) + '개' if a.allow else ''} · "
          f"키 {fable.mask(key)}({src}){' 외 ' + str(len(cands) - 1) + '개(쓸 수 없으면 다음 키로)' if len(cands) > 1 else ''} · 폴더 {cwd}", flush=True)

    t0 = time.time()
    log = open(a.log, "w", encoding="utf-8") if a.log else None
    spent, costed, tools, skipped = 0.0, False, 0, []
    resume, text_in = a.resume, prompt
    try:
        for i, (key, src) in enumerate(cands):
            left = a.budget - spent if a.budget and a.budget > 0 else 0
            if a.budget and a.budget > 0 and left < 0.01:
                print(f"[fable agent] 비용 상한(${a.budget:g})을 다 써서 다음 키로 띄우지 않았습니다 — 넘어간 키: {' · '.join(skipped)}"
                      + (f" · 이어 하려면 --resume {resume}" if resume else ""), file=sys.stderr)
                return 3
            if i:
                note = "같은 세션을 이어서" if resume and resume != a.resume else "같은 일감으로 처음부터"
                print(f"[fable agent] 다음 키 {fable.mask(key)}({src}) 로 {note}", flush=True)
                if log:
                    log.write(json.dumps({"type": "fable_agent", "event": "key_switch", "key": fable.mask(key), "source": src, "resume": resume}, ensure_ascii=False) + "\n")
            r = run(exe, a, cwd, key, text_in, resume, left, log, t0)
            tools += r["tools"]
            cost = (r["result"] or {}).get("total_cost_usd")
            if isinstance(cost, (int, float)):
                spent, costed = spent + cost, True
            if r["wrong_key"]:
                print(f"[fable agent] 끊음 — 이 실행은 API 키가 아니라 「{r['init'].get('apiKeySource')}」 로 청구됩니다(다른 인증이 먼저 잡힘). 아무 일도 시키지 않았습니다", file=sys.stderr)
                return 4
            p = key_problem(r)
            if not p:
                if r["result"] is not None and not r["result"].get("is_error"):
                    fable.mark(key)
                break
            fable.mark(key, *p)
            skipped.append(f"{fable.mask(key)} {p[0]}")
            print(f"[fable agent] 키 {fable.mask(key)}({src}) 쓸 수 없음 — {p[0]}", flush=True)
            sid = (r["result"] or {}).get("session_id") or r["init"].get("session_id")
            if r["tools"] and sid:   # 일을 하던 중 끊김 — 같은 세션을 다음 키로 잇는다(아무 일도 안 했으면 같은 일감으로 처음부터)
                resume, text_in = sid, GOON.format(why=p[0])
        else:
            print(f"[fable agent] 쓸 수 있는 키가 없습니다 — {' · '.join(skipped)}. 크레딧을 채우거나 /fable key <API 키> 로 키를 더하세요"
                  + (f" · 이어 하려면 --resume {resume}" if resume and resume != a.resume else ""), file=sys.stderr)
            return 2
    finally:
        if log:
            log.close()

    result = r["result"]
    if result is None:
        print(f"[fable agent] 결과 없이 끝났습니다(종료 코드 {r['code']}) — {' | '.join(r['errs'][-3:])[-400:]}", file=sys.stderr)
        return 2
    text = result.get("result") or ""
    if a.out:
        Path(a.out).write_text(text, encoding="utf-8")
    else:
        print("\n" + text, flush=True)
    denied = [f"{d.get('tool_name')}({brief('', d.get('tool_input')).strip()[:60]})" for d in result.get("permission_denials") or []]
    sub = result.get("subtype")
    tail = (f"[fable agent] {a.model} · 키 {fable.mask(key)}({src}) · 턴 {result.get('num_turns')} · 도구 {tools}번 · {time.time() - t0:.0f}초 · "
            + (f"비용 ${spent:.2f}(API 키로 청구)" if costed else "비용 모름") + f" · 세션 {result.get('session_id')}")
    if skipped:
        tail += f" · 넘어간 키: {' · '.join(skipped)}"
    if denied:
        tail += f" · 권한 거절 {len(denied)}건: " + " · ".join(dict.fromkeys(denied))[:400]
    if a.out:
        tail += f" · 보고 {a.out}"
    print(tail, file=sys.stderr)
    if sub and "budget" in str(sub):
        print(f"[fable agent] 비용 상한(${a.budget:g})에 닿아 멈췄습니다 — 이어 하려면 --resume {result.get('session_id')} (상한을 올려)", file=sys.stderr)
        return 3
    if result.get("is_error") or sub != "success":
        print(f"[fable agent] 실패로 끝났습니다({sub}) — 보고·기록을 확인하세요", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
