# 役割の割り振り（4 つの構成）

設定の `LANES_TOOLS`（使える道具）から、キットが構成を 1 つに決めて、実装とレビューを誰がやるかを割り振ります。
決めているのは `lanes/lanes-roles.sh` で、`zsh <kit>/lanes/lanes-roles.sh --print` で今の割り振りを見られます。
入口の `run-impl.sh`（実装）と `run-review.sh`（レビュー）は、この割り振りに合うランチャへ自動で振り分けます。

## 役割表

| 構成 | `LANES_TOOLS` | 実装 | レビュー | レビューの独立性 |
|---|---|---|---|---|
| ① `full` | `claude codex gemini` | Claude が主、軽い作業を Gemini（下の「分け方」） | Codex | 強い（別の会社の別の道具） |
| ② `claude-codex` | `claude codex` | Claude | Codex | 強い |
| ③ `claude-gemini` | `claude gemini` | Claude が主、軽い作業を Gemini | Claude（別セッション・読み取り専用） | **弱い** |
| ④ `claude-only` | `claude` | Claude | Claude（同上） | **弱い** |

- Claude は必須です（実装の主力で、③④ではレビューも担います）。
- Gemini（Antigravity CLI `agy`）の主な役は軽い実装です。
  `run-impl.sh ... --engine gemini --verify "<検証コマンド>" --allow-path <相対パス>` のように、検証コマンドと保存してよいパスを必ず渡します。
- ①③では、レビューの一部を Gemini（`run-gemini-review.sh`・読み取り専用）に回すこともできます（`LANES_REVIEW_GEMINI_PCT` の割合か `--engine gemini`。
  既定は `0` で回しません）。**Gemini で実装したものは Gemini でレビューしません**（下の「レビュー役の振り分け」）。
- 割り振りの結果は変数で出ます: `LANES_PROFILE`（構成名）、`LANES_ROLE_IMPL`（`claude` か `claude gemini`）、
  `LANES_ROLE_REVIEW`（`codex` か `claude`。構成の既定のレビュー役で、割合の振り分けでは変わりません）、`LANES_REVIEW_INDEPENDENT`（独立したレビューなら `1`、そうでなければ `0`）。

## 入口と起動前点検

```sh
zsh <kit>/lanes/lanes-roles.sh --print   # 今の構成と割り振りを表示（--env なら KEY=value の形）
zsh <kit>/lanes/lanes-doctor.sh [<worktree>]   # 起動前点検。--quiet なら問題が無いとき何も出さない。worktree を渡すと logs/ が無視されているかも見る
zsh <kit>/lanes/run-impl.sh <worktree> <prompt.md> [label] [--engine claude|gemini] [--dry-run] \
    [gemini 用: --verify "<検証コマンド>" --allow-path <相対パス> ... --no-push]
zsh <kit>/lanes/run-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] \
    [--allow-missing-checks] [--engine codex|gemini|claude] [--impl-engine claude|gemini|codex] [--dry-run]
```

- `lanes-doctor.sh` は、構成に入っている道具が入っているか・サブスク（月額契約）でログインしているか（API キーでの起動になっていないか）を確かめ、
  足りないものを全部並べて exit 2 で止まります（揃っていれば 0）。Claude は `claude auth status`、Codex は `codex login status` で見ます。
  Gemini の `agy` にはログイン確認のコマンドが無いので、ログイン情報の置き場所 `~/.gemini/antigravity-cli` があるかどうかで見ます。
  Gemini を含む構成では、`run-gemini.sh` が必須にしている macOS の端末サンドボックス（`/usr/bin/sandbox-exec`）を有効にできるかも見ます。
  点検を飛ばす抜け道（テスト用の変数など）はありません。`run-impl.sh` / `run-review.sh` も起動前に `lanes-doctor.sh --quiet` を通し、
  個別のランチャ（`run-claude.sh` など）も自分が使う道具だけ同じ点検をします。
