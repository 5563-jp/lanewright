# Changelog / 変更履歴

このファイルには、利用者から見える変更を書きます。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に沿い、版の付け方は [Semantic Versioning](https://semver.org/lang/ja/) に従います（1.0.0 になるまでは、0.x の中でも動きが変わることがあります）。

This file lists user-visible changes. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/) (behavior may change between 0.x releases before 1.0.0).

## [Unreleased]

0.1.8 の候補 / Candidate for 0.1.8

### 足したこと / Added
- Gemini（Antigravity CLI `agy`）でレビューするランチャ `lanes/run-gemini-review.sh`。レビュー役を Codex だけに偏らせず、別の目を足したいときに使う。
  **選んだときだけ動く**（`run-review.sh --engine gemini` か設定の `LANES_REVIEW_ENGINE=gemini`。構成に gemini があるときだけ）。既定のレビュー役（構成で決まる Codex / Claude）は変わらない。
  - 読み取り専用は、`agy` を `--mode plan`・`--sandbox`（端末サンドボックス）・`--settings`（起動単位の設定。利用者の設定ファイルは変えない）で起動して強制する。
    `--settings` の拒否は固定（MCP・ファイルの書き込み・URL の読み込みと実行・Claude レビューの固定の拒否の一覧のコマンドの分＝commit・push・stash・tag・PR のマージ・デプロイ・別のエージェントの起動など）で、設定キーでは緩められない。
    `--dangerously-skip-permissions`・`accept-edits`・`auto` は使わない。端末サンドボックスを有効にできない・`agy --help` に `--sandbox` / `--settings` / `--mode`（plan）が無い
    （オプション名は単語として照合し、`--model` の説明の「plan」では通さない）・登録済みの linked worktree でない（本体 checkout・管理領域を外に置いた本体・submodule）なら起動しない。
  - 書き込みの監査と最後の応答は、受け取り役（`lanes/gemini-stream-tee.py`）が `agy` の標準出力をパイプで直接受け取った親専用の写しで判定する（子が書ける `logs/<label>.json` は判定に使わず、
    子の回収後に受け取った中身で置き換える。実行中に書き換えられていたら改ざんとして `EXIT:4`）。1 行目が `init` でない記録（先頭の欠落・`result` だけ残った記録）は `VERDICT: NONE`。
  - 親（ランチャ）はレビュー対象の worktree へ `cd` せず（子だけを worktree で起動する）、親の `python3` は `-I` で動かす（レビュー対象の `json.py` などを読まない）。
  - 守りの強さは Codex・Claude のレビューと同じ: 親の chk-run の記録の使い回し・`LANES_REVIEW_REQUIRE_CHECKS=1` の起動前の停止・API キーを外す・MCP 拒否・子の git の通信止め・
    子の前後の比較（作業ツリー・git の管理フォルダ・git の制御ファイルを git を呼ぶ前に・全部の系列の再利用の記録・「使い回し禁止」の印。変わっていれば `NEEDS_FIX`・`EXIT:4`）。
    加えて、stream-json の書き込み系のツール呼び出し（拒否されて書けなかった試みも含む）が 1 件でもあれば `NEEDS_FIX`・`EXIT:4`（証跡に件数。`agy` の失敗の終了コードより優先し、`agy` の終了コードは証跡に別に書く）。
    「使い回し禁止」の印は置き場所（`logs/` の中と外）ごとに前後を比べる。書き込みの試み・改ざんで不合格にしたら、見つけた直後（証跡を書く前）に、その系列の前回の `CLEAN` を失効させる
    （次の通常の起動で古い合格を返さない。証跡の書き込みで止まっても残さない）。監査は親専用の写しをバイト列のまま行ごとに読む（末尾の文字切れでも、それまでの書き込みの試みを失わない）。
  - `agy` は点検の前に絶対パスへ直し、点検と起動に同じ実行ファイルを使う。受け取り役は `agy` の終了をパイプの終端とは別に見張る（補助のプロセスが標準出力を持ち続けても止まらない）。
    見張りは子の起動前に開いた番号から出力の更新と idle の行を読む（標準エラーのファイルを名前付きパイプに差し替えられても止まらない）。公開ログとの照合は 1 MiB ずつ読み比べる。
  - 周回の仕組み（`review-dedup.zsh` の full / delta / 同じ HEAD の省略・未解決指摘の引き継ぎ・round 3 以降の P2/P3 の後回し・`ESCALATE`）と、
    VERDICT・P0〜P3・GATE の判定は Claude レビューと同じ順番・同じ条件（同じ本文なら同じ判定になることをテストで確かめた）。
  - **実装と同じ道具でレビューしない**: Gemini で実装した worktree（`logs/` に Gemini 実装の記録がある）では起動しない（`EXIT:2`。Codex か Claude のレビューを案内する）。
    どうしても回すときだけ `--allow-same-engine`（証跡に残る）。
  - 証跡は「## Gemini レビュー証跡（<label>）」。行の並びは Claude レビューと同じで、「- レビューエンジン: gemini」と「- 読み取り専用の確認」の行が足される。
    出力は他のレビューと同じ（`logs/<label>.{log,json,stderr.log,prompt.md,evidence.md,last.md,pid,done}`）。
  - 見張りは Gemini 実装と同じ（出力が止まったら `EXIT:8`、idle のまま子が無ければ `EXIT:3`、全体の上限は `--print-timeout`）。
