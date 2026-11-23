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

### 環境変数に effort を上書きされないようにする

アプリ（デスクトップアプリやエディタなど）から起動したシェルは、`CLAUDE_EFFORT` などを環境変数として持っていることがあります。
見本の書き方（`"${CLAUDE_EFFORT-xhigh}"`）は環境変数が勝つので、そのシェルから起動したレーンは、設定ファイルに書いた値ではなく環境変数の値で動きます
（たとえば設定ファイルが `xhigh` でも、環境変数が `high` なら `high`）。勝つ順番は変わりません。

- 気づけるように、ランチャ（`run-impl.sh` / `run-review.sh` とその振り分け先・`run-qa.sh`）は起動時に、自分が使うキーの環境変数が
  設定ファイル（その行が無ければ既定）と違う値で勝っているときだけ、標準エラーに注意を 1 行出します（`--dry-run` でも出ます）:
  ```
  注意: CLAUDE_EFFORT は環境変数の値「high」で動く。設定ファイル（無ければ既定）の値「xhigh」は使われない（環境変数が設定ファイルより勝つ）。…
  ```
  `lanes-doctor.sh` も同じ内容を「注意」の行として出します。知らせるだけで、CLI に渡す値も子のプロセスの環境も変えません。
- いつも設定ファイルの値で動かしたいなら、値をそのまま書いて固定します（この書き方は環境変数より設定ファイルが勝ちます）:
  ```sh
  CLAUDE_EFFORT="xhigh"
  CODEX_EFFORT="xhigh"
  ```
  固定すると、その場だけの上書き（`CLAUDE_EFFORT=low zsh run-impl.sh ...`）は効かなくなります。その場だけ変えたいときは、別の設定ファイルを
  `LANES_CONF=<ファイル>` で指してください。
- 固定したまま、起動ごとに変えられるようにもできます。アプリが持ち込まない自分用の名前の変数だけを受ける書き方にします
  （設定ファイルはシェルとして読まれるので、変数の名前は自由です。キットが使う名前と重ならないものにしてください）:
  ```sh
  CLAUDE_EFFORT="${MY_CLAUDE_EFFORT:-xhigh}"   # 渡さなければ xhigh。CLAUDE_EFFORT という名前の環境変数は受けない
  ```
  ```sh
  MY_CLAUDE_EFFORT=high zsh <kit>/lanes/run-impl.sh <worktree> <プロンプト> <label>   # この起動だけ high
  ```
  軽い修正の回だけ effort を下げる、といった使い分けができます。
  レビュー（`run-review.sh`）に付けるときは、`chk-run.sh` にも同じ値を付けてください（入力の指紋に環境変数が入るので、
  片方だけに付けると、レビューが `chk-run.sh` の記録を使い回さずに必須検証を回し直します）。実装（`run-impl.sh`）だけに付ける分には関係ありません。
- 固定せずにその起動だけ環境変数を外すなら、`env -u CLAUDE_EFFORT zsh <kit>/lanes/run-impl.sh ...` のように起動します。
  `chk-run.sh` とレビューは同じ環境から呼ぶ必要があるので（入力の指紋に環境変数が入る）、外すなら両方とも同じように外します。

### どの設定で回したかを後から確かめる

ランチャは、そのレーンで CLI に渡す設定のモデルと effort を記録に残します。起動ごとに変えたときも、後から集計して比べられます。

- `logs/<label>.pid` の `model=` と `effort=`（空は、引数を付けずに CLI の既定に任せるという意味）
- 証跡 `logs/<label>.evidence.md` の「モデル: … / effort …」の行（空は「(CLI の既定)」と書く）

```sh
grep -E '^(lane|model|effort)=' <worktree>/logs/*.pid   # ファイル名（label）付きで出る。回転済みの <label>.prev-<日時>.pid も入る
```

- `.pid` は起動の直後に書くので、CLI を起動する前に止まったレーン（起動前点検の失敗、同じ head でのレビューの省略など）にも値が残ります。
  実際に回したかどうかは、`logs/<label>.done` の `EXIT:` と `note=` を合わせて見てください（省略したレビューの証跡には「モデル」の行を出しません）。
- モデルを空（CLI の既定に任せる。キットの既定）にしていると、`model=` はいつも空です。モデルで比べたいときは、設定ファイルに `*_MODEL` を明示してください。

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
| `GEMINI_REVIEW_DENY` | 空（固定の一覧だけ） | Gemini のレビュー（`run-gemini-review.sh`）で拒否するものに**足す**もの（カンマ区切りの道具の名前。空の項目は無視、改行などの制御文字・200 文字を超える項目があれば起動しない）。MCP（`mcp(*)`）・ファイルを書く道具（`write_to_file` など）・サブエージェント・ブラウザ・Web の検索と取得・予約・ワークフローを拒否する固定の一覧は `run-gemini-review.sh` にあり、外せない。ランチャは「固定の一覧 + ここに書いたもの」を agy の `--settings` の `permissions.deny` に渡し、実行の記録の監査でも同じ名前（`(` を含まないもの）を禁止として数える |

