#!/bin/zsh -f
# リポ全体の後片付け。使い方:
#   cleanup-merged-worktrees.sh <本体 checkout> [--apply]
# 全 worktree に cleanup-after-merge.sh を回し、worktree を持たないマージ済みローカル枝も削除する。既定は dry-run。
# マージ済みの判定は統合先の枝（設定キー LANES_BASE_BRANCH。既定 develop）。main / master / 統合先は消さない。
set -euo pipefail
LANES_DIR="${0:A:h}"; source "$LANES_DIR/_common.sh"
base="${LANES_BASE_BRANCH:-develop}"
git check-ref-format --branch "$base" >/dev/null 2>&1 || lanes_die "LANES_BASE_BRANCH が枝名として不正: $base"
repo="${1:-}"; apply="${2:-}"
[[ -n "$repo" ]] || lanes_die "使い方: cleanup-merged-worktrees.sh <本体 checkout> [--apply]"
[[ -z "$apply" || "$apply" == "--apply" ]] || lanes_die "第2引数は --apply のみ"
lanes_require_worktree "$repo"
repo="$(git -C "$repo" rev-parse --path-format=absolute --show-toplevel)"

git -C "$repo" fetch -q origin "$base" || lanes_die "origin/$base の fetch に失敗"
failed=0
print -- "=== worktrees ==="
for wt in "${(@f)$(git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p')}"; do
  [[ -n "$wt" ]] || continue
  print -- ""
  "$LANES_DIR/cleanup-after-merge.sh" "$wt" $apply || { rc=$?; print -- "  (skip: exit $rc)"; failed=1; }
done

print -- ""; print -- "=== worktree を持たないローカル枝（origin/$base にマージ済み）==="
inuse=("${(@f)$(git -C "$repo" worktree list --porcelain | sed -n 's|^branch refs/heads/||p')}")
for b in "${(@f)$(git -C "$repo" for-each-ref --format='%(refname:lstrip=2)' refs/heads/)}"; do
  [[ -n "$b" ]] || continue
  [[ "$b" == "main" || "$b" == "master" || "$b" == "$base" ]] && continue
  (( ${inuse[(Ie)$b]} )) && continue
  tip="$(git -C "$repo" rev-parse "refs/heads/$b")"
  if git -C "$repo" merge-base --is-ancestor "$tip" "origin/$base" 2>/dev/null; then
    if [[ "$apply" == "--apply" ]]; then
      # 一覧取得後に別レーンが枝を使い始めた場合も保全する。
      if git -C "$repo" worktree list --porcelain | grep -Fx "branch refs/heads/$b" >/dev/null; then
        print -- "keep (別の worktree が使用中): $b"
        continue
      fi
      git -C "$repo" update-ref -d "refs/heads/$b" "$tip" || { failed=1; continue; }
      print -- "[apply] deleted $b"
    else
      print -- "[dry-run] 確認済みの先端と一致する場合だけローカル枝 $b を削除"
    fi
  else
    print -- "keep (未マージ or squash/rebase マージ): $b"
  fi
done

# 個別の停止を成功扱いにしない。
(( failed == 0 ))
