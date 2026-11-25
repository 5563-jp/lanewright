# Changelog / 変更履歴

このファイルには、利用者から見える変更を書きます。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に沿い、版の付け方は [Semantic Versioning](https://semver.org/lang/ja/) に従います（1.0.0 になるまでは、0.x の中でも動きが変わることがあります）。

This file lists user-visible changes. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/) (behavior may change between 0.x releases before 1.0.0).

## [Unreleased]

### 足したこと / Added
- `detach-run.sh --tmux <セッション名> [--linger <秒>] <launch.log> <コマンド> [引数...]`: tmux のセッションを 1 つ作り、その画面の中に居続ける親から
  コマンドを起動する。起動したレーンが tmux のセッションとして見え、つなぐと、起動した pid・起動ログの続き・終わったときの終了コードがその画面に出る
  （起動したコマンドの親をたどると、tmux の画面のプロセスに着く）。起動するコマンドから見えるもの（環境変数・作業場所・umask・入出力・fd・新しいセッション・
  無視にしたシグナル）と、pid の出力・起動ログ・台帳・`chk-run.sh` の記録の使い回しは、付けないときと同じ。セッションを閉じても、画面で Ctrl-C を押しても、
  コマンドは止まらない。終わると `--linger` 秒（0〜86400 の整数。既定 600）のあとでセッションが閉じる。同じ名前のセッションがあれば `<名前>-2` … を使う。
  - tmux は、決まった 3 つの場所（`/opt/homebrew/bin/tmux`・`/usr/local/bin/tmux`・`/usr/bin/tmux`）だけから選ぶ（`PATH` からは探さない）。
    tmux へ渡す環境変数は、名前を挙げた 6 つだけ（呼び出し元からは `TMUX_TMPDIR` と `LANG`。`HOME`・`USER`・`LOGNAME` は OS のユーザー情報、`PATH` は決め打ち）。
    相対パスの `TMUX_TMPDIR` は、呼び出し元の作業場所につないで絶対パスにして渡す。
    tmux のサーバーがまだ無ければ、この起動が立ち上げる。そのとき、呼び出し元の環境変数を利用者のほかのウィンドウへ広げず、設定ファイルの場所・既定のシェル・
    `PATH` を、呼び出し元の値（起動する対象のリポジトリを指しうる）で決めさせない。
  - 門つきの起動: 画面の中の親が作った子は、コマンドを始める前の門で待ち、門を開けるのは呼び出し元だけ。失敗（決まった文言で exit 2）を返したときは、
    コマンドは始まっていない。起動ログと作業場所は、呼び出し元が開いた fd のまま渡す（画面の側はパスを開かない）。呼び出し元は tmux のセッションを作るだけで、
    閉じる・探す操作をしない。
  - 受け渡しのソケットがつながった直後に、呼び出し元と画面の中の親の両方が、相手が自分と同じ利用者であることを OS に確かめる（違う・確かめられないなら、
    環境変数・コマンド・開いたファイルを送る前／受け取る前に閉じる）。一時フォルダの名前を別の利用者に差し替えられても、その利用者のコマンドは始まらない。
  - 画面に流す起動ログの続きは、普通のファイルのときだけ。流す量を 1 回ごとに区切るので、起動ログが読むより速く増えても（`/dev/zero` のように
    読み終わらなくても）、コマンドが終われば終了コードが出て、`--linger` どおりに閉じる。画面が 1MiB より遅れたら、間を省いて末尾へ進む。
  - 起動するコマンドは tmux のサーバーの子孫として動くので、資源の上限・優先度・macOS のログインの文脈・サンドボックスなどは、tmux のサーバーのものになる
    （`lanes/README.md` の 12 章の「守られないこと・残る場面」）。
  `--tmux` を付けない起動は変わらない（1 つ目の引数が `--tmux`・`--linger`・`--tmux-pane` そのもののときだけ、新しい動きになる）。
  / `detach-run.sh --tmux <session> [--linger <seconds>] <launch.log> <command> [args...]` creates one tmux session and starts the command from a parent
  that stays inside its pane. The lane shows up as a tmux session; attaching shows the pid, the rest of the launch log, and the exit code when it ends.
  What the command sees (environment, working directory, umask, I/O, file descriptors, new session, ignored signals) and what the caller sees
  (the pid line, launch log, ledger, reuse of `chk-run.sh` records) are the same as without `--tmux`. Closing the session or pressing Ctrl-C in the pane
  does not stop the command. The session closes `--linger` seconds (integer 0-86400, default 600) after the command exits.
  tmux is picked only from three fixed locations (never from `PATH`) and receives exactly six named variables (`TMUX_TMPDIR` and `LANG` from the caller;
  `HOME`, `USER`, `LOGNAME` from the OS user database; a fixed `PATH`), so that a tmux server started by this launch neither spreads the caller's
  environment to the user's other windows nor takes its config location, default shell, or `PATH` from caller-controlled values.
  The launch is gated: the child waits before starting the command and only the caller opens the gate, so a failed launch (exit 2) never leaves the
  command running. Right after the handover socket connects, both ends ask the OS for the peer's user ID and close without sending or
  receiving anything unless it is their own. Log forwarding to the pane is chunked and limited to regular files, so the exit code still appears
  (and the session still closes after `--linger`) when the launch log grows faster than it can be read or never ends (`/dev/zero`).
  A relative `TMUX_TMPDIR` is made absolute against the caller's working directory.
  The launch log and working directory are handed over as already-open file descriptors. The caller only creates its own session;
  it never closes or looks up other sessions. Because the command runs as a descendant of the tmux server, resource limits, priority, the macOS
  login context, and any sandbox come from the tmux server, not from the caller. Without `--tmux`, nothing changes.

