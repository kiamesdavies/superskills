#!/usr/bin/env bash
# openspec-stack: the git and gh steps of running several OpenSpec changes as stacked branches.
#
#   stack.sh status                                   every change: trunk, tasks, branch, parent, PR, archived or not
#   stack.sh proposed <change> [--trunk <branch>] [--also <path>]... [--push]
#                                                     on the trunk: validate and commit the change's planning files
#   stack.sh start <change> [--parent <change|trunk branch>] [--branch <name>] [--path <dir>] [--no-worktree]
#                                                     cut the change's branch and worktree from its parent
#   stack.sh adopt <change> <branch> [--parent <change|trunk branch>]
#                                                     record a branch made elsewhere
#   stack.sh pr <change> [--body-file <file>] [--draft]
#                                                     push the branch, open its PR against its parent, and link the chain
#                                                     as a GitHub stack when gh-stack is installed and the chain is linear
#   stack.sh landed <change> [--force]                after its PR merged (alone or in a stack merge): archive it, and every
#                                                     merged change below it, on its trunk; remove their worktrees; restack
#                                                     the children; then delete their branches and records
#   stack.sh restack <change>                         rebase the change's children onto its trunk and retarget their PRs
#
# A trunk is the branch a stack lands on: main, or a release branch such as release/1.2. A change's parent is either a
# trunk branch or another change; its trunk is inherited from that parent. The stack lives in git config, shared by
# every worktree of the clone:
#   openspec-stack.<change>.branch   the change's branch
#   openspec-stack.<change>.parent   its parent: a trunk branch or a change name
#   openspec-stack.<change>.trunk    the branch it lands on
#   openspec-stack.trunk             the default trunk (main when unset)
#   openspec-stack.worktrees         where worktrees go (default ~/.agents/worktrees, or $OPENSPEC_STACK_WORKTREES)
# STACK_NO_GH=1 skips every gh step (pushes still happen when there is an origin).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

