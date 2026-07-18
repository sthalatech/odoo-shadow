# odoo-synth agent system prompt (placeholder)

> **Phase 1 provision.** This file is the project-level system prompt every AI
> agent (opencode via ralph-wiggum, or claude-code) loads inside a launched
> odoo-synth environment. The GitHub Actions hook writes its contents into the
> workspace as `AGENT.md` (when the repo ships none) and as the "Project system
> prompt" section of `AGENT_CONTEXT.md`, so the agent follows this context for
> every issue-driven run.
>
> **TODO (later phase): fill in the real project context below.** Replace this
> placeholder with the project-specific guidance: repo layout, Odoo conventions,
> addons-path structure, how to run/upgrade modules in this env, testing
> expectations, and any constraints the agent must respect. Until then the agent
> receives this minimal scaffold so the wiring is end-to-end functional.

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

## Your task

Read the `## GitHub issue` and `## Task` sections in
`/home/dev/workspace/AGENT_CONTEXT.md` (next to your cwd) for the specific work.
Make the smallest correct change, verify Odoo still serves `/web/login`, and
prefer committing to a branch over force-pushing. The DB data is masked/fake.