- `run-review.sh --engine codex|claude|gemini`（`run-impl.sh` の `--engine` と同じ流儀）。優先順は `--engine` ＞ `LANES_REVIEW_ENGINE` ＞ 構成のレビュー役。
  構成に無い道具・知らない値は今回の失敗（`EXIT:2`）として `.done` に残す。
- 設定キー: `LANES_REVIEW_ENGINE`（既定は空＝構成のレビュー役）・`GEMINI_REVIEW_MODEL` / `GEMINI_REVIEW_EFFORT`（既定は空＝付けない。実装用の `GEMINI_MODEL` / `GEMINI_EFFORT` とは別）・
  `GEMINI_REVIEW_PRINT_TIMEOUT`（既定 `45m`）・`GEMINI_REVIEW_NOOUTPUT_SEC`（既定 600 秒）。`GEMINI_REVIEW_EFFORT` も、環境変数が設定ファイルに勝ったときに注意を 1 行出す。
- `lanes-doctor.sh` は、`LANES_REVIEW_ENGINE=gemini` のときだけ、構成に gemini があるかと、`agy` が `--sandbox`・`--settings`・`--mode plan` に対応しているかも見る（既定の設定の点検結果は変わらない）。
- `lanes-roles.sh --print` は、構成に gemini があるとき「Gemini レビューは `--engine gemini` で選べる」と案内する（`--env` の出力は変わらない）。
- 監視（`lanes-monitor.sh`）は、Gemini レビューのレーンに `[gemini-review]` の印を付け、動いているときだけ要約に「Gemini レビュー N」を足す（Gemini 実装の数には入れない）。

### 実機で確かめたこと / Verified on a real CLI
- `agy` 1.5.14 で、使い捨ての git リポの linked worktree に、このランチャと同じ起動の仕方（`--mode plan`・端末サンドボックス・同じ `--settings`）で
  「ファイルを作る・書き換える・`git add -A && git commit` する・`git log` する」を頼んだ。`write_file`・`edit_file` の呼び出しと commit は deny ルールで拒否され、
  作業ツリーも HEAD も変わらなかった。result は `{"event":"result","result":{"status":"SUCCESS","response":…,"num_turns":…,"usage":…}}` の形で 1 回だけ出た。
- 最初の試しでは deny に相対パスの `write_file(.)` を入れていて、端末サンドボックスの設定エラー（`readonly .: non-absolute file path`）になり、読み取りのコマンドまで動かなかった。
  外して試し直すと `git log` などは動いた（ターミナルからの書き込みは作業場所の scratch に向かった）。キットの固定の一覧には相対パスを入れていない。
- plan モードだけでは道具の呼び出しは止まらず、止めていたのは deny ルールだった。実機の stream-json の形（個人のパスを消したもの）を `lanes/tests/fixtures/gemini-review/` に残し、テストで同じ数え方をしている。

### 変えたこと / Changed
- `agy` の起動と見張り（子プロセスの記録・idle・無出力の停止）を `lanes/gemini-agy.zsh` に切り出し、`run-gemini.sh` と `run-gemini-review.sh` で同じものを使う（`run-gemini.sh` の動きは変わらない）。
- `chk-run.sh` は `LANES_REVIEW_ENGINE` を入力の指紋に入れない（起動のときだけ渡しても親の記録を使い回せる）。
  **上げた後は、`chk-run.sh` を 1 回通し直す**（`chk-run.sh` の中身が変わったので、前の版の確認済みの記録は 1 回だけ使えなくなる）。
  `_common.sh` も変わったので、Codex・Claude のレビューも、上げた後の最初の 1 回は同じ HEAD でも前回の結果を使わずにレビューし直す（版を上げたときのいつもの動き）。
- 全ランチャ: 呼び出し元の `GIT_DIR`・`GIT_WORK_TREE`・`GIT_INDEX_FILE`・`GIT_OBJECT_DIRECTORY` などリポジトリの場所の環境変数を `_common.sh` を読んだ時点で外す
  （`chk-run.sh --query` と入口から振り分け先への引き渡しのときだけ元に戻す）。Gemini の実装・レビューは、git から見た最上位が渡した worktree であることも確かめる。
- 全ランチャ: 親の `python3`（`_common.sh`・`review-dedup.zsh`・`chk-run.sh`・監督役）を `-I` で動かす（作業場所の同名のモジュールや `PYTHON*` の環境変数を読まない）。
- `LANES_SCRATCH_ROOT` が相対パスなら、起動した場所を起点に絶対パスへ直す（ランチャが途中で `cd` しても、検査・作成・子への引き渡しが同じ場所を指す）。
- dry-run（Codex・Claude・Gemini のレビューと Gemini 実装）も、指示書を書く前に `logs/` と書き込み先を確かめる（`logs/` や書き込み先が前の実行の子の置いたリンクでも辿らない。台帳に載せられなければ書かずに止める）。
- `run-review.sh` は、優先順位を解決した後のレビュー役を振り分け先と起動前点検に渡す（設定が `LANES_REVIEW_ENGINE=gemini` でも、`--engine codex` / `claude` の起動を使わない Gemini の点検で止めない）。
- `run-codex-review.sh` は、テンプレの役名を Codex に読み替えてから worktree のパス・枝名を埋め込む（`Claude` を含むパス・枝名を書き換えない）。
- `lanes-roles.sh --print` の「レビューの独立性」は、`LANES_REVIEW_ENGINE` で選んだレビュー役に合わせて出す（`--env` は構成の既定のまま）。
- Codex・Claude・Gemini のレビュー: **同じ worktree のレビューは 1 本ずつ**（前回の記録を読む所から最後の保存まで `logs/` に排他のロックをかけ、取れなければ `EXIT:2`）。
  並行すると、後から終わった方が先に終わった方の正規の再利用の記録を子の改ざんとして巻き戻していた。並行して見たいときは worktree を分ける。
