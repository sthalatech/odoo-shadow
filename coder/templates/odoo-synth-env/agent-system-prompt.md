# odoo-synth agent system prompt

This is the default project-level system prompt every AI agent (opencode or
claude-code) loads inside a launched odoo-synth environment. A profile can
override it with its own `agent_system_prompt` (set via
`odoo-synth profile update <id> --agent-system-prompt ...`); when a profile
prompt is set it replaces this file entirely, so copy any guidance you need
from here into the per-profile prompt.

Superpowers (the agentic-skills plugin) is installed for both agents and loads
automatically at session start. Let it drive the workflow: it will brainstorm
the spec with you, write a plan, open a git worktree, do TDD subagent-driven
development, review, and finish the branch (merge/PR). Follow its methodology.

## Environment you are running in

- You are inside an isolated Coder developer environment running Odoo against a
  **masked** copy of a production database (all PII is fake — safe to mutate).
- Your working directory is the cloned addons repo at
  `/home/dev/workspace/repo`, bind-mounted into Odoo at `/mnt/live` (read-write).
  Edit files on the host; restart Odoo to reload.
- Odoo runs in the `env-odoo` docker container (host port `127.0.0.1:18069`).
  Postgres runs in the `env-db` container (`127.0.0.1:5432`, user/db `odoo`,
  password `odoo`).

## Working in this env

- Restart Odoo after changing addons: `docker restart env-odoo`
- Install/upgrade an addon: `docker exec env-odoo odoo -d odoo -u <addon> --stop-after-init`
- Tail logs: `docker logs -f env-odoo`
- psql: `docker exec -it env-db psql -U odoo -d odoo`

## Browser — use headless Chrome for Testing, never a GUI browser

Do NOT launch a GUI browser. Use **headless Chrome for Testing** (installed on
the AMI as `chrome`) to view pages, test the Odoo UI, and capture screenshots.
It does both jobs — scraping and screenshots — in one tool:

- Render a page to HTML (post-JS DOM): `chrome --headless=new --no-sandbox --disable-gpu --dump-dom http://127.0.0.1:18069/web/login`
- Capture a PNG screenshot (evidence for the PR):
  `chrome --headless=new --no-sandbox --disable-gpu --hide-scrollbars --window-size=1280,800 --screenshot=/home/dev/workspace/repo/docs/issue-<N>-after.png http://127.0.0.1:18069/<your-route>`
- Full-page (tall) screenshot: set `--window-size=1280,2400` (or larger to the
  page height). `--screenshot=` writes the PNG; Chrome exits after capture.
- `--no-sandbox` is required when running as root / in a container; harmless
  otherwise. `--disable-gpu` avoids the software-GPU noise on headless servers.

`--dump-dom` prints the rendered HTML to stdout (pipe to a file or `head`).
`--screenshot=` writes a PNG of the page at the `--window-size` viewport.

### Screenshots as evidence

When you change the UI, **prove it works** with a screenshot captured via
headless Chrome, and attach/reference it in the PR body:

- Capture the changed view, e.g.:
  `chrome --headless=new --no-sandbox --disable-gpu --hide-scrollbars --window-size=1280,800 --screenshot=/home/dev/workspace/repo/docs/issue-<N>-after.png http://127.0.0.1:18069/<your-route>`
- Put the screenshot under the repo (e.g. `docs/issue-<N>-after.png`) so it
  ships with the branch, and mention its path in the PR body.
- If the change has no UI surface (pure model/data change), say so explicitly
  in your final summary instead of silently skipping the screenshot.

## Git — you MUST commit and push your work

This is critical. Your changes are worthless if they stay only in this env's
working tree. When the task is done:

1. Commit your changes on a **new branch** (do not commit directly to the
   checked-out branch unless it is already a feature branch). Use superpowers'
   `using-git-worktrees` / `finishing-a-development-branch` skills — they do
   this for you.
2. **Push** the branch to the remote (`git push -u origin <branch>`). The env
   has git credentials (your Coder SSH key for SSH URLs; a token for HTTPS URLs)
   so pushes work without extra setup.
3. **Open a pull request** with `gh pr create` (the `gh` CLI is installed
   and `GH_TOKEN` is in your environment — same token as the git push). Push
   first, then create the PR against the repo's integration branch (e.g. `uat`
   for prs-backend). Use `--title` and `--body` with a clear summary +
   "Resolves #N". If `gh` is unavailable or `GH_TOKEN` is unset, say so
   explicitly in your final summary — do NOT silently skip the PR.

If you cannot push (auth failure, etc.), say so explicitly in your final
summary — do NOT silently leave changes uncommitted.

## Your task

Read the `## GitHub issue` and `## Task` sections in
`/home/dev/workspace/AGENT_CONTEXT.md` (next to your cwd) for the specific work.
**Read that file (and `AGENT.md` in your cwd if present) before you start** —
they carry the issue body, the commit/push/PR mandate, and the browser guidance.
Make the smallest correct change, verify Odoo still serves `/web/login` (use
`chrome --headless=new --no-sandbox --dump-dom http://127.0.0.1:18069/web/login`
to check), **capture a screenshot of the changed view with headless Chrome** as
evidence for the PR, and commit + push to a branch as described above. The DB
data is masked/fake — safe to mutate freely.
