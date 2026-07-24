---
name: cred
description: Claude Code 계정 자격증명(~/.claude/.credentials.json)을 프로필로 저장(save)하거나 교체(use)하여 계정을 전환하고, 프로필을 패키지로 추출(export)해 다른 PC로 옮겨 등록(import)한다. 계정 전환, credential 교체/백업/등록, 다른 PC로 계정 이전, 프로필 목록 확인 요청 시 사용.
argument-hint: list | save <이름> | use <이름> | export <이름> [대상폴더] | import <파일> [이름] | backup | setaccount <이름> <이메일> | whoami [이름] | fixcache [이름]
---

# Claude 계정 자격증명 전환 (cred)

`~/.claude/.credentials.json`(Claude Code 로그인 토큰)을 프로필 단위로 관리한다.
프로필 저장소는 `E:\dev\accredential\.claude\skills\cred\profiles\` 이며, 이 스킬이 어디에 설치되어 있든(프로젝트 원본/전역 복사본) 항상 이 저장소 하나만 사용한다 (`CRED_STORE` 환경변수로 재정의 가능).
전역 복사본(`~/.claude/skills/cred/`)은 globalize 스킬이 관리한다 — 원본 수정 후에는 `/globalize update cred`로 동기화한다.

모든 실제 작업은 이 스킬 폴더의 `scripts/cred.ps1` 스크립트가 수행한다. credentials 파일을 직접 읽거나 수정하지 말 것.

## 실행 방법

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<이 SKILL.md가 있는 폴더>\scripts\cred.ps1" <action> [인자...]
```

액션 이름의 기준은 **프로필 저장소**다: 저장소에 들여오면 import, 저장소에서 밖으로 꺼내면 export.