- 構成に無い道具のランチャを直接呼ぶと（例: ④で `run-codex-review.sh`）、起動せずに exit 2 で入口の名前を案内します。
- `run-impl.sh` / `run-review.sh` の終了コードは振り分け先のランチャのままです。入口自身の誤り（不明なオプションを含む引数・構成・点検）は exit 2 で止まります。

### レビューの入口（①② と ③④ で同じ）

`run-review.sh` は同じ引数で呼べ、①②（Codex レビュー）でも③④（Claude レビュー）でも、①③で Gemini に回したレビューでも、そのまま振り分け先へ渡します。
どのレビューも同じ仕組み（`lanes/review-dedup.zsh`）を使います。

| 引数 | ①②（Codex）・③④（Claude）・①③の Gemini |
|---|---|
| `--mode auto`（省略時） | 前回の結果から full / delta / 省略を自動で選ぶ（初回は full、前回 CLEAN・条件一致・未保存変更なしなら前回の HEAD からの delta、同じ HEAD なら前回の結果を使う。前回 NEEDS_FIX の後も前回の HEAD からの delta で未解決指摘を引き継ぐ。delta にできなければ full） |
| `--mode delta` | 前回レビューした HEAD からの差分（前回の記録が使えなければ full に戻す） |
| `--base <sha\|branch>` | commit に解決できるもの。full の比較起点と再利用の条件に使う |
| `--force` | 同じ head でもレビューし直す |
| `--round N` | round 3 以降の P2/P3 後回しの判定に使う（label 末尾の `-r<N>` でも可） |

| `--engine codex\|gemini\|claude` | レビュー役を明示する（構成に無い道具・知らない名前は exit 2）。下の「レビュー役の振り分け」 |
| `--impl-engine claude\|gemini\|codex` | 実装した道具のヒント（`gemini` なら Gemini でレビューしない） |

レビュー役（codex / claude / gemini）も再利用の条件に入るので、構成やレビュー役を変えたら前回の結果は使いません。
前回が `NEEDS_FIX` でも、役を変えた回は前回の HEAD からの差分ではなく全体を見ます（新しい役は元の変更を見ていないため。前回の指摘は引き継ぎます）。
読み取り専用の制限の設定（Codex の `CODEX_REVIEW_SANDBOX`、Claude の `CLAUDE_REVIEW_TOOLS` と `CLAUDE_REVIEW_DENY`、Gemini に渡す拒否の一覧）も条件に入り、変えたら同じ HEAD でもレビューし直します。
親が同じ中身で `chk-run.sh` を通した記録があれば、どちらのレビューでも必須検証（typecheck / lint / unit）をレビューの中で回させません
（`LANES_REVIEW_REUSE_CHECKS`。`lanes/README.md` の 6 章「必須検証の使い回し」）。何を確かめたことになるかは確認コマンドの中身次第です。

### レビュー役の振り分け（①③ の Gemini レビュー）

`run-review.sh` は、次の順で最初に当てはまるものをレビュー役にします（選んだ役と理由を標準エラーに `レビュー役: <役>（理由）→ <ランチャ>` の 1 行で出します）。

1. `--engine codex|gemini|claude` の明示。構成に無い道具・知らない名前は exit 2（今回の `.done` に残す）。
2. 同じ系列（label の末尾 `-r<N>` を外した名前）の前回のレビュー役。r2 以降も同じ役で続けるので、同じ head の結果の再利用と delta がそのまま効きます。
   前回の役は `logs/.<系列>.review-state` の `last_reviewer`（無い旧記録は、その記録の label の証跡の見出し `## Codex|Gemini|Claude レビュー証跡`、記録が無ければ `logs/<系列>-r<N>.evidence.md` の N が最大のものの見出し）から読みます。
   前回の役が今の構成に無いときは使いません。構成や割合を途中で変えた系列も、前回の役が今の構成にあればその役で続けます（変えるなら `--engine` か、新しい系列の label で）。
