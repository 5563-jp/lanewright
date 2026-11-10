# lanes — レーンのランチャ一式リファレンス

Mac で Claude / Codex / Gemini（Antigravity CLI `agy`）の CLI（コマンドラインで動く道具）を「レーン」として並列に回すための、
ランチャ（起動用スクリプト）・監視・後片付けの一式です。設定のしかたはキットのルートの手順書と `lanes.conf.example` を見てください。
ここでは各スクリプトの使い方・動き・終了コードをまとめます。

## 1. 全体像

### レーンとは
- **1 作業 = 1 worktree（git の作業ツリーを枝ごとに分けたもの）= 1 ランチャ**。触るファイルが重ならないように作業を分け、依存のないものは同時に起動します。
- worktree は `LANES_RUNS_ROOT`（既定 `$HOME/dev/_runs`）の下に置きます。監視はここを自動で探します。
- ランチャは `--dry-run` を付けると実際には起動せず、組み立てたコマンドだけを表示します（`.pid` / `.done` / ログは触らず、結合済みのプロンプトを `<label>.dry-run.prompt.md` に書くだけ）。

### label（レーンの名前）
- 省略するとプロンプトのファイル名（拡張子なし）になります。
- 使える文字は英数と `. _ -`、先頭は英数だけ（`.hidden` や `-lead` は不可）。日本語名のプロンプトは第 3 引数で label を渡します。二重指定は exit 2。

### 出力ファイル（`<worktree>/logs/`）
| ファイル | 中身 |
|---|---|
| `<label>.log` | 本文 |
| `<label>.json` | 生の出力。Claude は stream-json（1 行 1 イベント）で、実行中も増えるので「最後に出力した時刻」の判定に使う |
| `<label>.stderr.log` | 標準エラー |
| `<label>.prompt.md` | 実際に渡したプロンプトの全文（前置きテンプレを含む） |
| `<label>.last.md` / `<label>.completion.json` | Codex レビューの最終本文と、完了イベント・受信時刻・本文の SHA-256（内容から作る指紋）の照合記録 |
| `<label>.evidence.md` | PR 本文に貼る証跡（実行条件・検証結果・判定） |
| `<label>.pid` | 起動時に書く。pid・`lstart`（プロセス開始時刻）・開始時刻・レーン種別・worktree・子の pid と開始時刻・scratch のパス |
| `<label>.done` | 終了時に書く。`EXIT:n`・`VERDICT:`・終了時刻・経過分・補足 |
| `<label>.lock` | 同じ label の二重起動を防ぐ排他ロック（消さない・回転しない） |
| `.lanes-records` | ランチャの記録の台帳。ランチャと `detach-run.sh` が、`logs/` に何かを書く前に、書く名前の持ち主を 1 行ずつ載せる（`label:<label>` か `file:<名前>`）。`chk-run.sh` は、ここに載っている持ち主の記録だけを入力の指紋から外す（7 章）。手で書き換えない |

既存のログは上書きせず `<name>.prev-<日時>.<ext>` に退避します。

### scratch（レーン専用の一時領域）
- 各ランチャは起動時に `$LANES_SCRATCH_ROOT/<repo>/<label>/`（既定 `$LANES_RUNS_ROOT/_scratch/…`）を作り、`TMPDIR` と `LANES_SCRATCH` をそこへ向けます。中の `.lane` に worktree・枝・label を記録します。同じ名前のものが既にあり、それが自分の worktree の `.lane` を持つフォルダでなければ（別 worktree の scratch・`.lane` の無いフォルダやファイル）使わずに `<label>-2`・`-3` … へずらします。
- 一時 DB・ビルド出力・ログ・diff・CSV はすべてここへ置くよう、各 CLI にも指示を渡します（Codex には `developer_instructions`、Claude・Gemini・QA にはプロンプトの先頭）。
  **なぜ**: プロンプトに「ここに置け」と書くだけでは、レビュー用の CLI に届かず `~/Downloads` などへ一時物を作られたことがあるため、CLI 自体への指示として渡します。
- マージ後の `cleanup-after-merge.sh --apply` が、`.lane` の worktree が一致し、フォルダ名が `.lane` の label（ずらしたときは `<label>-<数>`）と合う scratch だけを消します。

### 証跡 `evidence.md`
PR を作るときは `logs/<label>.evidence.md` を本文に貼ります。実装レーンでは typecheck（型の検査）・lint（書き方の検査）・unit（単体テスト）を省略したら「完了」にしません（build は後述の分担に従い、ここでは「未実施（最終検証で担保）」と書きます）。

## 2. 役割の割り振り

`LANES_TOOLS`（使える道具。`claude` は必須）から `lanes-roles.sh` が構成を 1 つに決めます。

| 構成 `LANES_PROFILE` | 道具 | 実装 | レビュー |
|---|---|---|---|
| `full` | claude codex gemini | Claude が主、軽い作業を Gemini | Codex（`run-codex-review.sh`） |
| `claude-codex` | claude codex | Claude | Codex（`run-codex-review.sh`） |
| `claude-gemini` | claude gemini | Claude と Gemini | Claude（`run-claude-review.sh`・別セッション・読み取り専用） |
| `claude-only` | claude | Claude | Claude（同上） |

```zsh
zsh lanes/lanes-roles.sh --print      # 構成と LANES_ROLE_* を表示
zsh lanes/lanes-roles.sh --env        # KEY=value の形で表示
```

自分の zsh スクリプトで変数として使うときは、設定を読み込んでから判定の関数を呼びます（`source lanes-roles.sh` だけでは関数が定義されるだけで、変数は入りません）:
```zsh
source <kit>/lanes/lanes.env          # 設定ファイル（LANES_CONF）を読み、LANES_TOOLS などの既定を埋める
source <kit>/lanes/lanes-roles.sh     # 関数 lanes_roles_resolve を定義する
lanes_roles_resolve || { print -u2 -- "ERROR: $LANES_ROLES_ERROR"; exit 2; }   # ここで LANES_PROFILE などが入る
print -r -- "構成 $LANES_PROFILE / 実装 $LANES_ROLE_IMPL / レビュー $LANES_ROLE_REVIEW"
```

出す変数: `LANES_PROFILE`、`LANES_ROLE_IMPL`（`claude` か `claude gemini`）、`LANES_ROLE_REVIEW`（`codex` か `claude`）、`LANES_REVIEW_INDEPENDENT`（実装とは別の道具でレビューするなら `1`、同じ Claude の別セッションなら `0`）。

### 入口（ふだんはこの 2 つだけ使えばよい）
```zsh
# 実装。--engine を省くと構成どおり。gemini を選んだときは --verify / --allow-path も渡す
zsh lanes/run-impl.sh <worktree> <prompt.md> [label] [--engine claude|gemini] [--dry-run] [--verify "<cmd>" --allow-path <相対パス> ... --no-push]
# レビュー。構成に合うレビュー用ランチャへ振り分ける
zsh lanes/run-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--dry-run]
```
どちらも役割に合うランチャ（下の表の `run-*.sh`）へ振り分けます。個別のランチャを直接呼んでもかまいません（構成に無い道具のランチャは exit 2 で止まります）。
`run-review.sh` は①②（Codex レビュー）でも③④（Claude レビュー）でも、引数をそのまま振り分け先へ渡します。どちらのレビューも同じ `review-dedup.zsh` の仕組み（`--mode auto` の自動の full / delta / 同じ head の結果の再利用、`--round N` と round 3 以降の P2/P3 の後回し、`--force`、`--base` は commit に解決できるもの）と、親の `chk-run.sh` の記録による必須検証の使い回し（6 章）を持ちます。

Gemini と Claude の分け方の目安: 課金・認証・本番 DB・重い端末作業・重い設計判断は Claude。仕様が固まった小さめの作業（目安 6 ファイル・400 行まで）は Gemini に回せます。

### 起動前点検 `lanes-doctor.sh`
```zsh
zsh lanes/lanes-doctor.sh [--quiet] [<worktree>]
```
`LANES_TOOLS` の各道具が入っているか、**サブスク（定額プラン）のアカウントでログインしているか**（API キーでの起動になっていないか）を確かめ、足りないものを全部並べて exit 2 で止まります（揃っていれば 0）。
ログインの見方: Claude は `claude auth status`、Codex は `codex login status`、Gemini（`agy`）はログイン確認のコマンドが無いので、ログイン情報の置き場所 `~/.gemini/antigravity-cli` の有無です。
Gemini を含む構成では、`run-gemini.sh` が必須にしている macOS の端末サンドボックス（`/usr/bin/sandbox-exec`）があって実際に有効にできるかも見ます。ほかに python3 / git / zsh（必須）と gh（任意。無ければ注意だけ）も見ます。
作業ツリーを渡すと、ランチャが記録を書く `logs/` が git に無視されているか（`.gitignore` か `.git/info/exclude`）も見ます。無視されていなければ注意だけ出します（失敗にはしない）。git の作業ツリーでない場所を渡すと NG です。
各ランチャも冒頭で、自分が使う道具だけ同じ点検を通します。テスト用に点検を飛ばす抜け道は用意していません（テストはスタブの CLI で確かめます）。

## 3. スクリプト一覧

### 実装・レビュー・QA のランチャ
| スクリプト | 使い方 | 何をするか |
|---|---|---|
| `run-impl.sh` | `<worktree> <prompt.md> [label] [--engine claude\|gemini] [--dry-run] [gemini 用の --verify/--allow-path/--no-push]` | 構成に合う実装ランチャ（`run-claude.sh` / `run-gemini.sh`）へ振り分ける |
| `run-review.sh` | `<worktree> <prompt.md> [label] [--mode auto\|full\|delta] [--base <sha\|branch>] [--round N] [--force] [--dry-run]` | 構成に合うレビュー用ランチャ（`run-codex-review.sh` / `run-claude-review.sh`）へ振り分ける |
| `run-claude.sh` | `<worktree> <prompt.md> [label] [--dry-run]` | Claude の実装レーン。許可モード `CLAUDE_IMPL_PERMISSION_MODE`（既定 `acceptEdits`）と確認なしで使うツール `CLAUDE_IMPL_ALLOWED_TOOLS` を明示して渡す。前置き `templates/claude-impl-preamble.md`（自己レビューは最大 2 回・指示範囲外のファイルを触らない）を自動で付ける（`CLAUDE_NO_PREAMBLE=1` で無効） |
| `run-gemini.sh` | `<worktree> <prompt.md> [label] --verify "<cmd>" --allow-path <相対パス> [--allow-path ...] [--no-push] [--dry-run]` | Gemini の実装レーン（レビューには使わない）。詳細は下 |
| `run-codex-review.sh` | `<worktree> <prompt.md> [label] [--mode auto\|full\|delta] [--base <sha\|branch>] [--round N] [--force] [--dry-run]` | Codex の `exec review --json` によるレビュー（`-c sandbox_mode="read-only"` で読み取り専用を強制・子の push は止める）。既定 `--mode auto` |
| `run-claude-review.sh` | `<worktree> <prompt.md> [label] [--mode auto\|full\|delta] [--base <sha\|branch>] [--round N] [--force] [--dry-run]` | Claude によるレビュー（別セッション・読み取り専用）。テンプレ `templates/claude-review-{full,delta}.md` を自動で前置き。既定 `--mode auto`（Codex レビューと同じ仕組み） |
| `run-codex.sh` | `<worktree> <prompt.md> [label] [--dry-run]` | Codex に実装させる場合のランチャ（明示して使うときだけ）。sandbox は `CODEX_IMPL_SANDBOX`（既定 `workspace-write`）を明示する |
| `run-qa.sh` | `<worktree> <prompt.md> [label] [--dry-run]` | マージ後の bot QA（観点の洗い出し → bot でできる確認）。テンプレ `templates/qa-bot.md` を前置き。読み取り主体で、作業ツリーか git の管理フォルダ（共通の config・`config.worktree`・hooks・`info/attributes`・タグ・stash。Claude レビューと同じ `rvd_git_guard`）を変えたら `NEEDS_FIX`・`EXIT:4`。`CLEAN` は「人の QA 待ち」として報告するだけで、課題管理ツール（チケットの状態など）とは連携しない |