- レビュー・QA の子プロセスは、設定に関係なく git の通信（push・fetch）を止めて起動します（`GIT_ALLOW_PROTOCOL` に実在しない名前だけを渡す。git の `-c protocol.allow=always` より優先される）。
- これらは `CLAUDE_*` / `CODEX_*` なので、子のプロセスへ export しません（ランチャが引数で渡す）。
- レビューの判定は、必須検証（typecheck / lint / unit）の「該当なし（未導入）」・`NA` という自己申告を、ランチャが見た対象リポジトリの仕組みと突き合わせます。
  `package.json` の scripts にその項目（`typecheck` / `type-check` など・`lint`・`test` / `test:unit` など）があるのに `NA` なら不合格、
  `LANES_CHECK_CMD` が設定されているか `.lanes/check.sh` があるのに 3 項目すべて `NA` でも不合格です（Codex・Claude・Gemini のレビューとも）。
- この検証の設定（`LANES_CHECK_CMD` の値・`.lanes/check.sh` の中身・上の scripts）は、レビュー（Codex・Claude・Gemini とも）が前回の結果を再利用する条件にも入ります。変えたら同じ HEAD でも省略せずにレビューし直します。

| キー | 既定 | 意味 |
|---|---|---|
| `LANES_REVIEW_GEMINI_PCT` | `0` | レビューを Gemini（`run-gemini-review.sh`・読み取り専用）へ回す割合（`0`〜`100` の整数）。構成（`LANES_TOOLS`）に `gemini` があるときだけ効く。入口の `run-review.sh` が、`--engine` の無い新しい系列（label の末尾 `-r<N>` を外した名前）をこの割合で Gemini に回し、残りは構成の既定のレビュー役（① Codex / ③ Claude）にする。`1`〜`99` は `${XDG_STATE_HOME:-~/.local/state}/lanewright/review-split.state` に誤差を積み上げて決めるので、`50` なら既定の役・Gemini・既定の役・Gemini … と厳密に交互になる（記録を読めない・書けないときは既定の役に倒す。`--dry-run` は記録を進めない）。同じ系列の r2 以降は前回と同じレビュー役で続ける（割合より優先）。**Gemini で実装したもの（`--impl-engine gemini`、または `logs/` の `.pid` に `lane=gemini` の実装レーンがある）は Gemini に回さない。** `0`（既定）なら今までどおり。決め方の全体は [roles.md](roles.md) の「レビュー役の振り分け」。範囲外・整数以外は `lanes.env` が止める（ランチャでは今回の失敗として `.done` に残す）。この値は export されるので `chk-run.sh` の入力の指紋に入る。設定ファイルに書くか、その起動だけ環境変数で渡すなら `chk-run.sh` にも同じ値を付ける（片方だけだと、レビューが親の `chk-run.sh` の記録を使い回せない） |
| `LANES_REVIEW_REUSE_CHECKS` | `1` | `1` なら、レビューランチャ（`run-codex-review.sh` / `run-claude-review.sh` / `run-gemini-review.sh`）が子を起動する前に `chk-run.sh <worktree> --query` で問い合わせ、親が同じ中身で確認コマンドを通した記録（`passed.tsv`）があれば、指示書に「必須検証（typecheck / lint / unit）は親が実施済み。回さないこと」と入れ、必須検証は済んだものとして判定する。`0` なら問い合わせず、毎回レビューの中で回させる。`0` か `1` 以外は `lanes.env` が止める（ランチャでは今回の失敗として `.done` に残す） |
| `LANES_REVIEW_REQUIRE_CHECKS` | `0` | `1` なら、上の問い合わせで親の記録を使えないと分かったとき、レビューの子を起動せずに止める（`EXIT:2`。`.done` に `note=起動前の誤り: …` として理由と直し方が残り、`lanes-status.sh` は `FAILED` を返す）。止めるのは、問い合わせの理由が `no-record`（同じ中身の記録が無い）・`uncommitted`（未 commit の変更か未追跡のファイルがある）・`input-changed`（記録の後で依存・環境変数・確認コマンドなどが変わった）のとき。止まったら、表示された直し方のとおりに理由を解決して `chk-run.sh` を通し（出力に `recorded=` が出ること）、やり直す。**`chk-run.sh` が通っても `record=no` になる構成（確認コマンドを照合できない書き方・確認の途中で入力が変わる、など）は、記録が 1 件も無いので `no-record` として毎回止まる。** 通し直すだけでは直らないので、`record=no` の行に出る理由を先に直す。確認コマンドが未設定の案件（`no-check`）、`LANES_REVIEW_REUSE_CHECKS=0` のときは止めない。`logs/` がまだ無い worktree の初回の起動では `.done` を作らない（標準エラーと終了コード 2 だけ）。この値は `chk-run.sh` の入力の指紋に入らないので、起動のときだけ環境変数で渡しても記録は合う。その起動だけ記録なしで回すなら、ランチャに `--allow-missing-checks` を付ける（証跡に残る）。`0`（既定）なら今までどおり起動し、レビューの中で必須検証を回させる |

