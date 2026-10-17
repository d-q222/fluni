# Rules for agents and collaborators

These rules apply to every human and AI agent (Claude, Codex, etc.) working in this repo.

1. **Claim before you build.** Add or update your row in [WORKSTREAMS.md](WORKSTREAMS.md), then
   commit and push that change *before* you start the work, so everyone can see it.
2. **Stay in your lane.** Each workstream owns its own top-level directory. Don't edit another
   workstream's files. To request a change, add a note under "Requests" in WORKSTREAMS.md or open a
   GitHub issue.
3. **Shared contracts live in `docs/`.** Anything two workstreams depend on, such as data formats,
   goes in `docs/`. Changing one needs agreement from every workstream that uses it. Record the
   decision in WORKSTREAMS.md.
4. **Pull before you push.** Run `git pull --rebase` before every push. Never force-push to `main`.
5. **Commit small and often**, with messages that say what changed and why.
6. **Keep it runnable.** Every workstream directory has a short README that explains how to run it.

The product spec is in [docs/PRD.md](docs/PRD.md).