#### 排他を取る前の誤りの記録
引数の誤り・`--base` の形の誤り・設定の値の誤りなどで、label の排他（`.lock`）を取る前に止まったときも、同じ label の前回の `.done` を残したままにはしません。
- 排他を取れたら、前回の `.pid` / `.done` を `.prev-<日時>` に回転し、今回の `.done`（`EXIT:2`・`VERDICT: NONE`・`note=起動前の誤り: ...`）を書きます。`lanes-status.sh` は `FAILED` を返します。
- 排他を取れない（同じ label が実行中）・前回のプロセスが生きているときは「前回の記録には触らない」と出して、記録はそのままにします。
- `logs/` が無いとき（worktree が無い・一度も起動していない）と `--dry-run` のときは何も書きません。label が 2 回指定された・label の形が不正なときも、どの label か決められないので書きません。
- 不明なオプションも同じく止めて記録します。label は指示書の直後に置いてください。不明なオプションの次の語が `-` で始まらなければ、そのオプションの値として読み捨てます（`--mode full` の `full` を label と取り違えない。`--name=value` の形は次の語を読み捨てません）。全ランチャ共通（`_common.sh` の `lanes_unknown_opt_width`）です。
- 入口（`run-impl.sh` / `run-review.sh`）自身の誤り（不明なオプション・`--engine` の誤り・構成に無い道具・`--round` や `--base` の扱いの誤りなど）も同じです。

#### `run-gemini.sh` の補足
- `--verify`（必須）: 全体テストと build はランチャが**サンドボックス（隔離された実行環境）の外**で実行します。正常終了なら差分がなくても検証します。Gemini 本体はサンドボックス内で typecheck・lint・関係するテストだけを回します。
- `--allow-path`（必須・複数可）: 保存してよい相対パス。ファイルは完全一致、末尾 `/` は配下全体。範囲外の変更は `EXIT:4`。
- 開始時に未保存の変更があれば拒否します。commit はランチャが担当し、今回の `$LANES_SCRATCH/COMMIT_MSG.txt` と許可範囲の差分だけを検証成功後に保存します（古いメッセージは開始・再試行の前に退避）。
- `agy` には `--sandbox`・`--settings`（`mcp(*)` の呼び出し拒否など）・`ANTIGRAVITY_HEADLESS=true` を強制します。書けるのは worktree と scratch だけで、Git の管理領域（`.git` 本体・フック・設定）は渡しません。
  **なぜ**: `.git/hooks` に書かれると、ランチャの `git commit` のときにそのコードが走ってしまうため。そのため本体 checkout（`.git` がディレクトリ）では起動せず、専用の linked worktree が前提です。`agy` の終了後、git を実行する前に worktree の `.git` ファイルが変わっていないことも確かめます（変わっていれば `EXIT:4`）。
- `main` / `master` / 統合先 / detached HEAD（枝に乗っていない状態）では push しません。`--no-push` は通常終了時もローカル保存まで。
- 時間の上限: 子プロセスが無く出力が `GEMINI_IDLE_GRACE`（既定 60 秒、再開後は `GEMINI_IDLE_RESUME_GRACE` 既定 300 秒）止まれば強制停止（`EXIT:3`）。子が実行中なら idle でも待ちます。出力が `GEMINI_NOOUTPUT_SEC`（既定 600 秒）止まれば停止して作業中の差分を `$LANES_SCRATCH/wip.patch` に保存（`EXIT:8`）。全体の上限は `GEMINI_PRINT_TIMEOUT`（既定 `75m`）。
- 異常終了でも、許可範囲の差分・今回のメッセージ・書き込み監査・`--verify` の成功が揃えば救済 commit しますが、終了コードは `3` のままで push しません。
- 依存の自動用意: worktree の直下と `apps/*/`・`packages/*/` のロックファイル（依存の版を固定するファイル）を見て、`node_modules/.bin` が無い所だけ入れます（`npm ci` / `pnpm install --frozen-lockfile`。`yarn.lock` は案内のみ）。入れるのはサンドボックスの外で、ログは `$LANES_SCRATCH` の下です。
- 変更なしの一時エラーだけ 1 回再試行します。前置きは `templates/gemini-impl-preamble.md`（`GEMINI_NO_PREAMBLE=1` で無効）。

### 監視
| スクリプト | 使い方 | 何をするか |
|---|---|---|
| `lanes-status.sh` | `<worktree> [label] [--tail N]` | レーンの生死を 1 行で返す（4 章）。label 省略で全 label |
| `lanes-monitor.sh` | `[--no-append] [--reset] [--allow-redeploy]` | 1 回分の巡回。`LANES_RUNS_ROOT` の下で `logs/*.pid` を持つ作業場所を探し（`_`・`.` 始まり、退避済み、シンボリックリンクは除外）、`origin` が分かる GitHub リポジトリだけ open PR を照会。前回状態と比べて 1 行目に `WAKE: <理由>` か `QUIET` を出し、新しく終わったものと要対応は省略せず全件出す。`gh`（GitHub の CLI）が無い・未ログインなら PR の照会は黙って飛ばし、直前の PR 状態をそのまま保持する |
| `lanes-watch.sh` | `[--until-wake] [--interval 秒] [--max-hours 時間]` / `--check` | 5 分ごとのウォッチと定期の生存確認（既定 10 分ごと。`LANES_CHECK_INTERVAL_MIN`。5 章） |
| `hooks/claude-stop-watch-guard.sh` | （Claude Code の Stop フックとして登録） | 司令塔のセッションが 5 分の見張りをかけ直さないまま返事を終えるのを止める（[docs/commander-claude.md](../docs/commander-claude.md)） |

`lanes-monitor.sh` の状態は `$LANES_RUNS_ROOT/.lanes-monitor-state.json`（`.lock` で排他）、履歴は `$LANES_RUNS_ROOT/lanes-monitor-now.txt` に 1 行追記します（`--no-append` で止める）。`--reset` は既読状態を捨てて読み直します。

### 確認・後片付け・QA の準備
| スクリプト | 使い方 | 何をするか |
|---|---|---|
| `chk-run.sh` | `<worktree> <port> <outdir> [--merge <ref>] [--force]` / `<worktree> --query` | 統合直前の最終確認（7 章）。対象リポの `.lanes/check.sh`（優先）か `LANES_CHECK_CMD` を 1 本回し、`check=<rc>（出どころ）` を出す。`--query` は回さずに記録を使い回せるかだけ答える（レビューランチャが使う） |
| `cleanup-after-merge.sh` | `<worktree> [--apply]` | マージ後の後片付けと残骸の退避（9 章）。既定は dry-run（表示だけ） |
| `cleanup-merged-worktrees.sh` | `<本体 checkout> [--apply]` | リポ全体の worktree に `cleanup-after-merge.sh` を回し、worktree の無いマージ済みローカル枝（`origin/$LANES_BASE_BRANCH` 基準。`main` / `master` / 統合先は除く）も消す。既定 dry-run。個別の停止があれば非 0 |
| `after-develop-merge.sh` | `<feature-worktree> [--apply] [--skip-qa] [--no-deps] [--qa-prompt <path>] [--label <label>] [--repo owner/name] [--main-checkout <path> --feature-head <sha>]` | 統合後の入口。取り込み固定 → QA 用 worktree → 後片付け → QA 起動（9 章）。既定 dry-run。統合先は `LANES_BASE_BRANCH`（ファイル名は互換のため `develop` のまま） |
| `prepare-screen-qa.sh` | `<checkout> [label] [--url <preview-url>] [--viewpoints <観点ファイル>]` | 画面 QA のプロンプト雛形を `logs/` に書く（10 章）。URL が決まらなければ exit 2 |
| `detach-run.sh` | `<launch.log> <コマンド> [引数...]` | 呼び出し元のプロセスグループ（まとめて止められるプロセスの束）から切り離して起動する（12 章） |

### 中で使う部品（直接は呼ばない）
| ファイル | 役割 |
|---|---|
| `_common.sh` | ランチャ共通の処理（設定読み込み・点検・API キー無害化・MCP 遮断・排他・ログ回転・子プロセスの監督・VERDICT 判定）。zsh 専用で、bash から読むと exit 2 |
| `lanes.env` | 最初に `LANES_CONF` の設定ファイルを読み、空のキーを既定値で埋めて、`LANES_*` を export する（Python の部品と `chk-run.sh` に届けるため） |
| `lanes-roles.sh` / `lanes-doctor.sh` | 役割の割り振り / 起動前点検（2 章） |
| `review-dedup.zsh` | 同じレビューを繰り返さない仕組み（6 章） |
| `codex-review-output.py` | Codex レビューの JSON から最終本文と完了記録を作る |
| `lanes_monitor.py` / `lanes_watch.py` | 監視の本体 |
| `vercel_autoredeploy.py` | Vercel の自動再デプロイ（11 章・任意。`LANES_VERCEL_PROJECT` が空なら無効） |
| `templates/` | 実装の前置き・レビューのテンプレ・QA のテンプレ |

### ランチャ共通の流れ
1. worktree を確かめた直後に `.pid` を書く（以後どこで落ちても `.done` が残る）
2. 起動前点検（サブスクのログイン確認。認証状態の本文はログに出さない）→ API キーの環境変数を外す
3. MCP（外部サービスへつなぐ拡張機能）の遮断（8 章）
4. `logs/<label>.lock` の排他ロック
5. プロンプトは stdin（標準入力）で渡す（コマンドライン長の上限と、`-` 始まりのプロンプトがオプション扱いされる事故を避けるため）。上限は `LANES_PROMPT_MAX_BYTES`
6. ログ回転 → 実行 → `EXIT:n` と証跡を書く。終了時に macOS 通知（`LANES_NOTIFY=0` で無効）

## 4. 生死監視（`lanes-status.sh`）

```zsh
zsh lanes/lanes-status.sh <worktree>                    # 全 label を 1 行ずつ
zsh lanes/lanes-status.sh <worktree> <label> --tail 20  # DONE 以外は最終出力ファイルの末尾も出す
```

| 状態 | 意味 | 終了コード | 次にやること |
|---|---|---|---|
| `RUNNING` | pid が生きていて、最終出力から `LANES_STALL_MINUTES`（既定 10）分以内 | 10 | 待つ |
| `STALLED` | pid は生きているが、最終出力から閾値を超えた | 11 | 末尾を見る。許可待ち・利用枠待ちの疑い。子の CPU 時間が増えていれば「動いているが無出力」（build やテスト中など） |
| `DONE` | `.done` が `EXIT:0` | 0 | 待たずに次工程 |
| `FAILED` | `.done` が `EXIT≠0`（前提チェック失敗・VERDICT 無し・CLI エラー・シグナル）、または `.done` が無く pid の同一性が確かめられない | 13 | 末尾と推定原因を添えて報告。同一性不明なら持ち主と終了を確かめるまで止めない・消さない |
| `DEAD` | pid が消えたのに `.done` が無い（`kill -9`・再起動などで後始末も走れなかった） | 12 | 同上 |
| `NONE` | `.pid` も `.done` も無い | 14 | label の間違い。ランチャの標準エラーを見る |