- Codex・Claude・Gemini のレビュー: 子の起動前に `logs/` の外（`${XDG_STATE_HOME:-~/.local/state}/lanewright/review-inflight/`）へ「確認中」の印を置き、子の後の確認が済んだら消す。
  途中で終わった（終了シグナル・`kill -9` など）レビューの印が残っていたら、次のレビューが再利用の記録を子の前の中身に戻し、その系列の前回の `CLEAN` を再利用しない。
- Codex・Claude・Gemini のレビュー: 親の chk-run の記録を使い回したときは、子の後にも同じ環境で確認コマンドの入力を照合し直す（新しい `chk-run.sh <worktree> --query-input <port> <outdir>`。
  生成物は比べない）。レビュー中に未追跡の `logs/input.json` などが変わっていたら `NEEDS_FIX`・`EXIT:4`。`chk-run.sh --query` の答えに `port=` / `outdir=` / `input=` の行を足した。
- `LANES_REVIEW_REQUIRE_CHECKS=1` は、問い合わせそのものの失敗（`query-failed`。終了コードが 0・1 以外・答えの形の崩れ）でも子を起動せずに止める（前は止めなかった）。
- `chk-run.sh` は、回すときも問い合わせのときも、最初の git の呼び出しの前に git の場所の環境変数を全部外す（前は `GIT_DIR`・`GIT_WORK_TREE`・`GIT_INDEX_FILE` だけ。
  `GIT_COMMON_DIR`・`GIT_OBJECT_DIRECTORY` などが残ると、レビューの問い合わせが別の参照・オブジェクトを見ていた）。
- `lanes-doctor.sh --review-engine codex|claude|gemini`: レビューのランチャが確定したレビュー役を渡し、設定ファイルを読んだ後に当てる
  （設定ファイルに `LANES_REVIEW_ENGINE=gemini` と値をそのまま書いていても、`--engine codex` / `claude` の起動を使わない Gemini の点検で止めない）。
- `LANES_SCRATCH_ROOT` の相対指定は `lanes.env` で絶対パスに直す（`chk-run.sh` も同じ設定を読むので、親の検証とレビューの問い合わせで指紋がそろい、記録を使い回せる）。
- 全ランチャ: CLI の実行ファイル（`CLAUDE_BIN` / `CODEX_BIN` / `GEMINI_BIN`）と親の `python3` は、作業場所を移る前に絶対パスで確定する
  （相対パス・名前だけの指定・PATH の `.` で、点検と起動が別のファイルを指したり、作業ツリーの同名のファイルを選んだりしない。`chk-run.sh` の `python3` も同じ）。
- Gemini で実装した記録の確かめ: 記録の名前（`.pid`・証跡）なのに普通のファイルでない物（フォルダ・symlink など）は「記録なし」にせず「確かめられない」として止める（`--allow-same-engine` で回せる）。
- dry-run（Codex・Claude・Gemini のレビューと Gemini 実装）は、前回の指示書を先に消さず、確かめが通った後に `logs/` の中で新しい指示書を書いてから名前を付け替える（途中の確かめで止まっても前回の指示書が残る）。
- Gemini レビュー: 次回へ引き継ぐ本文（再利用の記録の未解決指摘）は、親が受信した最後の応答（`last.md`）だけにする（表示用の `logs/<label>.log` の見張りの行・証跡を入れない）。
  承認・質問ツールの回数は呼び出し単位で数える（`run-gemini.sh` も）。`run-gemini.sh` の監査も、ログを行ごとに読む（末尾の文字切れで外への書き込みを見落とさない）。
- `run-gemini.sh` も、登録済みの linked worktree だけで起動し、`agy` の出力を受け取り役で受けて、子の回収後に受け取った中身と突き合わせる（消された・書き換えられた → `EXIT:4`）。1 行目が `init` でない記録は監査の不備として扱う。

## [0.1.7] - Cloudflare Workers + vinext の構成の生成物があっても確認の結果を記録する / Record checks with Cloudflare Workers + vinext generated output

