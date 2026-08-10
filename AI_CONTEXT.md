# 18xx.games – AI Context

## Project Overview
18xx.games is an open-source implementation of 18xx-style board games (stock market + train route-building). The codebase is a Ruby/Sinatra backend with an Opal-compiled JavaScript frontend.

- **Repo**: github.com/tobymao/18xx (contributor: ddaybell)
- **Local path**: C:\dev\18xx.games\18xx
- **Live site**: 18xx.games

## Tech Stack
- **Backend**: Ruby / Sinatra (Rack)
- **Frontend**: Opal (Ruby → JavaScript transpiler)
- **Database**: PostgreSQL
- **Dev environment**: Docker Compose (containers: `18xx-rack-1`, `18xx-db-1`)
- **Dev server**: http://localhost:9292

## Development Commands

### Start the dev stack
```
make
```

### Recompile after Ruby/JS changes
```
docker compose restart rack
```
**IMPORTANT**: Use `docker exec 18xx-rack-1 <cmd>` for all other docker commands — `docker compose exec` panics on this machine.

### Run tests (Windows — do NOT use assets_spec.rb; spec/fixtures is a broken symlink)
```
docker exec 18xx-rack-1 rspec spec/lib/engine/game/fixtures_spec.rb
docker exec 18xx-rack-1 rspec spec/lib/engine/game/fixtures_auto_actions_spec.rb
```

### Run rubocop (before PRs only — not during development)
```
# Strip CRLF first (Windows-edited files):
docker exec 18xx-rack-1 bash -c "sed -i 's/\r//' path/to/file.rb"
# Auto-correct:
docker exec 18xx-rack-1 rubocop -a path/to/file.rb
# Then manually check for non-auto-correctable issues (e.g. Style/UnlessLogicalOperators)
```

## Code Conventions
- Prefer `empty?` over `any?`/`none?` when no block is needed (cheaper)
- Game logic lives in `lib/engine/game/`; each game has its own subdirectory
- Tab-specific UI controls (Map, Log, etc.) must only affect that tab; global preferences go in Profile
- Keep changes minimal — no unnecessary abstractions, no over-engineering
- Before writing new logic, check whether the base/engine class already provides it — don't reinvent something already available without a concrete reason (reviewers push back hard on this; e.g. PR #12703 required removing a custom `operating_order` override that just duplicated what the base class already derived from `MINORS`' order)
- No rubocop during development; run only before submitting PRs

## Windows-Specific Gotchas
- `docker compose exec` panics — always use `docker exec 18xx-rack-1 <cmd>`
- Files edited on Windows may have CRLF line endings; strip before rubocop: `sed -i 's/\r//'` inside Docker
- `spec/fixtures` is a broken symlink on Windows — never reference it; use the spec files above
- Git is configured with `core.autocrlf=true`; stored content is clean LF (CRLF warnings from rubocop are Windows artifacts)

## Git Workflow
- Always branch from `origin/master`: `git checkout -b <branch-name> origin/master`
- Always verify the active branch before making code changes
- PRs go to `tobymao/18xx` via GitHub API (`gh` CLI is not installed; use PowerShell `Invoke-RestMethod`)
- GitHub token is stored in the `GITHUB_TOKEN` environment variable
- Follow the repo's templates when submitting PRs or issues via the API (they aren't auto-applied outside the GitHub web UI, so read and follow them manually):
  - PRs: `.github/PULL_REQUEST_TEMPLATE.md` — title starts with a game tag (e.g. `[2038]`), use `[core]` if touching shared `lib/engine` code and `[dev]` for non-user-facing dev/maintainer changes, break new-game work into multiple PRs, and fill in the checklist (branched from latest `master`, rubocop -a, tests pass) plus Explanation of Change / Screenshots / Assumptions
  - Issues: pick the matching template under `.github/ISSUE_TEMPLATE/` (`bug_report.md`, `feature_request.md`, `interface_or_site_problem.md`) and follow its structure/fields

## Role: 18 India Bug Keeper
This contributor is the designated bug keeper for the 18 India game engine implementation.
Issue list: `C:\Users\teach\Documents\18india_issues.md`
