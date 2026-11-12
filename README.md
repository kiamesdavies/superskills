# superskills

Skills I've built for AI coding agents, shared so you can use them too.

A skill is a folder with a `SKILL.md` file: instructions, and sometimes scripts, that an agent such as Claude Code loads when a task calls for it. You install a skill once, and the agent uses it whenever your request matches what the skill is for.

## Skills

| Skill | What it does |
|---|---|
| [openspec-stack](skills/openspec-stack) | Builds several [OpenSpec](https://github.com/Fission-AI/OpenSpec) changes at once, each on its own branch, worktree and agent, and lands them in order as stacked pull requests. |

## Install

Install every skill in this repo with the [skills CLI](https://github.com/vercel-labs/skills):

```bash
npx skills add kiamesdavies/superskills
```

Or clone the repo and link the skills you want into your agent's skills folder. For Claude Code, that folder is `~/.claude/skills`:

```bash
git clone https://github.com/kiamesdavies/superskills.git
ln -s "$PWD/superskills/skills/openspec-stack" ~/.claude/skills/openspec-stack
```

A linked skill picks up new versions when you `git pull`.

## openspec-stack

OpenSpec keeps a written proposal, spec and task list for each change in your repo, and your agent builds the change from them. OpenSpec plans one change at a time. When a feature needs several changes, this skill adds the parts OpenSpec leaves out:

- which change builds on which;
- a branch and a git worktree (a second checkout of the same repo) for each change;
- one agent per change;
- the order the pull requests land in.

A typical run:

1. You and your agent split a feature into changes, for example a data model and then an API on top of it. Each proposal is committed on `main`.
2. Each change gets its own branch and worktree, cut from the change it builds on, and a separate agent builds it there. Your first session keeps planning the next changes.
3. Each pull request targets the branch of the change below it. A straight chain is linked as a GitHub stacked pull request, so reviewers see it as one stack and can merge it in one go.
4. When pull requests merge, the skill archives the changes on `main` in merge order, moves the open changes onto `main`, and removes the landed worktrees and branches.

It works the same way against a release branch such as `release/1.2`.

**Needs:** git and the [OpenSpec CLI](https://github.com/Fission-AI/OpenSpec). Opening pull requests needs the GitHub CLI (`gh`), and linking them as a stack needs its [gh-stack](https://github.com/github/gh-stack) extension (`gh extension install github/gh-stack`).

**Use it:** ask your agent to split work into several OpenSpec changes, to stack the pull requests, or to archive a change whose pull request merged. In Claude Code you can also type `/openspec-stack`. The helper script runs on its own too: `skills/openspec-stack/scripts/stack.sh help` lists its commands.

## License

MIT. See [LICENSE](LICENSE): use, change and share these skills freely, keeping the copyright notice.