### 直したこと / Fixed
- `chk-run.sh` が、Cloudflare Workers + vinext（Next.js 互換の Vite の枠組み）の構成で、確認コマンド（型の生成・lint・テスト・ビルド）が
  全部通っても記録を残さなかった（標準エラーに「検証中に入力が変化したため記録しない」と出て終了コード 1。レビューは親の記録を使い回せず
  `no-record`）。確認コマンドが回すたびに書き直す次のもの（どれも git が無視している）を、入力と数えていたため:
  `.cloudflare/`（Workers 向けのビルドの出力と型の生成）・`.vinext/`（枠組みのキャッシュ）・作業ツリー直下の `next-env.d.ts`・
  `node_modules/.vitest-cache/`（テストのキャッシュ。キャッシュを切っても書く）・`node_modules/.mf/`（Workers の実行環境のまねをする道具のキャッシュ）。
  これらと `node_modules/.vite/`・`node_modules/.cache/` を、生成物の定義（`lanes/_common.sh`。`chk-run.sh` と `cleanup-after-merge.sh` が使う 1 か所）に足した。
  `node_modules/` の中は道具のキャッシュのフォルダだけで、パッケージの中身・`package.json`・`.package-lock.json` などは今までどおり入力。
  `next-env.d.ts` は作業ツリー直下のその名前だけ（語尾の一致ではない。下の階層の `next-env.d.ts` やほかの `*.d.ts` は入力のまま。
  定義に作業ツリー直下のファイル名そのものの一覧 `LANES_GENERATED_FILES` を足した）。どれも作業ツリー直下だけで、パッケージ配下
  （`apps/web/node_modules/.vite/` など）とサブモジュールの中は入力のまま。
  使い回す条件は緩めていない: 生成物として外すのは git が無視しているものだけで（追跡しているもの・無視されていない未追跡のものは、
  この場所にあっても入力）、生成物の中身は今までどおり生成物の指紋に入り、使い回すとき（`skip=same-tree`・`--query` の `reuse=yes`）は
  記録のときと同じであることを求める。
  `cleanup-after-merge.sh` も同じ定義を使う。今までは `.cloudflare/`・`.vinext/`・`next-env.d.ts` を知らない物として後片付けを止めていた（exit 4）。
  `.cloudflare/` と作業ツリー直下の `next-env.d.ts` は、`dist/` と同じく linked worktree では退避して続け（ビルドの出力が千件を超えても止まらない）、
  本体 checkout では触らない。`.vinext/` は `.next/` と同じく退避せずに worktree ごと消す（パッケージ配下も）。`node_modules/` の中のキャッシュは
  今までどおり退避せずに消す。
  **上げた後は、`chk-run.sh` を 1 回通し直す。** `chk-run.sh` と `_common.sh` の中身が変わったので（どちらも入力の指紋に入る）、前の版で残した
  確認済みの記録は 1 回だけ使えなくなる（レビューの問い合わせは `input-changed`）。
  With a Cloudflare Workers + vinext (a Vite-based, Next.js-compatible framework) setup, `chk-run.sh` refused to record a passing check
  ("inputs changed during the check", exit 1) because the check command rewrites git-ignored files on every run: `.cloudflare/`
  (Workers build output and generated types), `.vinext/` (framework cache), `next-env.d.ts` at the worktree root,
  `node_modules/.vitest-cache/` (written even with `--no-cache`) and `node_modules/.mf/`. These, plus `node_modules/.vite/` and
  `node_modules/.cache/`, are now part of the shared generated-output definition in `lanes/_common.sh` (new list `LANES_GENERATED_FILES`
  for exact file names at the worktree root). Other `node_modules/` content, nested `next-env.d.ts` files, package-level directories
  (such as `apps/web/node_modules/.vite/`) and submodules are still inputs. Reuse is not relaxed: only git-ignored files are treated as
  generated (tracked and non-ignored untracked files stay inputs), and their content must still match the record.
  `cleanup-after-merge.sh` uses the same definition: `.cloudflare/` and the root `next-env.d.ts` are archived like `dist/` in linked
  worktrees (left untouched in the main checkout), and `.vinext/` is deleted with the worktree like `.next/`, instead of stopping the cleanup (exit 4).
  After upgrading, run `chk-run.sh` once again: records made by the previous version no longer match (`input-changed`) because
  `chk-run.sh` and `_common.sh` changed.

## [0.1.6] - 生成物の中のリンクがあっても確認の結果を記録する / Record checks when generated output contains symlinks

### 直したこと / Fixed
- `chk-run.sh` が、生成物（`dist/`・`.next/` などの中）にリンクが 1 本でもあると、行き先に関係なく「通ったが記録しない」
  （`record=no reason=unresolvable（生成物がリンクか、普通のファイルでない）`）にしていた。ビルドが出力の中に依存へのリンクを作る構成
  （例: `.next/node_modules/<名前>` → `../../node_modules/<名前>`）では、確認が毎回通っても記録が一度も残らず、レビューが親の記録を
  使い回せなかった（`no-record`）。生成物の中のリンクを、入力のリンクと同じ基準で扱うようにした: 作業ツリーの中を指すなら、
  向き先と行き先の中身を生成物の指紋に入れて記録する。作業ツリーの外（か `.git` の中）を指す・行き先が無い・行き先が普通のファイルでも
  フォルダでもないリンクは、今までどおり記録しない（理由にどのリンクかを出す）。使い回す条件は緩めていない。
  **この版に上げた後は、`chk-run.sh` を 1 回通し直す。** `chk-run.sh` の中身が変わったので（入力の指紋に入る）、前の版で残した
  確認済みの記録は 1 回だけ使えなくなる（レビューの問い合わせは `input-changed`）。
  `chk-run.sh` no longer refuses to record a passing check just because a generated directory (`dist/`, `.next/`, ...) contains a
  symlink. Symlinks inside generated output are now treated like symlinks in inputs: if the target is inside the worktree, the link
  target and its content go into the generated fingerprint and the result is recorded; links pointing outside the worktree (or into
  `.git`) and dangling links still prevent recording, and the reason names the link.
  After upgrading, run `chk-run.sh` once again: records made by the previous version no longer match (`input-changed`) because
  `chk-run.sh` itself changed.