- 複数 label のときは最も重いもの（NONE 14 > FAILED 13 > DEAD 12 > STALLED 11 > RUNNING 10 > DONE 0）。使い方の誤りは 2。
- 引数の誤り（`--base` の値が無い・形式違い、不明なオプション、設定の値の誤り）で排他を取る前に止まったときも、その label の排他を取れれば前回の `.pid` / `.done` を回転して今回の `.done`（`EXIT:2`・`VERDICT: NONE`・`note=起動前の誤り: ...`）を残すので、status は `FAILED` を返します（前回の `DONE` と取り違えない）。同じ label が実行中・前回の子が生きているときは、その旨を出して前回の記録に触りません。label そのものが不正なとき・`logs/` の無い worktree（一度も起動していない）・`--dry-run` のときは何も記録しません。
- **起動したと言う前に状態を見る**: 起動から 60 秒以内に status を見て、`RUNNING` か `DONE` でなければ起動失敗として末尾を添えて扱います。報告は毎回「状態 / 経過時間 / 最終出力の時刻 / 次にやること」の 4 点。
  **なぜ**: 起動したつもりで実は止まっていて、誰も気づかないまま時間だけ過ぎる事故を防ぐため。

### 同じ label の排他と止め方
- 同じ label は「ランチャが実行中」でも「前回の子（claude / codex / agy）が生きている」でも起動を拒否します（exit 2）。生死は `lstart`（`LC_ALL=C TZ=UTC` 固定の開始時刻）で照合し、pid の使い回しを見分けます。開始時刻が取れないなど同一性が確かめられないものは、終わったとみなさず再起動もログ回転も保留します。
- 止めるときは **`kill <ランチャの pid>`**（`.pid` の `pid=` 行）。ランチャは子の終了を最大 10 秒待ってから `.done` を書きます。`kill -9` は後始末が走らないので使いません。
- `FAILED` / `DEAD` の行に「子 pid=N 生存」と出たときだけ、その子を `kill N` してから再起動します。`RUNNING` / `STALLED` の子は健全なので kill しません。
- 子孫プロセスは監督役が pid・親 pid・プロセスグループ・開始時刻と起動ごとの合言葉で追い、別グループへ移った孫（テスト用サーバーなど）まで `TERM` → 最大 5 秒 → `KILL` で回収を確かめてから `.done` を書きます（回収を確かめられなければ `EXIT:3`）。プロセス一覧の取得が一時的に失敗しても健全な子は止めず、60 秒続いたときだけ打ち切ります。

### 起動のしかた（親を残す）
短命のシェルから `nohup ... &` で起動すると、シェルの終了と一緒に子が止められることがあります。ランチャ自体を長く生きるシェルからバックグラウンドで起動し、親を残してください（Bot のシェルから呼ぶ場合は 12 章）。

## 5. ウォッチ（`lanes-watch.sh`）

### 5 分ごとのウォッチ
```zsh
zsh lanes/lanes-watch.sh --until-wake          # WAKE: を見つけたら exit 0 で起こす
zsh lanes/lanes-watch.sh --interval 300 --max-hours 12
```
- 既定 300 秒ごと・上限 12 時間で `lanes-monitor.sh --no-append` を回し、`$LANES_RUNS_ROOT/.lanes-watch.heartbeat`（生きている印）を更新します。
- 二重起動は `.lanes-watch.heartbeat.lock` で排他し、exit 2（ロックファイルは消さない）。
- 司令塔が Claude（`LANES_COMMANDER=claude`）なら `--until-wake` をバックグラウンドで動かし、終了通知で起きて次工程を判断し、また監視を始めます。
- 外の Bot が司令塔なら、`lanes-watch.sh` を親から切り離して常駐させる（12 章の `detach-run.sh`）か、Bot の 5 分ごとの定期実行で `lanes-monitor.sh`（1 回分の巡回）を回します。
  `--until-wake` を付けない `lanes-watch.sh` は終わらずに回り続けるので、定期実行のたびに起動するものではありません（2 本目は exit 2）。

### 定期のウォッチのウォッチ（既定 10 分ごと）
```zsh
zsh lanes/lanes-watch.sh --check
```
- heartbeat の pid・`lstart`・経過秒を照合し、15 分以内（5 分の見回りの 3 回分）なら `WATCH OK`（exit 0）、それより古い `WATCH STALE` か、ウォッチが死んだ `WATCH DEAD` なら exit 1。1 なら司令塔がウォッチを再起動します。
- あわせて稼働中のレーン数（`LANES RUNNING`）と直近 N 分（`LANES_CHECK_INTERVAL_MIN`、既定 10）の `DONE`（次工程待ち）を出します。次工程待ちと、担当ファイルが重ならない並列作業があれば司令塔が起動を足します。**スクリプト自身は作業レーンを起動しません。**
- 差し替え用の環境変数（テスト用）: `LANES_RUNS_ROOT`、`LANES_WATCH_MONITOR`、`LANES_WATCH_HEARTBEAT`。

**なぜ全自動でつながないか**: DONE → レビュー → PR → マージ → 次レーンの判断は司令塔が status を見てすぐつなぎます。スクリプトで全自動に連鎖させると、止めるべき失敗を素通りさせやすいためです。

## 6. レビュー

### full と delta
| モード | 使う場面 | 比較起点 |
|---|---|---|
| `full` | 初回、重大（P0 / P1）の修正後、前回 `NEEDS_FIX` の後 | `--base`。無ければ `origin/$LANES_BASE_BRANCH` |
| `delta` | 前回 `CLEAN` の後の軽い修正 | 前回の記録の HEAD（前回の記録が使えなければ `delta` を指定しても `full` に戻す） |
| `auto`（既定。Codex・Claude とも） | いつでも | 下の条件で `full` / `delta` / 省略を自動で選ぶ |

- 差分が認証・DB・決済・メールなどに触れると、テンプレの指示で delta でも full 相当へ格上げします。
- `--base` の形: `run-codex-review.sh`・`run-claude-review.sh` とも commit に解決できるもの（枝名も可）。起動前に commit へ固定し、再利用の条件にも入れます。統合先の枝が無いリポでは `--base` が必須で、無ければ案内を出して `EXIT:2`。

### 同じレビューを繰り返さない（`--mode auto`・`review-dedup.zsh`）
- 状態は `logs/.<series>.review-state`（series = label の末尾 `-r<N>` を外したもの）に、HEAD・判定・条件の指紋・作業ツリーの写し・比較起点・本文をまとめて保存します（`NONE` は保存しない）。
- 前回が `CLEAN`（`EXIT:0`）で、前後とも未保存の変更が無く、比較起点・案件指示・モード・モデル・effort・スクリプト・テンプレ・検証の設定（`LANES_CHECK_CMD` の値・対象の `.lanes/check.sh` の中身・`package.json` の scripts のうち typecheck / lint / test 系のもの）が同じときだけ、同じ HEAD なら省略（`--force` で強制実行）、進んでいれば前回 HEAD からの delta にします。どれかが変われば full。検証が未導入で `CLEAN` になった後に検証を足した（例: `LANES_CHECK_CMD` を設定した）ときも、同じ HEAD のまま前回の結果を使わずにレビューし直します。
- 前回が `NEEDS_FIX` なら delta 指定でも full に戻し、前回の未解決の指摘を自動で引き継ぎます。全件の解消を確かめて独立した行 `RESOLVED_PREVIOUS_FINDINGS: YES` を出さない限り `NEEDS_FIX` のままです（コード例・引用・表の中や、`NO` との併記では解除しない）。
- Codex レビュー（`run-codex-review.sh`）と Claude レビュー（`run-claude-review.sh`）は同じ仕組みです。レビュー役（codex / claude）も条件に入るので、構成を変えたら前回の結果は使いません。どちらのランチャも、子の実行中に再利用の記録が書き換えられたら元の中身に戻して不合格（`NEEDS_FIX`・`EXIT:4`）にします。

### 必須検証の使い回し（親の `chk-run.sh` の記録）
レビューのたびに、親が同じ HEAD で回した確認（型検査・lint・単体テスト）をレビュアーがもう一度回さないための仕組みです（`LANES_REVIEW_REUSE_CHECKS`。既定 `1`、`0` で問い合わせない）。
- 出どころは `chk-run.sh` の確認済みの記録（`passed.tsv`）だけです。ランチャが計算した記録で、AI の自己申告は使いません。
- レビューランチャは子を起動する前に `chk-run.sh <worktree> --query` で問い合わせます。一致条件は `skip=same-tree` と同じ（tree・入力の指紋・確認コマンドの指紋）で、緩めません。
  入力の指紋には作業ツリー（無視対象のファイルも含む）と環境変数が入るので、ランチャは scratch や git の通信止めを export する前に、`_common.sh` が外した API キーなども元に戻した環境で問い合わせます。**親は `chk-run.sh` とレビューを同じ環境（同じシェル）から呼び、その間に作業ツリーを変えないでください。** 変えると使い回さず、今までどおりレビューの中で回させます。
  ランチャの記録（`logs/` の直下の `.pid`・`.done`・ログ・証跡・起動ログなどのうち、ランチャが台帳 `logs/.lanes-records` に載せた持ち主のもの。7 章の `chk-run.sh`）は指紋に入りません。`detach-run.sh` が起動ログ（`logs/launch.log`）を先に書いても、前のレーンの記録が残っていても、記録と合います。台帳に無い名前のファイル（確認コマンドが読む `logs/input.json` など）は、記録に似た名前でも入力のままです。
- 使い回せるとき: 指示書に「必須検証（typecheck / lint / unit）は親が同じ中身で実施済み（chk-run の記録: head・日時・確認コマンドの種類）。回さないこと。確かめたい点は該当テスト 1 本か小さな再現だけ」と入れ、必須検証は済んだものとして判定します（Codex: 成功確認 `COMPLETE` と同じ扱い。Claude: テンプレの「検証 1 に未実施があれば CLEAN を出さない」を適用しない）。レビュアーが自分で回したテストの「失敗」の報告だけは不合格にします。証跡には `- 必須検証: 親の chk-run の記録を使用（head・日時・確認コマンド）` を出します。
- 使い回せないとき（記録が無い・tree が違う・確認コマンドや環境が変わった・未 commit の変更がある・確認コマンドを確実に解決できない書き方など）: 今までとまったく同じ動きです。証跡には `- 必須検証: レビューの中で回すよう指示（親の chk-run の記録は使わない: <理由>）` を出します（指示した事実だけです。回せたかどうかは、証跡の「必須検証の成功確認」の行が示します）。
- 使い回しの有無と使った記録（head・日時・確認コマンドの種類）は再利用の条件に入ります。記録が変わったら（使い回しが無くなった・親が回し直した）同じ HEAD でも前回の結果を使いません。
  ランチャの記録は指紋に入らないので、レビュー自身が `logs/` に書いた後に同じ HEAD で呼び直しても、記録と合います（条件が同じなら前回の結果を使い、レビューし直しません）。
- **何を確かめたことになるかは確認コマンドの中身次第です。** 確認コマンドに単体テストを入れていなければ、単体テストを確かめたことにはなりません。型検査・lint・単体テストをすべて確認コマンド（`.lanes/check.sh` か `LANES_CHECK_CMD`）に入れてください。
- 記録（`passed.tsv`）は作業ツリーの外にあります。Bash を持つレーン（Claude の実装・レビュー）は作業ツリーの外にも書けるので、記録を書き換えることはできてしまいます（`chk-run.sh` 自身の省略と同じ前提です）。最終の担保は CI です。