die() { echo "stack: $*" >&2; exit 1; }
say() { echo "stack: $*"; }
cfg() { git config --get "openspec-stack.$1.$2" || true; }
setcfg() { git config "openspec-stack.$1.$2" "$3"; }
DEFAULT_TRUNK=$(git config --get openspec-stack.trunk || git config --get openspec-stack.main || echo main)
WORKTREES=$(git config --get openspec-stack.worktrees || echo "${OPENSPEC_STACK_WORKTREES:-$HOME/.agents/worktrees}")
WORKTREES=${WORKTREES/#\~/$HOME}
main_root() { git worktree list --porcelain | awk 'NR == 1 { print substr($0, 10) }'; }
repo_name() { basename -s .git "$(git remote get-url origin 2>/dev/null || main_root)"; }
has_origin() { git remote get-url origin >/dev/null 2>&1; }
have_gh() { [ -z "${STACK_NO_GH:-}" ] && command -v gh >/dev/null && git remote get-url origin 2>/dev/null | grep -q github.com; }
worktree_of() { git worktree list --porcelain | awk -v b="branch refs/heads/$1" '/^worktree / { w = substr($0, 10) } $0 == b { print w }'; }
is_change() { [ -n "$(cfg "$1" branch)" ]; }
on_branch() { [ "$(git branch --show-current)" = "$1" ] || die "run this on $1 (now on $(git branch --show-current))"; }
clean() { [ -z "$(git -C "${1:-.}" status --porcelain)" ] || die "${1:-this checkout} has uncommitted changes: commit or set them aside first"; }
trunk_of() { local t; t=$(cfg "$1" trunk); echo "${t:-$DEFAULT_TRUNK}"; }
branch_of() {  # a change's branch, or a trunk branch as itself
  if is_change "$1"; then cfg "$1" branch
  elif git rev-parse --verify -q "refs/heads/$1" >/dev/null; then echo "$1"
  else die "'$1' is neither a recorded change nor a local branch"; fi
}
chain_to() {  # the open changes from the bottom of the stack up to this one
  local x="$1" out=""
  while is_change "$x"; do out="$x $out"; x=$(cfg "$x" parent); done
  echo $out
}
is_merged() {
  local b; b=$(branch_of "$1")
  if have_gh; then [ "$(gh pr view "$b" --json state -q .state 2>/dev/null)" = MERGED ]
  else git merge-base --is-ancestor "$b" "$(trunk_of "$1")"; fi
}
trunk_for_parent() { if is_change "$1"; then trunk_of "$1"; else branch_of "$1"; fi; }
children_of() {
  git config --get-regexp '^openspec-stack\..*\.parent$' 2>/dev/null |
    awk -v p="$1" '$2 == p { sub(/^openspec-stack\./, "", $1); sub(/\.parent$/, "", $1); print $1 }'
}
tasks_count() {  # "done/total" from the freshest copy: its worktree, else its branch, else its trunk
  local c="$1" b wt text done total
  b=$(cfg "$c" branch); wt=$([ -n "$b" ] && worktree_of "$b" || true)
  if [ -n "$wt" ] && [ -f "$wt/openspec/changes/$c/tasks.md" ]; then text=$(cat "$wt/openspec/changes/$c/tasks.md")
  elif [ -n "$b" ] && text=$(git show "$b:openspec/changes/$c/tasks.md" 2>/dev/null); then :
  elif text=$(git show "$(trunk_of "$c"):openspec/changes/$c/tasks.md" 2>/dev/null); then :
  else echo "-"; return; fi
  done=$(printf '%s\n' "$text" | grep -cE '^[[:space:]]*- \[[xX]\]' || true)
  total=$(printf '%s\n' "$text" | grep -cE '^[[:space:]]*- \[.?\]' || true)
  echo "$done/$total"
}
archived_on() { git ls-tree --name-only "$2:openspec/changes/archive" 2>/dev/null | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}-$1\$"; }
pr_of() { have_gh && gh pr view "$1" --json number,state,baseRefName -q '"#\(.number) \(.state) into \(.baseRefName)"' 2>/dev/null || echo "-"; }

cmd_status() {
  local names c b t
  names=$( { git config --get-regexp '^openspec-stack\..*\.branch$' 2>/dev/null | awk '{ sub(/^openspec-stack\./, "", $1); sub(/\.branch$/, "", $1); print $1 }'
             git ls-tree --name-only "$DEFAULT_TRUNK:openspec/changes" 2>/dev/null | grep -v '^archive$' || true; } | sort -u)
  printf '%-28s %-16s %-7s %-34s %-20s %s\n' CHANGE TRUNK TASKS BRANCH PARENT PR
  for c in $names; do
    b=$(cfg "$c" branch); t=$(trunk_of "$c")
    if archived_on "$c" "$t"; then
      printf '%-28s %-16s %-7s %-34s %-20s %s\n' "$c" "$t" done "${b:--}" "$(cfg "$c" parent)" "archived on $t"
    else
      printf '%-28s %-16s %-7s %-34s %-20s %s\n' "$c" "$t" "$(tasks_count "$c")" "${b:-(not started)}" "$(cfg "$c" parent)" \
        "$([ -n "$b" ] && pr_of "$b" || echo -)"
    fi
  done
}

cmd_proposed() {
  local c="${1:?change name}" trunk="$DEFAULT_TRUNK" push=""; shift
  local paths=("openspec/changes/$c")
  while [ $# -gt 0 ]; do case "$1" in
    --trunk) trunk="$2"; shift 2 ;; --push) push=1; shift ;; --also) paths+=("$2"); shift 2 ;;
    *) die "unknown option $1" ;; esac; done
  on_branch "$trunk"
  [ -f "openspec/changes/$c/proposal.md" ] || die "no openspec/changes/$c/proposal.md here: propose it on $trunk first (/opsx:propose)"
  openspec validate "$c" --strict >/dev/null || die "openspec validate $c --strict fails: fix the change first"
  # Only these paths go into the commit; anything else staged here (another session's work) stays staged.
  git add -- "${paths[@]}"
  if git diff --cached --quiet -- "${paths[@]}"; then say "openspec/changes/$c is already committed on $trunk"
  else git commit -q -m "Propose $c" -- "${paths[@]}" && say "committed the $c proposal on $trunk"; fi
  if [ -n "$push" ] && has_origin; then git push -q origin "$trunk" && say "pushed $trunk"; fi
  return 0
}

cmd_start() {
  local c="${1:?change name}"; shift
  local parent="$DEFAULT_TRUNK" branch="" path="" worktree=1
  while [ $# -gt 0 ]; do case "$1" in
    --parent) parent="$2"; shift 2 ;; --branch) branch="$2"; shift 2 ;; --path) path="$2"; shift 2 ;;
    --no-worktree) worktree=""; shift ;; *) die "unknown option $1" ;; esac; done
  [ -z "$(cfg "$c" branch)" ] || die "$c already has branch $(cfg "$c" branch)"
  local base trunk; base=$(branch_of "$parent"); trunk=$(trunk_for_parent "$parent")
  git cat-file -e "$trunk:openspec/changes/$c/proposal.md" 2>/dev/null ||
    die "openspec/changes/$c is not committed on $trunk: run stack.sh proposed $c${trunk:+ --trunk $trunk} first (a worktree only sees committed files)"
  branch=${branch:-change/$c}
  path=${path:-$WORKTREES/$(repo_name)/$c}
  if [ -n "$worktree" ]; then
    mkdir -p "$(dirname "$path")"
    git worktree add -q -b "$branch" "$path" "$base"
    if ! git -C "$path" cat-file -e "HEAD:openspec/changes/$c/proposal.md" 2>/dev/null; then
      # Cut from a parent branch older than this change's proposal: bring the planning files in from the trunk.
      git -C "$path" checkout "$trunk" -- "openspec/changes/$c"
      git -C "$path" commit -q -m "Bring in the $c proposal from $trunk"
    fi
  else
    git cat-file -e "$base:openspec/changes/$c/proposal.md" 2>/dev/null || die "$base lacks the $c proposal: use a worktree so it can be brought in"
    git branch "$branch" "$base"
  fi
  setcfg "$c" branch "$branch"; setcfg "$c" parent "$parent"; setcfg "$c" trunk "$trunk"
  say "$c: branch $branch from $base, lands on $trunk${worktree:+, worktree $path}"
  if [ -n "$worktree" ]; then say "next: in $path run /opsx:apply $c, then stack.sh pr $c"; fi
}