3. `LANES_REVIEW_GEMINI_PCT`（`0`〜`100`。既定 `0`）の割合で Gemini（構成に `gemini` があるときだけ）。`100` なら毎回 Gemini。
   `1`〜`99` は `${XDG_STATE_HOME:-~/.local/state}/lanewright/review-split.state` に誤差を積み上げて決めます（毎回 `acc` に割合を足し、100 以上になったら 100 を引いて Gemini）。
   `50` なら「既定の役・Gemini・既定の役・Gemini …」と厳密に交互です。記録は排他を取ってから書き、読めない・書けないときは既定の役に倒します。`--dry-run` は記録を進めません（次に選ぶ役を見せるだけ）。
   同じ worktree の同じ系列に前に割り当てた役があれば、それを引き継いで数え方を進めません（振り分け先の起動前の点検、たとえば必須検証の記録が無くて止まった系列を、直して呼び直しても別の役にならない）。
4. 構成の既定のレビュー役（`LANES_ROLE_REVIEW`。① Codex / ③ Claude）。

**同じ道具でのレビューの禁止**: Gemini で実装したものは Gemini でレビューしません。`--impl-engine gemini` か、`logs/` の `.pid` に Gemini の実装レーン（`lane=gemini`）が 1 つでもあれば Gemini で実装したとみなします
（どちらかに当たれば。`--impl-engine claude` でも `logs/` の記録は打ち消しません。迷ったら Gemini に回さない側に倒します）。
そのとき `--engine gemini` は exit 2、2 と 3 では Gemini を選ばず構成の既定の役へ逃がします。`run-gemini-review.sh` を直接呼んでも同じ判定（`--impl-engine` も受け付けます）で、前回の結果の再利用・起動より前に止まります（exit 2）。ほかの組み合わせ（③④ で Claude の実装を Claude がレビューする、など）は今までどおりです。

Gemini のレビュー（`run-gemini-review.sh`）は、Codex・Claude のレビューと同じ入口・同じ判定・同じ終了コードの決まりで動き、読み取り専用を次のように担保します:

- agy に `--sandbox`（端末サンドボックス）・`--settings`（起動ごとの設定）・`--mode plan` を必ず付け、`ANTIGRAVITY_HEADLESS=true` で起動します（`agy --help` にこの 3 つが無ければ起動しません）。
  設定の `permissions.deny` で MCP・ファイルを書く道具・サブエージェント・ブラウザ・Web の検索と取得・予約・ワークフローを拒否します（固定の一覧。`GEMINI_REVIEW_DENY` で足せますが外せません）。
- 実行の記録（stream-json）を監査し、禁止の道具か質問の道具（`ask_*`）が 1 回でも呼ばれていれば、本文に関係なく不合格（`EXIT:4`・`VERDICT: NEEDS_FIX`）にします。名前から書き込みと分かる道具（`write`・`edit`・`delete` などを含む名前）も禁止として数えます。
- agy は時間切れや失敗でも終了コード 0 で `status: "ERROR"` の結果を出すことがあるので、結果がちょうど 1 つで最後にあり、`status` が `SUCCESS`、本文が空でないときだけ判定します。それ以外（`ERROR`・空の応答・結果が無い・JSON の破損）は `VERDICT: NONE`（`EXIT:3`）で、エラーの本文からは `VERDICT` を拾いません。
- 子の前後で作業ツリー・git の管理フォルダ（設定・hooks・タグ・stash）・再利用の記録を比べ、変わっていれば不合格（`EXIT:4`）。git の制御ファイル（`.git`・`config`・hooks など）が変わったら、git を 1 回も呼ばずに止めます。本体の checkout（`.git` がフォルダ）では起動しません（`run-gemini.sh` と同じく専用の worktree が前提）。
- 子の git は通信（push・fetch）を止め（`GIT_ALLOW_PROTOCOL`）、任意のロックを取らない設定（`GIT_OPTIONAL_LOCKS=0`）で動かします。管理フォルダは作業場所から見つけます（`GIT_DIR` / `GIT_WORK_TREE` は渡さないので、scratch に写した使い捨てのコピーの中ではそのコピーを見ます）。
- 書き込みは、防ぐ範囲と後から見つける範囲に分かれます。ファイルを書く道具は拒否の一覧と監査で防ぎます。端末のコマンドはサンドボックスの中で動き、書けるのは**作業ツリー**と scratch の **`work/`**（`--add-dir`・`LANES_SCRATCH`・`TMPDIR`）です。
  作業ツリーへの書き込みは防げず、前後の比較で見つけて不合格にします（元には戻しません。守りたい未保存の変更は commit してからレビューに回します）。`work/` の中は比べません。
  実行の記録の原本（scratch の `record.<実行ごと>/`）・子の git 用の設定・設定の写しは scratch の直下にあり、子からは書けません。監査と判定は原本で行い、子の終了後にだけ `logs/` へ写します（写せなければ合格を保存せず `EXIT:3`・`VERDICT: NONE`）。実行中の `logs/<label>.json` などは状態の確認用の写しです。
  原本の置き場所は実行ごとに新しく作り、前の実行の原本は消しません（`logs/` へ写せなかった回の原本は、同じ label で起動し直しても残ります。消すのはマージ後の後片付け）。
  子に渡す指示書も原本の置き場所に一度だけ書いて固定し、一時エラーのやり直しを含む全部の試行と最後の証跡で同じものを使います（`logs/<label>.prompt.md` はその写しで、子の終了後に原本で置き換えます）。
