English: [README.en.md](README.en.md)

# lanewright — Mac で AI のコーディング CLI を「レーン」で並列に回すキット

Mac に入れた Claude Code・Codex・Gemini（Antigravity CLI `agy`）の CLI（コマンドラインの道具）を、
**レーン**（1 作業 = 1 worktree = 1 ランチャ）として何本も同時に走らせ、実装 → レビュー → PR（プルリクエスト＝取り込みの申請）まで
安全に回すための道具一式です。

- worktree（ワークツリー＝同じリポジトリを別フォルダにもう 1 つ取り出したもの。枝ごとに独立して作業できる）
- ランチャ（起動役のスクリプト。前提の点検・ログ・生死の記録を全部引き受ける）

## 安全と注意書き（使う前に必ず読んでください）

- **AI に書き込み権限を持たせて自動で動かす道具です**: 実装レーンの AI は、対象の worktree へのファイルの書き込みとコマンドの実行ができる状態で、人の確認なしに動きます。
- **レビュー側の制限は完全なサンドボックス（外へ影響を出せないように閉じ込める仕組み）ではありません**: 読み取り専用の決まりや禁止コマンドの一覧に加えて、
  実行後に作業ツリーが変わっていないかを確かめる「事後検知」に頼る部分があります（push だけは git の通信を止めて防ぎます）。
- **自分のグローバルの指示ファイルもレーンに効きます**: MCP は遮断しますが、`~/.claude/CLAUDE.md`・`~/.codex/AGENTS.md`・`~/.gemini/` の指示などはレーンの AI も読み込みます（下の「自分のグローバル設定もレーンに効く」）。
- **本番に届く環境では使わないでください**: 本番の API キー・認証情報、本番 DB（データベース）、本番デプロイに届く Mac・アカウント・環境変数のある場所では動かさないでください。
- **検証の手順はサンドボックスの外で、AI が書いたコードを動かします**: `run-gemini.sh --verify`・`chk-run.sh`（`LANES_CHECK_CMD` / `.lanes/check.sh`）・マージ後の依存の導入（`npm ci` など）は、AI が書いた・変えたコード（`package.json` の scripts、テスト、`.lanes/check.sh` 自体など）をランチャの権限のまま実行します。サンドボックスが守るのは AI が動いている間だけです。また `.lanes/check.sh` は worktree の中にあり、設定の `LANES_CHECK_CMD` より優先されるので、レーンの差分に `.lanes/check.sh` の変更が入っていたら、レビューで必ず中身を確かめてください（`exit 0` だけにされると最終確認が素通りします）。
- **自己責任・無保証です（MIT ライセンス）**: 現状のまま（AS IS）提供し、どんな保証もしません。AI やスクリプトが行った操作の責任は使う人にあります（[LICENSE](LICENSE)）。
- **各 AI サービスの利用規約・ポリシーに従って使ってください**: Anthropic の Claude、OpenAI の ChatGPT・Codex、Google の Gemini・Antigravity それぞれの規約と利用ポリシーを守るのは使う人の役目です。
- **公式ではありません**: このキットは個人の OSS（公開ソースのソフトウェア）で、Anthropic・OpenAI・Google・GitHub の公式ではなく、提携・推奨・支援も受けていません。製品名・ロゴ・商標は各社のものです。
- **macOS・zsh 専用で、サポートは約束しません**: 各 CLI のオプションや出力の形が変わると、いつでも壊れることがあります。現状のまま提供し、サポートや保守は約束しません。
- 脆弱性（セキュリティ上の弱点）を見つけたときの連絡方法は [SECURITY.md](SECURITY.md) にあります（公開の Issue には書かないでください）。

## 何が嬉しいか

- **並列で速い**: 触るファイルが重ならない小さな作業に分けて、全部同時に走らせる。
- **止まったら分かる**: 各レーンは `logs/<label>.pid`（起動の記録）と `logs/<label>.done`（終了の記録）を必ず残す。
  `lanes-status.sh` が `RUNNING` / `STALLED`（止まっている疑い）/ `DONE` / `FAILED` / `DEAD`（落ちた）を 1 行で返す。