## [0.1.11] - レーンが終わったらすぐ見回る・切り離しに使う python3 を決め打ちにする / Check right after a lane finishes; a fixed helper python3 for detaching

### 変えたこと / Changed
- `lanes-watch.sh` が、レーンが終わったとき（新しい `.done`）だけは次の 300 秒を待たずに見回るようにした（`--until-wake` も終わらない常駐も同じ）。
  今までは、レーンが終わってから司令塔が起きて次工程をつなぐまで最大 5 分あいていた。見回りの合間に `logs/` の `.pid` と `.done` の更新時刻だけを
  `--quick-interval` 秒ごと（既定 5 秒。`0` で無効＝今までどおり）に見て、見回りの直前より後に終わったレーンがあれば、すぐ次の見回りを回す。
  `WAKE:` / `QUIET` の判定と既読の記録は今までどおり `lanes-monitor.sh` がする（出る行は同じで、早くなるだけ）。止まった疑い・落ちたプロセス・PR の状態は
  今までどおり 300 秒ごとの見回りで拾う。ルーティンで `lanes-monitor.sh` を回す形は変わらない。
  / `lanes-watch.sh` now runs its check without waiting for the next 300-second interval when a lane finishes (a new `.done`), in both
  `--until-wake` and daemon mode. Between checks it only compares the modification times of `.pid` / `.done` under `logs/` every `--quick-interval` seconds
  (default 5; `0` disables it). The `WAKE:` / `QUIET` decision still belongs to `lanes-monitor.sh`; stalled or dead lanes and PR state are still picked up by the regular check.
- `detach-run.sh` が切り離しに使う `python3` を、スクリプトに書いた 2 つの場所だけから選ぶようにした（前から順に、最初にあるもの:
  `/Library/Developer/CommandLineTools/usr/bin/python3`（Mac の Command Line Tools）→ `/usr/bin/python3`）。`PATH` の `python3`
  （pyenv・Homebrew・仮想環境のもの）は使わない。動きが変わる点は次の 4 つ（`lanes/README.md` の 12 章）。
  - 2 つの場所のどちらにも `python3` が無い環境では起動しない（今までは `PATH` の `python3` で動いた）。Mac は `xcode-select --install` を 1 回。
  - `python3` が無いときの終了コードが 127 → 2（固定の文言を出す）。
  - 呼び出し元の環境変数を受け取れないときは、注意を出して続行するのをやめ、exit 2 で止まる（続行すると、起動するコマンドが空の環境で動くため）。
  - 起動ログのフォルダを作れないときは、固定の文言を出す（exit 1 は同じ。パスと例外の本文は出さない）。
  起動するコマンドへ渡る環境変数・作業場所・入出力・pid・ほかの終了コードは変わらない。
  / `detach-run.sh` now picks the `python3` it uses for detaching only from two fixed locations (the first that exists:
  `/Library/Developer/CommandLineTools/usr/bin/python3`, then `/usr/bin/python3`). A `python3` on `PATH` (pyenv, Homebrew, a virtual environment)
  is never used. Behavior changes: it does not start when neither location has `python3` (on a Mac, run `xcode-select --install` once);
  the exit code for a missing `python3` is 2 instead of 127; when the caller's environment cannot be received it stops with exit 2 instead of
  continuing with a note; when the launch-log directory cannot be created it prints a fixed message (still exit 1, without the path or the exception text).
  The environment, working directory, I/O, pid, and other exit codes of the launched command are unchanged.