cmd_adopt() {
  local c="${1:?change name}" branch="${2:?branch}" parent="$DEFAULT_TRUNK"; shift 2
  [ "${1:-}" = --parent ] && parent="$2"
  git rev-parse --verify -q "refs/heads/$branch" >/dev/null || die "no local branch $branch"
  local trunk; trunk=$(trunk_for_parent "$parent")
  setcfg "$c" branch "$branch"; setcfg "$c" parent "$parent"; setcfg "$c" trunk "$trunk"
  say "$c: recorded branch $branch, parent $parent, lands on $trunk"
}

cmd_pr() {
  local c="${1:?change name}" body="" draft=""; shift
  while [ $# -gt 0 ]; do case "$1" in
    --body-file) body="$2"; shift 2 ;; --draft) draft=--draft; shift ;; *) die "unknown option $1" ;; esac; done
  is_change "$c" || die "no branch recorded for $c: start or adopt it first"
  local branch base trunk; branch=$(branch_of "$c"); base=$(branch_of "$(cfg "$c" parent)"); trunk=$(trunk_of "$c")
  has_origin || die "no origin remote to push to"
  git push -q -u origin "$branch" && say "pushed $branch"
  have_gh || { say "gh not used: open a PR from $branch into $base by hand"; return 0; }
  if gh pr view "$branch" --json number >/dev/null 2>&1; then
    gh pr edit "$branch" --base "$base" >/dev/null && say "PR for $branch now targets $base"
    link_stack "$c"; return 0
  fi
  if [ -z "$body" ]; then
    body=$(mktemp)
    { echo "OpenSpec change \`$c\` (openspec/changes/$c), landing on \`$trunk\`."; echo
      if [ "$base" != "$trunk" ]; then echo "Stacked on \`$base\`: merge that first."; echo; fi
      git show "$branch:openspec/changes/$c/proposal.md" | awk '/^## Why/ { f = 1; next } /^## / { f = 0 } f'; } > "$body"
  fi
  gh pr create --head "$branch" --base "$base" --title "$c" --body-file "$body" $draft
  link_stack "$c"
}

link_stack() {  # show the chain as a stack on GitHub; GitHub stacks are linear, so a chain with a fork is left unlinked
  local c="$1" chain ch branches=""
  gh stack --help >/dev/null 2>&1 || return 0
  chain=$(chain_to "$c")
  [ "$(echo $chain | wc -w)" -ge 2 ] || return 0
  for ch in $chain; do
    if [ "$ch" != "$c" ] && [ "$(children_of "$ch" | wc -l)" -gt 1 ]; then
      say "not linked as a GitHub stack: $ch has more than one change on it, and GitHub stacks are linear (the PR still targets its parent)"
      return 0
    fi
    if [ "$ch" != "$c" ] && ! gh pr view "$(branch_of "$ch")" --json number >/dev/null 2>&1; then
      say "not linked as a GitHub stack yet: open $ch's PR first (stack.sh pr $ch), then run stack.sh pr $c again"
      return 0
    fi
    branches="$branches $(branch_of "$ch")"
  done
  gh stack link --base "$(trunk_of "$c")" $branches >/dev/null && say "linked as a GitHub stack:$branches"
}