- **レビューを飛ばせない**: 実装とは別のレーンが読み取り専用でレビューし、最終行の `VERDICT: CLEAN`（指摘なし）/ `VERDICT: NEEDS_FIX`（直しが要る）で判定する。
  途中で切れた出力や曖昧な文は「CLEAN」と見なさない。
- **同じ確認を繰り返さない**: 2 回目からのレビューは前回からの差分だけを見る（Codex・Claude どちらのレビューも `--mode auto`）。親が同じ中身で確認コマンド（`chk-run.sh`）を通していれば、レビューは型検査・lint・単体テストを回し直さずにその記録を使う（`LANES_REVIEW_REUSE_CHECKS`）。
- **事故を起こしにくい**: API キーではなくサブスク（月額契約）のログインでだけ起動する。全レーンで MCP（外部サービスへ AI が直接つながる仕組み）を読み込まない。
  同じ label の二重起動は拒否する。マージ後の後片付けは未保存の変更があれば止まる。
- **道具の組み合わせを選べる**: Claude だけでも動く。Codex や Gemini を足すと役割が自動で割り振られる（[docs/roles.md](docs/roles.md)）。

## 全体の流れ

```
 司令塔（Grok Bot などの外の Bot、または Claude デスクトップの Code タブ）
   │  ゴールを「触るファイルが重ならない小レーン」に分ける
   ▼
 git worktree add ... → 指示書（prompt.md）を書く
   │
   ├─▶ run-impl.sh  ── 実装レーン（Claude / Gemini）── commit
   │        │ 60 秒以内に lanes-status.sh で生死を確認
   │        ▼ DONE
   ├─▶ run-review.sh ── レビューレーン（Codex、無ければ別セッションの Claude・読み取り専用）
   │        │ VERDICT: NEEDS_FIX → 実装レーンで直す → もう一度レビュー
   │        ▼ VERDICT: CLEAN
   ├─▶ 最終の確認（chk-run.sh）→ PR 作成（証跡 evidence.md を本文に貼る）
   │        ▼
   │    GitHub の auto-merge（CI＝自動テストが緑になったら GitHub が取り込む）
   │        ▼
   └─▶ cleanup-after-merge.sh で worktree と枝を片付ける
 並行して: lanes-watch.sh が 5 分ごとに全レーンを見回り、変化があれば WAKE: で司令塔を起こす
```

## 前提

- macOS（`sandbox-exec`・`osascript` などを使う）
- zsh（macOS の標準シェル）、git、python3
- gh（GitHub の公式 CLI。PR 作成と auto-merge に使う。任意）
- shellcheck・pyflakes（自己テストの静的検査。任意。無ければその項目だけ省く）
- Node.js（npm 付き）: 自己テスト（`selftest.sh`）の `lanes/tests/test-chk-run.sh` が、確認コマンドの例として npm で回すため。無いとそのテストは理由を出して赤になる（キット本体の動作には不要）
- 使う AI の CLI（少なくとも Claude Code）。入れ方は各公式の案内に従ってください:
  - Claude Code（Anthropic の公式ドキュメント）
  - Codex CLI（OpenAI の公式ドキュメント）
  - Antigravity CLI `agy`（Google の公式ドキュメント）
  - GitHub CLI `gh`（GitHub の公式ドキュメント）

### サブスクでログインしているか確かめる

ランチャは**サブスクのログインでだけ**起動します。API キーが環境変数に入っていても、起動前に外します。接続先の上書き（`ANTHROPIC_BASE_URL`・`OPENAI_BASE_URL`）も外すので、司令塔のシェルをローカルのモデルや中継に向けていても、レーンはサブスクの正規の窓口へつなぎます（レーン自体をローカルのモデルで動かす使い方はできません。Codex の `~/.codex/config.toml` の `model_provider` は環境変数ではないので外せません。レーンで使うなら既定のままにしてください）。
理由: API キーは使った分だけ請求され、並列で何本も回すと思わぬ金額になりやすいこと、鍵が漏れたときの被害が大きいこと、
そしてログイン方法が混ざると「どのアカウントで動いたか」が分からなくなるからです。

