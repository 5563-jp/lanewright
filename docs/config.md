# 設定リファレンス

キットの設定は 1 つのファイルにまとまっています。

- 場所: 環境変数 `LANES_CONF` があればそこ。無ければ `${XDG_CONFIG_HOME:-$HOME/.config}/lanewright/lanes.conf`
  （普通は `~/.config/lanewright/lanes.conf`）。`install.sh` が `lanes.conf.example` をここへコピーします。
- 形: zsh で読み込める `KEY="value"` の並び。設定ファイルは zsh のコードとしてそのまま読み込まれる（`source` される）ため、書いた行はすべて実行されます。他人が書き込める場所に置かないでください。また、`LANES_CONF` で他人のファイルや信頼できない場所を指さないでください。
- 勝つ順番: **環境変数 > 設定ファイル > 既定値**。その場だけ変えたいときは、コマンドの前に `CLAUDE_EFFORT=low zsh run-impl.sh ...` のように付けます。
  そのため設定ファイルでは、環境変数が空のときだけ値を入れる書き方にします:
  ```sh
  LANES_TOOLS="${LANES_TOOLS:-claude codex}"
  ```
- 読む場所: 各ランチャが最初に `lanes/lanes.env` を読み、そこが設定ファイルを（あれば）読んでから既定値を埋めます。
  `lanes.env` は `LANES_*` のキーを export（子のプロセスへ渡す）するので、設定ファイルを直接読まない Python のスクリプト（監視・Vercel の自動再デプロイ）にも、
  設定ファイルに書いた値が届きます。bash で書かれた `chk-run.sh` も、最初に `lanes.env` を通してから動きます。
  CLI のパス・モデル・effort（`CLAUDE_*` / `CODEX_*` / `GEMINI_*`）は export しません（各 CLI が同じ名前の環境変数を読むことがあるため。ランチャが引数で渡します）。

設定を変えたら `zsh <kit>/lanes/lanes-doctor.sh` で点検してください。

## 道具と司令塔

| キー | 既定 | 意味 |
|---|---|---|
| `LANES_TOOLS` | `claude` | 使える道具をスペース区切りで。`claude` `codex` `gemini` の組み合わせ。`claude` は必須。ここから構成（①〜④）が決まる → [roles.md](roles.md) |
| `LANES_COMMANDER` | `grok` | 司令塔（レーンを起動してつなぐ役）。`grok`（Grok Bot など Mac の外の Bot）か `claude`（Claude デスクトップの Code タブ）。運用の印で、変わるのは `lanes-doctor.sh` の監視の回し方の案内と、`claude` のとき `lanes-watch.sh` を `--until-wake` なしで起動したときの注意だけ（ランチャや判定は変わらない）→ [commander-grok.md](commander-grok.md) / [commander-claude.md](commander-claude.md) |

## 枝と置き場所

| キー | 既定 | 意味 |
|---|---|---|
| `LANES_BASE_BRANCH` | `develop` | 作業枝を取り込む先。マージ済みかどうかの判定・後片付け・QA（品質確認）の基準。`main` に直接取り込むリポジトリなら `main` |
| `LANES_RUNS_ROOT` | `$HOME/dev/_runs` | レーンの worktree を置く場所。監視（`lanes-watch.sh`）はこの下の `logs/*.pid` を自動で見つける。`_` で始まるフォルダと隠しフォルダは見ない |
| `LANES_ARCHIVE_ROOT` | `$LANES_RUNS_ROOT` と同じ | マージ後の残骸（ログ・指示書など）の退避先 |
| `LANES_SCRATCH_ROOT` | `$LANES_RUNS_ROOT/_scratch` | レーン専用の一時領域。`<root>/<リポジトリ>/<label>/` を作ってレーンの `TMPDIR` に渡し、後片付けで丸ごと消す |

## CLI の場所・モデル・effort