### 直したこと / Fixed
- 起動する対象のリポジトリの仮想環境を有効にしたシェルから `detach-run.sh` を呼ぶと、対象の中の `python3`・`mkdir` や、作業場所・`PYTHONPATH` に
  ある同じ名前のファイルが、呼び出し元の環境変数を持ったままランチャの中で動いていた（どちらも `PATH` から選び、`python3` は作業場所と
  `PYTHON*` を見ていた）。切り離しに使う `python3` は決め打ちの場所のものを、環境変数を 1 つも渡さずに `-I -S` で動かす。それが動き出すまで、
  シェルは組み込みだけを使う（`mkdir` などの外部コマンドを呼ばない・一時ファイルを通さない）。どこから起動しても、起動ログをどこに置いても同じ。
  `TMPPREFIX` が書けない場所を指していても起動できるようになった。
  / When `detach-run.sh` was called from a shell with the target repository's virtual environment activated, that environment's `python3` and `mkdir`,
  and same-named files in the working directory or on `PYTHONPATH`, ran inside the launcher with the caller's environment variables.
  The detaching `python3` now comes from a fixed location and runs with an empty environment and `-I -S`; until it starts, the shell uses built-ins only
  (no external commands, no temporary files). This holds wherever it is launched from and wherever the launch log is placed.

## [0.1.10] - レビューの判定行の字下げの数え方と、Gemini レビューの混入の点検 / Indent-aware verdict lines and contamination checks in Gemini review

### 足したこと / Added
- Gemini のレビューの指示書に、レビュー範囲の各 commit の変更パスと、混入の点検の結果を親が埋め込むようにした（v0.1.9 で先送りしたもの。
  点検は `lanes/review-history-inspect.py`）。見るのは各 commit の変更パス・変更後の大きさ・親フォルダの一覧（木）・その commit の時点の `.gitignore`・
  HEAD の木だけで、内容と作者は見ない。途中で追加して消したファイルも載る（HEAD の木に無いものには、公開履歴に残ることを書く）。結果は次の 3 つに分けて、件数・理由別の件数・
  代表箇所（各 20 件まで。理由ごとに最低 1 件）を載せる（点検は全件で行う）:
  - 規則に反する混入: その commit の時点の `.gitignore` で無視されるパスを、新しく持ち込んだもの（指摘に書く）。
  - 要確認候補: 新しく持ち込んだもののうち、秘密らしい名前（`.env*`・`id_rsa` など・`.pem`・`.key`・`.p8`・`.p12`・`.pfx`・`.keystore`・
    `credentials.json` など。`.gitignore` に個別の規則が無くても選ぶ）・`run-*.sh`・`logs/` の下・1 MiB 以上で規則には反しないもの。
    それより前から追跡しているファイルの変更は、その時点の `.gitignore` で無視されるもの・秘密らしい名前のもの・変更後に 1 MiB 以上のものだけ
    （正規のファイル・意図した見本なら指摘にしない。`.env*` や鍵の候補は中身を開かずに判断する）。
  - 判定できなかったもの: `.gitignore` を読めない（部分 clone で中身を取得できない など）・大きさが分からないなど、照合に失敗したもの
    （「該当なし」にせず、指摘に書く。変更 1 件につき 1 回数える）。

### 変えたこと / Changed
- Claude・Gemini のレビューの判定は、本文の入口で字下げの幅を数えるようにした（空白は 1 桁、タブは次の 4 の倍数の桁まで）。
  幅 4 以上の行はコード例として解析しないので、「空白 2 個＋タブ」のように空白とタブを混ぜて字下げした `VERDICT: CLEAN` でも、
  必須検証の使い回しの有無によらず合格にしない（`VERDICT: NONE`）。前後に 1〜3 個の空白（とタブ）を付けただけの判定行は今までどおり採用する。
  最後の空でない行は、本文解析で採用した行そのもの（行番号で照合）であることも求める（前に同じ中身の判定行があっても、最後がコード例なら採用しない）。
  v0.1.9 の条件（最後の行が判定行そのもので、本文解析で採用できる判定行が末尾にあること）は弱めていない。
