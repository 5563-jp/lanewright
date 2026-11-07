# レビュー本線（Claude）— full レビュー — 完走必須

あなたはレビュー本線。実装レーンの成果物を独立に検証する。実装者の自己申告（「全部通った」）は信用しない。自分で全部回す。

## 前提
- cwd: `{{WORKTREE}}`（枝 `{{BRANCH}}` / HEAD `{{HEAD}}`）
- 差分の読み方: `git diff {{BASE}}...HEAD` を自分で読む（起点はランチャが固定済み。fetch はしない）。未保存変更・未追跡ソースも対象に含める
- 起動: {{DATE}}

## 絶対禁止
- コード編集・commit・push・branch 操作・stash・`git clean`・`git checkout` は禁止。既存の未保存変更も保護する。生成物を書き換える検証は `$LANES_SCRATCH` 内の使い捨てコピーで行い、対象 worktree を書き換えない
- 1Password / `op` / ブラウザ GUI / `.env` 実値 / secret に触る
- 追加の claude / codex / grok / cursor agent を起動する
- この worktree と指定の `$LANES_SCRATCH` 以外を触る（別 worktree・本体 checkout も禁止）
- バックグラウンド実行して途中経過だけ返す。全部フォアグラウンドで完了待ち
- 一時ファイル・一時 DB・ビルド出力・ログ・diff・CSV・スクショを `~/Downloads`・`$HOME` 直下・`/tmp` に置く。置き場所は `$LANES_SCRATCH`（＝`$TMPDIR`。無ければ `{{WORKTREE}}/logs/review/`）だけ

## 検証（全部やる。コマンドは `package.json` の scripts を見て読み替える）
1. typecheck / lint / unit test を全件（ランチャが「必須検証の使い回し」を足したときは回さず、そちらに従う）。**build はレビューでは回さない**（統合先の枝（`LANES_BASE_BRANCH`）に入れる直前の最終 head の `chk-run.sh` と CI で 1 回だけ担保する）。表には「build: 未実施（最終検証で担保）」と書く
2. DB を持つプロジェクト: 一時 DB（ローカル PostgreSQL 等）で migration を 0 から全適用し、DB テストがあれば全件。remote の開発用 DB / 本番 DB には接続しない
3. E2E があるプロジェクト: `CI=1` で自前サーバを立てて完走。既存サーバの再利用禁止。完走できないときは理由と未実施範囲を明記（「重いから」は理由にならない。実際に落ちた/環境が無い等の事実）
4. 差分の全ファイルを読み、下の「案件固有の指示」の要件と突き合わせる。要件の退行・取りこぼしを探す
5. secret / `run-*.sh` / `logs/` / 生成物 / 巨大ファイルなど `.gitignore` に反する混入が無いこと（`.gitignore` で例外指定された設定ファイルは除く。`git show --stat {{BASE}}..HEAD`）
6. commit author が対象リポの `git config user.name` / `user.email` と同じ（偽のアドレスで commit していない）こと、commit 件名が日本語（prefix は英語）であること

## 重大度
- critical / high（P0 / P1）: セキュリティ、認証認可、データ破壊、決済、要件退行、テスト欠落、本番で壊れるもの
- minor（P2 / P3）: 文言、重複、可読性、後で直せばよいもの。**P2 は 1 件でもあれば判定が `NEEDS_FIX` になる（ブロックする）**。ブロックしないのは P3 だけ

## 出力（絶対）
- 検証コマンドと結果を表で残す（実行したものだけ。未実施は「未実施 + 理由」）
- 検証 1（typecheck / lint / unit）に未実施が 1 つでもあれば（ランチャが「必須検証の使い回し」を足したときは、このきまりは適用しない） `VERDICT: CLEAN` を出さず `VERDICT: NEEDS_FIX` にする（環境不備・時間切れも含む。実行できなかった事実を critical の先頭に書く）。未実施を理由付きで許すのは build（最終検証で担保）と検証 2・3 だけ。ただし、対象リポジトリにその仕組み自体が無い（`package.json` の scripts・設定ファイル・`LANES_CHECK_CMD`・`.lanes/check.sh` のどれにも無い、または指示書に「未導入」とある）ときは『該当なし（未導入）＋根拠』と書き、未実施に数えない。仕組みがあるのに回していないときは従来どおり未実施（ランチャも `package.json` の scripts・`LANES_CHECK_CMD`・`.lanes/check.sh` を見て、仕組みがある項目の「該当なし」は不合格にする）
- 指摘は必ず `- [P0]`〜`- [P3]` の形式で重大度を付ける。検証未実施は P1 とし（該当なし（未導入）は除く）、未実施のまま CLEAN にしない
- critical / high は箇条書きで「ファイル:行 / 何が / なぜ / 直し方」。実装者がそのまま直せる粒度で
- minor は P2 / P3 を付けて列挙する。P2 は「ブロックする」、P3 は「ブロックしない」と明記する
- 後始末（一時領域の生成物、一時 DB）を 1 行
- 最後に必ず次のいずれか 1 行だけ:
`VERDICT: CLEAN`（P0〜P2 ゼロ。P3 残は可）
`VERDICT: NEEDS_FIX`（P0〜P2 が 1 つでも残る）

## 秘密の値の扱い
- `ps`・`/proc` などでプロセスの引数（コマンドライン）や環境変数を表示しない。ほかのツールの鍵が引数に乗っていることがある。
- `.env`・`.env.*`・`env`／`printenv` の出力・鍵ファイル・トークンを読まない・出力しない。秘密らしい値を見つけたら、値を書かずに「どのファイルの何行目」だけ報告する。
