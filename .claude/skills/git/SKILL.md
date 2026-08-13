---
name: git
description: git 작업 자동화. 인자 없으면 stage+commit+push(변경 없으면 pull), 'pull'이면 pull, 'revert'면 미커밋 변경 전체 취소, 'public|private'이면 원격 저장소 공개여부 변경, 그 외 인자는 git 서브커맨드로 그대로 실행. 커밋/푸시/풀/변경 취소/레포 공개설정 요청 시 사용.
argument-hint: "(없음: commit+push) | pull | revert | public | private | help | <git 서브커맨드>"
---

# git 작업 자동화 (git)

인자에 따라 아래 규칙대로 git 작업을 수행한다.

## 실행 방식: sonnet 서브에이전트에 위임 (기본)

실제 git 작업은 **직접 하지 말고** `Agent` 도구로 sonnet 서브에이전트를 띄워 그 안에서 끝낸다.
호출 형태:

```
Agent(
  subagent_type: "general-purpose",
  model: "sonnet",
  run_in_background: false,
  description: "git <동작>",
  prompt: "<아래 프롬프트 규격>"
)
```

**서브에이전트에 주는 프롬프트 규격** — 다음 세 가지만 넣는다:
1. 이 스킬 파일의 절대경로(`<스킬 base 디렉터리>/SKILL.md`)를 읽고 **§동작 규칙 중 해당 번호**를
   그대로 따르라는 지시.
2. 사용자가 준 인자(없으면 "인자 없음 — 규칙 1").
3. 작업 디렉터리(현재 저장소 경로).

**서브에이전트의 반환 규격 — 완료 여부 한 줄만.** 프롬프트에 그대로 지시한다:
> 마지막 응답은 아래 중 **정확히 한 줄**만 출력한다. 그 밖의 설명·명령 출력·diff·파일 목록·
> 커밋 메시지·해시·통계·요약은 **절대 포함하지 않는다**.
> - 성공: `완료`
> - 실패: `실패: <한 줄 사유>`
> - 사용자 확인이 필요해 중단: `확인필요: <한 줄>`

메인 에이전트는 돌아온 그 한 줄을 사용자에게 그대로 전한다. 결과를 부풀리려고 `git log`·
`git status` 등을 다시 돌려 상세를 캐지 않는다. `확인필요:` 가 오면 그때만 메인에서
`AskUserQuestion` 으로 사용자에게 묻고, 답을 받아 같은 방식으로 서브에이전트를 다시 띄운다.

**위임하지 않고 메인에서 직접 처리하는 예외**:
- 규칙 0 (`help`) — 출력만 하면 되므로 서브에이전트 불필요.
- 규칙 3 (`revert`) 의 사용자 확인, 그리고 **공통 규칙**의 원격 미설정 확인 —
  `AskUserQuestion` 은 메인에서만 한다. 확인 후 실제 실행은 다시 서브에이전트에 위임한다.
- 규칙 5 중 **조회성 서브커맨드**(`status`·`log`·`diff`·`show`·`branch` 등 저장소를 바꾸지 않고
  출력 자체가 목적인 것) — 출력을 보여주는 게 요청이므로 메인에서 직접 실행해 결과를 보여준다.
  상태를 바꾸는 서브커맨드는 위임한다.

## 공통 규칙: 원격(origin) 미설정 처리

push / pull / public / private 등 **원격이 필요한 작업**을 하기 전에 `git remote -v`(또는 `git remote get-url origin`)로 origin 존재 여부를 먼저 확인한다. origin이 없으면 실패 메시지만 출력하고 끝내지 말고, `AskUserQuestion` 도구로 사용자에게 필요한 정보를 요청한다:

> "이 저장소에 원격(origin)이 없습니다. 어떻게 할까요?"
- 옵션 1: **GitHub에 새 레포 생성 (private)** — `gh` 사용 가능하면 `gh repo create <레포명> --private --source . --remote origin --push` 실행. 레포명 기본값은 현재 폴더명이며, 사용자가 다른 이름을 주면 그것을 쓴다.
- 옵션 2: **기존 원격 URL 연결** — 사용자에게 URL을 물어 `git remote add origin <URL>` 후 작업 계속. URL을 받기 전에는 진행하지 않는다.
- 옵션 3: **원격 없이 진행** — 로컬 커밋만 유지하고 push/pull은 건너뜀 (해당 작업이 원격 전용이면 그냥 종료).

옵션 1을 고르면 `gh --version` / `gh auth status`를 먼저 확인하고, 미설치·미인증이면 4번 규칙과 같은 안내를 하고 옵션 2로 유도한다.

**최초 푸시 전 안전 점검**: 원격에 처음 올리는 경우, 커밋에 자격증명·토큰·개인 프로필 파일(예: `credentials.json`, `profiles/`, `.env`)이 포함되어 있는지 `git ls-files`로 확인한다. 포함되어 있으면 그대로 밀지 말고 사용자에게 알리고, `.gitignore` 추가 및 추적 해제 여부를 먼저 확인받는다. private 레포라도 마찬가지로 알린다.

## 동작 규칙