## [0.1.5] - 確認の記録を使えないレビューを起動の前に止める / Stop reviews that cannot reuse the check record

### 足したこと / Added
- 設定キー `LANES_REVIEW_REQUIRE_CHECKS`（既定 `0` = 今までどおり）を足した。`1` にすると、レビューランチャ（`run-review.sh` /
  `run-codex-review.sh` / `run-claude-review.sh`）は、親の `chk-run.sh` の記録を使えないと分かったとき（`no-record` /
  `uncommitted` / `input-changed`）、レビューの子を起動せずに止める（`EXIT:2`。`.done` に `note=起動前の誤り` として理由と直し方が残る）。
  確認コマンドが未設定の案件・`LANES_REVIEW_REUSE_CHECKS=0` のときは止めない。`chk-run.sh` が通っても `record=no` になる構成は、
  記録が無いので `no-record` として止まる（`record=no` の理由を先に直す）。その起動だけ記録なしで回すなら
  `--allow-missing-checks`（証跡に残る）。この値は `chk-run.sh` の入力の指紋に入らない（起動のときだけ環境変数で渡しても記録は合う）。
  記録が無いまま起動したレビューは、読み取り専用の閉じ込めの中で必須検証を回せず、「必須検証が未完了」の指摘で終わることが多い。
  この指摘は直しのレーンでは直せないので、周回だけが増えていた。`chk-run.sh` を必ず通す運用なら `1` を勧める。
  **この版に上げた後は、`chk-run.sh` を 1 回通し直す。** `chk-run.sh` の中身が変わったので（入力の指紋に入る）、前の版で残した
  確認済みの記録は 1 回だけ使えなくなる（レビューの問い合わせは `input-changed`。`1` にしていれば、通し直すまで止まる）。
  New config key `LANES_REVIEW_REQUIRE_CHECKS` (default `0`, unchanged behavior). With `1`, review launchers stop before starting the
  reviewer (`EXIT:2`, reason and fix recorded in `.done`) when the parent `chk-run.sh` record cannot be reused (`no-record` /
  `uncommitted` / `input-changed`). Use `--allow-missing-checks` to run a single review without a record.
  After upgrading, run `chk-run.sh` once again: records made by the previous version no longer match (`input-changed`) because
  `chk-run.sh` itself changed.

## [0.1.4] - モデルと effort を記録に残す / Record the model and effort of each lane

### 足したこと / Added
- ランチャが、そのレーンで CLI に渡す設定のモデルと effort を記録に残すようにした。`logs/<label>.pid` に `model=` / `effort=` の行
  （空は、引数を付けずに CLI の既定に任せるという意味。起動の直後に書くので、CLI を起動する前に止まったレーンにも残る）、証跡 `logs/<label>.evidence.md` に「モデル: … / effort …」の行が入る
  （Gemini 実装の証跡には前からあり、Claude 実装・Codex 実装・Codex レビュー・Claude レビュー・QA を同じ形に揃えた）。
  起動ごとに effort やモデルを変えて試したとき、どの設定で回したレーンかを後から集計して比べられる。
  `.pid` を読む側（`lanes-status.sh`・監視）は行の名前で拾うので、動きは変わらない。
  起動ごとに effort を変える設定の書き方を `docs/config.md` に足した。
  Launchers now record the model and effort configured for the lane: `model=` / `effort=` lines in `logs/<label>.pid`
  (empty means the flag is omitted and the CLI default is used; written at launch, so it is also present for lanes that stopped before starting the CLI) and a "モデル: … / effort …" line in `logs/<label>.evidence.md`.
  This lets you compare lanes run with different settings afterwards. Readers of `.pid` look fields up by name, so behavior is unchanged.

## [0.1.3] - detach-run.sh 経由でも記録を使い回す直し / Reuse records through detach-run.sh