- `CLEAN` を保存するのは、必須検証の成功行（`CHECKS:`）か、親の `chk-run.sh` の記録の使い回しで成功を確かめたときだけです（どちらも無ければ `NEEDS_FIX`）。
- 子の git は最小の設定で動くので、commit の作者の照合は親が元の有効な設定（利用者の共通設定を含む）で、レビューの範囲（比較起点..HEAD）について行い、件数と一致しない commit の番号だけを指示書に入れます。
  名前・メールの値は渡さず、テンプレの作者の確認の項目もこの結果を使う指示に置き換えます（子に作者の名前・メールを表示させる指示はしません）。
  作者の設定（`user.name` / `user.email`）の指紋は再利用の条件に入るので、設定を変えたら同じ HEAD でもレビューし直します（Codex・Claude のレビューも同じ）。
- 親の補助処理（Python）は、起動時に作業ツリーの外から選んで固定した `python3` を `-I` で動かします（`PATH` の絶対パスのフォルダを前から見て、フォルダか `python3` の実パスが作業ツリーの中にあるものは飛ばします。`chk-run.sh` も同じ決め方）。
  作業ツリーの中の仮想環境（`.venv`）を有効にしたシェルから起動しても、その環境の起動時の処理や、レビュー対象のリポにある同じ名前のモジュールを読み込みません。作業ツリーの外に `python3` が無ければ起動しません（exit 2）。
- 見張りは `run-gemini.sh` と同じです（出力が `GEMINI_NOOUTPUT_SEC` 秒止まれば `EXIT:8`。全体の上限は `GEMINI_REVIEW_PRINT_TIMEOUT`、無ければ `GEMINI_PRINT_TIMEOUT`、既定 `75m`。単位なしは秒）。作業ツリーの変わらない一時エラー（503 など）だけ 1 回やり直し、やり直しには初回の開始から数えた残り時間だけを渡します。残り時間は作業ツリーの比較とエラーの確認を終えた後、2 回目を起動する直前に求めます（残りが全体の 1 割未満ならやり直しません）。

限界: 監査は「呼ばれた道具の名前」を後から見るもので、拒否された呼び出しも違反として数えます（読み取り専用の約束を指示書に書いているので、普通は呼ばれません）。
書き込みを防げるのは上に書いた範囲だけで、作業ツリーへの書き込みは後から見つけるだけです（上の「書き込みは、防ぐ範囲と後から見つける範囲に分かれます」）。

### Claude と Gemini の分け方（①③）

- Claude に固定するもの: 課金・認証・本番 DB に関わる作業、重い端末作業、設計の判断が重い作業。
- Gemini を優先してよいもの: 仕様が固まっていて、目安として 6 ファイル・400 行までの作業。
- 迷ったら Claude。Gemini の実装もレビューは必ず通します。

