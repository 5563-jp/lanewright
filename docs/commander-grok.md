# 司令塔を外の Bot（Grok Bot など）にする

設定: `LANES_COMMANDER="${LANES_COMMANDER:-grok}"`（既定）

司令塔（レーンを起動し、終わったら次工程へつなぐ役）を、Mac の外で動くチャットの Bot に任せる形です。
Bot が Mac のシェルに入れる（Mac 上でコマンドを実行できる）ことが前提です。
人が寝ていても、Bot の定期実行（ルーティン）が動く限りレーンが前へ進みます。

`LANES_COMMANDER=grok` のときの意味:
（この設定は運用の印です。キットの動きとして変わるのは、`lanes-doctor.sh` の「司令塔」の表示（監視の回し方の案内）と、`LANES_COMMANDER=claude` で `lanes-watch.sh` を `--until-wake` なしで起動したときの注意の 1 行だけで、ランチャや判定の動きは変わりません）
- 監視の通知・`WAKE:` を受けて動くのは外の Bot。Mac のデスクトップアプリのセッションが起きている必要はない。
- 画面 QA（ブラウザでの見た目の確認）は Bot が受け持つ（`prepare-screen-qa.sh` が観点の雛形を作る）。

## 仕組み

| 間隔 | Bot が回すもの | 目的 |
|---|---|---|
| 5 分ごと | ルーティンなら `zsh <kit>/lanes/lanes-monitor.sh`（1 回分の見回り）。常駐させるなら `zsh <kit>/lanes/lanes-watch.sh` を 1 本だけ | 全レーンの見回り。1 行目が `WAKE: <理由>` なら次工程を判断、`QUIET` なら何もしない |
| 10 分ごと（`LANES_CHECK_INTERVAL_MIN`） | `zsh <kit>/lanes/lanes-watch.sh --check` | 監視そのものが生きているかの確認（ウォッチのウォッチ）と、並列で足せる作業の判断 |

- `lanes-monitor.sh` は `$LANES_RUNS_ROOT` の下の `logs/*.pid` を自動で見つけ、前回からの変化（新しく終わったレーン・止まった疑い・PR の状態）だけを短く出して終わります。
- `lanes-watch.sh` は同じ見回りを繰り返す常駐版で、終わらずに回り続けます（既定は 300 秒間隔・最長 12 時間。`--interval` / `--max-hours` で変更）。
  定期実行のたびに起動するものではありません。二重起動は exit 2 で拒否します。常駐させるときは下の「親を残す」起動をします。
  **`--check` が見る心拍（heartbeat）を書くのは `lanes-watch.sh` だけ**なので、ルーティンで `lanes-monitor.sh` だけを回す形では `--check` は `WATCH DEAD` になります。
  その形なら定期の確認は、ルーティン自体が動いているかを Bot 側で見ます（`--check` の後半のレーン数・次工程待ちの表示は使えます）。
- `--check` は心拍（heartbeat＝監視が生きている印のファイル）を見て、15 分以内（5 分の見回りの 3 回分）なら `WATCH OK`（exit 0）、
  古い `WATCH STALE` か `WATCH DEAD` なら exit 1。**exit 1 なら Bot が監視を起動し直す。**
  あわせて動いているレーン数（`LANES RUNNING`）と、直近 N 分（`LANES_CHECK_INTERVAL_MIN`、既定 10）に終わって次工程待ちのレーンを表示します。
  **スクリプトは作業レーンを自分では起動しません。** 次工程と追加の並列作業を起動するのは Bot です。

### 起動のしかた（親を残す）

Bot の Shell は 1 回の実行が終わると子のプロセスまで止めることがあります。ランチャや監視は親から切り離して起動します:

```sh
zsh <kit>/lanes/detach-run.sh ~/dev/_runs/my-app/hello/logs/launch.log \
  zsh <kit>/lanes/run-impl.sh ~/dev/_runs/my-app/hello ~/dev/_runs/my-app/prompts/hello.md hello-impl
```

短い Shell の中で `nohup ... &` するだけだと、親が終わった時点で止まることがあります。

## 司令塔がやること

1. **ゴールを衝突しない小レーンに分ける**: 触るファイルが重ならない単位に分け、依存のあるものだけ待つ。
2. **最大並列**: 依存の無いレーンは全部同時に起動する。手順書・テスト用の設定など、並行できる作業も出てきたそばから足す。
3. **起動 60 秒以内に status**: `lanes-status.sh <worktree> <label> --tail 20`。`RUNNING` か `DONE` 以外は起動失敗として末尾付きで報告する。
   **status を見る前に「起動した」と言わない**（言うなら「起動確認 OK: pid / ログのパス」）。
4. **DONE で即次工程**: 実装 DONE → レビュー、レビュー CLEAN → 最終確認 → PR、PR マージ → 後片付け → 次のレーン。待たずにつなぐ。
   スクリプトで全自動に連鎖させる仕組みは作らない（判断は司令塔がする）。
5. **FAILED / DEAD / STALLED は聞かれる前に報告**: 状態 / 経過時間 / 最終出力の時刻 / 次にやること、の 4 点を毎回同じ形で。
   同じ起動を黙って繰り返さない。止めるときは `kill <ランチャの pid>`（`kill -9` はしない）。
6. **CI は見張らない**: PR を作ったら `gh pr merge <PR> --auto --merge --delete-branch` で GitHub の auto-merge に任せ、次の見回りのついでに
   `gh pr view <PR> --json state,mergedAt` を見る。マージ済みなら `cleanup-after-merge.sh <worktree> --apply`。
   CI 待ちだけのレーンは作らない。必須チェック（ブランチ保護）が無いリポジトリでは `--auto` が即マージになるので、
   `gh pr checks <PR> --watch --fail-fast` を 1 回待ってから手でマージする。
7. **本番は人の GO**: main への取り込み・本番デプロイ・本番 DB・課金の本番切り替えは、人の明示の GO を待つ。

## 注意

- Bot が Mac のシェルを使えるようにする設定は Bot 側の機能です。Bot に渡す権限は、このキットと対象リポジトリの操作に必要な範囲に絞ってください。
- Bot から CLI のログイン状態を確かめるコマンドの出力を、チャットにそのまま貼らせないでください（秘密の値が載ることがあります）。
- Mac がスリープすると何も進みません。夜も回すなら、電源につないでスリープしない設定にします。