| 道具 | 確かめ方 | 通る条件 |
|---|---|---|
| Claude | `claude auth status` | `loggedIn` が true で、ログイン方法が claude.ai（サブスク） |
| Codex | `codex login status` | `Logged in using ChatGPT`（ChatGPT のサブスク） |
| Gemini（`agy`） | 対話モードで `agy` を起動してアカウントでログイン | ログイン情報のフォルダ（`~/.gemini/antigravity-cli`）がある |

> 注意: これらのコマンドの出力をチャットや Issue に貼らないでください。環境によっては秘密の値が載ることがあります。

### 許可の扱い（AI に何を確認なしでさせるか）

ランチャは CLI を非対話で動かすので、途中で「この操作を許可しますか？」と聞けません（確認が要る操作は拒否されて止まります）。
そのため、何を確認なしで許すかを**ランチャが毎回明示して渡します**。利用者の `~/.claude/settings.json` や `~/.codex/config.toml` の設定に任せません。

| レーン | 渡すもの | 既定 | 変える設定キー |
|---|---|---|---|
| Claude の実装 | 許可モード（`--permission-mode`）と確認なしで使うツール（`--allowedTools`） | `acceptEdits`（作業ツリー内の編集を確認なしで通す）と `Bash,Edit,Write,Read,Glob,Grep,TodoWrite` | `CLAUDE_IMPL_PERMISSION_MODE` / `CLAUDE_IMPL_ALLOWED_TOOLS` |
| Codex の実装（明示したときだけ） | sandbox（閉じ込めの範囲。`--sandbox`） | `workspace-write`（作業ツリーと一時領域に書ける。commit のため git の管理フォルダのうち commit に要る場所（gitdir・objects・refs・logs）も書ける。共通の config・hooks は書けない。gitdir の中の制御ファイル（`commondir`・`config.worktree` など）は書けてしまうので、実行の前後で指紋を比べ、変わっていたら git を呼ばずに EXIT:4 で止める。通信は止まる） | `CODEX_IMPL_SANDBOX` |
| Codex のレビュー | sandbox（`-c sandbox_mode=...`） | `read-only`（読み取り専用） | `CODEX_REVIEW_SANDBOX`（`read-only` か `workspace-write` だけ） |
| Claude のレビュー・QA | 使えるツールの集合・拒否の一覧・許可モード `manual` | 編集系を外し、履歴の書き換え・PR のマージ・デプロイなどを拒否 | `CLAUDE_REVIEW_TOOLS` / `CLAUDE_REVIEW_DENY` |

- Claude の実装は既定で **Bash（任意のコマンド）を確認なしで実行できます**。作業ツリーの外にも書けるので、本番の鍵や DB に届く環境では動かさないでください（上の注意書き）。
- レビューと QA の子プロセスは git の通信（push・fetch）を止めて起動します（`GIT_ALLOW_PROTOCOL`。詳しくは [lanes/README.md](lanes/README.md)「レビューは読み取り専用」）。
- 設定キーを空にすると、その指定を付けません（利用者の CLI の設定に任せる）。依存の取得など通信が要る作業を Codex の実装に任せるなら `CODEX_IMPL_SANDBOX=danger-full-access`（閉じ込めなし）を自分の判断で選びます。

### 自分のグローバル設定もレーンに効く

ランチャは MCP を遮断し、許可も明示して渡しますが、**各 CLI が普段読む指示ファイルはそのまま読み込まれます**。
本物の CLI で試運転すると、グローバルの指示ファイルに書いた commit の作者や口調の指示が、レーンの AI にも効いていました。
読み込まれるものの例（各 CLI の仕様に従うので、詳しくは各公式の案内を見てください）:

| 道具 | レーンにも効くもの（例） |
|---|---|
| Claude | `~/.claude/CLAUDE.md`、対象リポジトリの `CLAUDE.md`、`~/.claude/settings.json` のフック（決まった時に自動で動く処理）など |
| Codex | `~/.codex/AGENTS.md`、対象リポジトリの `AGENTS.md` |
| Gemini（`agy`） | `~/.gemini/` の下の指示ファイル（`GEMINI.md` など）、対象リポジトリの指示ファイル |

- commit の作者・末尾の署名・メッセージの言語、口調、「実装の前に計画を出して承認を待つ」のような進め方の指示も、レーンでそのまま守られます。
- 困るのは**人の返事を待つ指示**です。レーンは非対話なので、承認待ちで止まって `STALLED` になったり、何もせずに終わったりします。
  グローバルの指示に「レーン（非対話）では承認を待たずに進める」と書くか、指示書の先頭にそう書いてください（ひな形は `templates/`）。