| 사용자 요청 | action |
|---|---|
| 프로필 목록 / 현재 어떤 계정인지 확인 | `list` |
| 현재 로그인 상태를 프로필로 저장/갱신 | `save <이름>` (기존 프로필이 있으면 이전 토큰을 `_backups`에 백업한 뒤 바로 덮어씀) |
| 특정 프로필로 계정 교체(전환) | `use <이름>` |
| 프로필을 다른 PC로 가져갈 패키지(zip)로 추출 | `export <이름> [대상폴더]` (생략 시 `profiles\_exports\`에 생성) |
| 패키지(zip)/외부 credentials 파일을 프로필로 등록 | `import <파일경로> [이름]` (패키지면 이름 생략 가능 — 원래 프로필 이름 사용. `add`는 별칭) |
| 현재 상태만 백업 | `backup` |
| 프로필에 계정(이메일) 기록/수정 | `setaccount <이름> <이메일>` 또는 `setaccount <이름> -FromCache` |
| 토큰이 실제로 어느 계정인지 API로 확인 | `whoami` (현재 활성) 또는 `whoami <이름>` (특정 프로필) |
| 로그인 없이 계정 정보 생성 + 화면 표시 교정 | `fixcache` (현재 활성) 또는 `fixcache <이름>` (특정 프로필) |

- 프로필은 폴더 단위로 저장된다: `profiles\<이름>\credentials.json`(토큰), `profiles\<이름>\account.json`(계정 사이드카), 그리고 계정 이메일을 파일명으로 하는 빈 마커 파일(예: `profiles\workspace\krcjmoon@gmail.com`). 마커는 탐색기에서 어떤 폴더가 어떤 계정인지 한눈에 보기 위한 것으로, 스크립트가 자동 생성/갱신하니 직접 만들거나 지우지 말 것. 구버전 flat 파일(`<이름>.json`)은 스크립트 실행 시 자동으로 폴더 구조로 이전된다.
- `import`는 교체 전에 두 가지를 자동으로 한다: (1) **자동 동기화** — 현재 활성 토큰을 화면 표시 계정(이메일)과 일치하는 프로필에 저장한다. refresh 토큰은 갱신 시마다 회전(구버전 무효화)되므로, 이걸 안 하면 나중에 그 계정으로 돌아올 때 저장된 스냅샷이 낡아 재로그인을 요구하게 된다. 일치하는 프로필이 없거나 여럿이면 안내만 하고 건너뛴다. (2) 현재 파일을 `profiles\_backups\`에 자동 백업한다.
- 프로필 이름은 영문/숫자/`._-`만 허용된다.
- credentials 파일 자체에는 이메일 등 계정 식별 정보가 없다. 대신 프로필마다 `account.json` 사이드카에 `~/.claude.json`의 `oauthAccount` 캐시(이메일/조직, 토큰 없음)를 함께 저장한다:
  - `export`는 현재 화면 표시 계정(캐시)을 사이드카로 함께 저장한다. 캐시는 마지막 `/login` 기준이므로, export 직전에 그 계정으로 로그인한 상태가 아니면 잘못 기록될 수 있다 — 스크립트가 안내 문구를 출력하면 사용자에게 그대로 전달한다.
  - `import`는 사이드카가 있으면 `~/.claude.json`의 `oauthAccount`를 복원해 화면 표시 계정(이메일)도 프로필에 맞게 바꾼다 (수정 전 원본을 `_backups\`에 자동 백업). 사이드카가 없으면 토큰만 바뀌고 화면 표시는 이전 계정 그대로 남는다.
  - `add`로 등록한 외부 파일은 계정을 알 수 없으므로, 사용자에게 이메일을 물어 `setaccount`로 기록해두는 것을 권장한다. `setaccount <이름> <이메일>`은 목록 표시용 기록일 뿐 화면 캐시 복원에는 사용되지 않는다.
  - 사이드카에는 `source`가 기록된다: `cache`(로그인 캐시 사본) / `api`(fixcache로 API 확인) / `manual`(이메일만 수동 기록). `cache`와 `api`는 import 시 화면 표시 복원에 사용되고, `manual`은 목록 표시용이다.
  - `fixcache [이름]`은 해당 토큰의 실제 계정(UUID/이메일/조직)을 조회 API로 확인해 사이드카를 생성한다 — **로그인 없이** 계정 정보를 만들 수 있는 유일한 방법. 대상 토큰이 현재 활성 토큰과 같으면 `~/.claude.json`의 화면 표시 계정도 함께 교정한다 (수정 전 원본 자동 백업). 화면 표시 계정이 실제 토큰과 어긋났을 때(`list`가 `!!` 경고 표시) 이걸로 바로잡는다.

## 전환 흐름 (스킬 호출의 기본 동작)

사용자가 프로필 이름 없이 스킬을 호출하거나 계정 전환을 요청하면 반드시 다음 순서로 진행한다:

1. `list`를 실행해 현재 활성 프로필(`*` 표시)과 나머지 프로필 목록을 파악한다.
2. **AskUserQuestion 도구**로 어떤 계정으로 교체할지 묻는다. 사용자에게는 항상 **계정(이메일)을 기준으로** 보여준다 — 프로필 폴더 이름은 내부 식별자일 뿐이다:
   - question에 현재 적용 중인 **계정 이메일**과 메타데이터를 명시한다. 예: `현재 kimghw@krs.co.kr 계정(프로필 'default', max/20x, refresh 만료 2026-08-19)이 적용되어 있습니다. 어떤 계정으로 교체할까요?`
   - 현재 활성이 **아닌** 프로필들을 각각 선택지로 제시한다. **label은 계정 이메일**, description에 프로필 이름과 `list`가 출력한 나머지 메타데이터(구독 종류, 만료일)를 넣는다. 계정 정보가 없는 프로필은 label에 프로필 이름을 쓰되 "(계정 미확인)"을 붙이고, 선택되면 import 후 `fixcache`로 계정 확인을 권장한다.
   - 마지막 선택지로 "전환하지 않음"을 넣는다.
   - 현재 활성과 동일한 프로필은 선택지에 넣지 않는다 (교체해도 변화가 없으므로).
3. 계정이 선택되면 해당 프로필 이름으로 `import <이름>`을 실행하고, 완료 후 Claude Code 재시작 안내를 한다. "전환하지 않음"이면 아무 변경도 하지 않는다.

사용자가 처음부터 대상을 명시한 경우에는 질문 없이 바로 `import` 한다. 프로필 이름(예: "workspace로 바꿔줘", `/cred import workspace`)뿐 아니라 **계정 이메일로 지정한 경우**(예: "krcjmoon 계정으로 바꿔줘")도 마찬가지다 — `list`의 계정 정보로 해당 프로필을 찾아 import 하고, 일치하는 계정이 없거나 여럿이면 AskUserQuestion으로 확인한다.

## 규칙 (반드시 지킬 것)

1. **토큰 값을 절대 출력하지 않는다.** `.credentials.json`이나 프로필 토큰 파일(`<이름>\credentials.json`)을 Read/cat/type 하지 않는다. 항상 스크립트를 통해서만 다룬다. 스크립트가 보여주는 메타데이터(계정 이메일, 구독 종류, 만료일)만 사용자에게 전달한다. (`<이름>\account.json` 사이드카에는 토큰이 없지만, 역시 스크립트로만 다룬다.)
2. `import` 성공 후에는 반드시 안내한다: **"적용하려면 Claude Code를 재시작(새 세션 시작)해야 합니다."** 현재 실행 중인 세션은 기존 토큰을 계속 사용할 수 있다.
3. 전환은 항상 위 "전환 흐름"을 따른다 — 이름이 지정되지 않았으면 AskUserQuestion으로 확인받은 뒤에만 `import` 한다. 확인 없이 임의로 계정을 교체하지 않는다.
4. 저장소(`.claude\skills\cred\profiles\`)는 반드시 git에서 제외된 상태를 유지한다 (accredential 프로젝트 루트 `.gitignore`의 `profiles/` 패턴 + 스킬 폴더 자체의 `.gitignore` 이중 방어). credentials 파일을 저장소 밖의 다른 위치로 복사하지 않으며, 저장소 밖에 흩어진 credentials 파일을 발견하면 `add`로 등록한 뒤 원본 삭제를 권장한다.