| キー | 既定 | 意味 |
|---|---|---|
| `CLAUDE_BIN` `CODEX_BIN` `GEMINI_BIN` | `command -v claude` / `codex` / `agy` の結果 | 各 CLI の実行ファイルのパス。PATH に無い場所に入れたときだけ書く |
| `CLAUDE_MODEL` `CODEX_MODEL` `GEMINI_MODEL` | 空 | 空なら `--model` を付けず、CLI の既定のモデルを使う。決まったモデルを使いたいときだけ、そのモデル名を自分で書く（キットにはモデル名を書いていません） |
| `CLAUDE_EFFORT` `CODEX_EFFORT` `GEMINI_EFFORT` | `xhigh` / `xhigh` / `high` | effort（どれだけ深く考えさせるか）。空なら `--effort` を付けない。モデルによって使える値が違うので、エラーになったら下げる |

effort を付けたくないとき:

```sh
# いつも付けない: 設定ファイルにその行を空で書く（この書き方だけは環境変数より設定ファイルが勝つ）
CLAUDE_EFFORT=""
# その場だけ付けない: 環境変数で空を渡す。設定ファイルの行が "${CLAUDE_EFFORT-xhigh}"（コロン無し。見本の書き方）のときに効く
CLAUDE_EFFORT= zsh <kit>/lanes/run-impl.sh <worktree> <prompt.md> my-label
```

`"${CLAUDE_EFFORT:-xhigh}"`（コロンあり）と書くと、環境変数の空は「未設定」と同じ扱いになり、`xhigh` に戻ります。

## 実装・レビューの許可

ランチャは CLI を非対話で動かすので、途中で許可の確認を出せません（確認が要る操作は拒否されます）。何を確認なしで許すかをランチャが毎回明示して渡し、
利用者の `~/.claude/settings.json` や `~/.codex/config.toml` には任せません。空（`KEY=""`）にすると、その指定を付けません（CLI 側の設定に任せる）。
空を効かせたいので、`CLAUDE_IMPL_*` と `CODEX_IMPL_SANDBOX` は effort と同じく `"${KEY-値}"`（コロン無し）で書きます。

| キー | 既定 | 意味 |
|---|---|---|
| `CLAUDE_IMPL_PERMISSION_MODE` | `acceptEdits` | Claude の実装レーン（`run-claude.sh`）の許可モード（`--permission-mode=`）。`acceptEdits` は作業ツリー内の編集を確認なしで通す。ほかの値は `claude --help` の choices を見る |
| `CLAUDE_IMPL_ALLOWED_TOOLS` | `Bash,Edit,Write,Read,Glob,Grep,TodoWrite` | Claude の実装レーンで確認なしに使えるツール（`--allowedTools=`、カンマ区切り）。`Bash` があるので任意のコマンドを実行でき、作業ツリーの外にも書ける |
| `CODEX_IMPL_SANDBOX` | `workspace-write` | Codex の実装レーン（`run-codex.sh`）の sandbox（閉じ込めの範囲。`--sandbox`）。`read-only` / `workspace-write` / `danger-full-access`。`workspace-write` では作業ツリーと一時領域（`TMPDIR`）に書け、commit のために git の管理フォルダのうち commit に要る場所だけ（その worktree の gitdir（`git rev-parse --git-dir`）と、共通の管理フォルダの `objects`・`refs`・`logs`）を書ける場所に足す（`-c sandbox_workspace_write.writable_roots=[...]`。自分の config.toml の同じ設定は置き換わる）。共通の `config`・`hooks` は足さない（サンドボックスの中から書けると、後でサンドボックスの外の git 操作から実行され得るため）。gitdir の中の制御ファイル（`commondir`・`gitdir`・`config.worktree`）は書けてしまう（gitdir の中で書ける場所をファイル単位に絞ると、git が作る一時ファイルの置き場が無くなり commit が落ちる）ので、ランチャが子の前後で worktree の `.git` ファイル・それらの制御ファイル・共通の `config`・`hooks` の指紋を比べ、変わっていたら git を 1 回も呼ばずに `EXIT:4`（`VERDICT: NEEDS_FIX`）で止める。この比較は `read-only`・`danger-full-access` でも行う（`danger-full-access` で Codex が `git push -u` や `git config` を使うと共通の `config` が変わるので、同じく止まる）。worktree でなく本体の checkout で回すと絞れないので、管理フォルダ全体を足して注意を出す（レーンは worktree で回す）。通信は止まるので、依存の取得などが要るなら `danger-full-access` を自分の判断で選ぶ |
| `CODEX_REVIEW_SANDBOX` | `read-only` | Codex のレビュー（`run-codex-review.sh`）の sandbox（`-c sandbox_mode="..."`）。`read-only` か `workspace-write` だけ受け付け、ほかの値では起動しない。テストが書き込みを要して読み取り専用で回らないときだけ `workspace-write` にする（作業ツリーの変更は前後の比較で不合格になるのは同じ） |
| `CLAUDE_REVIEW_TOOLS` | `Bash,Read,Glob,Grep` | Claude のレビュー・QA で使える内蔵ツールの集合（`--tools=`、カンマ区切りのツール名）。上書きできるが、編集系（`Edit` `Write` `MultiEdit` `NotebookEdit`）かサブエージェント（`Agent` `Task`）を入れるとランチャが起動しない（exit 2） |
| `CLAUDE_REVIEW_DENY` | 空（固定の一覧だけ） | Claude のレビュー・QA で拒否するものに**足す**もの（カンマ区切り）。編集系ツール・サブエージェント・履歴の書き換え・PR のマージ・デプロイなどを拒否する固定の一覧は `lanes/_common.sh`（`LANES_CLAUDE_REVIEW_DENY_BASE`）にあり、環境変数や設定ファイルでは外せない。ランチャは「固定の一覧 + ここに書いたもの」を `--disallowedTools=` に渡す |