0. **인자가 `help` / `-h` / `--help`인 경우**: 본 스킬이 받는 인자 목록과 각 인자의 동작 설명을 한눈에 출력하고 종료 (실제 git 작업 수행 안 함).

   출력 형식 (예시):
   ```
   /git [인자]

   (없음)            변경 있으면 stage(-A)+커밋 메시지 자동 생성+push / 변경 없으면 git pull
   pull              git pull 실행
   revert            현재 미커밋 변경(staged+unstaged+untracked) 전체 취소 — 사용자 확인 필요
   public            현재 레포의 원격 저장소(origin)를 공개(public)로 전환
   private           현재 레포의 원격 저장소(origin)를 비공개(private)로 전환
   help|-h|--help    이 도움말 출력
   <기타>            git 서브커맨드로 그대로 전달 (예: /git status)
   ```

1. **인자가 비어 있거나 없는 경우** (기본 동작):
   - `git add -A`로 모든 변경사항 스테이지
   - `git diff --cached --stat`으로 스테이지된 내용 확인
   - 변경사항이 없으면 커밋할 내용이 없으므로 `git pull`을 실행해 원격 변경을 가져온 뒤 종료 (2번 `pull` 동작과 동일)
   - 변경사항이 있으면 diff를 분석해 간결한 커밋 메시지 자동 생성 (한국어, 1줄)
   - `git commit`으로 커밋
   - `git push`로 현재 브랜치에 푸시 (upstream 없으면 `-u origin <branch>` 사용). origin 자체가 없으면 위 **공통 규칙**에 따라 사용자에게 원격 정보를 요청한다 — 커밋은 이미 끝났으므로 원격을 붙이면 그 커밋을 그대로 푸시한다.

2. **인자가 `pull`인 경우**:
   - origin이 없으면 위 **공통 규칙**에 따라 처리 (원격을 새로 연결한 경우 pull 대신 첫 푸시가 맞는지 확인)
   - `git pull`을 실행 (출력 확인은 서브에이전트 내부에서만, 반환은 `완료` / `실패: …` 한 줄)

3. **인자가 `revert`인 경우** (미커밋 변경 전체 취소 — 파괴적):
   - 현재 상태 미리보기 출력:
     - `git status --short` — 변경 파일 목록
     - `git diff --stat HEAD` — staged+unstaged diff 통계
     - `git ls-files --others --exclude-standard` — untracked 파일 목록
   - 취소 대상이 없으면 (`git status --porcelain` 빈 결과) "취소할 변경 없음" 출력 후 종료.
   - `AskUserQuestion` 도구로 사용자 확인:
     > "현재 미커밋 변경을 모두 취소합니다. 복구 불가. 다음 중 선택:"
     - 옵션 1: **취소 (tracked 만)** — `git reset --hard HEAD` 실행. 추적 파일의 staged+unstaged 변경 제거. untracked 파일은 보존.
     - 옵션 2: **취소 + untracked 삭제** — `git reset --hard HEAD && git clean -fd` 실행. 신규 파일·디렉터리까지 모두 제거. (Recommended 아님 — 신규 작업물 손실 위험)
     - 옵션 3: **중단**
   - 옵션 1 또는 2 선택 시 실행, 옵션 3 선택 시 종료.
   - 실행 후 `git status` 로 결과를 확인(서브에이전트 내부 확인용, 사용자에게는 한 줄만 반환).
   - **주의**: `git stash` 와 달리 복구 경로 없음. 사용자가 선택한 옵션 외에는 추가 작업 금지.

4. **인자가 `public` 또는 `private`인 경우** (원격 저장소 공개여부 전환):
   - 사전 조건 확인:
     - `gh --version`으로 GitHub CLI 설치 여부 확인. 없으면 "gh CLI 미설치 — `winget install GitHub.cli`(Windows) 또는 https://cli.github.com 설치 후 재시도" 안내 후 종료
     - `gh auth status`로 인증 확인. 미인증이면 "`gh auth login` 먼저 실행" 안내 후 종료
   - 현재 origin 저장소 식별:
     - `git remote get-url origin`으로 원격 URL 획득. 없으면 위 **공통 규칙**에 따라 사용자에게 원격 정보를 요청하고, 연결된 뒤 이어서 진행 (연결을 원치 않으면 종료)
     - URL에서 `OWNER/REPO` 추출 (예: `git@github.com:foo/bar.git` 또는 `https://github.com/foo/bar.git` → `foo/bar`)
   - 현재 가시성 조회: `gh repo view <OWNER/REPO> --json visibility -q .visibility`
     - 이미 요청한 상태와 같으면 "이미 <public|private> 상태입니다" 출력 후 종료
   - 가시성 변경 실행:
     - public 으로 전환: `gh repo edit <OWNER/REPO> --visibility public --accept-visibility-change-consequences`
     - private 으로 전환: `gh repo edit <OWNER/REPO> --visibility private --accept-visibility-change-consequences`
   - 결과 확인: `gh repo view <OWNER/REPO> --json nameWithOwner,visibility` 로 전환 여부만 확인
   - 실패(권한 부족·소유 아님 등) 시 `실패: <gh 에러 요지 한 줄>` 로 반환하고 종료

5. **그 외 인자**:
   - 인자를 그대로 `git` 명령의 서브커맨드로 전달하여 실행 (예: `/git status` → `git status`)