- commit の作者を決めたいときは、指示ファイルより対象リポジトリの `git config user.name` / `user.email` で決めるほうが確実です。
- 鍵や個人の情報を指示ファイルに書いている場合、それもレーンの AI に渡ります。

## 導入

1. キットを好きな場所に展開する（例: `/Users/you/tools/lanewright`。以下 `<kit>` と書きます）。**展開した場所は動かさずにそのまま使います。**
   git なら `git clone https://github.com/owner/lanewright.git /Users/you/tools/lanewright`（`owner` は公開している人のアカウント）、zip なら `lanewright.zip` をそこへ展開します。
2. 導入スクリプトを回す。まず予定だけ見てから本番:
   ```sh
   cd <kit>
   ./install.sh --dry-run
   ./install.sh
   ```
   やること: `skills/` の中身を、入っている道具のスキル置き場（`~/.claude/skills` など）へ symlink（シンボリックリンク＝別の場所を指す目印）で置く。
   設定のひな形 `lanes.conf.example` を `~/.config/lanewright/lanes.conf` へ（無いときだけ）コピーする。同名の自前のファイルがある場合や、スキル置き場自体が壊れた symlink などでフォルダでない場合は、触らず警告して続けます。
3. 設定を編集する: `~/.config/lanewright/lanes.conf`。最低限は次の 3 つ。全部の意味は [docs/config.md](docs/config.md)。
   > 注意: 設定ファイルは zsh のコードとして読み込まれる（`source` される）ため、書いた行はすべて実行されます。他人が書き込める場所に置かないでください。また、環境変数 `LANES_CONF` で他人のファイルや信頼できない場所を指さないでください。
   ```sh
   LANES_TOOLS="${LANES_TOOLS:-claude codex}"     # 使う道具
   LANES_COMMANDER="${LANES_COMMANDER:-claude}"   # 司令塔（運用の印。lanes-doctor.sh が監視の回し方を案内する）
   LANES_BASE_BRANCH="${LANES_BASE_BRANCH:-develop}"  # 作業枝の取り込み先
   ```
   取り込み前の最終確認（`chk-run.sh`）を使うなら、確認コマンドも書きます（対象リポジトリに `.lanes/check.sh` を置けばそちらが優先）:
   ```sh
   LANES_CHECK_CMD="${LANES_CHECK_CMD:-pnpm lint && pnpm typecheck && pnpm test && pnpm build}"
   ```
4. 起動前点検: `zsh <kit>/lanes/lanes-doctor.sh`。足りない道具・ログイン・設定値の誤りを全部並べて exit 2 で教えてくれます（揃っていれば 0）。
   対象リポジトリのパスを付ける（`lanes-doctor.sh /Users/you/dev/my-app`）と、`logs/` が git に無視されているかも見ます（下の「最初の 1 本」の準備）。
   役割の割り振りは `zsh <kit>/lanes/lanes-roles.sh --print` で確かめられます。