### round と GATE
`--round N`（または label 末尾の `-r<N>`）を付けると、証跡と `.done` に `GATE:` と指摘数（P0〜P3）を書きます（Codex・Claude のレビューとも）。
| GATE | 条件 |
|---|---|
| `CLEAN` | 指摘なし |
| `FIX` | 修正して再レビュー（検証未実施などの、指摘を伴わない `NEEDS_FIX` もここ） |
| `MERGE_WITH_FOLLOWUP` | 3 回目以降で P0 / P1 が 0 件、P2 / P3 だけ。修正周回をせず PR → CI → マージへ進み、残りは `logs/<series>.followups.md`（後回し票の下書き）から課題として起票して別レーンで直す |
| `STOP_P0P1` | 3 回目以降も P0 / P1 が残る。止めて報告 |
| `ESCALATE` | 周回が `LANES_REVIEW_MAX_ROUNDS`（既定 5）を超えても `CLEAN` にならない（P0 / P1 が残っていても）。修正を続けず、人に「直して続けるか・締めるか」を返す。続けるなら上限を上げる。締めるなら残りを `.lanes/accepted-limitations.md`（受け入れ済みの限界）か後回し票へ |

受け入れ済みの限界: 対象リポに `.lanes/accepted-limitations.md`（symlink は読まない）を置くと、Codex・Claude のどちらのレビューの指示書にも「ここに当てはまる指摘は P0〜P2 にしない（気づいたら P3 で一言）」として必ず入ります。中身はレビューの再利用の条件にも入るので、書き換えたら同じ HEAD でもレビューし直します。仕組み上防げないもの（例: Claude のレビューの子は同じ利用者の権限で Bash を使える）や、想定する脅威の外のものを書きます。

後回し票の保存に失敗したら合格にせず `VERDICT: NONE`・`EXIT:3`・`GATE: FIX` です。修正レーンの指示書には「指摘箇所だけでなく、同じ種類の問題を差分全体から探してまとめて直す」と入れてください。

### VERDICT のきまり
最終行は必ず `VERDICT: CLEAN` / `VERDICT: NEEDS_FIX` / `VERDICT: NONE` のどれかです。判定は `_common.sh` の `lanes_parse_review` と `codex-review-output.py` が行います。
- **明示の判定行は「行全体が」`VERDICT: CLEAN` / `VERDICT: NEEDS_FIX` のときだけ採用**します（箇条書きの `- * +`、太字、バッククォートは可。番号付き・見出し・文中の引用・表のセルは不可）。
  **なぜ**: 本文中で「VERDICT: CLEAN と書くべき」などと触れただけで合格扱いになる、偽の CLEAN を通さないため。
- コードフェンス（` ``` ` / `~~~`）・字下げのコード・引用（`>`）・表（`|`）の中は解析しません。
- **未完了を最優先で失敗にする**: 途切れた出力、閉じていないコードフェンス、「レビューを実施できませんでした」などの未実施・中断の文言、Codex の完了イベント（開始 → 本文 → 完了、エラーなし、終了コード 0）と最終本文の SHA-256 の不一致は、指摘数より優先して `NONE`。
- P0 / P1 / P2 の指摘が 1 件でもあれば、明示の `CLEAN` 行があっても `NEEDS_FIX`（3 回目以降の `MERGE_WITH_FOLLOWUP` を除く）。
- 明示の判定行も P0〜P2 も無いときは、Codex で完了の証明と「問題が見つからなかった」旨の文が揃うときだけ `CLEAN`。それ以外（P3 だけで判定行なし、`is_error`、result イベント欠落を含む）は `NONE`。
- **`NONE` は必ず非 0**（`EXIT:3`）。`NONE` かつ `EXIT:0` はありません。CLI が非 0 で終わったときは `NONE` にしてその終了コードを返します。
- 検証の報告: typecheck・lint・unit の未実施は不足として `CLEAN` にしません。build だけは「未実施（最終検証で担保）」を正当な報告として受け付けます。両レビューランチャが指示書に足す成功行は `CHECKS: typecheck=PASS lint=PASS unit=PASS build=SKIP`（`build=PASS` も可。必須検証を使い回すときは求めません）。対象リポジトリにその仕組み自体が無い項目（`package.json` の scripts・設定ファイル・`LANES_CHECK_CMD`・`.lanes/check.sh` のどれにも無い、または指示書に「未導入」）は「該当なし（未導入）」として未実施に数えず、成功行では `NA`（例: `lint=NA`）と書きます。仕組みがあるのに回していないときは従来どおり不足です（「未導入」「仕組みが無い」などの言い換えや、`**lint**` のような太字・行内コードの項目名も同じく突き合わせます）。Claude レビューのテンプレート（`templates/claude-review-full.md`・`claude-review-delta.md`）も同じ扱いです。
  `NA`・「該当なし」はレビュー役の自己申告だけでは通しません。ランチャ（`run-codex-review.sh`・`run-claude-review.sh`）が対象の `package.json` の scripts・`LANES_CHECK_CMD`・`.lanes/check.sh` を見て（`_common.sh` の `lanes_checks_present`）、scripts にある項目の `NA`、または `LANES_CHECK_CMD` か `.lanes/check.sh` があるのに 3 項目すべて `NA` なら `NEEDS_FIX` にします。見た項目は証跡に残ります。

### レビューは読み取り専用
- Claude のレビュー・QA: `--tools` で内蔵ツールを `CLAUDE_REVIEW_TOOLS`（既定 Bash / Read / Glob / Grep。編集系・サブエージェントを入れると起動しない）に絞り、`--disallowedTools` の固定の一覧（`_common.sh` の `LANES_CLAUDE_REVIEW_DENY_BASE`。設定では外せず、`CLAUDE_REVIEW_DENY` は足すだけ）で編集系ツール・サブエージェント・Bash 経由の履歴操作・別 CLI の起動・作業ツリーの外に副作用を出すコマンド（`gh pr merge/close/create/edit`、`gh api`、`vercel`、`supabase db push/reset`、`git tag/config/remote/update-ref`、`publish` など）を明示的に拒否します（拒否は許可より優先）。読み取りのコマンドは通ります。ただし、この禁止一覧（`gh` / `vercel` / `supabase` などの副作用）は「コマンド先頭一致」なので、`command gh ...` や絶対パス（`/opt/homebrew/bin/gh ...` など）の書き方では抜けられます。
- Bash の先頭一致では防げない操作のうち、作業ツリーの変更（commit・ファイルの書き換えなど）は前後の内容・権限・履歴・索引の写しを比べて検出し、変わっていれば `VERDICT: NEEDS_FIX`・`EXIT:4` にします。Claude のレビューと QA は、git の管理フォルダ側（共通の `config`・`config.worktree`・hooks・`info/attributes`・タグ・stash）も前後で比べます（`review-dedup.zsh` の `rvd_git_guard`）。無視対象のファイル（`.env.local` など）も中身まで比べます。依存・ビルド・テストの出力（`node_modules` `dist` `build` `out` `__pycache__` など）と `logs/` は比べません。この比較はリモートを見ないので、push は検出ではなく**止めて**防ぎます: レビュー・QA の子プロセスには `GIT_ALLOW_PROTOCOL`（git が使ってよい通信方式の一覧）に実在しない名前だけを渡し、`git -C . push`・パスを直接書いた push・`-c protocol.allow=always` 付きの push も含めて git の通信（push・fetch）をすべて失敗させます。レビューは fetch をしない約束なので困りません。ただし、子が環境変数そのものを外す操作までは防げず、`gh` や `vercel` などの外部 CLI にも `GIT_ALLOW_PROTOCOL` は効きません。本番の鍵・本番 DB・本番デプロイがある環境では使わないでください。
- Codex のレビュー: `-c sandbox_mode="read-only"` で読み取り専用を強制します（`CODEX_REVIEW_SANDBOX`。`read-only` か `workspace-write` だけ。利用者の `~/.codex/config.toml` が `danger-full-access` でも上書きします）。作業ツリーの変更と git の管理フォルダ側（`rvd_git_guard`）は Claude と同じ前後の比較で不合格にします。加えて、`workspace-write` の子は worktree の `.git` ファイルを書けるため、`run-codex.sh` と同じく git の制御ファイル（`.git`・`commondir`・`gitdir`・`config`・`config.worktree`・hooks）の指紋（`_common.sh` の `lanes_git_ctl_fingerprint`）を子の直後・git を呼ぶ前に比べ、違えば git を 1 回も呼ばずに `EXIT:4` で止めます（sandbox の種類によらず比べます）。再利用の記録（`logs/.<系列>.review-state`。今の系列だけでなく全部の系列）が子の実行中に増えた・変わった・消えたら、子の前の状態に戻して不合格にします。戻しきれなかったとき（消せない物を置かれた・`logs/` を書けなくされた）と、「使い回し禁止」の印が子の実行中に消されたときは、印を `logs/.review-reuse-blocked` と、`logs/` の外の `${XDG_STATE_HOME:-~/.local/state}/lanewright/reuse-blocked/<logs/ の実パスの指紋>` の両方に置きます。どちらか一方でもあれば、どの系列のレビューも前回の記録を使わず毎回 full で回します。印は `logs/.*.review-state` の中身を確かめてから、両方とも手で消してください（ランチャが場所を表示します）。限界: Claude のレビューの子は同じ利用者の権限で Bash を使えるので、`logs/` の外の印も消せます。ランチャは前後の比較で気づいて不合格にしますが、完全な閉じ込めではありません（Codex のレビューは読み取り専用で外へ書けません）。
- `logs/` の差し替え: 起動時に `logs/` が symlink なら起動しません。子（エージェント・確認コマンド）が実行中に `logs/` を symlink や別のフォルダに差し替えたら、ランチャはそこへ `.done`・証跡を書かずに exit 5 で止めます（起動時に覚えたフォルダの識別子と比べます）。`logs/` の中のファイル 1 つずつを外向きの symlink・ハードリンク・特殊ファイルにされた場合も同じく止めます（起動時に残っていれば起動しません。中身を確かめてから消してください）。Codex レビューの本文と完了の証明は、子の起動前に開いたフォルダの中で一時ファイルに書いてから名前を置き換えます。Codex 実装の最終メッセージ（`-o`）は、子の書ける場所の外（`${XDG_STATE_HOME:-~/.local/state}/lanewright/out/`）に書かせ、子の後に `logs/` へ写します（強制終了したときはそこに小さなフォルダが残ることがあります。中身は最終メッセージだけで、消して構いません）。
- Codex のレビューには、テンプレ（`templates/claude-review-{full,delta}.md` の役名を置き換えたもの）と `templates/codex-review-focus.md`（重い順に全件列挙・同じ種類は全箇所）を `developer_instructions` として渡します。

## 7. ビルドの分担

- **build は、統合先へ入れる直前の最終 head で `chk-run.sh` と CI に 1 回だけ任せます。** レビューの途中の head や修正レーン（Gemini 本体を含む）では build を回さず、typecheck・lint・関係するテストだけにします。Gemini レーンでは必須の `--verify` が全体テストと build を担います。
  **なぜ**: 同じ確認を何度も回すと時間ばかりかかり、結果も変わらないため。

### `chk-run.sh <worktree> <port> <outdir> [--merge <ref>] [--force]`
- 回す確認コマンドは **1 本だけ**で、次の順に決めます。どちらも無ければ何も回さず、用意のしかたを出して exit 2 です。
  1. 対象リポの `.lanes/check.sh`（優先。シンボリックリンクなら使わない。worktree を作業場所にして `bash` で実行）
  2. 設定キー `LANES_CHECK_CMD`（例 `pnpm lint && pnpm typecheck && pnpm build`。`bash -c` で実行）
- `origin` があれば最初に `git fetch origin` します（失敗すると `fetch=FAIL` で exit 1）。`--merge <ref>` を付けると `<ref>` を取り込んでから確かめます（失敗すると `merge=FAIL` で exit 1）。取り込みで `.lanes/check.sh` が増減したら選び直します。
- 確認コマンドには環境変数 `LANES_CHECK_PORT`（`<port>`）と `LANES_CHECK_OUTDIR`（`<outdir>`）を渡します。標準出力・標準エラーは `<outdir>/check.log` に残ります。
- **Preview サーバー（画面確認用のサーバー）の起動とポートの確認は `chk-run.sh` ではしません。** 画面の確認が要るなら `.lanes/check.sh` の中で `LANES_CHECK_PORT` を使って立ててください。確認コマンドは共通の監督役（`_common.sh` の `LANES_PROCESS_GUARD`）の下で起動するので、裏で立てたサーバーなどの孫プロセスも、開始時刻を照合して終了時に回収します（回収を確かめられないと非 0）。
- 出力の行:
  | 行 | 意味 |
  |---|---|
  | `head=<短い SHA>` | 確かめた HEAD |
  | `check=<rc>（.lanes/check.sh）` / `check=<rc>（LANES_CHECK_CMD）` | 確認コマンドの終了コードと出どころ。非 0 なら次の行に `ログ: <outdir>/check.log` |
  | `skip=same-tree ...` と `check=0 SKIP(same-tree)` | 前に同じ入力で通っていたので何も回さなかった |
  | `recorded=tree <短い tree>（full）` | 通ったので記録した |
  | `record=no reason=<理由>（説明）` | 通ったが記録しなかった（次に同じ中身で呼んでも省かず、レビューの問い合わせは `no-record` になる）。理由は `uncommitted`（未 commit の変更・未追跡のファイル・変更検知を省く設定）か `unresolvable`（確認コマンドや依存を確実に照合できない）。説明に、原因になったファイルや書き方（例: `確認コマンド（.lanes/check.sh）の「exec」`）が出る。確認コマンドが失敗したときは出さない |
- 同じ git tree かつ同じ入力の指紋（`input_fp`。スクリプト自身・実行環境・確認コマンドの出どころ・確認コマンドの文字列（`.lanes/check.sh` なら中身）と、各コマンドの先頭の実行ファイル（PATH で解決した先とその `#!` の解釈系）の中身・ポート・使うバイナリ・`node_modules` などの追跡外の入力・追跡ファイルの中身から作る）で通っていれば何も回しません（`--force` で強制）。差分があれば部分的に省かず全部回します。
- 未保存の変更があるとき、変更検知を省く設定（`assume-unchanged` / `skip-worktree`）があるとき、作業ツリーの外を指すシンボリックリンク（共有依存など）か行き先の無いリンクがあるとき（作業ツリーの中を指すリンク（npm の `node_modules/.bin/*` など）はリンク先の中身を指紋に入れて続けます）、または確認コマンドの実体の同一性を確かめられないときは、結果を再利用も記録もしません。確認コマンドに**確実に解決できない書き方が 1 つでもあれば、回すが記録しません**（再利用しない）。対象は、変数・`~`・ワイルドカードで組み立てた名前、見つからない名前、`PATH` の付け替え（`PATH=/別:$PATH tool` の前置・`export PATH=…`）、`cd` などの作業場所の移動、引数のコマンドを起動する包み（`exec`・`env`・`command`・`xargs`・`nohup` など）、関数・alias の定義、`source` / `.`、`eval`、サブシェル `( )`、パイプ `|`、コマンド置換 `$( )` / `` ` ` ``、ヒアドキュメント `<<`、`bash -c` などです。指紋に入れるのは、先頭が素のコマンド名か相対・絶対パスで、前置の代入が `PATH` 以外の単純な形だけです。`.lanes/check.sh` の `#!` やコメントの行は行単位で読み飛ばし、後ろの行のコマンドも見ます。
- **ランチャの記録は入力に数えません。** レーンを起動・終了するたびに増えるので、数えると「`chk-run.sh` の直後にレビューを起動する」だけで記録が使えなくなります（`detach-run.sh` が起動ログを先に書くため）。
  **名前が記録に似ているだけでは外しません。** 外すのは、ランチャが書く前に台帳（`logs/.lanes-records`）へ載せた持ち主の、決まった名前のファイルだけです。対象は、作業ツリー直下の `logs/` の直下にある、git が無視している普通のファイル（シンボリックリンク・ハードリンクでないもの）のうち、次のものです。
  - 台帳に `label:<label>` がある label の `<label>.pid` / `.done` / `.lock` / `.log` / `.stderr.log` / `.json` / `.prompt.md` / `.dry-run.prompt.md` / `.evidence.md` / `.last.md` / `.completion.json` / `.try1.json` / `.try1.stderr.log` / `.verify.log` / `.meta.txt`（名前の組は `chk-run.sh` の `LANE_LABEL_SUFFIXES`）
  - 台帳に `file:<名前>` がある名前そのもの（`detach-run.sh` の起動ログ、`.<系列>.review-state`、`<系列>.followups.md`、`.review-reuse-blocked`、`qa-case.md`、`qa-deps-<名前>.log`）
  - 上の名前の回転した前回分（`<名前>.prev-<日時>.<拡張子>`）と、置き換え用の一時ファイル
  - 台帳そのもの
