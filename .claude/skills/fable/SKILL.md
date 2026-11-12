---
name: fable
description: Claude Fable 5.2(claude-fable-5-2)를 Anthropic API 키로 직접 불러 답을 받고, 그 API 키를 받아 저장·확인·삭제한다. `/fable <질문·작업>` 으로 묻기(파일·그림·PDF 첨부 가능), `/fable key <API 키>` 로 키 설정, `/fable key status|test|remove`. 지금 대화 모델과 별도로 Fable 의 답·검토·두 번째 의견을 받을 때, 또는 Fable 용 API 키를 등록·교체할 때 사용. 유료(입력 $8 · 출력 $40 / 1M 토큰).
argument-hint: <질문> [파일 경로 …] [effort=low|medium|high|xhigh|max] | key <API 키> | key status | key test | key remove
---

# Claude Fable 5.2 — API 키로 직접 부르기 (fable)

`/fable` 은 이 대화의 모델과 **따로** Claude Fable 5.2 를 Anthropic API 로 한 번 부른다. 지금 대화하는 모델을 바꾸는 것은 `/model` 이고, 이 스킬과는 다르다.
모든 실제 일은 이 SKILL.md 옆의 `scripts/fable.py` 가 한다(`anthropic` 파이썬 패키지 필요 — 없으면 `pip install anthropic`).

```
python -X utf8 "<이 SKILL.md가 있는 폴더>/scripts/fable.py" <인자…>
```

## 인자에 따라

| 사용자 입력 | 할 일 |
|---|---|
| `/fable key <API 키>` | 키 저장. 키를 **표준 입력으로** 넘긴다(명령 줄 인자에 안 남게): `printf '%s' '<키>' \| python -X utf8 ".../fable.py" key set` — 저장 전에 작은 호출로 키를 확인한다(비용 토큰 수백 개). 확인 없이 저장하라고 하면 `--no-test`. |
| `/fable key` · `/fable key status` | `key status` — 지금 쓰이는 키(앞 7자…끝 4자)와 출처, 다른 곳에 다른 키가 있는지 |
| `/fable key test` | `key test` — 작은 호출로 지금 키가 되는지 |
| `/fable key remove` | `key remove` — 저장한 키 파일을 지운다(그 뒤 쓰이는 키를 알려 줌). 지우기 전에 한 번 확인한다 |
| `/fable <질문>` (그 밖 모두) | 아래 「묻기」 |
| `/fable` (인자 없음) | 무엇을 물을지 짧게 되묻는다. 키가 없으면 `key status` 결과와 함께 키 설정을 안내한다 |

### 키를 다룰 때

- 사용자가 준 키를 **답에 되풀이해 적지 않는다**(끝 네 글자만). 키를 파일·명령 줄 인자·커밋에 남기지 않는다 — 표준 입력으로만 넘긴다.
- 저장 위치는 `~/.claude/fable/config.json`(스킬 폴더 밖 — 스킬 원본은 git 저장소다). env `FABLE_CONFIG` 로 바꿀 수 있다.
- 키를 찾는 차례: env `FABLE_API_KEY` → 저장한 키 → env `ANTHROPIC_API_KEY` → `~/.claude/settings.json` 의 `env.ANTHROPIC_API_KEY`. 저장한 키는 Claude Code 자체의 로그인에는 영향이 없다.
- 키를 처음 저장했으면 한 줄로 알린다: 대화에 붙여 넣은 키는 이 대화 기록에 남는다 — 걱정되면 Console 에서 새 키를 만들어 다시 저장하고 옛 키를 지우면 된다.

## 묻기

1. **질문 글을 만든다** — Fable 은 이 대화를 못 본다. 사용자의 질문에 이 대화의 맥락이 필요하면(「위 코드 봐 줘」 · 「이 설계 어때」) 필요한 맥락을 질문 글에 함께 적는다.
   사용자가 파일 경로를 주거나 「이 파일」 이라고 가리키면 `--file <경로>` 로 붙인다(여러 개 가능 · 그림 png/jpg/gif/webp · PDF 도). 파일 내용을 질문 글에 다시 붙여 넣지 않는다.
   큰 파일을 통째로 보내기 전에 크기를 보고, 비용이 크면(수십만 토큰) 필요한 부분만 보낼지 사용자에게 묻는다.
2. **질문 글은 임시 파일로** 넘긴다(셸 따옴표 문제를 피함 — 세션의 scratchpad 폴더에): `--prompt-file <파일>`. 답이 길 수 있으니 `--out <답 파일>` 도 준다.
3. **실행**: Bash 로 위 명령(`--prompt-file … --out … [--file …] [--effort …]`). Fable 은 한 답에 몇 분 걸릴 수 있다 — timeout 을 600000 으로, 아주 큰 일은 `run_in_background` 로 돌리고 끝나면 이어서.
   - effort: 기본 `high`. 사용자가 `effort=…` 을 적으면 그 값. 가벼운 질문이면 `medium`.
   - 거절(refusal)에 대비해 서버 쪽 대체가 기본으로 켜져 있다 — 끝 줄의 「대체: …」 가 그 표시. 사용자가 원하지 않으면 `--no-fallback`.
4. **보여 주기**: Fable 의 답을 **고치거나 줄이지 않고 그대로** 보여 준다(「Fable 의 답」 이라고 밝히고). 그 뒤에 끝 줄(모델 · 토큰 · 대략 비용)을 한 줄로.
   사용자가 물으면 그 답에 대한 내 의견을 따로 덧붙일 수 있다 — 답과 섞지 않는다.
5. **실패**: 종료 코드 1 = 키 없음·인자 오류(키가 없으면 `/fable key <API 키>` 안내) · 2 = API 오류(401 이면 키 확인 안내) · 3 = 대체 모델까지 거절. 같은 요청을 그대로 되풀이하지 않는다.