5. 自己テスト: `zsh <kit>/selftest.sh`（偽の CLI を入れた一時 HOME で、既定では 4 構成すべてについてテストを回し、表で結果を出します。本物の AI は呼びません）。
   構成によって結果が変わるテスト（先頭に `# selftest: 構成ごと` の行があるもの。今は `test-common-security.sh` と `test-gemini-launcher.sh`）だけを構成ごとに回し、
   ほかのテストは最初の構成で 1 回だけ回して、ほかの構成の列には同じ結果を `＝緑` のように「＝」付きで流用します。全部のテストを構成ごとに回したいときは `--every-profile` を付けます。
   **所要時間の目安は 1 構成で約 10〜15 分、4 構成（既定）で約 15〜20 分**（`--every-profile` なら 40 分以上）です。急ぐときは `--profile claude-codex` のように 1 構成だけ回し、
   さらに 1 本だけなら `--test lanes/tests/test-roles.sh` のようにキットからの相対パスで指定します（複数指定可）。
   表の「対象外」（テストの終了コード 77）は、その構成では使わない道具のテストで、代わりに「その構成ではきちんと止まること」を確かめています。
   表の `緑(一部)` は、その構成では一部を停止の確認だけにしたものです（理由は表の下に出ます）。
   赤が 1 つでもあれば exit 1 で、ログの場所を出します。テストの前後でキットのリポ（HEAD・枝・ref（リモート追跡・他の worktree の枝も）・stash・worktree・ファイルの中身・索引・設定・info/ と alternates・hooks）が変わったときも赤になります
   （テストが一時リポの外の git を書き換えた疑い）。そのため、自己テストを回している間はキットのファイルを編集しないでください。
   同じリポで別の作業が枝や worktree を動かしたり fetch したりしている間も赤になるので、そのときは clone した場所で回してください。
   一時領域（`TMPDIR`）がキットの中にあると使い方の誤り（exit 2）で止まるので、キットの外の一時フォルダを `TMPDIR` にしてください。
   公開前のチェックなどで自分固有の名前・ドメイン・組織名の混入も検査したいときは、キットの外に禁止語ファイル（1 行 1 パターン）を作って `LANES_PRIVATE_DENYLIST=/path/to/denylist.txt` を渡せます（`selftest.sh` でも `zsh <kit>/tests/test-no-private.sh` 単体でも効きます）。公開前はこれで禁止語も調べてください。
6. （任意）PATH（コマンドを探す場所の一覧）に足す: `~/.zshrc` に `export PATH="<kit>/lanes:$PATH"`。足すと `lanes-status.sh ...` のように名前だけで呼べます。

## 最初の 1 本

例として、自分のリポジトリ `my-app`（取り込み先は `develop`）に小さな機能を足します。

### その前に: 対象リポジトリの準備（1 回だけ）

1. **`logs/` を `.gitignore` に足す**。ランチャは worktree の中の `logs/` に記録を書きます。無視していないと `git status` に未追跡のファイルとして出続け、
   AI が `git add -A` などで記録（指示書の全文・ログ）を誤って commit することがあります。
   ```sh
   cd /Users/you/dev/my-app
   grep -qxF 'logs/' .gitignore 2>/dev/null || echo 'logs/' >> .gitignore
   git add .gitignore && git commit -m "chore: レーンの記録 logs/ を無視する"
   # 取り込み先（develop）へ入れる。保護された枝なら PR 経由で。レーンの worktree は origin/develop から作るので、入る前に作った worktree には効かない
   ```
   リポジトリに入れたくなければ、`.git/info/exclude`（その Mac だけで効く無視の一覧。worktree にも共通）に `logs/` を書いても効きます。
   `zsh <kit>/lanes/lanes-doctor.sh /Users/you/dev/my-app` のように作業ツリーを渡すと、`logs/` が無視されているかも点検します（無視されていなければ「注意」）。
2. **確認コマンドを用意する**: `LANES_CHECK_CMD`（導入の手順 3）か、対象リポジトリの `.lanes/check.sh` に、型チェック・lint・単体テストを回すコマンドを書いておきます。
   レビューは「検証コマンドを実際に回したか」を見るので、確認コマンドが決まっていると実装・レビュー・最終確認で同じ検証がそろいます。
   型チェック・lint・単体テストの仕組みがまだ無いリポジトリでは、指示書に「この仕組みは無い（未導入）」と書いておくと、レビューが「未実施」と取り違えにくくなります。