- 台帳（`logs/.lanes-records`）に載せるのは、各ランチャ（`_common.sh` の `lanes_records_claim`。起動時・dry-run・起動前の誤りの記録）、`prepare-screen-qa.sh`、`after-develop-merge.sh`、`detach-run.sh`（起動ログが worktree の `logs/` の直下にあるときだけ）です。行は足すだけで、同じ行は足しません。台帳が symlink・ハードリンクのときは、ランチャは書かず、`chk-run.sh` も使いません（何も外さない）。
- 台帳に無い名前のファイル（例 `logs/input.json`・`logs/input.txt`）、`logs/` の中のフォルダ、リンク、追跡しているファイル、下の階層の `logs/`（例 `src/logs/`）は入力です。確認コマンドが `logs/input.json` を読む構成で中身を変えれば、記録と合わなくなり回し直します。**確認コマンドが読む設定やデータを、起動した label の記録と同じ名前（`logs/<起動した label>.json` など）で置かないでください**（変えても気づけません）。
- 台帳の仕組みより前の版のランチャが書いた記録は台帳に無いので、入力として数えます（同じ label を起動し直すと台帳に載ります）。
- 限界: 台帳は `logs/` の中にあるので、worktree に書ける者（レーンの子・確認コマンド）が行を足せば、外す範囲を広げられます。入力の指紋は「うっかり古い成功を使い回す」のを防ぐ仕組みで、worktree に書ける者の意図的な細工までは防ぎません（確認コマンド自体を書き換えられるのと同じ前提です）。気になるときは `logs/.lanes-records` に起動した覚えの無い label・名前が無いかを見るか、`chk-run.sh --force` で回し直してください。
- 生成物（git が無視している、作業ツリー直下の `dist/` `build/` `out/` `.next/` `.turbo/` `coverage/` `test-results/` `playwright-report/` の中と、`*.tsbuildinfo`）は確認コマンド自身が作り直すので、検証の前後の照合からは外し、使い回すときは今の出力が記録のときと同じであることを求めます。定義は `_common.sh` の `LANES_GENERATED_DIRS` / `LANES_GENERATED_SUFFIXES` の 1 か所で、`cleanup-after-merge.sh` も同じものを使います。
- 検証の前後で HEAD・tree・作業ツリー・`input_fp` を照合し、変化が無く通ったときだけ記録します。記録先は `CHK_CACHE`（既定 `$LANES_RUNS_ROOT/_chk-cache/passed.tsv`）。1 行は `tree・head・full・日時・worktree・input_fp・port・outdir` のタブ区切りです（port と outdir は問い合わせが同じ条件で照合し直すために残します）。
- 終了コード: 0 = 通った・省略した / 1 = 確認コマンドの失敗・fetch / merge の失敗・検証中の入力の変化 / 2 = 使い方の誤り・確認コマンドが未設定。

### `chk-run.sh <worktree> --query`（回さずに、使い回せるかだけ答える）
- 確認コマンドを一切実行せず、記録・出力先・記録のフォルダを作らず、fetch もしません。`--merge` / `--force` とは組み合わせられません（exit 2）。
- 一致条件は `skip=same-tree` と同じです（tree・入力の指紋・確認コマンドの指紋）。同じ tree の記録ごとに、その記録の port と outdir で指紋を計算し直して照合します（port・outdir の無い旧形式の記録は使いません）。
- 使い回せる: 1 行目 `reuse=yes`、続けて `head=<記録の head 12 桁>` / `recorded=<記録の日時>` / `check=<.lanes/check.sh か LANES_CHECK_CMD>` を出して exit 0。
- 使えない: `reuse=no reason=<理由>` を出して exit 1。理由は `no-check`（確認コマンドが未設定）/ `no-record`（同じ tree の記録が無い。`chk-run.sh` をまだ通していないか、通ったが記録できなかった。後者は `chk-run.sh` が `record=no reason=…` の行に理由を出している）/ `cache-link`（記録がリンク）/ `uncommitted`（未 commit の変更・変更検知を省く設定）/ `unresolvable`（確認コマンドや依存を確実に解決できない）/ `input-changed`（確認コマンド・環境変数・依存・ランチャの記録でない無視対象のファイルなどが記録と違う）/ `state-error`。
- 使い方の誤り（worktree が無い・git の作業ツリーでない・余計な引数）は exit 2。
- 入力の指紋には環境変数が入るので、`chk-run.sh` を回したのと同じ環境から呼びます。レビューの入口・ランチャだけが持つ制御の値（`LANES_ENTRY_PREFLIGHT`・`LANES_REVIEW_REUSE_CHECKS`）は指紋に入れません。

## 8. 全レーンで MCP を使わない

レーンから本番の決済・DB などへ届く経路を断つため、すべてのランチャで MCP を遮断します。
- **Claude**（`run-claude.sh` / `run-claude-review.sh` / `run-qa.sh`）: `--strict-mcp-config` でユーザー設定の MCP を読み込まない。
- **Codex**（`run-codex-review.sh` / `run-codex.sh`）: `_common.sh` の `lanes_codex_no_mcp_args "$wt"` が実行場所の設定も含めてサーバーを列挙し、`-c features.apps=false` と全サーバーの `enabled=false` を `LANES_CODEX_NO_MCP_ARGS` 配列に入れ、`codex mcp list --json` で有効 0 件を確かめます。確かめられなければ起動しません。
- **Gemini**（`run-gemini.sh`）: macOS の `sandbox-exec` と `agy` の `--sandbox` / `--settings` を起動前に確かめ、`mcp(*)` の呼び出し拒否を強制します（設定の読み込みそのものを隔離するのではなく、呼び出しを拒否する仕組みです）。

## 9. マージ後の後片付け

統合先の枝は `LANES_BASE_BRANCH`（既定 `develop`）です。マージ済みかどうかは `origin/$LANES_BASE_BRANCH` を基準に判定します。