- 本文の行は `\n`・`\r\n`・`\r` だけで分けるようにした（`\v`・`\f`・U+2028 などで分けると、コード例の行の途中から判定行が始まったように見えるため）。
  判定行の前後に付けてよいのは空白とタブだけ（ノーブレークスペース・全角空白で囲んだ行は判定行として採用しない）。
  最後の行を探すときに空行として飛ばすのも、空白とタブだけの行に限る（判定行の後ろに全角空白・ノーブレークスペース・改ページだけの行があれば、
  それが最後の行になるので採用しない）。
- Gemini のレビューで、テンプレの「`git show --stat`」の項目は、埋め込みの変更パスと混入の点検の結果と `git diff --stat` を参照する文に差し替える。
- 再利用の条件（`rvd_context`）に `review-history-inspect.py` の中身と、対象リポジトリで有効な `core.ignoreCase` を足した（設定で無視の判定が変わるので、変えたら同じ HEAD でもレビューし直す）。上げた後の最初のレビューは、前回 `CLEAN` の系列でも 1 回 full になる。
- 合格の判定行（`VERDICT: CLEAN`・`VERDICT: PASS`）の候補は、元の行に行区切りの文字（`\v`・`\f`・U+2028・U+2029 など）があれば採用しない。
  本文の行分けを `\n`・`\r\n`・`\r` だけにしたので、これらの文字は行の中に残る。「VERDICT:」と「CLEAN」の間に挟まれた行や、行頭に置いて字下げの数え方を
  すり抜けたコード例の行を、合格の判定にしない（0.1.9 までは、ここで行が切れて判定にならなかった。同じ結果に保つ）。`VERDICT: NEEDS_FIX` は今までどおり拾う。

### 直したこと / Fixed（v0.1.9 の作業枝で先送りした点検の穴を、戻す前に塞いだもの）
- 点検は macOS 付属の `python3`（3.9）でも動く（文字列の埋め込み式の中で外側と同じ引用符を使わない。3.11 以前の `python3` で動くことをテストで確かめる）。
- 正規の `run-*.sh` の変更や、`.gitignore` の例外（`!.env.example` など）で許可した見本を、名前だけで混入と決めつけない
  （名前による要確認候補と、規則に反する混入を分ける。例外で許可した名前は候補にもしない）。
- マージ commit 自体で生じた変更（すべての親と違うパス）も点検し、指示書に載せる一覧と点検に同じ変更一覧を使う。
- パスは Git の表示用の名前ではなく、NUL 区切りで得た実名のまま照合する（引用符・タブ・前後の空白を含む名前もすり抜けない）。表示するときだけ引用する。
- 過去の commit も、今の作業ツリーではなく、その commit の時点の `.gitignore`（最上位とパスの親フォルダのもの）で照合する。
- 比較起点からあったファイルを消しただけの変更は、混入に数えない。照合の失敗を「見つからなかった」にしない。
- `.gitignore` の有無と種類は、その commit の親フォルダの木で確かめる（名前で引いた「missing」は、無い場合と部分 clone で中身を取得できない場合を
  区別できないため）。通常ファイルの中身を取得できないときだけ「判定できなかったもの」にする。リンクの `.gitignore` は Git と同じく規則にしない
  （リンク先の名前を規則として扱わない）。
- 無視の照合の大文字・小文字の扱いは、照合用の一時リポではなく対象リポジトリで有効な `core.ignoreCase` に合わせる。
- フォルダの `.gitignore` の規則に当たったとき、規則の出典のパスも表示用に引用する（タブ・復帰文字を含むフォルダでも証跡の行が崩れない）。
- 「HEAD には無い」は HEAD の木で確かめる（別の枝で同じ名前を足して消しても、HEAD に残っていれば書かない）。
- Gemini の成功した応答は、末尾を削らずにログへ残してから判定する（判定行の直後の全角空白・ノーブレークスペースが保存のときに消えて、
  共通の判定では採用しない最終行が `CLEAN` になっていた）。空白の許否は共通の判定（`lanes_parse_review`）の 1 か所だけが決める。