- レビュー・QA の子プロセスは、設定に関係なく git の通信（push・fetch）を止めて起動します（`GIT_ALLOW_PROTOCOL` に実在しない名前だけを渡す。git の `-c protocol.allow=always` より優先される）。
- これらは `CLAUDE_*` / `CODEX_*` なので、子のプロセスへ export しません（ランチャが引数で渡す）。
- レビューの判定は、必須検証（typecheck / lint / unit）の「該当なし（未導入）」・`NA` という自己申告を、ランチャが見た対象リポジトリの仕組みと突き合わせます。
  `package.json` の scripts にその項目（`typecheck` / `type-check` など・`lint`・`test` / `test:unit` など）があるのに `NA` なら不合格、
  `LANES_CHECK_CMD` が設定されているか `.lanes/check.sh` があるのに 3 項目すべて `NA` でも不合格です（Codex・Claude のレビューとも）。
- この検証の設定（`LANES_CHECK_CMD` の値・`.lanes/check.sh` の中身・上の scripts）は、レビュー（Codex・Claude とも）が前回の結果を再利用する条件にも入ります。変えたら同じ HEAD でも省略せずにレビューし直します。

| キー | 既定 | 意味 |
|---|---|---|
| `LANES_REVIEW_REUSE_CHECKS` | `1` | `1` なら、レビューランチャ（`run-codex-review.sh` / `run-claude-review.sh`）が子を起動する前に `chk-run.sh <worktree> --query` で問い合わせ、親が同じ中身で確認コマンドを通した記録（`passed.tsv`）があれば、指示書に「必須検証（typecheck / lint / unit）は親が実施済み。回さないこと」と入れ、必須検証は済んだものとして判定する。`0` なら問い合わせず、毎回レビューの中で回させる。`0` か `1` 以外は `lanes.env` が止める（ランチャでは今回の失敗として `.done` に残す） |