### PR とマージの進め方（CI 待ちのレーンは作らない）
- 必須チェックで保護された統合先なら `gh pr merge <PR> --auto --merge --delete-branch` で CI 緑のときに GitHub にマージさせ、Mac で待ちません。次の status のついでに `gh pr view <PR> --json state,mergedAt` を見て、マージ済みなら後片付けへ。
- **必須チェックが無いリポで `--auto` は使わない**でください。CI を待たずに即マージされます。その場合は `gh pr checks <PR> --watch --fail-fast` を 1 回待ち、緑なら `gh pr merge <PR> --merge --delete-branch`、赤なら止めます。
- `.github/` を触った PR だけ、初回の run を `gh run watch <run-id> --exit-status` で 1 回確認します。
- 本番へのリリースは人の判断で行い、auto-merge しません。

### `cleanup-after-merge.sh <worktree> [--apply]`
1. HEAD が `origin/$LANES_BASE_BRANCH` に含まれる（マージ済み）ことを確かめる。含まれなければ何もしない（`EXIT:5`）。**squash / rebase でマージした枝は祖先にならないので「未マージ」扱い**（安全側）。その場合は手で `git worktree remove` と `git branch -D`
2. 追跡ファイルの未 commit 変更（staged を含む）があれば `uncommitted.patch` を退避先に保存して停止（`EXIT:4`）
3. 残骸（`run-*.sh` / `prompts/` / `logs/` / `*.log` / レビュー出力など。ignore 済みも含む）を `$LANES_ARCHIVE_ROOT/<repo>/<日付>-<枝>/` へ退避（消さない・GitHub にも上げない）。
   ignore 済みの生成物（確認コマンドのビルドが残した、作業ツリー直下の `dist/` `build/` `out/` の中など）も、残骸と同じく退避してから続けます。生成物の定義は `chk-run.sh` と同じ（`_common.sh` の `LANES_GENERATED_DIRS` / `LANES_GENERATED_SUFFIXES`。7 章）。依存とキャッシュ（下の表の「削除してよいもの」）は退避せず worktree ごと消します
4. worktree を削除 → ローカル枝を削除 → リモート枝は先端も統合済みのときだけ削除。`main` / `master` / 統合先の枝は永久枝として、ローカルもリモートも絶対に消さない
5. そのレーンの scratch を削除（中の一時 PostgreSQL は実体を照合して `pg_ctl stop`）
6. `LANES_DOWNLOADS_SCAN=1` のときだけ、`~/Downloads` に直近 3 日で置き忘れたレビュー出力らしいもの（`*review*` / `*.diff` / `*.patch` / `*.prompt.md` / `*.log` など）を報告だけする（消さない。既定 `0` では見ない）

本体 checkout を渡した場合は退避と残骸削除だけ行い、worktree と枝は消しません（本体 checkout の生成物は退避も削除もせず、そのまま残します）。

止まる条件（安全側）:
| 終了コード | 条件 |
|---|---|
| 4 | 追跡ファイルの未 commit 変更、または退避対象（残骸と、ignore 済みの生成物 `dist/` `build/` `out/` など）・削除してよいもの（依存とキャッシュ: `node_modules/` `.next/` `.turbo/` `.cache/` `coverage/` `test-results/` `playwright-report/` `*.tsbuildinfo`）・`.env*` 以外の未追跡・除外ファイル（手書きのメモなど）がある。git が無視していない `dist/` などの未追跡ファイルと、パッケージ配下の `dist/`（例 `apps/web/dist/`。生成物の定義は作業ツリー直下だけ）もここで止まる |
| 5 | 未マージ |
| 6 | linked worktree の `.env*` が本体 checkout と一致しない（worktree を消すと一緒に消えるため。一致していれば worktree ごと消えてよい） |
| 7 | 実行中・同一性不明のレーンがある（生存情報は `$LANES_SCRATCH_ROOT/.cleanup-guards/` に保全）、一時 PostgreSQL を照合・停止できない、枝の先端が確認後に変わった |
| 8 | worktree が既に無く（`gh pr merge --delete-branch` が消した等）、残った scratch の現世代が止まっていると証明できないので消さずに保全した。ほかの後片付けは完了。手で消す手順（RUNNING / STALLED でないことの確認 → `postmaster.pid` があれば `pg_ctl -D <フォルダ> stop -m fast` → `rm -rf`）を出す |

- 一時 PostgreSQL はデータ領域・開始時刻・UID・実行主体・`cwd` がすべて一致したときだけ `pg_ctl stop` で止めます（直接 `kill` はしない）。
- 枝の削除は確認した先端 SHA と一致するときだけ（ローカルは `git update-ref -d`、リモートは `git push --force-with-lease` による削除）。
- `.cleanup-guards/` の控えは、記録したプロセスがすべて終わって 1 分以上たてば `--apply` の終わりに消します。
- `--apply` の直前に、呼び出し元の cwd（今いるフォルダ）が削除対象の worktree の中なら exit 2 で止めます（dry-run は警告だけ）。本体 checkout か `~` に移ってから呼んでください。
  **なぜ**: 今いるフォルダが消されると、以後そのシェルからのコマンド起動がすべて `ENOENT`（ファイルが無い）で失敗するため。そうなったら、別のターミナルで消えたパスを `mkdir -p` で作り直し、元のシェルで `cd ~` してから `rmdir` します。

### `after-develop-merge.sh`（統合後の入口）
```zsh
zsh lanes/after-develop-merge.sh <feature-worktree> --apply [--qa-prompt <path>] [--label <label>] [--repo owner/name]
```
既定は dry-run（計画の表示だけ）。`--apply` で次を順に行います。
1. `origin/$LANES_BASE_BRANCH` を取得した直後に、feature が最初に取り込まれた merge SHA と対応 PR を固定する
2. 同じリポの終わった QA worktree（`$LANES_SCRATCH_ROOT/<repo>/*-checkout` で、全 `.pid` に新しい `.done` があり、ランチャも子も生きていない）を `cleanup-after-merge.sh --apply` で片付ける（止まったものは警告して残す）
3. 固定した履歴で QA 専用の worktree（`$LANES_SCRATCH_ROOT/<repo>/<label>-checkout`）を作る。本体の未保存変更や先の履歴を混ぜないため
4. 依存を QA worktree の中で入れ直す（本体の `node_modules` は共有しない）。`package-lock.json` → `npm ci` / `pnpm-lock.yaml` → `pnpm install --frozen-lockfile` / `yarn.lock` → `yarn install --frozen-lockfile`。対象はルートと `apps/*`・`packages/*`。ログは `logs/qa-deps-*.log`。`--no-deps` で省略
5. 本体 checkout の未追跡の `.env*` を同じ相対パスへ複製し、`cmp` で同一を確かめる（中身は表示せず件数だけ）。ソースマップ送信用の鍵ファイルなど、ビルド時だけの鍵は複製しない
6. feature の worktree を後片付けする
7. `run-qa.sh` を起動する（監視は `lanes-status.sh <QA_WORKTREE> <label>`）

- 準備（3〜5）に失敗したら feature は消さずに `EXIT:1` で止め、QA worktree を残して撤去コマンド（`git -C <本体> worktree remove --force <QA_WORKTREE>`）を出します。
- `--qa-prompt` は最初に絶対パスへ直し、QA worktree の `logs/qa-case.md` に複製します。
- `--skip-qa` は後片付けだけ（`cleanup-after-merge.sh` の終了コードをそのまま返す）。
- `--repo` を省くと `origin` から推定します。推定できない（GitHub 以外の接続先など）、または `gh` が無い・未ログインのときは PR を照会せず「未特定」のまま、取り込み履歴だけで QA へ進みます（PR を照会したいときだけ `--repo owner/name`）。
- 課題管理ツール（チケットの状態など）とは連携しません。bot QA が `CLEAN` なら「人の QA 待ち」として報告し、状態の更新が要るなら手順書に沿って自分で足します。
- feature の worktree が既に消えているときは `--main-checkout <本体 checkout> --feature-head <40 桁の SHA>` を付けます。後片付けが 8（scratch だけ保全）でも、手順を出して QA へ進みます。
- QA 指示書の変更ファイル一覧は取り込み全体から作ります（merge commit なら第 1 親との差分、fast-forward なら PR の基点などから取り込み前の位置を求める。特定できなければ対象 commit 分だけにして注記）。
- **マージ後の bot QA では build を回しません**（7 章で担保済み）。typecheck・lint・unit と観点の確認だけです。`VERDICT: NEEDS_FIX` なら実装レーンで直し → レビュー → PR → 統合 → QA をやり直します。

## 10. 画面 QA の準備（`prepare-screen-qa.sh`）

bot QA のあと、司令塔がブラウザで Preview（公開前の確認用環境）を実際に触る場合の準備です。レーンの CLI にはやらせません。

```zsh
zsh lanes/prepare-screen-qa.sh <checkout> [label] [--url <preview-url>] [--viewpoints <観点ファイル>]
# → logs/<label>.prompt.md を画面操作を担う道具へ渡す
```

- URL と観点ファイルは **引数（`--url` / `--viewpoints`）＞ 設定キー `LANES_SCREEN_QA_MAP` の対応表** の順で決めます。
- 対応表は改行区切りで、1 行 = `origin に含まれる文字列|Preview URL|観点ファイルのパス`。最初に一致した行を使います（空行と `#` 始まりの行は飛ばす）。
  ```zsh
  LANES_SCREEN_QA_MAP="owner/my-app|https://preview.example.com|qa/screen.md"
  ```
- 観点ファイルの相対パスは `<checkout>` からの相対として読みます（`~/` も可）。観点ファイルは無くてもよく、無いときは「変更点に関わる画面と主要な導線を確認する」指示になります（指定したのに見つからなければ警告）。
- 表に無い `origin` は警告します。**URL が決まらない（表に無く `--url` も無い）ときは exit 2** で理由を出します。表示する URL・接続先からは認証情報とクエリを取り除きます。
- label は共通の命名規則で検証し、書き込み先が実ディレクトリの `logs/` 直下（シンボリックリンク不可）であることを確かめます。
- 判定は `SCREEN_VERDICT: CLEAN|NEEDS_FIX`。これが出なければ画面 QA を完了にしません。

## 11. Vercel の自動再デプロイ（任意・既定は無効）

`LANES_VERCEL_PROJECT`（プロジェクト名）を設定し、`lanes-monitor.sh --allow-redeploy` を付けたときだけ動きます。`LANES_VERCEL_PROJECT` が空なら何もせず「無効」と 1 行出します（`LM_NO_VERCEL=1` でも止まる）。`LANES_VERCEL_SCOPE`（チームのスコープ）は任意で、空なら `vercel` に `--scope` を付けません。
- Preview のデプロイが「Git information retrieval failed」で落ちたものを **1 回だけ** 再デプロイします。Production は対象外です。
- 記録 `$LANES_RUNS_ROOT/.vercel-autoredeploy.json`（`.lock` で排他）に「再デプロイ待ち」と再デプロイ先を保存し、同じものを何度も再デプロイしません。

## 12. Bot のシェルから呼ぶとき（`detach-run.sh`）

外の Bot のシェルの中には、ツールの実行が終わるとプロセスグループごと `TERM` / `KILL` するものがあります。`nohup` や `&!` だけでは同じグループに残った子が巻き込まれます。
`detach-run.sh <launch.log> <コマンド> [引数...]` は新しいセッション（`setsid` 相当）でコマンドを起動し、呼び出し元から切り離します。出力は `<launch.log>` へ追記し、引数や例外の本文はログに書きません。
起動ログを worktree の `logs/` の直下（`<worktree>/logs/<名前>`）に置くと、書く前にその名前をランチャの記録の台帳（`logs/.lanes-records`）へ載せるので、`chk-run.sh` の入力には数えません（7 章）。それ以外の場所（ほかのフォルダ・`logs/` の下のフォルダ・worktree の下の階層の `logs/`）に置いたときは、台帳を作りません。
`after-develop-merge.sh` は設定キー `LANES_DETACH_QA=1` のとき、QA をこれで起動します（既定 `0` は QA へそのまま exec）。Bot のシェルから呼ぶときは、設定ファイルか環境変数で `LANES_DETACH_QA=1` にします。

