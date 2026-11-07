# レビュー本線（Claude）— delta 再レビュー — 完走必須

前回 `VERDICT: CLEAN` を出した SHA `{{BASE}}` 以降の差分だけを見る再レビュー。軽微（minor）修正の確認用。critical / high の修正後は full で回すので、ここでは差分外を掘り返さない。

## 前提
- cwd: `{{WORKTREE}}`（枝 `{{BRANCH}}` / HEAD `{{HEAD}}` / 前回 CLEAN `{{BASE}}`）
- 対象差分: `git diff {{BASE}}...HEAD` を自分で読む。統合先の枝（`LANES_BASE_BRANCH`）全体の再レビューはしない
- 起動: {{DATE}}

## 絶対禁止（full と同じ）
- コード編集・commit・push・branch 操作・stash・`git clean`・`git checkout` は禁止。既存の未保存変更も保護する。生成物を書き換える検証は `$LANES_SCRATCH` 内の使い捨てコピーで行い、対象 worktree を書き換えない
- 1Password / `op` / ブラウザ GUI / `.env` 実値 / secret に触る
- 追加の claude / codex / grok / cursor agent を起動する
- この worktree と指定の `$LANES_SCRATCH` 以外を触る
- バックグラウンド実行。全部フォアグラウンド
- 一時ファイル・一時 DB・ビルド出力・ログ・diff・CSV・スクショを `~/Downloads`・`$HOME` 直下・`/tmp` に置く。置き場所は `$LANES_SCRATCH`（＝`$TMPDIR`。無ければ `{{WORKTREE}}/logs/review/`）だけ

## 自動エスカレーション
差分が次のどれかに触れていたら delta をやめ、full と同じ全検証（typecheck / lint / unit 全件 / 一時 DB / E2E。build は full でも回さない）を回し、その旨を出力の最初に書く:
auth / authz / RLS / JWT / migration / DB スキーマ / 決済 / ポイント / メール送信 / webhook / cron / 外部 API 呼び出し / E2E 制御 / CI・workflow 設定 / 環境変数

## 検証
- remote の開発用 DB / 本番 DB には接続しない。一時 DB は `$LANES_SCRATCH` 内だけ
1. typecheck / lint は必ず全体（ランチャが「必須検証の使い回し」を足したときは 1・2 を回さず、そちらに従う）
2. unit は差分に関係するテストファイルだけ（例: `vitest run <path>`）。判断に迷えば全件
3. build はレビューでは回さない（統合先の枝（`LANES_BASE_BRANCH`）に入れる直前の最終 head の `chk-run.sh` と CI で 1 回だけ担保する）。表には「build: 未実施（最終検証で担保）」と書く
4. E2E は差分が画面・API に触れたときだけ該当 spec を回す
5. 差分の全ファイルを読み、前回指摘（案件固有の指示に書いてある）が意図どおり直っているか、新しい退行が無いかを見る
6. secret / `run-*.sh` / `logs/` / 生成物の混入なし
7. `git log --format='%an <%ae> %s' {{BASE}}..HEAD` で、前回 CLEAN 以降の commit author が対象リポの `git config user.name` / `user.email` と同じ（偽のアドレスで commit していない）こと、commit 件名が日本語（prefix は英語）であること

## 出力（絶対）
- 最初に「delta のまま」か「full にエスカレーション」かを 1 行
- 検証コマンドと結果を表で（未実施は「未実施 + 理由」）
- 検証 1（typecheck / lint 全体）と、実施条件に当たった unit に未実施があれば（ランチャが「必須検証の使い回し」を足したときは、このきまりは適用しない） `VERDICT: CLEAN` を出さず `VERDICT: NEEDS_FIX` にする（環境不備・時間切れも含む。実行できなかった事実を critical の先頭に書く）。ただし、対象リポジトリにその仕組み自体が無い（`package.json` の scripts・設定ファイル・`LANES_CHECK_CMD`・`.lanes/check.sh` のどれにも無い、または指示書に「未導入」とある）ときは『該当なし（未導入）＋根拠』と書き、未実施に数えない。仕組みがあるのに回していないときは従来どおり未実施（ランチャも `package.json` の scripts・`LANES_CHECK_CMD`・`.lanes/check.sh` を見て、仕組みがある項目の「該当なし」は不合格にする）
- 指摘は必ず `- [P0]`〜`- [P3]` の形式で重大度を付ける。検証未実施は P1 とし（該当なし（未導入）は除く）、未実施のまま CLEAN にしない
- critical / high は「ファイル:行 / 何が / なぜ / 直し方」
- minor は P2 / P3 を付けて列挙する。**P2 は 1 件でもあれば判定が `NEEDS_FIX` になる（ブロックする）**ので「ブロックする」、P3 は「ブロックしない」と明記する
- 最後に必ず次のいずれか 1 行だけ:
`VERDICT: CLEAN`
`VERDICT: NEEDS_FIX`

## 秘密の値の扱い
- `ps`・`/proc` などでプロセスの引数（コマンドライン）や環境変数を表示しない。ほかのツールの鍵が引数に乗っていることがある。
- `.env`・`.env.*`・`env`／`printenv` の出力・鍵ファイル・トークンを読まない・出力しない。秘密らしい値を見つけたら、値を書かずに「どのファイルの何行目」だけ報告する。