- 親フォルダの木は、フォルダの名前の末尾の `/` を付けたまま `git cat-file --batch` に問い合わせる（最上位は `<commit>:`）。過去にフォルダの下へ足したパスの名前が HEAD で通常ファイルに置き換わっていても、その本文を取得しない。末尾が復帰文字のフォルダも、Git が行末の復帰文字を落として別のフォルダの木を返すことがなくなる。
- 木の応答は届いた順に読み、`.gitignore` と、HEAD に残っているかを確かめるパスの次の名前だけを残す（コミットごとの木の本文と全項目を最後まで持たない）。
- 秘密らしい名前・`run-*.sh` の判定は、パスの最後の名前で行う（鍵の拡張子は大文字・小文字を区別しない末尾の一致）。名前の途中に改行があっても候補から漏れず、ルート直下の `.key` も `sub/.key` と同じく候補になる。
- git の呼び出しは、パスの数によらず 6 回まで（変更一覧・大きさ・木と `.gitignore` の中身・`core.ignoreCase`・照合用の一時リポの作成・無視の判定）。
  照合用の一時フォルダは scratch の直下（dry-run で無ければ `TMPDIR`）に作って、終わったら消す。点検のために外から取りに行かない（部分 clone でも）。

## [0.1.9] - 読み取り専用の Gemini レビューとレビュー役の振り分け / Read-only Gemini review and reviewer routing

### 足したこと / Added
- 読み取り専用の Gemini レビューランチャ `lanes/run-gemini-review.sh` を足した（構成に `gemini` がある ① `full` / ③ `claude-gemini` で使える）。
  Codex・Claude のレビューと同じ入口（`run-review.sh`）・同じ判定（`review-dedup.zsh` の full / delta / 同じ head の再利用・round 3 以降の後回し票・
  必須検証の使い回し）・同じ終了コードの決まりで動く。agy に `--sandbox`・`--settings`（MCP・書く道具・サブエージェント・ブラウザ・Web・予約・ワークフローを拒否）・
  `--mode plan` を必ず付け、実行の記録で禁止の道具・質問の道具（`ask_*`）が呼ばれていれば不合格（`EXIT:4`）にする。
  agy は時間切れや失敗でも終了コード 0 で `status: "ERROR"` を出すことがあるので、`SUCCESS` で本文があるときだけ判定する（それ以外は `VERDICT: NONE`）。
  `CLEAN` は必須検証の成功（成功行か親の `chk-run.sh` の記録の使い回し）を確かめたときだけ保存する。子が書けるのは作業ツリー（前後の比較で不合格）と
  scratch の `work/` だけで、実行の記録の原本と渡す指示書は子から書けない scratch の `record.<実行ごと>/`（実行ごとに新しく作り、前の実行の原本は消さない）に置き、
  監査・判定は原本で行って子の終了後に `logs/` へ写す。一時エラーのやり直しも同じ指示書を使い、残り時間は作業ツリーの比較の後に求める。
  Gemini で実装したものは、`run-gemini-review.sh` を直接呼んでも起動しない（`--impl-engine` も受け付ける）。
  Gemini のレビューは作業ツリーがきれいなときだけ起動する（`logs/` 以外に未 commit の変更・未追跡のファイルがある、またはサブモジュールがあるときは exit 2。
  commit してから起動する）。作業ツリーを scratch に写して試すときは `.git` ごと写さず（元の管理フォルダを指すため）、`git archive HEAD` を
  新しい空のフォルダ（`mktemp -d`）へ展開して `git init` し直すよう指示書に書く（写すのは commit 済みの中身だけ）。
- `run-review.sh` に `--engine codex|gemini|claude`（レビュー役の明示）と `--impl-engine claude|gemini|codex`（実装した道具のヒント）を足した。
- 設定 `LANES_REVIEW_GEMINI_PCT`（既定 `0`）: 新しい系列のレビューをこの割合で Gemini に回す（`50` なら既定の役と交互）。
  割合で決めた役は作業ツリーの `logs/.<系列>.review-pick` に残して引き継ぐ（起動前の点検で止まった系列を呼び直しても、数え方を二重に進めない。
  作業ツリーと同じ寿命なので、同じパスに作り直した作業ツリーには持ち越さない）。
  同じ系列の r2 以降は前回と同じレビュー役で続ける。**Gemini で実装したもの（`--impl-engine gemini` か `logs/` の `.pid` に `lane=gemini`）は Gemini でレビューしない。**
  実装の記録（`logs/` の `.pid`）を読めないときも、実装元が分からないので同じに扱う。