## 13. 終了コードのまとめ

| code | 意味 |
|---|---|
| 0 | 正常（cleanup は dry-run でも 0。`lanes-watch.sh` は WAKE 検知・時間上限・`WATCH OK`） |
| 1 | `chk-run.sh`: 確認コマンドの失敗・fetch / merge の失敗・検証中の入力の変化 / `lanes-watch.sh --check`: `WATCH STALE`・`WATCH DEAD` / `after-develop-merge.sh`: QA worktree の準備失敗 |
| 2 | 使い方・前提の誤り（引数不足、未ログイン・API キー起動、MCP 遮断の失敗、排他ロック取得不可、fetch 失敗、python3 なし、同じ label の二重起動、cwd が削除対象の中、`LANES_BASE_BRANCH` が枝名として不正、`chk-run.sh` の確認コマンドが未設定、`prepare-screen-qa.sh` の URL が決まらない） |
| 3 | レビュー・QA・`run-codex.sh`: `VERDICT: NONE`（完走せず・解釈不能）または子の回収未確認 / `run-gemini.sh`: `agy` の異常終了・idle 強制停止（救済 commit でも 3・push なし） |
| 4 | `run-gemini.sh`: 書き込み監査失敗・`--allow-path` 外の変更・`.git` ファイルの変更 / レビュー・QA: 実行中に作業ツリーや条件が変わった（または result イベント無し） / `run-codex.sh`: `VERDICT: NEEDS_FIX`・実行中に git の制御ファイル（`.git`・`commondir`・`gitdir`・`config`・`config.worktree`・hooks）が変わった（git を呼ばずに停止） / cleanup: 未 commit・未追跡ファイルで停止 |
| 5 | `run-gemini.sh`: 今回の `COMMIT_MSG.txt` 無し・commit 失敗 / レビュー・QA: Claude の `is_error` / cleanup・`after-develop-merge.sh`: 未マージ / 全ランチャ: 実行中に子が `logs/` を差し替えた（記録を書かずに止めるので `.done` は無く、`lanes-status.sh` は DEAD と出す） |
| 6 | `run-gemini.sh`: push 失敗 / cleanup: `.env*` が本体と不一致 |
| 7 | `run-gemini.sh`: `--verify` の失敗 / cleanup: 実行中レーン・一時 PostgreSQL の照合や停止の失敗・枝の先端の変化 |
| 8 | `run-gemini.sh`: 無出力で停止（差分は `wip.patch`） / cleanup: scratch だけ保全（`after-develop-merge.sh` は QA へ進む） |
| 10〜14 | `lanes-status.sh`: RUNNING 10 / STALLED 11 / DEAD 12 / FAILED 13 / NONE 14（DONE は 0） |
| 129 / 130 / 143 | ランチャ・ウォッチが HUP / INT / TERM で終了（`.done` の補足に理由） |
| その他 | CLI（claude / codex）の終了コードをそのまま返す（非 0 なら VERDICT は NONE） |

`run-impl.sh` / `run-review.sh` は振り分け先のランチャの終了コードに従います。`lanes-doctor.sh` は揃っていれば 0、足りなければ 2 です。

## 14. 設定のうち、このランチャが読むもの

設定ファイルは `LANES_CONF`（既定 `${XDG_CONFIG_HOME:-$HOME/.config}/lanewright/lanes.conf`）の 1 つだけで、`lanes.env` が最初に zsh のコードとして `source`（読み込み）します（書いた行はすべて実行されるため、他人が書き込める場所に置かない・`LANES_CONF` で他人のファイルを指さないでください）。勝つ順は **環境変数 > 設定ファイル > 既定** です。

| キー | 既定 | 使う場所 |
|---|---|---|
| `LANES_TOOLS` | `claude` | 役割の割り振り・起動前点検 |
| `LANES_COMMANDER` | `grok` | 司令塔が外の Bot（`grok`）か Claude（`claude`）か。運用の印（`lanes-doctor.sh` が監視の回し方を案内し、`claude` で `lanes-watch.sh` を `--until-wake` なしで起動すると注意を出す。ランチャや判定は変わらない） |
| `LANES_BASE_BRANCH` | `develop` | 統合先。レビューの比較起点・マージ済み判定・QA |
| `LANES_RUNS_ROOT` / `LANES_ARCHIVE_ROOT` / `LANES_SCRATCH_ROOT` | `$HOME/dev/_runs` / 同じ / `$LANES_RUNS_ROOT/_scratch` | worktree・退避先・scratch |
| `CLAUDE_BIN` `CODEX_BIN` `GEMINI_BIN` | `command -v claude` / `codex` / `agy` | 各 CLI のパス |
| `CLAUDE_MODEL` `CODEX_MODEL` `GEMINI_MODEL` | 空 | 空なら `--model` を付けず CLI の既定モデル |
| `CLAUDE_EFFORT` `CODEX_EFFORT` `GEMINI_EFFORT` | `xhigh` / `xhigh` / `high` | effort（考える深さ。空なら付けない。上限はモデルごとに違う） |
| `LANES_CHECK_CMD` | 空 | `chk-run.sh` の確認コマンド（`.lanes/check.sh` が優先。どちらも無ければ `chk-run.sh` は exit 2） |
| `LANES_SCREEN_QA_MAP` | 空 | 画面 QA の対応表（`--url` / `--viewpoints` が優先） |
| `LANES_VERCEL_PROJECT` `LANES_VERCEL_SCOPE` | 空 | 自動再デプロイ（`LANES_VERCEL_PROJECT` が空なら無効。`LANES_VERCEL_SCOPE` が空なら `--scope` を付けない） |
| `LANES_DOWNLOADS_SCAN` | `0` | 1 のときだけ cleanup が `~/Downloads` の置き忘れを警告（消さない） |
| `LANES_DETACH_QA` | `0` | 1 のとき `after-develop-merge.sh` が QA を `detach-run.sh` で切り離して起動（12 章） |
| `LANES_NOTIFY` | `1` | 終了時の macOS 通知 |
| `LANES_STALL_MINUTES` | `10` | STALLED とみなす無出力の分数 |
| `LANES_PROMPT_MAX_BYTES` | `200000` | プロンプトの上限（巨大な diff を埋め込む事故の検出） |
| `LANES_REVIEW_REUSE_CHECKS` | `1` | 1 ならレビューランチャが `chk-run.sh --query` で問い合わせ、親の確認済みの記録があれば必須検証を回させない（6 章「必須検証の使い回し」）。0 なら問い合わせない |

数値のキー（`LANES_STALL_MINUTES` `LANES_NOTIFY` `LANES_PROMPT_MAX_BYTES` `LANES_DOWNLOADS_SCAN` `LANES_DETACH_QA` `LANES_REVIEW_REUSE_CHECKS`）は `lanes.env` が整数か確かめ、数字以外なら計算に使わずに exit 2 で止まります（0 / 1 のキーと 1 以上のキーの別は `docs/config.md`）。ランチャ（`run-*.sh`）では、その label の排他を取れれば今回の失敗（`EXIT:2`・`note=起動前の誤り: 設定の誤り: ...`）を `.done` に残すので、前回成功した label でも `lanes-status.sh` は `FAILED` を返します。

Python の部品（`lanes_monitor.py`・`vercel_autoredeploy.py` など）は設定ファイルを直接読まず、環境変数を読みます。`lanes.env` が `LANES_*` を export し、
`lanes-monitor.sh`（`_common.sh` 経由）と `lanes-watch.sh` が `lanes.env` を読んでから Python を起動するので、設定ファイルの値も届きます。bash の `chk-run.sh` は最初の 1 回だけ zsh で `lanes.env` を読んでから自分を起動し直します。
CLI のパス・モデル・effort（`CLAUDE_*` / `CODEX_*` / `GEMINI_*`）は export しません（ランチャが引数で渡す）。effort を空にする書き方は `docs/config.md` を見てください（`CLAUDE_EFFORT=""` など）。アプリから起動したシェルが `CLAUDE_EFFORT` などを環境変数として持っていると、設定ファイルの値より環境変数が勝ちます。そのときランチャは起動時に「注意: CLAUDE_EFFORT は環境変数の値「…」で動く …」を標準エラーに 1 行出します（`lanes-doctor.sh` でも出ます）。設定ファイルの値に固定する書き方は `docs/config.md` の「環境変数に effort を上書きされないようにする」を見てください。

## 15. テストの回し方

```zsh
zsh selftest.sh                         # キットのルートで。既定は 4 構成すべて（--profile all と同じ）。構成に左右されないテストは 1 回だけ
zsh selftest.sh --every-profile         # 全部のテストを構成ごとに回す（時間がかかる）
zsh selftest.sh --profile claude-codex  # 1 構成だけ（full / claude-codex / claude-gemini / claude-only）
zsh selftest.sh --profile claude-only --test lanes/tests/test-roles.sh   # 1 構成で 1 本だけ（--test は複数指定可）
zsh lanes/tests/test-codex-verdict.sh   # 1 本だけ回す例
zsh tests/test-no-private.sh lanes      # 固有名・個人のパス・ID・鍵の形が残っていないか（0 件で緑）
LANES_PRIVATE_DENYLIST=/path/to/denylist.txt zsh selftest.sh --profile claude-only --test tests/test-no-private.sh   # 禁止語ファイル（キット外・1 行 1 パターン）もあわせて検査
LANES_TEST_SOCKET_ROOT=/Users/you/tmp/s zsh selftest.sh   # TMPDIR が深いとき: PostgreSQL のソケットの逃がし先（浅い既存フォルダ。キットの外）を渡す
LANES_LINT_STRICT=1 zsh selftest.sh --test tests/test-lint.sh   # shellcheck が未導入なら赤にする（公開前の確認など）
```
`selftest.sh` はスタブ（本物の代わりに決まった応答を返す偽物）の CLI を入れた一時 HOME で、指定した構成ごとに `lanes/tests/test-*.sh` と `tests/test-*.sh` を回し、最後に「構成 × テスト」の表を出します（`LANES_PRIVATE_DENYLIST` を渡せば `selftest.sh` の中の `test-no-private.sh` にも届きます）。
- 構成ごとに回すのは、先頭の 15 行に `# selftest: 構成ごと` の行があるテスト（呼び出し元の `LANES_TOOLS` で結果が変わるもの。今は `test-common-security.sh` と `test-gemini-launcher.sh`）だけです。
  それ以外（`LANES_TOOLS` を見ない、または `test-roles.sh` / `test-doctor.sh` のように中で変数を外して 4 構成を自分で試すもの）は最初の構成で 1 回だけ回し、2 つ目以降の構成の列には同じ結果を `＝緑` のように「＝」付きで流用します（合計の行の「流用」の数）。
  `--every-profile` を付けると、前と同じく全部のテストを構成ごとに回します。新しいテストが呼び出し元の `LANES_TOOLS` を読むなら、先頭のコメントに `# selftest: 構成ごと` の行を足してください。