### 直したこと / Fixed
- `detach-run.sh` 経由で起動したレビューが、`python3` の入口が環境変数を書き換える Mac で、親の `chk-run.sh` の記録を使い回さなかった
  （証跡が毎回 `input-changed`。0.1.2 の直しが、こうした Mac の普段のシェルからの起動では効いていなかった）。
  Mac の `python3` は、本物の前に入口を通ることが多い（Xcode の `/usr/bin/python3`・pyenv の shims など）。入口は、本物を起動する前に
  環境変数を書き換える（Xcode: `MANPATH` の先頭へ通るたびに足す・`SDKROOT` などを足す / pyenv: `PYENV_DIR` に最初に通った場所を入れる・
  `PATH` の先頭に本物の場所を足す）。`detach-run.sh` は切り離しに `python3` を使い、そこから見えた環境変数をそのまま起動するコマンドへ
  渡していたので、起動したランチャだけが呼び出し元と違う環境で動き、入力の指紋（環境変数が入る）が `chk-run.sh` を回したときと合わなかった。
  `detach-run.sh` は、呼び出し元のシェルの環境変数をそのまま起動するコマンドへ渡すようにした（`python3` の入口や `python3` 自身が
  足した・書き換えた分は渡さない。挟まずに起動したときと同じ環境で動く。値はパイプで渡し、ファイルにも引数にも書かない）。
  使い回す条件（入力の指紋）は緩めていない。
  この不具合は、テストの結果も回す場所で変えていた: `lanes/tests/test-review-reuse-launch.sh` は、入口を一度通った後の環境
  （レーンの中・`chk-run.sh` の確認コマンドの中）から回すと緑、普段のシェルから回すと赤だった（pyenv は一度通ると `PATH` の先頭が
  本物になり、そこから先は入口を通らないので、赤が隠れた）。テストに、通るたびに環境変数を書き換える偽の `python3` の入口を
  PATH の先頭に置いた確認（どの Mac でも、直す前は赤・直した後は緑）と、同じ確認をそのまま回しても `chk-run.sh` の確認コマンドの
  中から回しても同じ結果になる確認を足した。
  Reviews launched through `detach-run.sh` never reused the parent's `chk-run.sh` record (`input-changed` every time) on Macs whose `python3`
  launcher rewrites environment variables, so the 0.1.2 fix did not take effect when launching from a plain shell on such Macs.
  On macOS, `python3` usually goes through a launcher before the real interpreter (Xcode's `/usr/bin/python3`, pyenv shims, and so on), and
  the launcher rewrites the environment first (Xcode prepends to `MANPATH` on every pass and adds `SDKROOT` and others; pyenv stores the
  directory of the first pass in `PYENV_DIR` and prepends the real interpreter's directory to `PATH`). `detach-run.sh` detaches with `python3`
  and passed the environment seen there to the launched command, so only the launched launcher ran in an environment different from its
  caller, and the input fingerprint (which includes environment variables) no longer matched the one recorded by `chk-run.sh`.
  `detach-run.sh` now passes the calling shell's environment to the launched command unchanged (nothing added or rewritten by the `python3`
  launcher or by `python3` itself is passed on; the command runs in the same environment as when launched without `detach-run.sh`; values travel
  through a pipe and are never written to a file or an argument). The reuse conditions (the input fingerprint) are unchanged.
  The bug also made a test result depend on where it ran: `lanes/tests/test-review-reuse-launch.sh` passed in an environment that had already
  gone through the launcher once (inside a lane, or inside the `chk-run.sh` check command) and failed from a plain shell (with pyenv, the first
  pass puts the real interpreter first in `PATH`, so later calls skip the launcher and hide the failure). The test now puts a fake `python3`
  launcher that rewrites the environment on every pass first in `PATH` (red before the fix and green after it on any Mac), and verifies that
  the same check gives the same result when run directly and when run inside the `chk-run.sh` check command.

## [0.1.2] - レビューで手元確認の記録を使い回す直し / Reuse check records in reviews

### 直したこと / Fixed
- `chk-run.sh` が成功を記録した直後に `detach-run.sh` 経由でレビューを起動すると、証跡が毎回「親の chk-run の記録は使わない: input-changed」になり、
  必須検証の使い回しが効かなかった。`detach-run.sh` が起動ログ（`<worktree>/logs/launch.log`）をランチャの問い合わせより先に書き、
  その無視対象のファイルが入力の指紋に入っていたため（dry-run や手での問い合わせでは再現しない）。
  ランチャの記録を入力の指紋に入れないようにした。名前が記録に似ているだけでは外さない: ランチャと `detach-run.sh` が、`logs/` に書く前に
  書く名前の持ち主を台帳（`logs/.lanes-records`。`label:<label>` か `file:<名前>` の行）へ載せ、`chk-run.sh` は台帳に載っている持ち主の
  決まった名前のファイル（`<label>.pid`・`.done`・`.log`・`.json`・`.prompt.md`・`.evidence.md`・起動ログなど。git が無視している普通のファイル）だけを外す。
  台帳に無い名前のファイル（確認コマンドが読む `logs/input.json` など）、`logs/` の中のフォルダ、リンク、追跡しているファイルは今までどおり入力として
  照合する（中身を変えれば、古い成功の記録を使い回さずに回し直す）。レビューの後に `chk-run.sh` を呼び直しても、同じ確認を省く（`skip=same-tree`）。
  この版より前のランチャが書いた記録は台帳に無いので入力として数える（同じ label を起動し直すと台帳に載る）。
  台帳が symlink・ハードリンク・FIFO（名前付きパイプ）など、普通のファイルでないときは、ランチャは書かず、`chk-run.sh` も使わない
  （どちらも待たずに開いてから種別を確かめるので、台帳が FIFO でも `chk-run.sh`・レビューの起動は止まらない）。
  Reviews launched through `detach-run.sh` right after a successful `chk-run.sh` never reused the parent's check record
  (`input-changed`), because `detach-run.sh` wrote the launch log (`<worktree>/logs/launch.log`) before the launcher queried the record,
  and that git-ignored file was part of the input fingerprint. Launcher records are no longer part of the fingerprint. A record-like name is not enough:
  launchers and `detach-run.sh` register the owner of what they write in a ledger (`logs/.lanes-records`, lines of `label:<label>` or `file:<name>`)
  before writing, and `chk-run.sh` only skips the well-known file names of registered owners (`<label>.pid`, `.done`, `.log`, `.json`, `.prompt.md`,
  `.evidence.md`, launch logs, and so on; git-ignored regular files). Unregistered names (for example a `logs/input.json` read by the check command),
  subdirectories, links, and tracked files under `logs/` are still fingerprinted, so changing them re-runs the check instead of reusing an old success.
  Records written by launchers older than this version are not in the ledger and count as input until the same label is launched again.
  If the ledger is a symlink, a hard link, or not a regular file (for example a FIFO), launchers do not write to it and `chk-run.sh` ignores it;
  both open it without blocking and check the file type afterwards, so a FIFO ledger cannot make `chk-run.sh` or a review launch hang.
- `detach-run.sh` が、起動ログのパスに FIFO（名前付きパイプ）があると、読み手が現れるまで待ち続けた（読み手がいれば、起動したコマンドの出力が
  その先へ流れた）。ハードリンクのときは、追記が別の名前のファイルにも届いた。起動ログは待たずに開いてから種別を確かめ、普通のファイル
  （ハードリンクでないもの）か `/dev/null` のような文字デバイスでなければ、書かずに exit 2 で止め、コマンドを起動しないようにした
  （symlink を辿らないのは今までどおり）。
  `detach-run.sh` waited forever when the launch log path was a FIFO with no reader (with a reader, the launched command's output went into it),
  and appended through a hard link into the file's other name. The launch log is now opened without blocking and its type is checked afterwards:
  unless it is a regular file with a single link or a character device such as `/dev/null`, nothing is written, the command is not started,
  and the script exits with status 2 (symlinks are still not followed).
- `chk-run.sh` が、確認コマンドは通ったのに結果を記録しないとき（未 commit の変更がある・確認コマンドや依存を確実に照合できない）、何も出さずに終わっていた。
  そのためレビューの証跡が `no-record` になる理由が分からなかった（`.lanes/check.sh` に `exec zsh -f …` と書いただけで起きる。`exec` は
  「引数のコマンドを起動する包み」なので、仕様どおり記録しない）。`record=no reason=<uncommitted|unresolvable>（理由）` の行を出すようにした。
  説明には原因になったファイルや書き方が出る（例: `確認コマンド（.lanes/check.sh）の「exec」`）。記録する・しないの条件は変えていない。
  `chk-run.sh` printed nothing when the check command passed but the result was not recorded (uncommitted changes, or a check command or dependency
  that cannot be fingerprinted reliably), so it was unclear why review evidence said `no-record` (writing `exec zsh -f …` in `.lanes/check.sh` is enough:
  `exec` is a wrapper that launches its argument, so by design the result is not recorded). It now prints
  `record=no reason=<uncommitted|unresolvable>` with an explanation naming the file or construct. The conditions for recording are unchanged.
- `cleanup-after-merge.sh` が、`chk-run.sh` のビルドが残した無視対象の `dist/` で止まった（`EXIT:4`）。git が無視している生成物
  （作業ツリー直下の `dist/` `build/` `out/` の中など）は、残骸と同じく退避してから後片付けを続けるようにした（本体 checkout の生成物は退避も削除もしない）。
  生成物の定義は `chk-run.sh` と共通の 1 か所（`lanes/_common.sh` の `LANES_GENERATED_DIRS` / `LANES_GENERATED_SUFFIXES`）にまとめた。
  git が無視していない未追跡ファイルや、知らない除外ファイルで止まる動きは変えていない。
  `cleanup-after-merge.sh` stopped (`EXIT:4`) on a git-ignored `dist/` left by the `chk-run.sh` build. Git-ignored build outputs
  (files under the worktree's top-level `dist/`, `build/`, `out/`, and so on) are now archived like other leftovers and the cleanup continues
  (in the main checkout they are left in place). The definition of build outputs is shared with `chk-run.sh` in one place
  (`LANES_GENERATED_DIRS` / `LANES_GENERATED_SUFFIXES` in `lanes/_common.sh`). Untracked files that are not ignored, and unknown ignored files, still stop the cleanup.
- 必須検証を使い回さなかったレビューの証跡が、回せていなくても「レビューの中で実施」と書いていた。「レビューの中で回すよう指示」に直し、
  使わなかった理由に一言の説明を足した（回せたかどうかは「必須検証の成功確認」の行が示す）。
  Review evidence no longer claims the required checks were "performed in the review" when they were only requested;
  it now says they were requested and adds a short explanation of why the parent's record was not reused.

### 変えたこと / Changed
- 起動元のシェルが `CLAUDE_EFFORT`・`CODEX_EFFORT`・`GEMINI_EFFORT` を環境変数として持っていて、設定ファイル（無ければ既定）と違う値で勝っているとき、
  ランチャが起動時に注意を 1 行出すようにした（`lanes-doctor.sh` でも出る）。勝つ順番（環境変数 > 設定ファイル > 既定）と、CLI に渡す値は変えていない。
  設定ファイルの値に固定する書き方（`CLAUDE_EFFORT="xhigh"` と値をそのまま書く）を `lanes.conf.example` と `docs/config.md` に書いた。
  When the launching shell has `CLAUDE_EFFORT`, `CODEX_EFFORT`, or `GEMINI_EFFORT` set as an environment variable and it overrides a different value
  from the config file (or the default), the launcher now prints a one-line notice at startup (`lanes-doctor.sh` shows it too).
  Precedence (environment variable > config file > default) and the value passed to the CLI are unchanged.
  `lanes.conf.example` and `docs/config.md` describe how to pin the config value (write the value literally, e.g. `CLAUDE_EFFORT="xhigh"`).
- Codex レビューの `--dry-run` の表示に、必須検証を使い回すかどうか（`必須検証の使い回し: yes / no / off`）を出すようにした（Claude レビューと同じ）。
  The Codex review `--dry-run` output now shows whether the parent's check record will be reused, like the Claude review.

## [0.1.1] - chk-run の記録の直し / chk-run record fix

### 直したこと / Fixed
- `chk-run.sh` が npm の作業ツリーで成功を一度も記録しなかった。`node_modules/.bin/*` のシンボリックリンクを見て、毎回「使い回し不可」と判断していたため。
  リンクの実体が作業ツリーの中にあれば、リンク先の中身をハッシュしたうえで記録・使い回しを続けるようにした。作業ツリーの外を指すリンクや行き先の無いリンクは、今までどおり記録しない。
  `chk-run.sh` never recorded a successful run in npm worktrees, because the symlinks in `node_modules/.bin/*` disabled reuse. Symlinks that resolve inside the worktree no longer disable reuse (their targets are still hashed). Symlinks pointing outside the worktree, and dangling ones, still disable it.

## [0.1.0] - 最初の公開 / Initial release

### 追加 / Added
- レーンのランチャ（`lanes/`）: Claude・Codex・Gemini（Antigravity CLI `agy`）の実装とレビューを、1 作業 = 1 worktree = 1 ランチャで並列に回す。
  入口は `run-impl.sh`（実装）と `run-review.sh`（レビュー）。構成（`LANES_TOOLS`）に合わせて振り分ける（4 構成: `full` / `claude-codex` / `claude-gemini` / `claude-only`）。
  Lane launchers for running Claude, Codex, and Gemini implementation and review in parallel (one task = one worktree = one launcher), routed by the tool profile.
- 生死の記録と見張り: `logs/<label>.{pid,done}`、`lanes-status.sh`（RUNNING / STALLED / DONE / FAILED / DEAD）、`lanes-watch.sh`（5 分ごとの見回りと `WAKE:` 通知）。
  Liveness records and monitoring.
- レビューの合否の厳格な判定（最終行の `VERDICT:`。途中で切れた出力や曖昧な文は CLEAN にしない）と、同じ確認を繰り返さない仕組み（`--mode auto` の差分レビュー、round 3 以降の P2/P3 の後回し）。
  Strict review verdicts and de-duplication of repeated reviews.
- 安全策: サブスクでのログインの点検（API キーでの起動を止める）、MCP の遮断、同じ label の排他、レビューと QA の読み取り専用（前後の比較・push の遮断）、
  git の制御ファイルの指紋比較、`logs/` や作業場所の symlink・ハードリンクを辿らない書き込み。
  Safety measures: subscription-login checks, MCP blocking, per-label locking, read-only reviews, git control-file fingerprinting, and writes that never follow symlinks or hard links.
- 同じ確認を繰り返さない仕組み: レビューは親の確認済みの記録（`chk-run.sh --query`）を使い回す（`LANES_REVIEW_REUSE_CHECKS`）。Claude レビューも差分の自動切り替え（`--mode auto`）。
  Reviews reuse the parent's recorded check results, and Claude reviews also switch to delta mode automatically.
- 司令塔の見張り: 定期の確認の間隔（`LANES_CHECK_INTERVAL_MIN`、既定 10 分）、見張りが終わるときの `RE-ARM:` 行、かけ直し忘れを止める Claude Code の Stop フック（`lanes/hooks/claude-stop-watch-guard.sh`）。
  Commander watch: configurable check interval (default 10 minutes), a `RE-ARM:` line when the watcher exits, and a Claude Code Stop hook that prevents finishing a reply without the watcher.
- 適度に締める仕組み: レビューの周回の上限（`LANES_REVIEW_MAX_ROUNDS`、既定 5。超えたら `GATE: ESCALATE` で人に返す）、受け入れ済みの限界（`.lanes/accepted-limitations.md` をレビューの指示書に必ず入れる）、締め切り前の機能の凍結（運用ルール）。
  Wrap-up controls: a review round limit (`GATE: ESCALATE`), accepted limitations fed into every review prompt, and a feature freeze rule before release.
- 起動前の点検（`lanes-doctor.sh`）、導入（`install.sh`。`--dry-run` / `--uninstall`）、自己テスト（`selftest.sh`。偽の CLI で 4 構成を回す）。
  Pre-flight checks, installer, and self-test.
- 汎用のスキル 6 本（`skills/`。開発の流れの `dev-loop` を含む）、運用ルールのひな形（`templates/`）、日本語と英語の手順書。
  Six generic skills (including the `dev-loop` development flow), operating-rule templates, and Japanese/English documentation.