- 使い回す条件は `chk-run.sh` が同じ確認を省く条件（`skip=same-tree`）と同じです（tree・入力の指紋・確認コマンドの指紋。緩めません）。入力の指紋には環境変数も入るので、親は `chk-run.sh` とレビューを同じ環境から呼びます。ランチャの記録（`logs/` の直下の `.pid`・ログ・証跡・起動ログなど）は指紋に入らないので、`detach-run.sh` の起動ログを `logs/` に置いても、前のレーンの記録が残っていても使い回せます（`lanes/README.md` の 7 章）。
- **何を確かめたことになるかは確認コマンドの中身次第です。** 確認コマンドに単体テストを入れていなければ、単体テストを確かめたことにはなりません。型検査・lint・単体テストをすべて `.lanes/check.sh` か `LANES_CHECK_CMD` に入れてください。
- 使い回しの有無と使った記録（head・日時・確認コマンドの種類）はレビューの再利用の条件に入ります。記録が変わったら同じ HEAD でも前回の結果を使いません。証跡には `- 必須検証: 親の chk-run の記録を使用（head・日時・確認コマンド）` か、`- 必須検証: レビューの中で回すよう指示（親の chk-run の記録は使わない: <理由>）` が出ます。

## 確認・QA・デプロイ連携

| キー | 既定 | 意味 |
|---|---|---|
| `LANES_CHECK_CMD` | 空 | `chk-run.sh`（取り込み前の最終確認）が回すコマンド。例 `pnpm lint && pnpm typecheck && pnpm build`。対象リポジトリに `.lanes/check.sh` があればそちらを優先。前に通った結果を再利用するのは、呼ぶ実行ファイルを確実に決められる単純な書き方のときだけ（`PATH` の付け替え・`cd`・パイプ・サブシェルなどがあれば毎回回す。`lanes/README.md` の chk-run の節） |
| `LANES_SCREEN_QA_MAP` | 空 | 画面 QA の対応表。1 行 1 件で `origin の URL に含まれる文字列\|Preview の URL\|観点ファイルのパス`。画面 QA の準備（`prepare-screen-qa.sh`）がリポジトリから Preview の URL と観点を引くのに使う。空なら対応付けしない（URL は `--url` で渡す） |
| `LANES_VERCEL_PROJECT` `LANES_VERCEL_SCOPE` | 空 | Vercel（ホスティングサービス）の自動再デプロイ機能を使うときのプロジェクト名とチーム名。空なら無効 |

例（`LANES_SCREEN_QA_MAP` は複数行の文字列）:

```sh
LANES_CHECK_CMD="${LANES_CHECK_CMD:-pnpm lint && pnpm typecheck && pnpm test}"
LANES_SCREEN_QA_MAP="${LANES_SCREEN_QA_MAP:-owner/my-app|https://preview.example.com|/Users/you/dev/my-app/qa/screens.md}"
```

## 監視・通知・その他

| キー | 既定 | 意味 |
|---|---|---|
| `LANES_REVIEW_MAX_ROUNDS` | `5` | レビューの周回の上限（1 以上）。超えた周で `CLEAN` にならなければ `GATE: ESCALATE` で止め、続けるか締めるかを人に返す（系列ごとに数える） |
| `LANES_CHECK_INTERVAL_MIN` | `10` | 司令塔が定期に回す確認（`lanes-watch.sh --check`）の間隔（分、1〜1440）。`--check` が出す「直近 N 分に終わって次工程を待つレーン」の N に使う。定期実行（Claude の `/loop` や Bot のルーティン）もこの間隔で組む。監視が止まったとみなす時間（心拍が 15 分より古い＝5 分の見回りの 3 回分）とは別 |
| `LANES_STALL_MINUTES` | `10` | 最終出力からこの分数を超えて更新が無いと、`lanes-status.sh` が `STALLED`（止まっている疑い）と判定 |
| `LANES_NOTIFY` | `1` | レーン終了時に macOS の通知を出す。`0` で出さない |
| `LANES_PROMPT_MAX_BYTES` | `200000` | 指示書の大きさの上限（バイト）。diff の貼り込み事故を止めるため |
| `LANES_DOWNLOADS_SCAN` | `0` | `1` にすると、後片付けのときに `~/Downloads` に置き忘れたレビュー出力らしいファイルを一覧で知らせる（消さない） |
| `LANES_DETACH_QA` | `0` | `1` にすると、`after-develop-merge.sh` が QA を `detach-run.sh` で呼び出し元から切り離して起動する（シェルが終わるとプロセスグループ（まとめて止められるプロセスの束）ごと止める Bot から呼ぶとき用）。`0` なら QA へそのまま切り替わる（exec） |