- 設定 `GEMINI_REVIEW_DENY`: Gemini レビューで拒否する道具を足す（固定の一覧は外せない）。

### 変えたこと / Changed
- 再利用の記録（`logs/.<系列>.review-state`）にレビュー役（`last_reviewer`）を残すようにした（Codex・Claude のレビューとも。旧記録は証跡の見出しで判別する）。
- 再利用の条件（`rvd_context`）に `run-gemini-review.sh` の中身を足した。上げた後の最初のレビューは、前回 `CLEAN` の系列でも 1 回 full になる。
- 前回 `NEEDS_FIX` の後の再レビューも、レビュー役を変えた回は差分ではなく全体を見る（Codex・Claude・Gemini とも。前回の指摘は引き継ぐ）。
- 読み取り専用の制限の設定（`CODEX_REVIEW_SANDBOX`・`CLAUDE_REVIEW_TOOLS`・`CLAUDE_REVIEW_DENY`・`GEMINI_REVIEW_DENY`）を再利用の条件に入れた。
- commit の作者の照合に使う有効な作者の設定（`user.name` / `user.email`）の指紋を再利用の条件に入れた（値は入れない）。設定を変えたら同じ HEAD でもレビューし直す。
  Gemini のレビューでは、作者の照合を親で行い、件数と一致しない commit の番号だけを指示書に入れる（名前・メールは渡さない）。
  レビュー範囲の commit の一覧（短い SHA と件名）と変更統計（`git diff --stat`）も親が作って指示書に埋め込み、子には `git log`・`git show`・`git blame`・
  `git shortlog` などの履歴・作者を表示し得るコマンドを使わないよう書く（中身は `git diff` と作業ツリーのファイルの読み取りで確かめる）。
  テンプレの履歴・作者の確認の項目は固定の文言のまま埋め込みを参照する文に差し替える（指示書の全文をコマンドの形で書き換えることはしない）。
- Claude・Gemini のレビューは、整形前の元の本文の最後の空でない行（前後の空白を除く）が `VERDICT: CLEAN` / `VERDICT: NEEDS_FIX` そのものであるときだけ
  それを最終判断とし、そうでなければ（判定行の後ろに表・引用・補足が続く、飾りが付いている、判定行が無い）指摘があっても重大度から推定せず
  `VERDICT: NONE`（`EXIT:3`）にする（round 3 以降の後回し・合格への昇格・前回の指摘の後回し・再利用の記録の保存をしない）。
  Claude レビューのテンプレにも、最後の行は飾りを付けずその後ろに何も書かないことを書いた。Codex のレビューは完了証明が最終判断の代わりなので今までどおり。
- レビューのランチャ・`review-dedup.zsh`・`_common.sh`・`chk-run.sh` が呼ぶ Python は、起動時に作業ツリーの外から選んで固定した `python3` を `-I` で動かすようにした
  （作業ツリーの中の仮想環境を有効にしたシェルから起動しても、その環境の起動時の処理や対象リポにある同じ名前のモジュールを読み込まない。
  作業ツリーの外に `python3` が無ければ exit 2）。入口（`run-review.sh`・`run-impl.sh`）で 1 回だけ決めた `python3` を、振り分け先・起動前点検（`lanes-doctor.sh`）・
  `chk-run.sh --query` へ渡し、渡された側は選び直さない（作業ツリーの外の実行ファイルであることだけ確かめ、作業ツリーの中なら止める）。
  固定するのは `PATH` の `python3` そのものではなく実体（作業ツリーの外のフォルダだけの `PATH`・`cd /`・`PYENV_VERSION` / `PYENV_DIR` なしで一度呼んで得た
  `sys.executable` の実パス）なので、pyenv の shim のように呼ばれるたびに元の `PATH` から作業ツリーの中の `python3` を選び直すことはない。
  実体を確かめる探索先からも、`python3` が作業ツリー内の実行ファイルへのリンクであるフォルダは外す（振り分けプログラムが、確かめる前にそのプログラムを動かさない）。
