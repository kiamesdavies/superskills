---
name: openspec-stack
description: Build several OpenSpec changes in parallel as stacked branches, and land them in order on main or a release branch. Each change gets its own git worktree, its own agent and its own pull request. A helper script commits each proposal on the trunk and cuts each change's branch from the change it builds on. It opens each PR against that change and links the chain as a GitHub stacked pull request. After merges, it archives the changes in merge order, moves the open ones onto the trunk, and removes the landed worktrees and branches. Use it when the user wants to split work into several OpenSpec changes, build changes in parallel or in worktrees, or stack PRs. Use it too when they hand a change to another agent or work against a release branch. Use it when they ask where their changes stand or need a merged change archived, even if they never say "stack". It wraps /opsx:propose, /opsx:apply and /opsx:archive; it does not replace them.
compatibility: Needs git and the OpenSpec CLI. Pull requests need the GitHub CLI (gh); linked stacks need its gh-stack extension.
---

# OpenSpec stack

OpenSpec plans one change at a time. It has no idea of branches, worktrees, PR order or which change builds on which. This skill adds that layer: a small script (`scripts/stack.sh`) does the git and gh steps, and the rules below keep parallel changes from trampling each other.

## The model

- **A trunk is the branch a stack lands on.** It is `main` by default, or a release branch such as `release/1.2`. Everything below that says "trunk" means whichever one the change lands on. A change inherits its trunk from its parent.
- **One planner, many owners.** The planner is the session that splits the work, proposes on the trunk, starts each change's owner, and lands merged PRs. Owners are separate agents, one per change, each in its own worktree. Keeping them apart means the planner never waits on a build, and no build ever runs on the trunk.
- **One change, one branch, one worktree, one owner.** A change's `tasks.md` is a single to-do list with one owner ticking it. Two agents on one change means two agents editing the same files and the same list. Parallel work comes from more changes, never from more agents on one change. Helpers inside a change are fine for reading, reviewing, or task groups that touch different files, with the owner still doing the ticking. If a change feels too big for one agent, split it into two changes.
- **Propose on the trunk, and commit the planning files.** The agent proposing a change on the trunk can read the main specs and every other change in flight. A worktree only sees committed files, so an uncommitted proposal never reaches the worktree that builds it.
- **Once a change has started, edit its plan only in its worktree.** From `stack.sh start` on, the change's proposal, design, specs and tasks belong to its owner. When the change is cut from a parent branch that predates its proposal, `start` copies the plan in from the trunk; if the planner then edits that plan on the trunk, the owner's copy and the trunk's disagree and the restack after the parent lands stops on a conflict. A planner who wants the plan changed tells the owner.
- **Proposing needs the parent's plan; building needs the parent's code.** Change B can be proposed as soon as change A's proposal is committed on the trunk; it does not wait for A to be built. B's branch is cut from A's branch once A has the parts B relies on. If B never touches A's code, cut B from the trunk and there is no stack.
- **A PR targets its parent's branch, and a linear chain is a GitHub stack.** B's PR goes into A's branch until A merges, then into the trunk. GitHub's stacked pull requests show such a chain as one stack: a stack map in each PR's merge box, and an atomic merge of every PR up to the one chosen. GitHub stacks are strictly linear, so when two changes are stacked on the same parent, neither chain is linked; their PRs still target the parent and land the same way.
- **Archive only on the trunk, only after the PR merges, in merge order.** Archiving rewrites the shared main specs. Done on a branch or before merge, it races other changes and records behaviour the trunk does not have yet. Archiving in merge order also means a change that modifies another change's requirements finds them in place.

```
step  trunk                   branch-A (from trunk)   branch-B (from branch-A)
----  ----------------------  ----------------------  ------------------------
1     propose A, commit
2                             cut from trunk
3     propose B, commit       build A
4                             build A                 cut from branch-A
5                             PR into trunk           build B
6     merge A, archive A                              rebase onto trunk
7                                                     PR into trunk
8     merge B, archive B
```

## The script

Run it from anywhere inside the repo, by its full path: `scripts/stack.sh` in this skill's folder. It keeps the stack in git config, which every worktree of the clone shares: each change's branch, parent (a trunk branch or another change) and trunk. Worktrees go in `~/.agents/worktrees/<repo>/<change>`, outside the repo (change it with `git config openspec-stack.worktrees <dir>`). The default trunk is `main` (change it with `git config openspec-stack.trunk <branch>`). Set `STACK_NO_GH=1` to skip gh.

| Command | Does |
|---|---|
| `stack.sh status` | Every change: trunk, tasks done, branch, parent, PR, or archived |
| `stack.sh proposed <change> [--trunk <branch>] [--also <path>]... [--push]` | On the trunk: validates the change and commits only its folder, plus any `--also` paths (such as the requirements doc it answers); files other sessions staged stay staged and out of the commit. Optionally pushes |
| `stack.sh start <change> [--parent <change\|trunk>] [--branch <name>] [--path <dir>]` | Cuts `change/<change>` from the parent into a worktree in the worktrees folder. If the parent's branch predates this change's proposal, it brings the planning files in from the trunk as one commit, which drops out on the later rebase |
| `stack.sh adopt <change> <branch> [--parent <change\|trunk>]` | Records a branch made some other way |
| `stack.sh pr <change> [--body-file <file>] [--draft]` | Pushes the branch and opens its PR against the parent (or retargets an existing one). When `gh stack` is installed and the chain from the trunk up to this change is linear, it links the chain as a GitHub stack with `gh stack link --base <trunk>` |
| `stack.sh landed <change> [--force]` | On the change's trunk, after the PR merged on its own or in a stack merge: pulls, checks every change from the bottom of the chain up to this one has merged, refuses if tasks are unticked, archives them bottom up with `openspec archive`, commits, pushes, removes each landed change's worktree (keeping any that holds uncommitted work), restacks the children, then deletes each landed change's local branch and its record in git config (not a branch whose worktree was kept) |
| `stack.sh restack <change>` | Moves the change's open children onto its trunk and retargets their PRs. When GitHub already rebased a stacked PR itself, it starts from GitHub's version; otherwise it rebases. It force-pushes with lease, and skips children that merged too |

