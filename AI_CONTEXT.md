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

## Reviewer & Codebase Conventions
Derived from a review of ~90 merged PRs' reviewer comments (2025-08 to 2026-08) plus a codebase pattern survey. See `[[18xx_reviewer_conventions]]` memory for methodology/provenance.

### Architecture & reuse
- Check the base/engine class before writing custom logic — by far the most common review comment category (e.g. `operating_order`, `must_buy_train?`, `spend_minmax`, `last_share_sold_price`, `SimpleDraft` all had custom reimplementations rejected)
- Prefer existing declarative DSL knobs over hand-rolled logic: `PHASES` `train_limit:`/`status:`, `EBUY_*` constants, `STATUS_TEXT`/`EVENTS_TEXT` (extend via `.merge`), phase `status` arrays instead of hardcoded phase-number checks
- Steps should call named methods on the game class, not reach into its ivars/structures directly (e.g. `region_available?`, `claim_region!` instead of manipulating game-class state from a step)
- Scalar constants: direct `@game.class::CONST` access is the accepted, dominant engine-wide pattern — don't wrap unnecessarily. Structured/keyed constants (hash by entity type): wrap in a game method instead for a real API boundary (`train_limit(entity)` pattern)
- Don't prefix a constant with `self.class::` unless a subclass actually overrides it
- If a subclass file (e.g. a game variant) overrides nothing that isn't already in its parent, delete the file — don't keep empty ceremonial subclasses
- When two related games (base + variant) end up with near-duplicate step logic, prefer generalizing the shared logic upward into the parent game over forking files
- 100%-duplicate code between methods → extract a shared helper
- Look at how another game solved a similar mechanic before inventing a new pattern (reviewers routinely cite precedent games)
- Keep constants as pure data; put conditional variation behind an accessor method rather than embedding logic inline in a constant
- Prefer `case/when` (regex or hash-based dispatch) over chained if/elsif or manual string-splitting for multi-branch action handling; reuse existing helpers (e.g. `create_choice`) before inventing a bespoke encoding scheme

### Style
- `empty?` over `any?`/`none?` without a block — the single most repeated comment across all reviewers
- `index` over `find_index`; `starts_with?` over manual prefix checks; `intersect?` over `(a | b).empty?`
- Boolean methods end in `?`; mutating methods end in `!`
- No magic numbers — promote to named constants
- No dead code, unused methods, or leftover debug/TODO scaffolding in a PR
- Explicit entity/player parameters over implicit `current_entity` in shared or lower-level methods
- Extract helper methods when a method handles multiple branches or is "getting long"
- Descriptive names — reviewers routinely rename vague variables (`result`, bare `number`) and overly generic or overly long identifiers
- Errors should raise, not silently no-op, when an invariant is violated
- `make style` (rubocop) must actually pass in CI — not optional, despite not running it during development

### Rules fidelity
- Cite the specific rulebook section when implementing or debating a mechanic — disagreements get resolved by citation, not opinion
- When the rulebook is ambiguous, get designer/official clarification (BGG threads, direct designer contact) rather than guessing
- Reproduce the physical game faithfully (token counts, `num: 'unlimited'` stated explicitly rather than omitted)
- Mark known-incomplete rule implementations with a TODO comment in code plus a note on the game's wiki page — don't add a `todo.md` file to the repo; use a GitHub issue instead
- Verify behavior survives the auto-router and game-load/replay path, not just interactive play

### Compatibility & migrations
- Never silently change something with save-game implications (tile orientation, train counts) without a migration script
- Migration scripts must be validated against a real copy of the production DB (`import_game`, `strict: true`) before merge — spot-checking isn't enough
- Shared/global definitions (e.g. `lib/engine/config/tile.rb`) should match conventions already established across other games to ease future migrations
- Hard-to-reach game states still need fixture coverage; if truly unreachable, use the documented `SKIP_BETA_PROD` escape hatch rather than skipping silently

### PR hygiene
- Split large games/features into a dependency-ordered chain of small, single-mechanic PRs
- **Never force-push a branch once review has started** — called out explicitly, repeatedly, as a hard rule. Add new commits and push normally instead
- Screenshots/screencasts expected for UI-visible changes; cross-browser/device testing expected for CSS/layout changes
- Keep PR scope minimal — no unrelated fixes bundled in

### Views/frontend
- Shared view components (`assets/app/view/game/**`) must stay generic — hardcoding one game's layout/behavior into common code gets pushed back hard. Game-specific behavior should flow through action names returned by the active step, never game-name checks in shared views

## Exemplar Implementation Patterns
Derived by surveying the flagship games of three prolific, well-regarded implementers — Chris Rericha (18USA, 18NY, 1844), Michael Brandt (1868 Wyoming, 1822CA, 18 Royal Gorge), Steve Undy (System 18, 1841, 1862) — for patterns that repeat across at least two of the three authors' own games (the signal of a deliberate personal convention rather than a one-off). This is a different kind of evidence than the PR-review section above: it's what respected authors actually ship, not what reviewers push back on. See `[[18xx_exemplar_authors]]` memory for methodology.

