# gemini-agy.zsh — run-gemini.sh（Gemini 実装）と run-gemini-review.sh（Gemini レビュー）が source する、agy の起動と見張り。
# _common.sh を読んだ後に読む（lanes_start_child_in・lanes_kill_child・lanes_record_child・lanes_logdir_check・lanes_write_new_at・
# lanes_now を使う）。
# 呼び出し元が用意する変数:
#   cmd（agy のコマンドの配列。-p より前まで）/ final（渡す全文のファイル）/ log（ランチャのログ）/ wt / gitdir / scratch（最小 gitconfig と
#   親専用の写しを一時的に作る場所）/ poll / idle_grace / resume_grace / noout_sec（見張りの秒数）/ GEM_TAG（ログの行の頭。既定 [run-gemini]）
# 起動のしかた:
#   - 子（監督役・受け取り役・agy）の作業場所（cwd）だけを worktree にする（lanes_start_child_in）。呼び出し元のシェルは移らない。
#     監督役と受け取り役の python3 は _common.sh が起動時に確定した絶対パス（LANES_PYTHON3）。agy は呼び出し元が絶対パスで cmd に入れる
#   - agy の標準出力（stream-json）は受け取り役（gemini-stream-tee.py）がパイプで直接受け取り、公開用の logs/<label>.json と、
#     親専用の写し（子の起動前に作ってすぐ名前を消した一時ファイル。開いた番号 GEM_STREAM_FD だけが残る）の両方へ書く。
#     子は logs/ に書けるので、監査（書き込みの試み・最後の応答）は親専用の写しを読む（gem_stream_read）。子と孫の回収が済んだら、
#     公開用を親専用の写しと突き合わせ（消された・書き換えられた → GEM_PUBLIC_TAMPERED=1。ランチャは改ざんとして不合格にする）、
#     そのあと公開用の logs/<label>.json を親専用の写しで置き換える（残る記録を受け取った中身にそろえる）
# 見張りの考え方（実装・レビューで同じ）:
#   - 出力（json・stderr）が noout_sec 秒止まったら停止（GEM_NOOUT=1。ランチャは EXIT:8）。出力の更新と idle の行は、子の起動前に開いた
#     番号（親専用の写しと標準エラー）から読む（gem_watch_poll。名前は開き直さないので、子が名前付きパイプに差し替えても止まらない）
#   - agy が「root agent idle」を出したあと、子（テストなど）が無く json が idle_grace 秒動かなければ異常終了として停止（GEM_IDLE_KILLED=1。EXIT:3）
#     json が動いたら時計を戻し、猶予を resume_grace 秒に延ばす。子が動いている間は idle だけで止めない
#     （監督役・受け取り役・agy の 3 つだけなら「子が無い」と数える。GEM_BASE_PROCS）
#   - 全体の上限は agy の --print-timeout（ランチャが cmd に入れる）