数値のキー（`LANES_STALL_MINUTES` `LANES_NOTIFY` `LANES_PROMPT_MAX_BYTES` `LANES_DOWNLOADS_SCAN` `LANES_DETACH_QA` `LANES_REVIEW_REUSE_CHECKS` `LANES_CHECK_INTERVAL_MIN` `LANES_REVIEW_MAX_ROUNDS`）は、使う前に `lanes.env` が整数か確かめます。
数字以外（`10m`・`-1`・式など）なら、その値を計算に使わずに exit 2 で止まります（zsh の計算は値の中のコマンドを実行してしまうため）。
ランチャ（`run-*.sh`）から起動したときは、その label の排他（同じ label の二重起動を防ぐ鍵）を取れれば今回の失敗（`EXIT:2`）を `.done` に残してから止まります。前回成功した label に誤った値で起動しても、`lanes-status.sh` は前回の `DONE` ではなく `FAILED` を返します。
`LANES_NOTIFY` `LANES_DOWNLOADS_SCAN` `LANES_DETACH_QA` `LANES_REVIEW_REUSE_CHECKS` は `0` か `1`、`LANES_STALL_MINUTES` と `LANES_PROMPT_MAX_BYTES` は 1 以上、`LANES_CHECK_INTERVAL_MIN` は 1〜1440、`LANES_REVIEW_MAX_ROUNDS` は 1 以上です。

## 設定の場所そのもの

| 環境変数 | 意味 |
|---|---|
| `LANES_CONF` | 設定ファイルのパスを差し替える（複数の設定を切り替えたいとき・テスト用）。zsh で `source` されるため、他人のファイルや他人が書き込める場所を指さない。`install.sh` は HOME の外を指すと止まる |
| `XDG_CONFIG_HOME` | 設定の置き場所の基準。未設定なら `$HOME/.config` |

## 導入記録

`install.sh` は、作った symlink の一覧を設定ファイルと同じフォルダの `installed-links.txt` に残します。
1 行に 1 つのリンクで、形は `リンクのパス<TAB>作ったときの行き先` です（TAB はタブ文字）。

- `./install.sh --uninstall` と入れ直しは、「キットの `skills/` を指す symlink」と「記録した行き先を今も指している記録済みの symlink」だけを消す・張り替えます。
  キットを指すかどうかは、行き先を正規化して（相対パス・`..` を解き、在れば実体のパスにして）から `skills/<名前>` の直下かで判定します。`<キット>/skills/../../別の場所` のように外へ出る行き先は、キットの物として扱いません。
  利用者が別の場所へ向け直したリンクは、行き先が存在しなくても触りません。
- 行き先の無い古い形式の行（リンクのパスだけ）は、自分が作ったものと確かめられないので記録からは触りません（キットの `skills/` を指していれば、その判定で扱います）。
- 記録ファイル自体が symlink のとき、または自分の持ち物の普通のファイルでないときは、記録を読み書きせずに警告します（リンク先を上書きしません。書くときも一時ファイルに書いてから置き換えます）。設定の置き場所そのものが HOME の外なら `install.sh` は止まります。
- `LANES_CONF` が導入記録と同じパス（名前が `installed-links.txt` / `installed-dirs.txt`。大文字・小文字の違いは同じとみなす。または実体が同じファイル）になるときは、設定が記録として書き換え・削除されるのを防ぐため、何も書かずに exit 2 で止まります。
- `install.sh` がスキル置き場のフォルダを作ったときは、同じフォルダの `installed-dirs.txt` に 1 行 1 フォルダで残し、`--uninstall` で空のときだけ消します（元からあったフォルダは記録しません）。スキル置き場自体が行き先の無い symlink などでディレクトリでないときは、警告してその置き場を飛ばし、残りの処理を続けます。
- 手で編集する必要はありません。