```sh
L=<kit>/lanes   # ランチャの場所（PATH に足したなら、以下の "$L/" は省いてよい）

# 1. レーン用の worktree を作る（置き場所は LANES_RUNS_ROOT の下。監視が自動で見つけます）
cd /Users/you/dev/my-app
git fetch origin
git worktree add -b lane/hello ~/dev/_runs/my-app/hello origin/develop

# 2. 指示書を書く（目的・触ってよいファイル・完了条件・検証コマンド）。置き場所は worktree の外（例: LANES_RUNS_ROOT/my-app/prompts/）
mkdir -p ~/dev/_runs/my-app/prompts
$EDITOR ~/dev/_runs/my-app/prompts/hello.md

# 3. 実装レーンをバックグラウンドで起動（detach-run.sh で切り離してすぐ戻る。Claude Code ならツールのバックグラウンド実行でもよい）
zsh "$L/detach-run.sh" ~/dev/_runs/my-app/hello/logs/launch.log \
  zsh "$L/run-impl.sh" ~/dev/_runs/my-app/hello ~/dev/_runs/my-app/prompts/hello.md hello-impl

# 4. 起動から 60 秒以内に生死を見る（RUNNING か DONE でなければ起動失敗）
zsh "$L/lanes-status.sh" ~/dev/_runs/my-app/hello hello-impl --tail 20

# 5. DONE になったら、先に取り込み前の確認を 1 回通す（確認コマンドは導入の手順 3 の LANES_CHECK_CMD か、対象リポジトリの .lanes/check.sh。
#    引数は <worktree> <port（画面確認のサーバー用の番号）> <出力先>。出力先は実装レーンの一時領域（LANES_SCRATCH_ROOT/<repo>/<label>。後片付けで消える）に置く。
#    chk-run.sh は bash で呼ぶ）。通った記録が残るので、次のレビューは同じ中身なら型検査・lint・単体テストを回し直さずにこの記録を使う
#    （LANES_REVIEW_REUSE_CHECKS。確認とレビューは同じシェルから呼び、その間に作業ツリーを変えない）
bash "$L/chk-run.sh" ~/dev/_runs/my-app/hello 3100 ~/dev/_runs/_scratch/my-app/hello-impl/chk   # 0 以外なら直して 5 から

# 6. レビュー。レビュー用の指示書も同じ場所に作る（観点・検証の進め方の共通部分はキットのテンプレートが前に付く。
#    ここには何の変更か・特に見てほしい所だけを書く）。label は hello-r1 → hello-r2 … と末尾の数字だけ増やす（同じ系列で数える）。
#    NEEDS_FIX なら直して 5 から。周回が LANES_REVIEW_MAX_ROUNDS（既定 5）を超えても CLEAN にならなければ GATE: ESCALATE で止まるので、
#    続けるか・締めるかを人が決める（締めるなら残りを .lanes/accepted-limitations.md か後回し票へ）
cat > ~/dev/_runs/my-app/prompts/hello-review.md <<'EOF'
# レビュー: あいさつ機能（lane/hello）
- 目的: トップページにあいさつ文を出す。触ってよいのは src/hello/ と tests/hello/ だけ
- 特に見てほしい所: 空の名前・長い名前のときの表示、既存のテストを壊していないか
- 差分は自分で git diff origin/develop...HEAD を読む
EOF
zsh "$L/run-review.sh" ~/dev/_runs/my-app/hello ~/dev/_runs/my-app/prompts/hello-review.md hello-r1
zsh "$L/lanes-status.sh" ~/dev/_runs/my-app/hello hello-r1

# 7. VERDICT: CLEAN なら PR。本文に logs/hello-r1.evidence.md を貼る
cd ~/dev/_runs/my-app/hello
git push -u origin lane/hello
gh pr create --base develop --title "feat: あいさつ機能" --body-file logs/hello-r1.evidence.md
gh pr merge --auto --merge --delete-branch

# 8. マージされたら、削除対象の作業フォルダの外（本体リポジトリ）へ移動してから後片付け（まず dry-run で予定を見る）
cd /Users/you/dev/my-app
zsh "$L/cleanup-after-merge.sh" ~/dev/_runs/my-app/hello
zsh "$L/cleanup-after-merge.sh" ~/dev/_runs/my-app/hello --apply
```

指示書の書き方のこつ: 「触ってよいファイル」と「完了条件（どのコマンドが緑になれば終わりか）」を必ず書く。
差分（diff）を指示書に貼り込まず「`git diff origin/develop...HEAD` を自分で読んで」と書く（大きすぎると止まります）。

## 日々の流れ

1. 司令塔がゴールを小レーンに分け、依存の無いものを全部同時に起動する（[docs/commander-grok.md](docs/commander-grok.md) / [docs/commander-claude.md](docs/commander-claude.md)）。
2. `lanes-watch.sh` が 5 分ごとに見回り、変化（DONE・FAILED・STALLED・PR の状態）があると `WAKE:` で知らせる。
   司令塔が Claude のときは、`WAKE:` で見張りが終わる（最後の行が `RE-ARM:`）ので、次工程の前にかけ直します。Claude Code の Stop フック `lanes/hooks/claude-stop-watch-guard.sh` を登録しておくと、かけ直し忘れのまま返事を終えるのを止めます（[docs/commander-claude.md](docs/commander-claude.md)）。