# ---- 子プロセスの記録と停止 ----
# 無出力の監視用に、監督役と agy の子孫を pid・pgid・lstart で数える。
# 停止対象の同一性確認と回収は共通監督役が行う。
typeset -gA GEM_TRACK PSL PSPP PSPG
typeset -g GEM_PGID="" GEM_ROOT_LS=""
# 親専用の写しを読む番号（最後の実行の分）。前の実行の分も閉じずに残すので、呼び出し元は番号を控えておけば後で読み直せる
# （run-gemini.sh の再実行が、1 回目の記録を置き換え直すのに使う）
typeset -g GEM_STREAM_FD="" GEM_STREAM_WFD="" GEM_ERR_WFD="" GEM_ERR_RFD=""
# 見張りが数える「子が無い」ときのプロセスの数（監督役・受け取り役・agy）
typeset -gi GEM_BASE_PROCS=3
gem_ps_snapshot() {   # 全プロセスの ppid / pgid / lstart を 1 回の ps で取る（引数・環境は読まない）。呼び出し元のシェルで実行する
  local line psout
  local -a w
  psout="$(LC_ALL=C TZ=UTC ps -axo pid=,ppid=,pgid=,lstart= 2>/dev/null)" || return 1
  [[ -n "$psout" ]] || return 1
  PSL=(); PSPP=(); PSPG=()
  for line in ${(f)psout}; do
    w=(${=line})
    (( ${#w} >= 4 )) || continue
    [[ "$w[1]" == <-> && "$w[2]" == <-> && "$w[3]" == <-> ]] || continue
    PSPP[$w[1]]="$w[2]"; PSPG[$w[1]]="$w[3]"; PSL[$w[1]]="${(j: :)w[4,-1]}"
  done
  return 0
}
gem_track_tree() {   # 根（agy）が起動時と同じプロセスのときだけ子孫を GEM_TRACK に足す。死んだ・別物になった記録は外す
  local root="${GEM_PGID:-}" p
  local -A kids
  local -a queue
  gem_ps_snapshot || return 0
  for p in ${(k)GEM_TRACK}; do
    if [[ "${PSL[$p]:-}" != "${GEM_TRACK[$p]}" ]]; then unset "GEM_TRACK[$p]"; fi
  done
  [[ -n "$root" && -n "$GEM_ROOT_LS" && "${PSL[$root]:-}" == "$GEM_ROOT_LS" ]] || return 0
  gem_adopt_group
  for p in ${(k)PSPP}; do kids[${PSPP[$p]}]="${kids[${PSPP[$p]}]:-} $p"; done
  queue=($root)
  while (( ${#queue} )); do
    p="${queue[1]}"; shift queue
    if [[ -n "${PSL[$p]:-}" && "$p" != "$$" ]]; then
      GEM_TRACK[$p]="${PSL[$p]}"
    fi
    queue+=(${=kids[$p]:-})
  done
  return 0
}
gem_adopt_group() {   # 監督役の集団の今のメンバーを記録する。根の同一性を確認した直後だけ呼ぶ
  local p
  [[ -n "${GEM_PGID:-}" && "$GEM_PGID" != "${PSPG[$$]:-y}" ]] || return 0
  for p in ${(k)PSPG}; do
    if [[ "${PSPG[$p]}" == "$GEM_PGID" && "$p" != "$$" && -n "${PSL[$p]:-}" ]]; then GEM_TRACK[$p]="${PSL[$p]}"; fi
  done
  return 0
}
# 停止は共通監督役に任せる。待受ポートや作業場所だけでは所有者と判断しない。
gem_kill_all() { lanes_kill_child; }
# .pid の子の記録（child_pid / child_lstart）を差し替える（再実行でも lanes_child_alive が今の子を見るように）
# （lanes_record_child は起動時の中身＋今の子だけを書き直すので、前の子の記録は残らない）
gem_record_child() { lanes_record_child "$1"; }

# 公開用の <path> が、親専用の写し（番号 <fd>）と同じ中身か。子と孫の回収が済んだ後だけで呼ぶ。0 = 同じ / 1 = 違う・消えた・普通のファイルでない。
# 受け取り役は親専用の写し → 公開用の順に書くので、見張りで止めた（受け取り役を途中で止めた）ときは、公開用が写しの頭の部分なら同じとみなす
# （<allow_prefix> = 1）。止めていないのに頭の部分しか無いのは、子が切り詰めた（または公開用へ書けなかった）ので違うとする。
# 両方を頭から一定量（1 MiB）ずつ読み比べる（全体をメモリに持たない。長い実装・大きなコマンド出力でもメモリは一定量だけ）
gem_check_public() {   # <fd> <path> <allow_prefix 0|1>
  [[ "$1" == <-> ]] || return 1
  python3 -I -c 'import os, stat, sys
d, name, allow_prefix = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
CHUNK = 1 << 20
def read_full(fd, n):
    # n バイトそろうか終わりに着くまで読む（普通のファイルでも 1 回の read が短く返ることがある）
    parts, got = [], 0
    while got < n:
        b = os.read(fd, n - got)
        if not b:
            break
        parts.append(b); got += len(b)
    return b"".join(parts)
os.lseek(3, 0, os.SEEK_SET)
try:
    dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        sys.exit(1)
    while True:
        private, public = read_full(3, CHUNK), read_full(fd, CHUNK)
        if private == public:
            if not private:
                sys.exit(0)   # 両方とも同時に終わった（同じ中身）
            continue
        # 違う所がある。公開用が先に終わり（短い）、そこまでが写しと同じなら頭の部分（見張りで止めたときだけ同じとみなす）
        sys.exit(0 if allow_prefix and len(public) < len(private) and private.startswith(public) else 1)
except OSError:
    sys.exit(1)' "${2:h}" "${2:t}" "${3:-0}" 3<&$1
}

# 親専用の写し（番号 <fd>）で、公開用の <path>（logs/<label>.json など）を置き換える。子と孫の回収が済んだ後だけで呼ぶ。
# logs/ を symlink を辿らずに開き、一時ファイルに書いてから名前を付け替える（lanes_write_new_at）。書けなければ公開用を消して 1 を返す
# （残った公開用を、受け取った中身と取り違えて読まないように）
gem_publish_stream() {   # <fd> <path>
  [[ "$1" == <-> ]] || return 1
  lanes_write_new_at "${2:h}" "${2:t}" rewind <&$1 && return 0
  rm -f -- "$2" 2>/dev/null || true
  return 1
}

# 見張りの 1 回分。子の起動前に開いた番号（親専用の写し = agy の標準出力と、標準エラー）だけを見て、名前（logs/ のパス）は開き直さない
# （子が標準エラーのファイルを名前付きパイプなどに差し替えても、見張りが読み取りで止まらない。開いた番号は元の普通のファイルを指したまま）。
# 標準エラーは前回読んだ位置から先だけを読み（1 回に最大 16 MiB）、「root agent idle」の数を足していく（区切れ目にまたがる分も数える）。
# 出力: "<写しの更新時刻> <標準エラーの更新時刻> <idle の数の合計> <次に読む位置>"（失敗したら何も出さず非 0）
gem_watch_poll() {   # <読んだ位置> <それまでの idle の数>
  python3 -I -c 'import os, stat, sys
off, total = int(sys.argv[1]), int(sys.argv[2])
PHRASE = b"root agent idle"
s_json, s_err = os.fstat(3), os.fstat(4)
if not (stat.S_ISREG(s_json.st_mode) and stat.S_ISREG(s_err.st_mode)):
    sys.exit(1)
start = max(0, off - (len(PHRASE) - 1))
data = os.pread(4, min(max(0, s_err.st_size - start), 1 << 24), start) if s_err.st_size > start else b""
i = data.find(PHRASE)
while i >= 0:
    if start + i + len(PHRASE) > off:   # 前回までに読み終えた範囲に収まる分は数えた済み
        total += 1
    i = data.find(PHRASE, i + 1)
print(int(s_json.st_mtime), int(s_err.st_mtime), total, max(off, start + len(data)))' "$1" "$2" 3<&$GEM_STREAM_FD 4<&$GEM_ERR_RFD
}

# agy を 1 回走らせて見張る。結果: GEM_RC / GEM_IDLE_KILLED / GEM_NOOUT / GEM_SECS / GEM_STREAM_FD（親専用の写し）/
#   GEM_PUBLIC_TAMPERED（公開用の json が受け取った中身と違った）/ GEM_PUBLISH_FAILED（公開用を置き換えられず消した）
run_agy_once() {
  local j="$1" e="$2" now last m m_json m_err idle_at=0 idle_seen=0 n=0 err_off=0 poll_out poll_warned=0 ta grace=$idle_grace tag="${GEM_TAG:-[run-gemini]}" stream_tmp
  local -a pw
  GEM_RC=0; GEM_IDLE_KILLED=0; GEM_NOOUT=0; GEM_PUBLISH_FAILED=0; GEM_PUBLIC_TAMPERED=0; ta=$(date +%s)
  # 子の実行中はログへパスのまま書かない（子が logs/<label>.log を外向きの symlink にすると先へ追記してしまう）。
  # 子の起動前に開いた番号（fd）にだけ書く。差し替えられても、開いた元のファイルに書くだけで外へは届かない
  lanes_logdir_check
  exec {GEM_LOGFD}>>"$log"
  # 親専用の写し。子の起動前に作り、書く番号と読む番号を開いてから名前を消す（以後、子は名前で開けない）
  stream_tmp="$(mktemp "${scratch%/}/.gem-stream.XXXXXX")" || lanes_die "親専用の写しを作れない: $scratch"
  exec {GEM_STREAM_WFD}>"$stream_tmp"
  exec {GEM_STREAM_FD}<"$stream_tmp"
  rm -f -- "$stream_tmp"
  [[ ! -e "$stream_tmp" && ! -L "$stream_tmp" ]] || lanes_die "親専用の写しの名前を消せない: $stream_tmp"
  # 標準エラー（logs/<label>.stderr.log）も子の起動前に作り、書く番号と見張りが読む番号を開いておく（見張りは名前で開き直さない。gem_watch_poll）
  lanes_fresh_file "$e"
  exec {GEM_ERR_WFD}>"$e"
  exec {GEM_ERR_RFD}<"$e"
  # 受け取り役は起動時に確定した python3（LANES_PYTHON3）で動かす（監督役が作業場所で PATH から探し直さない）
  ANTIGRAVITY_HEADLESS=true GIT_DIR="$gitdir" GIT_WORK_TREE="$wt" GIT_CONFIG_GLOBAL="$scratch/gitconfig" GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat \
    lanes_start_child_in "$wt" "$LANES_PYTHON3" -I "$LANES_DIR/gemini-stream-tee.py" "${j:h}" "${j:t}" -- "${cmd[@]}" -p "$(<"$final")" \
    < /dev/null >&$GEM_STREAM_WFD 2>&$GEM_ERR_WFD
  exec {GEM_STREAM_WFD}>&- {GEM_ERR_WFD}>&-
  GEM_PGID="$LANES_CHILD"; GEM_TRACK=()
  GEM_ROOT_LS="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$LANES_CHILD" 2>/dev/null)" || GEM_ROOT_LS=""
  GEM_ROOT_LS="${(j: :)${=GEM_ROOT_LS}}"
  gem_record_child "$LANES_CHILD"
  last=$ta
  while kill -0 "$LANES_CHILD" 2>/dev/null; do
    sleep "$poll"
    kill -0 "$LANES_CHILD" 2>/dev/null || break
    gem_track_tree
    now=$(date +%s)
    # 出力の更新時刻と idle の数は、開いておいた番号から取る（確かめられない回は更新しない＝無出力の見張りは進む。1 回だけ記録する）
    poll_out="$(gem_watch_poll "$err_off" "$n" 2>/dev/null)" || poll_out=""
    pw=(${=poll_out})
    if (( ${#pw} == 4 )) && [[ "${pw[1]}" == <-> && "${pw[2]}" == <-> && "${pw[3]}" == <-> && "${pw[4]}" == <-> ]]; then
      m_json=${pw[1]}; m_err=${pw[2]}; n=${pw[3]}; err_off=${pw[4]}
    else
      m_json=0; m_err=0
      if (( ! poll_warned )); then
        poll_warned=1
        print -u "$GEM_LOGFD" -- "$tag $(lanes_now) 出力の更新を確かめられない（見張りは続ける。出力が ${noout_sec} 秒動かなければ停止）"
      fi
    fi
    if (( m_json > last )); then last=$m_json; fi
    if (( m_err > last )); then last=$m_err; fi
    if (( n > idle_seen )); then
      idle_seen=$n; idle_at=$now; grace=$idle_grace
      print -u "$GEM_LOGFD" -- "$tag $(lanes_now) agy が idle（裏の作業待ち）。子の処理が無く、json が ${idle_grace} 秒動かなければ異常終了として停止"
    fi
    if (( idle_at > 0 )); then
      m=$m_json
      if (( m > idle_at )); then
        # json が動いた（裏の作業の出力か、agy が続きを始めた）→ 見張りは解除せず時計だけ戻す。動いた後の猶予は長め（GEMINI_IDLE_RESUME_GRACE、既定 300 秒）
        idle_at=$now; if (( grace < resume_grace )); then grace=$resume_grace; fi
      elif (( now - idle_at >= grace && ${#GEM_TRACK} <= GEM_BASE_PROCS )); then
        # テスト等の子が動いている間は idle だけで停止しない。全体の時間上限と無出力監視は維持。
        GEM_IDLE_KILLED=1
        print -u "$GEM_LOGFD" -- "$tag $(lanes_now) idle のまま ${grace} 秒 → 異常終了として停止（EXIT:3）"
        break
      fi
    fi
    if (( now - last >= noout_sec )); then
      GEM_NOOUT=1
      print -u "$GEM_LOGFD" -- "$tag $(lanes_now) json / stderr が ${noout_sec} 秒更新なし → 停止（EXIT:8）"
      break
    fi
  done
  if (( GEM_IDLE_KILLED || GEM_NOOUT )); then gem_kill_all; fi
  wait "$LANES_CHILD" 2>/dev/null || GEM_RC=$?
  exec {GEM_LOGFD}>&- {GEM_ERR_RFD}<&-
  lanes_logdir_check
  # 監督役の終了は子孫の回収完了を意味する。終了後に集団番号を再利用しない。
  LANES_CHILD=""; GEM_PGID=""
  # 子が実行中に公開用の logs/<label>.json を消した・書き換えた・切り詰めたら改ざんとして知らせる（判定はランチャ。中身は親専用の写しを使う）
  if ! gem_check_public "$GEM_STREAM_FD" "$j" $(( GEM_IDLE_KILLED || GEM_NOOUT )); then
    GEM_PUBLIC_TAMPERED=1
    ( print -u2 -- "$tag 子の実行中に公開用の stream-json（$j）が消された・書き換えられた（受け取った中身と違う）" ) || true
  fi
  # 公開用の logs/<label>.json を、受け取った中身（親専用の写し）で置き換える（残る記録を受け取った中身にそろえる）
  if ! gem_publish_stream "$GEM_STREAM_FD" "$j"; then
    GEM_PUBLISH_FAILED=1
    ( print -u2 -- "$tag 公開用の stream-json（$j）を受け取った中身で置き換えられない。公開用は消した（監査は親専用の写しで行う）" ) || true
  fi
  GEM_SECS=$(( $(date +%s) - ta ))
  return 0
}

# 親専用の写し（番号 <fd>）を、<コマンド...> の番号 3 に渡して実行する（監査の python が頭へ戻してから os.fdopen(3) で読む）
gem_stream_read() {   # <fd> <コマンド...>
  local fd="$1"; shift
  [[ "$fd" == <-> ]] || return 1
  "$@" 3<&$fd
}