`landed` finds the children from the git config entries whose parent is the landed change. That record is local to this clone, so start or adopt every change in the stack from the same clone.

## The workflow

1. **Plan the split.** Explore the work (`/opsx:explore`, an architecture sketch) and decide the changes, their order and their trunk. OpenSpec does not record order between changes; write it down where the team keeps plans, for example a "Depends on" column in the requirements index, and tell the user which change is stacked on which.
2. **Propose each change on the trunk.** Check the tree is clean, run `/opsx:propose`, then `stack.sh proposed <change>` (add `--trunk release/1.2` for a release branch). Push when the user wants others to see it. Propose the next change while earlier ones are being built.
3. **Hand each change to a new owner.** The session you are in is the planner, and it never builds a change itself. It stays on the trunk so it can keep proposing the next changes and land the merged ones. Each change is built by a separate agent, started fresh in that change's worktree. Pick the change's parent (the trunk, or the change whose code it builds on) and run `stack.sh start <change> --parent <parent>`; it prints the worktree's path.
   - **In the Claude desktop app**, start a new session as the owner: `start_session` with `initiation: "user_asked"`, `context: "fresh"`, `cwd` set to the printed path, `use_worktree: false`, and the brief below. It runs on its own in that worktree while this session carries on planning, and it reports back when it finishes a turn.
   - **Anywhere else**, open a new agent (another terminal, another tool) in the printed path and give it the brief below. Do not build the change in the planner's own session.
4. **The owner builds in its worktree.** It runs `/opsx:apply <change>`, ticks tasks as they pass, and commits to its branch. It never archives.
5. **Open the PR.** `stack.sh pr <change>`, from the bottom of a chain up, so each parent's PR exists before its child links to it. Pass `--body-file` when the PR body needs more than the proposal's Why, such as an attribution line the session requires.
6. **Merge, one PR or a whole stack.** Merging is the user's or reviewer's call. A single PR merges as usual. A linked stack can be merged in one go, up to any PR in it, from the stack map in GitHub's merge box or with `gh stack merge <top PR>`: all of them or none. GitHub checks every PR in it against the trunk's rules (reviews, required checks), retargets the PRs above it to the trunk, and rebases them.
7. **When PRs merge**, switch to the trunk and run `stack.sh landed <change>` with the topmost merged change. It archives every merged change from the bottom up in merge order, pushes the trunk, removes the landed changes' worktrees, moves the open children onto the trunk, and deletes the landed changes' local branches. Report what moved and which worktrees and branches went; an owner session still open in a removed worktree has finished its job and can be archived.
8. **Check where things stand** at any point with `stack.sh status`, or on GitHub in any linked PR's stack map. (`gh stack view` reads gh-stack's own local tracking, which `link` does not create, so it shows nothing here.)

## Brief for an owning session

```
Build the OpenSpec change `<change>` in this worktree (branch `<branch>`, cut from `<parent branch>`, landing on `<trunk>`).
Run /opsx:apply <change>, tick each task in openspec/changes/<change>/tasks.md as it passes, and commit to this branch.
You are the only owner of this change: do not split its tasks.md between agents.
Do not archive the change: it is archived on `<trunk>` after its PR merges.
When all tasks are done, run `<path to stack.sh> pr <change>` and report the PR link.
```

## When something goes wrong

- **`start` says the change is not committed on the trunk:** run `stack.sh proposed <change>` (with `--trunk` if needed) first. Proposing inside the worktree is the mistake this guards against: that agent would not see the other changes in flight.
- **`landed` says a change below is not merged:** merge it first, or merge the stack up to this change; then land the topmost merged change.
- **`pr` says the chain is not linked:** either a change below has two changes stacked on it (GitHub stacks are linear) or a parent's PR is not open yet. The PR still targets its parent, so it lands the same way, just without the stack map.
- **The user edits a started change's plan on the trunk:** move that edit into the owner's worktree before the parent lands, or the restack conflicts.
- **`landed` says the PR is not merged:** stop. Do not archive. Archive only after the merge.
- **A restack stops on a conflict:** resolve it in the worktree the message names, run `git rebase --continue`, then run `stack.sh restack <parent change>` again. Tell the change's owner its branch moved. The landed changes' branches are still there, because the restack needs them; run `stack.sh landed <change>` again to delete them.
- **A worktree has uncommitted changes:** the restack refuses rather than rebase under someone's work. Ask the owner to commit first.
- **`landed` kept a worktree:** it held uncommitted changes, so neither it nor its branch was removed. Look at them with the user; once they are saved elsewhere or discarded, run `stack.sh landed <change>` again: it skips what is already archived and removes the worktree and the branch.
- **Two changes modify the same requirement:** whichever archives second must update its delta to the first one's wording before landing. `openspec validate <change> --strict` on the trunk after the first lands will show it.
- **A release branch later merges into main:** its archived changes and main specs come with it; nothing is archived twice.