- 表の `緑(一部)` は、その構成では一部を停止の確認だけにしたもの・道具が無くて一部の検査を省いたもの（テストの出力の `LANES_PARTIAL: <理由>` の行。理由は表の下に並べます。例: shellcheck が未導入のときの `tests/test-lint.sh`）。
- 一時領域（`TMPDIR`）が深い場所（レーンの scratch の中など）にあると、テストの一時 PostgreSQL のソケット（接続口のファイル）のパスが上限の 103 バイトを超えます。`selftest.sh` は既定で自分の一時領域の浅い場所を逃がし先にしますが、それでも超えるときは `LANES_TEST_SOCKET_ROOT=<浅い既存フォルダ>`（キットの外。`/tmp` などを勝手には使いません）を付けて回してください。付けずに超えた PG の試験は、黙って緑にせず対象外（77）か `緑(一部)` と理由を出します。
- `selftest.sh` はテストに `LANES_*` を持ち込みませんが、`LANES_PRIVATE_DENYLIST`・`LANES_TEST_SOCKET_ROOT`・`LANES_LINT_STRICT` の 3 つだけは渡します。
- 公開前は `LANES_PRIVATE_DENYLIST=<禁止語ファイル> zsh selftest.sh`（または `zsh tests/test-no-private.sh`）で禁止語も調べます。禁止語ファイルはキットの外に置き、中身をキットに書き写しません。
- テストの終了コード: 0 = 緑 / **77 = 対象外**（その構成では意味が無いテスト。例: Gemini の無い構成の `test-gemini-launcher.sh` は、`run-gemini.sh` が exit 2 で止まり `agy` を起動しないことだけ確かめて 77）/ それ以外 = 赤。
- `selftest.sh` の終了コード: 0 = 全部緑か対象外 / 1 = 赤がある（ログの場所を出して残す）/ 2 = 使い方の誤り。
- 所要時間の目安: 1 構成で約 10〜15 分、4 構成（既定）で約 15〜20 分（構成ごとのテスト 2 本の分だけ増える）、`--every-profile` の 4 構成で 40 分以上。
- 本物のリポを書き換えない保証: `selftest.sh` は git の場所を差し替える環境変数（`GIT_DIR` / `GIT_WORK_TREE` / `GIT_INDEX_FILE` / `GIT_COMMON_DIR` / `GIT_CONFIG*` など）を外してからテストを回し、
  実行前後でキットの HEAD・いまの枝・ref（リモート追跡の `refs/remotes/` と他の worktree で checkout 中の枝も含む。リモートの名前を使った push はリモート追跡の ref が動くのでここで見つかる）・stash・worktree の一覧・`git status --ignored`・ファイルの中身と索引の指紋（無視対象の `logs/` の中身は除く）・git の設定ファイル（共通の `.git/config` と `config.worktree`）・`info/` の下（`exclude`・`attributes` など）・`objects/info/alternates`・hooks（下のフォルダも）を比べ（値は出さず指紋だけ比べる）、変わっていたら赤にします。
  テストの PATH には偽の `gh` を置き、GitHub の認証関連の環境変数を外し、git の通信を `GIT_ALLOW_PROTOCOL=file`（ローカルのパスどうしだけ）にして渡します。同じリポで別の作業が枝や worktree を動かしたり fetch したりしている間は赤になるので、そのときは clone した場所で回してください。
  一時領域（`TMPDIR`）がキットの中にあると作業フォルダがキットの中にできてしまうので、`selftest.sh` は使い方の誤り（exit 2）として止まります。キットの外の一時フォルダを `TMPDIR` に渡してください。
  各テストも冒頭で `lanes/tests/_git-isolate.sh` を読み、同じ変数を外して `GIT_CEILING_DIRECTORIES`（git がリポを探して上へ上がらない境目）を一時領域に置き、
  一時リポを作った直後に `git rev-parse --show-toplevel` がその一時ディレクトリであることを確かめます（違えば即失敗）。
  経緯: 外から入った `GIT_DIR` / `GIT_WORK_TREE` で、テストの一時リポ作成がキットの `.git/config` に `core.worktree` を書き、作業枝にテスト用の空 commit を作った事故がありました。

| テスト | 見ているもの |
|---|---|
| `test-codex-verdict.sh` | VERDICT の判定（偽 CLEAN・未完了・コードフェンスなど） |
| `test-review-dedup.sh` | レビューの省略・delta・未解決指摘の引き継ぎ・後回し票（Codex・Claude のレビューとも）・親の確認結果の使い回し |
| `test-common-process.sh` / `test-common-security.sh` | 子プロセスの監督と回収、排他、秘密の扱い |
| `test-gemini-launcher.sh` | Gemini レーンのサンドボックス・監査・救済 commit |
| `test-chk-run.sh` / `test-chk-regressions.sh` | 最終確認の省略条件と入力照合・問い合わせ（`--query`）・通ったのに記録しないときの理由の表示（`record=no reason=…`） |
| `test-review-reuse-launch.sh` | `chk-run.sh` の直後に `detach-run.sh` 経由で本物の起動（dry-run でない）をしたレビューが、親の記録を使い回すこと（`node_modules`・`dist` のある worktree。Codex・Claude のレビューとも）。台帳（`logs/.lanes-records`）に載っている持ち主の記録は入力に数えず、台帳に無い名前（記録に似た名前の `logs/input.json` など）・`logs/` に置いたほかの入力・リンク・依存・生成物の変化では使い回さないこと。確認コマンドが `logs/input.json` を読む構成で中身を変えたら回し直すこと。台帳の書き方（リンクの台帳を辿らない） |
| `test-cleanup-safety.sh` / `test-cleanup-qa.sh` / `test-scratch-cleanup.sh` / `test-cleanup-pg-failures.sh` | 後片付けの停止条件・QA worktree・scratch・一時 PostgreSQL |
| `test-lanes-monitor.sh` / `test-lanes-watch.sh` | 巡回とウォッチ |
| `test-prepare-screen-qa.sh` | 画面 QA の準備 |
| `test-roles.sh` / `test-doctor.sh` | 4 構成の割り振り・入口の振り分け・構成に無い道具での停止・排他前の誤りの記録 / 起動前点検（未導入・未ログイン・API キーでのログイン・Gemini の端末サンドボックス） |
| `test-config-export.sh` | 設定ファイルの値が Python の部品と `chk-run.sh` まで届くこと・数値のキーの確かめ・Claude レビューのツール集合と固定の拒否の一覧 |
| `test-effort-override-note.sh` | 環境変数の effort が設定ファイル（無ければ既定）と違う値で勝っているときだけ、ランチャと `lanes-doctor.sh` が注意を出すこと。渡す値・子の環境は変えないこと |
| `tests/test-install.sh` / `tests/test-no-private.sh` | 導入・アンインストール / 固有名・個人のパス・ID・鍵の形の機械検査（`LANES_PRIVATE_DENYLIST` で禁止語ファイルも指定可） |
| `tests/test-selftest-guard.sh` | キットのリポを書き換える偽テスト（commit・`GIT_DIR` 付きの `git init`・未保存の変更・中身だけの上書き・索引・枝の切り替え・枝やタグ・stash・worktree・info/exclude・info/attributes・alternates・hooks（下のフォルダも）・リモート追跡の ref・リモートへの push・他の worktree の枝・`logs/`）で `selftest.sh` が赤になること、`TMPDIR` がキットの中なら exit 2 になること、テストに見える `gh` が偽物であること |
| `tests/test-lint.sh` | 全シェルの構文・bash の shellcheck・Python の pyflakes。shellcheck が未導入なら省略して緑、`LANES_LINT_STRICT=1` で赤 |

テストはすべて `$LANES_SCRATCH` / `$TMPDIR` の中の使い捨て領域で完結します。PostgreSQL の試験は、入っているのに初期化・起動に失敗したら原因ログを残して FAIL にします（失敗を模擬する `test-cleanup-pg-failures.sh` だけ `LANES_TEST_PG_FAILURE_EXPECTED=1` で許可）。ソケット（PostgreSQL への接続口のファイル）も一時領域の中にだけ置き、`/tmp` などの外へは逃がしません。パスが 103 バイトを超えるときは、`LANES_TEST_SOCKET_ROOT`（許可された一時領域の中の浅いフォルダ）の下の専用フォルダに置きます（`selftest.sh` は、指定があればそれを、無ければ自分の一時領域の浅い場所を渡します）。それでも収まらなければ PG は起動せず、後片付け試験を最後まで走らせてから対象外（exit 77）と理由を出します（黙って緑にしません）。

## 16. 実装で踏んだ落とし穴（再発防止のメモ）
- `claude -p` の `--allowedTools` / `--tools` / `--disallowedTools` は値を何個でも取るので、直後に置いたプロンプトが食われる → `=` 形式にし、`-p` を最後に置き、プロンプトは stdin で渡す
- `codex exec` に位置引数でプロンプトを渡すと `-` / `---` 始まりの文書がオプション扱いされる → `-`（stdin）で渡す
- `git worktree remove --force` は ignore 済みの `.env*` も消す → 本体と `cmp` で一致しなければ止める
- `git diff` は staged を含まない → 退避 patch は `git diff --binary HEAD`
- `git ls-files` / `status --porcelain` は非 ASCII のパスをエスケープして出す → `-c core.quotePath=false`
- `git rev-parse --git-common-dir` は本体 checkout だと相対パス → `--path-format=absolute`
- `git ls-remote --heads origin <name>` は末尾一致 → `refs/heads/<name>` で完全一致
- `chk-run.sh` の入力の指紋にランチャの記録（`logs/` の直下）を入れると、`detach-run.sh` が起動ログ（`logs/launch.log`）をランチャより先に書くだけで記録と合わなくなり、本物の起動でだけ「使い回さない」になる（dry-run や手での問い合わせでは再現しない）→ ランチャの記録を指紋から外す。起動の経路を変えたら `test-review-reuse-launch.sh` のように本物の起動で確かめる
- ランチャの記録を**名前だけ**で指紋から外すと、ランチャが作っていない `logs/input.json` のような「記録に似た名前の入力」まで外れ、確認コマンドがそれを読む構成では、中身を失敗する内容に変えても古い成功の記録を使い回す → ランチャが書く前に台帳（`logs/.lanes-records`）へ持ち主を載せ、台帳に載っている持ち主の決まった名前だけを外す。ランチャが `logs/` に書く名前を足したら、`chk-run.sh` の `LANE_LABEL_SUFFIXES` に足すか、書く前に `lanes_records_claim` で載せる
- `chk-run.sh` が「通ったのに記録しない」ときに何も出さないと、レビューの問い合わせが `no-record` になる理由が分からない（`.lanes/check.sh` に `exec zsh -f …` と書いただけで起きる。`exec` は引数のコマンドを起動する包みなので、仕様どおり記録しない）→ `record=no reason=…（理由）` を出す。確認コマンドの最後の行は `exec` を付けずに書く
- zsh: スクリプトの実行中に、閉じた stderr（`2>&-` で起動されたとき）へ `print -u2` すると、`|| true` を付けていてもそのシェルごと終了コード 1 で止まる（`zsh -c` では止まらない）→ 失敗の経路ではない案内（effort の上書きの注意など）は子シェル `( print -u2 … ) || true` の中で出す
- zsh: 関数内の `trap ... EXIT` は関数の終わりで発火する / 関数形式の `TRAPEXIT` は `$(...)` の子シェルの終了でも走る（`ZSH_SUBSHELL` で弾く）/ 関数内で `set -e` が発火すると `TRAPEXIT` は走らない（`TRAPZERR` も定義する）。ランチャは `TRAPZERR` と `TRAPEXIT` の 2 段で `.done` を書く