3. 司令塔は DONE を見たら待たずに次工程（レビュー → PR）へつなぐ。FAILED / DEAD / STALLED は聞かれる前に人へ報告する。
4. CI は見張らない。PR は GitHub の auto-merge に任せ、次の見回りのついでに状態を見る。
5. 本番への反映（main への取り込み・本番デプロイ・本番 DB）は人の GO を待つ。

守ってほしい運用ルールは [docs/operating-rules.md](docs/operating-rules.md)。自分の `AGENTS.md` / `CLAUDE.md` に貼れるひな形が `templates/` にあります。

## よくある詰まり

| 症状 | 原因と対処 |
|---|---|
| ランチャがすぐ FAILED（EXIT:2） | 前提の点検で落ちている。`lanes-status.sh <worktree> <label> --tail 20` と `lanes-doctor.sh` を見る。多いのはサブスク未ログイン・道具の未導入 |
| 「起動禁止」と出る | API キーやサブスク以外の方法でログインしている。上の「サブスクでログインしているか確かめる」をやり直す |
| 「この構成では使えない」と出る（exit 2） | 構成（`LANES_TOOLS`）に無い道具のランチャを直接呼んだ。入口の `run-impl.sh` / `run-review.sh` を使う |
| 起動したのにすぐ DEAD | 起動元のシェルが終わって巻き添えで止まった。親を残してバックグラウンドで起動する（Bot の短い Shell なら `lanes/detach-run.sh <log> <コマンド...>`） |
| ずっと STALLED | 許可待ち・CLI の固まり・利用上限の待ちの疑い。`--tail` で末尾を見る。子の CPU 時間が増えていればビルド中などで動いている。原因が分かれば `kill <ランチャの pid>`（`kill -9` はしない）して起動し直す |
| 同じ label で起動できない（exit 2） | 前回のランチャか子がまだ生きている。`lanes-status.sh` で確かめ、FAILED / DEAD の行に「子 pid=N 生存」と出たときだけ `kill N` |
| レビューが `VERDICT: NONE` | 出力が途中で切れた・判定行が無い。失敗扱いなので、もう一度レビューを回す |
| プロンプトが大きすぎると止まる | 指示書に diff を貼っている。「自分で読め」と書き換える（上限は `LANES_PROMPT_MAX_BYTES`） |
| cleanup が止まる | 未保存の変更・未追跡のファイル・実行中のレーンがある。表示された退避先と理由を見て片付けてから `--apply` |
| auto-merge が CI を待たずに即マージした | そのリポジトリに必須チェック（ブランチ保護）が無い。保護を設定するか、`gh pr checks <PR> --watch --fail-fast` で緑を見てから手でマージする |

## アンインストール

```sh
cd <kit>
./install.sh --uninstall --dry-run   # 消す予定だけ見る
./install.sh --uninstall             # install.sh が作った symlink だけ消す
```

設定ファイル（`~/.config/lanewright/lanes.conf`）は残します。不要なら手で消してください。そのあとキットのフォルダを消せば完了です。
`~/.zshrc` に PATH を足した場合はその行も消してください。

## ドキュメント一覧

全体の地図は [docs/README.md](docs/README.md) にあります。

- 設定: [docs/config.md](docs/config.md) ／ 構成と役割: [docs/roles.md](docs/roles.md) ／ 運用ルール: [docs/operating-rules.md](docs/operating-rules.md)
- 司令塔: [外の Bot](docs/commander-grok.md) ／ [Claude の Code タブ](docs/commander-claude.md)
- ランチャの詳しい説明（引数・出力・終了コード・安全策）: [lanes/README.md](lanes/README.md)
- 脆弱性の報告: [SECURITY.md](SECURITY.md) ／ 開発に参加する: [CONTRIBUTING.md](CONTRIBUTING.md) ／ 変更履歴: [CHANGELOG.md](CHANGELOG.md)

## ライセンス

MIT License。[LICENSE](LICENSE) を見てください。