### Confirmed across all three authors
- **Many small, single-purpose step files, not a few large ones.** All three consistently split even narrow mechanics into their own step file (10-24 step files per game is typical) rather than growing one step class to handle several actions. `round/` directories stay thin — logic lives in `game.rb` and step files, not round classes.
- **Heavy use of the engine's declarative DSL.** `PHASES` with `status:` arrays, `STATUS_TEXT`/`EVENTS_TEXT`/`MARKET_TEXT` built via `Base::X.merge(...)`, `EBUY_*` flags, `GAME_END_CHECK`/`GAME_END_REASONS_TEXT` — all three lean on these instead of procedural equivalents. This corroborates the PR-review rule above from the shipped-code side, not just the review-comment side.
- **`self.class::CONST` is used deliberately, not habitually.** All three default to a bare constant reference within the same class, and reach for `self.class::` specifically when the context needs it to resolve polymorphically — from a step or mixin module, or when a subclassed game might override the constant. It's a signal of *why* the qualifier is there, not a reflex.
- **Steps essentially never touch `@game`'s internals directly.** All three call named, often bang-suffixed `@game` methods for anything that mutates state. The one common exception: once a method exposes a mutable collection by name (a hash, a share pool), steps may act on the returned object directly — encapsulation lives at "expose a named accessor," not at "hide the object's own mutability."
- **`raise GameError` for real invariant violations; guard-clause `return`/`return unless` for normal "nothing to do" paths.** None of the three use exceptions for routine control flow, and none silently no-op on a genuine rule violation.
- **Comments are consistently sparse, and none of the three cite rulebook section numbers in shipped code**, despite that being a common ask in PR review threads (the PR-review section above). Read this as an artifact of seniority, not a practice to copy: these three know the rules well enough that the citation lives in their head, not the comment. For anyone else, keep citing the specific rulebook section in code comments per the Rules Fidelity rule above — it's cheap insurance against the exact kind of rules dispute the PR-review corpus shows happening constantly, and costs a senior author nothing to skip only because they've already internalized what the citation would say.
- **`?` for every predicate method, `!` for every mutating/event method** — uniform across all three, no exceptions found. `event_<name>!` is the standard shape for train-event/phase-event handlers.
- **Pervasive `@x ||= ...` memoization** wrapped in a same-named accessor method, used as the default way to cache any derived or looked-up value (a corporation reference, a hex, a computed list) — appears dozens of times per game in every author's code.
- **Method length correlates with genuine transactional complexity, not laziness.** All three keep the bulk of methods short (guard-clause chains, 3-15 lines), and reserve longer methods specifically for inherently multi-step processes — mergers, formations, complex payouts — which are still usually broken into several well-named cooperating methods (a mini state machine) rather than one sprawling method.

### Distinctive per-author techniques (worth adopting selectively, not universal)
- **Brandt**: for a large, cleanly separable subsystem (an auction variant, a side-mechanic like Credit Mobilier), pull it into its own top-level file as a module and `include` it into `Game`, rather than growing `game.rb` further. Also: when subclassing another game, explicitly null out inherited constants that don't apply (`COMPANY_X = nil # reason`) to document the divergence instead of leaving it implicit.
- **Brandt**: manages regional/company-group complexity through data-driven hash lookup tables (hex↔company↔tile) rather than branching conditionals — worth reaching for when a mechanic is naturally a lookup rather than a decision tree.
- **Rericha**: narrates nearly every state-changing action through `@log <<` as a full descriptive sentence naming the entity and amount — strong for player-facing transparency and for debugging replay logs, worth treating as a default habit even though it wasn't universal across all three.
- **Rericha**: "compose via super" — override an engine hook (`revenue_for`, `upgrades_to?`, etc.), call `super`, and layer only the delta on top, rather than reimplementing the whole method.
- **Undy**: credits external non-rulebook sources in comments when borrowing a general algorithm (e.g. hex-distance math) — good practice for distinguishing "this comes from the rules" vs. "this is a known technique from elsewhere."
- **Undy**: leaves honest uncertainty markers (`# FIXME`, `# ??? `) rather than confidently-worded comments over code he wasn't sure about — worth normalizing over leaving such spots uncommented.

### A caution, not a pattern to copy
- One author's shipped code had no `private` sections in any `game.rb` (every method public) and another had leftover commented-out debug `puts` statements in a merged step file. Neither was flagged in the PR-review corpus, so the community evidently doesn't enforce either strongly — but both are worth avoiding on new work regardless: unnecessary public surface area and stray debug output are exactly the kind of thing the "no dead code" style rule above already covers.

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
