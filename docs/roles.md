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
- Gemini（Antigravity CLI `agy`）はレビューには使いません。軽い実装専用です。
  `run-impl.sh ... --engine gemini --verify "<検証コマンド>" --allow-path <相対パス>` のように、検証コマンドと保存してよいパスを必ず渡します。
- 割り振りの結果は変数で出ます: `LANES_PROFILE`（構成名）、`LANES_ROLE_IMPL`（`claude` か `claude gemini`）、
  `LANES_ROLE_REVIEW`（`codex` か `claude`）、`LANES_REVIEW_INDEPENDENT`（独立したレビューなら `1`、そうでなければ `0`）。

## 入口と起動前点検

```sh
zsh <kit>/lanes/lanes-roles.sh --print   # 今の構成と割り振りを表示（--env なら KEY=value の形）
zsh <kit>/lanes/lanes-doctor.sh [<worktree>]   # 起動前点検。--quiet なら問題が無いとき何も出さない。worktree を渡すと logs/ が無視されているかも見る
zsh <kit>/lanes/run-impl.sh <worktree> <prompt.md> [label] [--engine claude|gemini] [--dry-run] \
    [gemini 用: --verify "<検証コマンド>" --allow-path <相対パス> ... --no-push]
zsh <kit>/lanes/run-review.sh <worktree> <prompt.md> [label] [--mode auto|full|delta] [--base <sha|branch>] [--round N] [--force] [--dry-run]
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

`run-review.sh` は同じ引数で呼べ、①②（Codex レビュー）でも③④（Claude レビュー）でもそのまま振り分け先へ渡します。
どちらのレビューも同じ仕組み（`lanes/review-dedup.zsh`）を使います。

| 引数 | ①②（Codex）・③④（Claude） |
|---|---|
| `--mode auto`（省略時） | 前回の結果から full / delta / 省略を自動で選ぶ（初回は full、前回 CLEAN・条件一致・未保存変更なしなら前回の HEAD からの delta、同じ HEAD なら前回の結果を使う。前回 NEEDS_FIX なら full に戻して未解決指摘を引き継ぐ） |
| `--mode delta` | 前回 CLEAN からの差分（前回の記録が使えなければ full に戻す） |
| `--base <sha\|branch>` | commit に解決できるもの。full の比較起点と再利用の条件に使う |
| `--force` | 同じ head でもレビューし直す |
| `--round N` | round 3 以降の P2/P3 後回しの判定に使う（label 末尾の `-r<N>` でも可） |

レビュー役（codex / claude）も再利用の条件に入るので、構成を変えたら前回の結果は使いません。
親が同じ中身で `chk-run.sh` を通した記録があれば、どちらのレビューでも必須検証（typecheck / lint / unit）をレビューの中で回させません
（`LANES_REVIEW_REUSE_CHECKS`。`lanes/README.md` の 6 章「必須検証の使い回し」）。何を確かめたことになるかは確認コマンドの中身次第です。

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

`lanes-roles.sh --print` は、③④のときに「レビューの独立性: 弱い」と注意を表示します（`lanes-roles.sh --env` では `LANES_REVIEW_INDEPENDENT=0`）。PR の本文にも「レビューは実装と同じ道具（独立性弱）」と書いておくと、あとから見た人に分かります。