cmd_landed() {
  local c="${1:?change name}" force=""; shift; [ "${1:-}" = --force ] && force=1
  is_change "$c" || die "no branch recorded for $c"
  local trunk chain ch open; trunk=$(trunk_of "$c")
  on_branch "$trunk"; clean
  if has_origin; then git pull -q --ff-only origin "$trunk"; fi
  chain=$(chain_to "$c")
  for ch in $chain; do  # a stack merge merges everything below the chosen PR; anything else must already have landed
    is_merged "$ch" || die "$ch is not merged into $trunk: archive only after merge (for $c, land or merge $ch first)"
  done
  for ch in $chain; do
    if [ ! -d "openspec/changes/$ch" ]; then say "$ch is already archived on $trunk"; setcfg "$ch" parent "$trunk"; continue; fi
    open=$(grep -cE '^[[:space:]]*- \[ \]' "openspec/changes/$ch/tasks.md" 2>/dev/null || true)
    [ "${open:-0}" = 0 ] || [ -n "$force" ] || die "$ch has $open unticked tasks on $trunk: finish them, or pass --force"
    openspec archive "$ch" -y
    git add -A openspec
    git commit -q -m "Archive $ch" && say "archived $ch on $trunk"
    setcfg "$ch" parent "$trunk"
  done
  if has_origin; then git push -q origin "$trunk" && say "pushed $trunk"; fi
  # Worktrees go before the restack, so a restack that stops on a conflict still leaves none behind. Branches go after
  # it, because the restack rebases the children off them; after a conflict, run landed again to finish.
  for ch in $chain; do remove_worktree "$ch"; done
  for ch in $chain; do cmd_restack "$ch"; done
  for ch in $chain; do forget_change "$ch"; done
}

forget_change() {  # a landed change's local branch and its record, once its worktree is gone
  local c="$1" b; b=$(cfg "$c" branch)
  if [ -n "$b" ] && [ -n "$(worktree_of "$b")" ]; then say "kept $b: its worktree is still there"; return 0; fi
  if [ -n "$b" ] && git rev-parse -q --verify "refs/heads/$b" >/dev/null; then
    git branch -q -D "$b" && say "deleted branch $b"  # -D: a squash merge leaves it unmerged in git's eyes
  fi
  git config --remove-section "openspec-stack.$c" 2>/dev/null || true
}

remove_worktree() {  # a landed change's worktree, unless it holds uncommitted work
  local c="$1" b wt; b=$(cfg "$c" branch); wt=$([ -n "$b" ] && worktree_of "$b" || true)
  [ -n "$wt" ] && [ "$wt" != "$(main_root)" ] || return 0
  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    say "kept $wt: it has uncommitted changes; save or discard them, then git worktree remove $wt"; return 0
  fi
  git worktree remove "$wt" && say "removed $c's worktree $wt"
  rmdir "$(dirname "$wt")" 2>/dev/null || true  # the repo's folder in the worktrees folder, once it is empty
}

cmd_restack() {
  local c="${1:?change name}" old trunk child cb wt dir tmp before after took
  old=$(branch_of "$c"); trunk=$(trunk_of "$c")
  for child in $(children_of "$c"); do
    cb=$(branch_of "$child"); wt=$(worktree_of "$cb")
    if is_merged "$child"; then
      setcfg "$child" parent "$trunk"; say "$child is merged too: land it with stack.sh landed $child"; continue
    fi
    before=""; after=""; took=""
    if has_origin; then
      before=$(git rev-parse -q --verify "refs/remotes/origin/$cb" || true)
      git fetch -q origin "$cb" 2>/dev/null || true
      after=$(git rev-parse -q --verify "refs/remotes/origin/$cb" || true)
    fi
    dir=$wt; tmp=""
    if [ -z "$dir" ]; then tmp=$(mktemp -d); git worktree add -q "$tmp" "$cb"; dir=$tmp; else clean "$dir"; fi
    if [ -n "$before" ] && [ -n "$after" ] && ! git merge-base --is-ancestor "$before" "$after" &&
       [ "$(git -C "$dir" rev-parse HEAD)" = "$before" ]; then
      # GitHub rebased this stacked PR itself when its parent merged: start from its version.
      git -C "$dir" reset -q --hard "$after"; took=1
    fi
    if [ -n "$took" ]; then git -C "$dir" rebase -q "$trunk"; else git -C "$dir" rebase -q --onto "$trunk" "$old"; fi ||
      die "rebasing $cb stopped on a conflict: resolve it in $dir, run git rebase --continue, then stack.sh restack $c again"
    [ -z "$tmp" ] || git worktree remove "$tmp"
    setcfg "$child" parent "$trunk"
    say "$child: $cb now sits on $trunk${took:+ (starting from the rebase GitHub made)}"
    if [ -n "$after" ]; then
      git push -q --force-with-lease origin "$cb" && say "pushed $cb"
      if have_gh && gh pr view "$cb" --json number >/dev/null 2>&1; then
        gh pr edit "$cb" --base "$trunk" >/dev/null && say "PR for $cb now targets $trunk"
      fi
    fi
  done
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  status) cmd_status ;; proposed) cmd_proposed "$@" ;; start) cmd_start "$@" ;; adopt) cmd_adopt "$@" ;;
  pr) cmd_pr "$@" ;; landed) cmd_landed "$@" ;; restack) cmd_restack "$@" ;;
  -h|--help|help) sed -n '2,27p' "$0" ;; *) die "unknown command $cmd (try stack.sh help)" ;;
esac