- 数値の設定キーは、`lanes.env` が先頭の 0 を外して整数に揃える（`LANES_REVIEW_GEMINI_PCT=0050` は `50`）。
- 既定（`LANES_REVIEW_GEMINI_PCT=0`）のまま `--engine` を使わなければ、新しい系列のレビュー役は今までと同じ（構成の既定の役）。
  同じ系列の途中で構成（`LANES_TOOLS`）を変えたときは、前回の役が今の構成にあればその役で続ける（変えるなら `--engine` か新しい系列の label で）。

- 空白とタブが混在する字下げ判定行の解析や行番号照合、各 commit の変更パスによる混入点検、パス照合の強化は v0.1.10 へ回した（r6 の指摘。枝 `feat/review-inspect-v0.1.10`）。
  v0.1.9 の VERDICT は、元の最終行が判定行そのものであることに加え、本文解析で採用できる判定行が末尾にあること（explicit）も求める。
  「書式例」のあとに 4 空白またはタブで字下げした `VERDICT: CLEAN` だけで終わる応答は合格にしない（v0.1.8 と同じ強さ）。

## [0.1.8] - レビューの重さに「起きる条件」を足し、P0/P1 が減らない周回を止める / Severity needs a trigger condition; stop loops where P0/P1 do not go down

### 変えたこと / Changed
- レビューの指示（`lanes/templates/codex-review-focus.md`・`claude-review-full.md`・`claude-review-delta.md`）に重さの決め方を足した。
  P0 / P1 は、普通の使い方・普通の入力で起きて、利用者に誤った結果が出る・データが壊れる・お金や本番に影響する・要件が退行するものに付け、
  指摘ごとに「起きる条件」と「影響」を書く。秘密の値・認証と認可・お金・本番のデータ・個人情報に関わるものは、起きにくい条件でも重さを下げない。
  それ以外で起きにくい場面（途中での強制終了や停止の合図・書き込み失敗・同じ作業場所での同時実行・操作する人が持ち込む環境・
  実際のデータ元が返さない形の入力）は P2、結果が安全な側に倒れるだけなら P3。
  前回の直しで足したコードに出た問題はそう書かせ、同じ原因で同じ直し方になる穴は全箇所を書いて「作りの問題」として 1 件にまとめさせる（別々の直しが要るものは分ける）。
  受け入れ済みの限界（`.lanes/accepted-limitations.md`）に当たるものはそちらが優先で、起きやすさの分類はその外にだけ使う。
  Claude のレビュー（`claude-only`・`claude-gemini` 構成）にも同じ決め方が渡る。
- 実装レーンの前置き（`claude-impl-preamble.md`・`gemini-impl-preamble.md`）に「レビューの指摘を直すとき」を足した。
  指摘ごとに守りを足すのではなく根の原因を減らし、直すほど複雑になるなら作りを単純にする案を報告に書く。
- `skills/review-loop`・`docs/operating-rules.md`・ひな形（`templates/AGENTS.md.example`・`templates/CLAUDE.md.example`）に「今回の P0+P1 が 1 件以上あり、その件数が 2 回続けて前の回より減らなければ、修正を続けずに人に返す」決まりを足した。
  系列（label）を変えて数え直さない。
- 前回 `NEEDS_FIX` の後の再レビューも、前回レビューした HEAD からの `delta`（差分だけ）にした（`review-dedup.zsh` の `rvd_fix_mode`。Codex・Claude のレビューとも）。
  今までは前回 `CLEAN` の後だけ delta で、`NEEDS_FIX` の後は毎回 full に戻っていたため、2 回目以降も全体を読み直して差分の外の指摘が足されていた。
  前回の未解決指摘は今までどおり全件引き継ぎ、解消の確認には差分の外も読む。新しい指摘は今回の差分の行と、その直しが直接影響する箇所に限る。
  比較起点が変わった・前回の HEAD が今の HEAD の祖先でない・同じ HEAD・未保存変更・旧形式の記録・再利用の記録を戻しきれなかった印・`--mode full` のときは full。
- 判定の仕組み（`VERDICT`・round 3 以降の後回し・周回の上限・必須検証の扱い）は変えていない。検証未実施は今までどおり P1。
- 上げた後の最初のレビューは、指示書が変わったので前回 `CLEAN` の系列では 1 回 full になる（前回 CLEAN からの delta や同じ HEAD の省略は効かない）。前回 `NEEDS_FIX` の系列は、上の条件が揃えば delta のまま。

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
