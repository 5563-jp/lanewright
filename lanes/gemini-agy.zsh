# gemini-agy.zsh — run-gemini.sh（Gemini 実装）と run-gemini-review.sh（Gemini レビュー）が source する、agy の起動と見張り。
# _common.sh を読んだ後に読む（lanes_start_child_in・lanes_kill_child・lanes_record_child・lanes_logdir_check・lanes_write_new_at・
# lanes_now を使う）。
# 呼び出し元が用意する変数:
#   cmd（agy のコマンドの配列。-p より前まで）/ final（渡す全文のファイル）/ log（ランチャのログ）/ wt / gitdir / scratch（最小 gitconfig と
#   親専用の写しを一時的に作る場所）/ poll / idle_grace / resume_grace / noout_sec（見張りの秒数）/ GEM_TAG（ログの行の頭。既定 [run-gemini]）
# 起動のしかた:
#   - 子（監督役・受け取り役・agy）の作業場所（cwd）だけを worktree にする（lanes_start_child_in）。呼び出し元のシェルは移らない
#   - agy の標準出力（stream-json）は受け取り役（gemini-stream-tee.py）がパイプで直接受け取り、公開用の logs/<label>.json と、
#     親専用の写し（子の起動前に作ってすぐ名前を消した一時ファイル。開いた番号 GEM_STREAM_FD だけが残る）の両方へ書く。
#     子は logs/ に書けるので、監査（書き込みの試み・最後の応答）は親専用の写しを読む（gem_stream_read）。子と孫の回収が済んだら、
#     公開用を親専用の写しと突き合わせ（消された・書き換えられた → GEM_PUBLIC_TAMPERED=1。ランチャは改ざんとして不合格にする）、
#     そのあと公開用の logs/<label>.json を親専用の写しで置き換える（残る記録を受け取った中身にそろえる）
# 見張りの考え方（実装・レビューで同じ）:
#   - 出力（json・stderr）が noout_sec 秒止まったら停止（GEM_NOOUT=1。ランチャは EXIT:8）
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
typeset -g GEM_STREAM_FD="" GEM_STREAM_WFD=""
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
# （<allow_prefix> = 1）。止めていないのに頭の部分しか無いのは、子が切り詰めた（または公開用へ書けなかった）ので違うとする
gem_check_public() {   # <fd> <path> <allow_prefix 0|1>
  [[ "$1" == <-> ]] || return 1
  python3 -I -c 'import os, stat, sys
d, name, allow_prefix = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
def read_all(fd):
    parts = []
    while True:
        b = os.read(fd, 1 << 20)
        if not b:
            return b"".join(parts)
        parts.append(b)
os.lseek(3, 0, os.SEEK_SET)
private = read_all(3)
try:
    dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        sys.exit(1)
    public = read_all(fd)
except OSError:
    sys.exit(1)
sys.exit(0 if public == private or (allow_prefix and private.startswith(public)) else 1)' "${2:h}" "${2:t}" "${3:-0}" 3<&$1
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

mtime_of() { local m; m="$(stat -f %m "$1" 2>/dev/null)" || m=0; print -- "${m:-0}"; }
idle_count() { local n; n="$(grep -c 'root agent idle' "$1" 2>/dev/null)" || n=0; print -- "${n:-0}"; }

# agy を 1 回走らせて見張る。結果: GEM_RC / GEM_IDLE_KILLED / GEM_NOOUT / GEM_SECS / GEM_STREAM_FD（親専用の写し）/
#   GEM_PUBLIC_TAMPERED（公開用の json が受け取った中身と違った）/ GEM_PUBLISH_FAILED（公開用を置き換えられず消した）
run_agy_once() {
  local j="$1" e="$2" now last m idle_at=0 idle_seen=0 n ta grace=$idle_grace tag="${GEM_TAG:-[run-gemini]}" stream_tmp
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
  ANTIGRAVITY_HEADLESS=true GIT_DIR="$gitdir" GIT_WORK_TREE="$wt" GIT_CONFIG_GLOBAL="$scratch/gitconfig" GIT_OPTIONAL_LOCKS=0 GIT_PAGER=cat \
    lanes_start_child_in "$wt" python3 -I "$LANES_DIR/gemini-stream-tee.py" "${j:h}" "${j:t}" -- "${cmd[@]}" -p "$(<"$final")" \
    < /dev/null >&$GEM_STREAM_WFD 2> "$e"
  exec {GEM_STREAM_WFD}>&-
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
    m="$(mtime_of "$j")"; if (( m > last )); then last=$m; fi
    m="$(mtime_of "$e")"; if (( m > last )); then last=$m; fi
    n="$(idle_count "$e")"
    if (( n > idle_seen )); then
      idle_seen=$n; idle_at=$now; grace=$idle_grace
      print -u "$GEM_LOGFD" -- "$tag $(lanes_now) agy が idle（裏の作業待ち）。子の処理が無く、json が ${idle_grace} 秒動かなければ異常終了として停止"
    fi
    if (( idle_at > 0 )); then
      m="$(mtime_of "$j")"
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
  exec {GEM_LOGFD}>&-
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