## 選び方

- **迷ったら ②（Claude + Codex）**。実装とレビューが別の道具になり、見落としの癖が重なりにくい。設定も一番シンプル。
- 並列の本数を増やしたい・Claude の利用上限に当たりやすいなら ①（Gemini を足して実装を分担）。
- Codex を使えないなら ③ か ④。下の「独立性が弱いことの補い方」を必ず読んでください。
- ③ と ④ の違いは実装を Gemini と分担するかどうかだけ。レビューの強さは同じです。

## ③④ はレビューの独立性が弱い

③④では、レビューも実装と同じ Claude がやります。キットは次の手当てをしています:

- 実装とは**別のセッション**（会話の履歴を共有しない）で起動する。
- **読み取り専用**: 編集系のツールを外し、履歴を書き換える git 操作・PR のマージ・デプロイ（`gh` / `vercel` / `supabase` などの副作用）を禁止一覧で拒否し、前後の作業ツリーを比べて変更があれば不合格にする。git の管理フォルダ（`.git`）のうち、設定（`config`・`config.worktree`。`core.hooksPath` など）・hooks（git 操作のたびに走るスクリプト）・`info/attributes`・タグ・stash も前後で比べます。ただし Bash は残る（テストや git の読み取りに要る）ため、作業ツリーの**外**へ書くことはできてしまい前後の比較にも出ません。`.git` の中でも、枝（`refs/heads`）や追跡枝の作成・移動は比べていません（worktree 同士で共有され、並行する他のレーンの commit や fetch でも変わるため、比べると誤検出になります）。また、禁止一覧は「コマンドの先頭一致」なので `command gh ...` や絶対パス（`/opt/homebrew/bin/gh ...` など）の書き方では抜けられます（push だけは下の `GIT_ALLOW_PROTOCOL` で別に止めていますが、`gh` などには効きません）。本番の鍵・本番 DB・本番デプロイがある環境では使わないでください。
- **push は止める**: レビューの子プロセスでは git の通信（push・fetch）を環境変数 `GIT_ALLOW_PROTOCOL` で止めているので、`git -C . push` のような拒否の一覧をすり抜ける書き方でも push は失敗します（子が環境変数そのものを外す操作までは防げません）。
- 判定は最終行の `VERDICT:` だけで機械的に行い、曖昧な文や途中で切れた出力は CLEAN にしない。

それでも、**同じ道具は同じところを見落としやすい**ので、別の道具のレビューほどの強さはありません。正直に言って、これは手当てであって置き換えではありません。
補い方:

1. **人のレビューを厚くする**: PR を自動で取り込まず、人が差分を読んでからマージする（少なくとも認証・課金・データ削除に触る PR は必ず）。
2. **CI を厚くする**: 型チェック・lint（書き方の機械検査）・単体テスト・E2E（画面を通した通しのテスト）を必須チェックにし、ブランチ保護で緑以外はマージできないようにする。
3. **できれば Codex を足す**: ChatGPT のサブスクがあれば `LANES_TOOLS` に `codex` を足すだけで ②（または ①）になり、レビューが自動で Codex に切り替わります。
4. **③ なら一部を Gemini に回す**: `LANES_REVIEW_GEMINI_PCT` を 1 以上にすると、その割合のレビューは Claude と別系統の Gemini が読み取り専用で見ます（上の「レビュー役の振り分け」。Gemini で実装したものは Claude のまま）。
   `lanes-roles.sh --print` は割合が 1 以上のとき「うち N% を Gemini レビューへ振り分け」と補足します（`LANES_REVIEW_INDEPENDENT` の値は変わりません）。

`lanes-roles.sh --print` は、③④のときに「レビューの独立性: 弱い」と注意を表示します（`lanes-roles.sh --env` では `LANES_REVIEW_INDEPENDENT=0`）。PR の本文にも「レビューは実装と同じ道具（独立性弱）」と書いておくと、あとから見た人に分かります。