- 使い回す条件は `chk-run.sh` が同じ確認を省く条件（`skip=same-tree`）と同じです（tree・入力の指紋・確認コマンドの指紋。緩めません）。入力の指紋には環境変数も入るので、親は `chk-run.sh` とレビューを同じ環境から呼びます。ランチャの記録（`logs/` の直下の `.pid`・ログ・証跡・起動ログなどのうち、ランチャが台帳 `logs/.lanes-records` に載せた持ち主のもの）は指紋に入らないので、`detach-run.sh` の起動ログを `logs/` に置いても、前のレーンの記録が残っていても使い回せます。`detach-run.sh` は呼び出し元の環境変数をそのまま起動するコマンドへ渡すので（`python3` の入口が書き換えた分は渡しません）、`detach-run.sh` を挟んで起動しても同じ環境として照合します。台帳に無い名前のファイル（確認コマンドが読む `logs/input.json` など）は、記録に似た名前でも入力として照合します（`lanes/README.md` の 7 章）。
- `chk-run.sh` が通ったのに記録できなかったときは、`record=no reason=<uncommitted|unresolvable>（理由）` を出します。このときレビューの証跡は `no-record` になります。よくある原因は、`.lanes/check.sh` の `exec <コマンド>`（`exec` は「引数のコマンドを起動する包み」なので照合できません。`exec` を付けずに書きます）と、`logs/` が git に無視されていないことです。作業ツリーの外（か `.git` の中）を指すリンク・行き先の無いリンクが、依存や生成物（`dist/`・`.next/` などの中）にあるときも記録しません（理由にどのリンクかが出ます。作業ツリーの中を指すリンクは、生成物の中にあっても記録します）。確認の途中で入力のファイルが変わる構成（テストが `node_modules/` の中の、下に挙げた場所以外にキャッシュを書く、など）も記録しません（このときは `record=no` の行ではなく、標準エラーに「検証中に入力が変化したため記録しない」と出て、終了コード 1 で終わります）。キャッシュを書かせない・置き場を生成物のフォルダか作業ツリーの外へ移す、で直します。道具がよく書く場所（作業ツリー直下の `node_modules/.vitest-cache/`・`node_modules/.mf/`・`node_modules/.vite/`・`node_modules/.cache/`、`.cloudflare/`・`.vinext/`、作業ツリー直下の `next-env.d.ts`）は、git が無視していれば生成物として扱うので、ここに書いても記録します（一覧は `lanes/README.md` の 7 章）。
- **記録が無いままレビューを起動しても、たいてい「必須検証が未完了」の指摘で終わります。** レビューは既定で読み取り専用の閉じ込めの中で動くので、その中で単体テストなどを回そうとすると、一時ファイルを書けずに失敗します。この指摘は直しのレーンでは直せません（コードの欠陥ではないため）。`chk-run.sh` を必ず通す運用なら、`LANES_REVIEW_REQUIRE_CHECKS=1` にして、記録を使えないレビューを起動の前に止めてください。証跡の「必須検証:」の行が「親の chk-run の記録は使わない: …」なら、指摘を直しに行く前に、理由を解決して `chk-run.sh` とレビューをやり直します。
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

数値のキー（`LANES_STALL_MINUTES` `LANES_NOTIFY` `LANES_PROMPT_MAX_BYTES` `LANES_DOWNLOADS_SCAN` `LANES_DETACH_QA` `LANES_REVIEW_REUSE_CHECKS` `LANES_REVIEW_REQUIRE_CHECKS` `LANES_CHECK_INTERVAL_MIN` `LANES_REVIEW_MAX_ROUNDS` `LANES_REVIEW_GEMINI_PCT`）は、使う前に `lanes.env` が整数か確かめます。
数字以外（`10m`・`-1`・式など）なら、その値を計算に使わずに exit 2 で止まります（zsh の計算は値の中のコマンドを実行してしまうため）。
ランチャ（`run-*.sh`）から起動したときは、その label の排他（同じ label の二重起動を防ぐ鍵）を取れれば今回の失敗（`EXIT:2`）を `.done` に残してから止まります。前回成功した label に誤った値で起動しても、`lanes-status.sh` は前回の `DONE` ではなく `FAILED` を返します。
`LANES_NOTIFY` `LANES_DOWNLOADS_SCAN` `LANES_DETACH_QA` `LANES_REVIEW_REUSE_CHECKS` `LANES_REVIEW_REQUIRE_CHECKS` は `0` か `1`、`LANES_STALL_MINUTES` と `LANES_PROMPT_MAX_BYTES` は 1 以上、`LANES_CHECK_INTERVAL_MIN` は 1〜1440、`LANES_REVIEW_MAX_ROUNDS` は 1 以上、`LANES_REVIEW_GEMINI_PCT` は 0〜100 です。

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
