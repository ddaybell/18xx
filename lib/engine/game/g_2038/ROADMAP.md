# 2038: Tycoons of the Asteroid Belt — Implementation Roadmap

## Current State Assessment

**What's in good shape (as of PRs 0–4):**
- `meta.rb` — solid
- `entities.rb` — all data bugs fixed; minor/corp structure correct
- `map.rb` — full tile set (2001–2023) with correct labels/paths; MINE_DATA and TRANSSHIPMENT_HEXES constants added
- `game.rb` — market, phases, train list, corporation groups, AL event hooks, route distance/validation, mine revenue model
- `round/operating.rb` — OR entity ordering, Fast Buck treasury income
- `step/waterfall_auction.rb` — full waterfall auction with minor capitalization and all-pass resolution
- `step/buy_train.rb` — minors allowed to buy trains
- `step/dividend.rb` — full minor (split/retain) and corporation (payout/half/withhold) dividend with stock price movement
- `step/route.rb` — route processing with exploration stub, check_distance/check_connected wired
- `assets/app/view/game/part/track.rb` — HIDE_TILE_TRACK support; blue hex paths invisible when not on active route

**What needs work next:**
- Tile bag draw (random tile placement on exploration) — Phase 4h
- Mine pickup selection UI — Phase 4g
- Used Mine marker enforcement — Phase 4e
- Base/claim/refueling station placement steps — Phase 5
- TSI probe operation — Phase 6
- Independent special abilities — Phase 7
- Growth Corp formation / AL formation / mergers — Phases 8–9

---

## PR Index

| PR | GitHub # | Status | Scope |
|---|---|---|---|
| PR0 | — | merged | Initial game scaffold (meta, market, phases, trains, map/entity stubs) |
| PR1 | #12703 | merged | Phase 1: entity data fixes + map data fixes |
| PR2 | #12806 | open | Phase 2 auction + Phase 3a–3b OR foundation |
| PR3 | — | pending PR2 | Phase 3c–3e dividend + route steps |
| PR4 | — | in progress | Phase 4 routing mechanics + mine revenue model |
| PR5 | — | planned | Phase 5 infrastructure (claims/bases/refueling) + Phase 4c–4j routing completion |
| PR6 | — | planned | Phase 6 TSI probe + Phase 4i undo logging |
| PR7 | — | planned | Phase 7 independent special abilities |
| PR8 | — | planned | Phase 8 Growth Corp formation |
| PR9 | — | planned | Phase 9 Asteroid League formation |
| PR10 | — | planned | Phase 10 private company post-auction abilities |
| PR11 | — | planned | Phase 11 endgame & scoring |

---

## Recommended File Structure (New Steps Needed)

```
g_2038/
  step/
    waterfall_auction.rb           ← exists ✓ (PR2)
    buy_train.rb                   ← exists ✓ (PR2)
    dividend.rb                    ← exists ✓ (PR3)
    route.rb                       ← exists ✓ (PR3; tile bag pending PR5)
    buy_infrastructure.rb          ← bases, refueling stations, claims (PR5)
    form_growth_corporation.rb     ← independent → Growth Corp (PR8)
    form_asteroid_league.rb        ← AE owner triggers AL (PR9)
    merge_into_league.rb           ← independents join AL (PR9)
```

---

## Phase 1: Entity & Data Fixes (Prerequisite for everything else)

**Goal:** Get the data layer correct before building mechanics on top of it.

### 1a. Fix `entities.rb`
- [x] Fix Torch minor: `sym: 'TT'` → `sym: 'TH'` *(PR1)*
- [x] Fix Ice Finder minor: `coordinates: 'G7'` → `coordinates: 'M13'` *(PR1)*
- [x] Fix VP corporation: `coordinates: 'J1'` → `coordinates: 'J2'` (J1 is not on the map) *(PR1)*
- [x] Fix all corporation `type:` values from strings to symbols (were `'group_a'` etc.; `game.rb` compares with `:group_a` — would silently break group partitioning) *(PR1)*
- [x] Fix AL `type: 'groupD'` → `type: :group_d` (inconsistent casing and wrong type) *(PR1)*
- [x] Fix `color: :'#xxxxxx'` (Ruby symbol) → `color: '#xxxxxx'` (string) for VP, OPC, RCC, AL *(PR1)*
- [x] Remove placeholder `tile_lay` abilities from TS, VA, RS; replaced with TODO comments pointing to Phase 10 *(PR1)*
- [x] Fix AE's `when: ['Phase 3', 'Phase 4']` → `when: %w[3 4]` to match framework phase name strings *(PR1)*
- [x] Fix same `when:` guard on all independent company exchange abilities (FB, IF, DH, OC, TH, LY) *(PR1)*
- [ ] Verify that the dual COMPANIES/MINORS structure (same sym appears in both) works correctly in the framework — COMPANIES is the auctioned certificate, MINORS is the operating entity *(PR5?)*

### 1b. Fix `map.rb`
- [x] Fix LOCATION_NAMES typo: `'J18' => 'OCP'` → `'J18' => 'OPC'` *(PR1)*
- [x] Ice Finder LOCATION_NAMES entry was already correct at M13 — the bug was only in the MINORS coordinates (fixed in 1a) *(PR1)*
- [x] Verify all remaining LOCATION_NAMES coordinates are correct *(PR1)*
- [x] Revise asteroid tile definitions (2001–2022) to correctly model N/I/R labels and unclaimed/claimed revenue values — tiles defined with SP6/DP6 path templates and correct labels; `revenue:42` is a placeholder (real values in `MINE_DATA`) *(PR1)*
- [x] Verify double-mine tile (2009) `city=;city=` structure is correct — DP6 template with two cities *(PR1)*
- [x] Define a "base tile" (gray side of explored hex: base marker + refueling slot, no track) — tile 2023 *(PR1)*
- [x] Confirm all blue unexplored hexes are listed and have blank content — all 107 blue hexes in `HEXES` with `BX6` template *(PR1)*
- [x] Add mechanism to track which hexes have been explored — `@mine_state` hash on game object *(PR4)*
- [x] Add `MINE_DATA` constant mapping each tile number (2001–2022) to per-mine ore type and unclaimed/claimed revenue values *(PR4)*
- [x] Add `TRANSSHIPMENT_HEXES` constant listing the five gray delivery hex IDs (A13, D2, H10, O11, H18) *(PR4)*

### 1c. Fix spaceship train data model
- [x] **Naming convention:** Spaceships are now named `movement/cargo_holds` (e.g. `'3/2'`, `'5/1'`) matching the physical spaceship cards. `distance:` holds movement points; `cargo_holds:` is the custom field for max mine pickups. All phase `on:` triggers, `rusts_on:` arrays, and `discount:` keys updated to match. *(PR1)*
- [x] **Added `cargo_holds:` field** to every entry in TRAINS (top-level and variants). The base engine stores unknown keys safely in `Train#@opts`. `cargo_holds_for_train` parses the value from the train name (second component) rather than `@opts` for simplicity. *(PR1)*
- [x] **Added `rusts_on:` to variant sub-hashes** — they were previously missing from variants, meaning the engine would use the primary train's rusts_on for all variants of a group. *(PR1)*
- [x] **Probe documented:** 4 movement, 0 cargo holds. Belongs to TSI; not bought from bank. Retirement on TSI's first real spaceship purchase is handled by the ST private's close ability. *(PR0)*
- [x] Verify train obsolescence (`rusts_on:`) matches the rules chart — confirmed correct. *(verified PR4)*

---

## Phase 2: Auction Round

**Goal:** Complete the initial auction so the game can start.

- [x] **2a. Minor capitalization rounding** — rule is `$100 + ½ of (price - $100)`, rounded down. Code: `capital = (price - 100) / 2; bank.spend(100 + capital, minor)` — correct Ruby integer division. *(PR2)*
- [x] **2b. TSI share distribution** — when ST is bought, `after_buy_company` in game.rb gives the buyer the TSI president cert and pars TSI at $100 (full) or $67 (short game). MARKET has `100p` and `67p` at the correct positions. *(PR2)*
- [ ] **2c. AE certificate timing** — AE is sold in Phase 1 but grants the AL president cert only in Phase 3/4. Add a hook at Phase 3 start that gives AE's owner the AL president certificate (AL must already exist in `@corporations` via `event_asteroid_league_can_form!`). *(PR9?)*
- [x] **2d. All-pass resolution** — `all_passed!` sets `@process_round_end_auction = true`; `resolve_bids` processes all pending bids in order; `round_end_auction_complete` fires `payout_companies` + `or_set_finished` and unpauses all entities. *(PR2)*
- [ ] **2e. Auction ordering** — confirm companies are auctioned in order "0" through "11" (PI, then TS/VA/RS/ST/AE as privates, then FB/IF/DH/OC/TH/LY as independents) *(PR2 verification pending)*

---

## Phase 3: Operating Round Structure

**Goal:** Implement the OR sequence and independent/corporation turn flow.

- [x] **3a. OR entity ordering** — `bank_sort` in `game.rb` uses `ENTITY_DISPLAY_ORDER` to sort independents (FB→IF→DH→OC→TH→LY) before corporations. Corporations operate in descending stock price order via the engine's default OR ordering. *(PR2)*
- [x] **3b. Private company income** — `payout_companies` (called in base `Round::Operating#setup`) handles all private revenues. `G2038::Round::Operating#setup` calls `super` then adds Fast Buck's $15 directly to the FB minor's treasury. *(PR2)*
- [x] **3c/3d. Turn sequence** — `new_operating_round` uses `G2038::Round::Operating` with step stack: `Bankrupt`, `DiscardTrain`, `G2038::Step::Route`, `G2038::Step::Dividend`, `G2038::Step::BuyTrain`, `BuyCompany`. Route and Dividend steps are fully implemented; base/station/claim placement steps are Phase 5. *(PR3)*
- [x] **3e. OR cleanup hook** — `or_round_finished` resets all `mine[:used]` flags to `false` at end of each OR. *(PR3)*

---

## Phase 4: Spaceship Routing (Biggest Engineering Challenge)

**Goal:** Implement the custom route runner for XdYc spaceships.

- [x] **4a. Hex-based movement model** — `hex_edge_cost` counts inter-hex path transitions; `route_distance` sums over `route.chains` (18Ireland model); `route_distance_str` shows "3H" etc. *(PR4)*
- [x] **4b. Dual constraint enforcement** — `check_distance` raises `GameError` if hex transitions exceed `train.distance`, or (once wired) if pickup count exceeds `cargo_holds_for_train`. *(PR4)*
- [x] **4c. Route origin/destination rules**: *(PR4)*
  - [x] Route must **start** at one of the company's own bases — `check_connected` verifies `route.hexes.first` is in the corporation's placed token hexes *(PR4)*
  - [x] Route must **end** at any base OR a transshipment point to earn pickup revenue — `revenue_for` gates mine pickup values on `deliverable_destination?(route.hexes.last)`; exploring-only routes earn $0 pickup revenue *(PR4)*
  - [ ] Ending at a transshipment point with an **empty** cargo hold earns the lower (transshipment) value — not yet enforced; transshipment revenue currently always counted *(PR5)*
- [ ] **4d. Refueling station bonus** — when a ship belonging to the owning corporation enters a refueling station hex, remaining MPs are bumped to `min(remaining + 3, original_movement_allowance)` *(PR5)*
- [ ] **4e. Used Mine enforcement** — only one pickup per mine per OR; place Used Mine marker after pickup selection is confirmed; `mark_mines_used!` and `or_round_finished` reset are in place but not yet wired to pickup selection *(PR5)*
- [ ] **4f. Claimed mine access** — any ship can pick up at unclaimed mines (lower value); only the owning company's ships can pick up at claimed mines (higher value). Foundation is in `pickup_value` and `pickable_stops`; not yet enforced in routing. *(PR5)*
- [ ] **4g. Route valuation and pickup selection**: *(PR5)*
  - [ ] After the player confirms their full route path, present a list of all eligible pickups along that path *(PR5)*
  - [ ] Pre-populate with the highest-scoring combination (up to cargo hold limit) as the default selection *(PR5)*
  - [ ] Player may override the selection before confirming *(PR5)*
  - [ ] Revenue = sum of confirmed pickup values + delivery bonuses from destination base *(PR5)*
  - [ ] `revenue_for` currently auto-picks best mines greedily (correct behavior for AI/autorouter; UI interaction is the remaining work) *(PR5)*
- [ ] **4h. Exploration mid-route** — uses a blended client-side/server-side model: *(PR5)*
  - [ ] Movement is client-side: the player traces the route hex by hex in Opal without server round-trips *(PR5)*
  - [ ] When the ship enters an unexplored blue hex, the UI presents an "Explore?" prompt *(PR5)*
  - [ ] Choosing to explore fires `Action::ExploreHex` (hex_id) to the server; the server reveals the pre-assigned tile (see Decision D), places it, updates `@mine_state`, logs the event, and the client re-renders before the player chooses the next hex *(PR5)*
  - [ ] Choosing not to explore: hex is traversed at normal MP cost without revealing its tile *(PR5)*
  - [ ] `process_explore_hex` in the route step: looks up `@hex_assignments[hex_id]`, calls `hex.lay(tile)`, updates `@mine_state`, fires undo-watch logic (see 4i) *(PR5)*
  - [ ] Owning company receives $10 exploration bonus to treasury (not route revenue) *(PR5)*
  - [ ] Previously explored hexes are traversed at normal MP cost *(PR5)*
  - [ ] `RunRoutes` submission includes the full route path; server validates total MP usage including exploration costs *(PR5)*
- [ ] **4i. Exploration undo policy** — see Architectural Decision B. `ExploreHex` actions are committed to `@raw_actions` individually, so any undo that crosses one is trivially detectable: scan for undo entries whose `action_id` falls after an `ExploreHex` in the same OR. `initialize_actions` override not yet written. *(PR6)*
- [ ] **4j. Multiple ships per company** — more than one ship can operate per OR; each runs one route separately *(PR5)*
- [x] **Additional: `HIDE_TILE_TRACK = true`** — blue hex paths are invisible when not part of an active route; implemented in `assets/app/view/game/part/track.rb` via Snabberb store access to `@game` *(PR4)*
- [x] **Additional: `skip_route_track_type(:broad)`** — prevents `Path#walk` from traversing broad-gauge blue hex paths, avoiding exponential path-walk explosion across ~1500 connected paths *(PR4)*
- [x] **Additional: `can_run_route?`** — overrides graph connectivity check (2038 has no rail network); returns `route_trains(entity).any?` *(PR4)*

---

## Phase 5: Mine, Claim & Base Infrastructure

**Goal:** Implement persistent state objects for claims, bases, and refueling stations.

- [ ] **5a. Asteroid tile state** — for each explored hex, track:
  - [x] Number of mines (1 or 2) and ore type per mine (N/I/R) — populated by `explore_hex!` from `MINE_DATA` *(PR4)*
  - [x] Unclaimed value and claimed value per mine — in `MINE_DATA` and copied into `@mine_state` on exploration *(PR4)*
  - [x] Whether there is a Used Mine marker on each mine this OR — `mine[:used]` flag; reset in `or_round_finished` *(PR3/PR4)*
  - [ ] Which company (if any) owns a claim on each mine — `mine[:owner]` field exists (set to `nil`); claim placement step not yet built *(PR5)*
  - [x] `@mine_state` hash on game object; `revenue_for` looks up values dynamically *(PR4)*
- [ ] **5b. Claims**: *(PR5)*
  - [ ] Cost $60 for first claim per round, $100 for second (AL may place 3: $60/$75/$100) *(PR5)*
  - [ ] Must be within range of at least one of the company's spaceships *(PR5)*
  - [ ] Mark the mine as claimed by that company (`mine[:owner] = entity.id`) *(PR5)*
  - [ ] Claims are permanent; cannot be removed or transferred *(PR5)*
  - [ ] Cannot place a claim on a mine that already has one *(PR5)*
- [ ] **5c. Bases**: *(PR5)*
  - [ ] Cost $50 (exception: Mars Mining pays $25) *(PR5)*
  - [ ] Placed on any explored asteroid tile that doesn't already have a **claim** on it *(PR5)*
  - [ ] Flip tile to its gray base side (tile 2023) when placed *(PR5)*
  - [ ] Mark hex as a route starting point for that company (token placed → `deliverable_destination?` returns true) *(PR5)*
  - [ ] Only one base may be placed per round per company *(PR5)*
- [ ] **5d. Refueling stations**: *(PR5)*
  - [ ] Cost $50 (exceptions per corp — see Company and Corporation Summary) *(PR5)*
  - [ ] Must be placed at a base hex (one refueling station per base) *(PR5)*
  - [ ] Grants +3 MP (capped at ship's max) to ships of the owning company *(PR5)*
  - [ ] Only one refueling station per base *(PR5)*

---

## Phase 6: TSI Probe

**Goal:** Model TSI's special probe mechanics.

- [x] **6a. Probe entity** — probe is removed from depot in `setup`; `@probe.buyable = false`; given to TSI via `float_corporation` override *(PR4)*
- [ ] **6b. Probe operation** — before independents operate each OR: if TSI has not yet bought a spaceship, the ST private owner flies the probe from TSI's base; exploration bonuses ($10/hex) go to TSI's treasury; no revenue earned *(PR6)*
- [ ] **6c. Probe retirement** — when TSI buys its first spaceship, ST is removed from the game and the probe is retired (the `close: { when: 'bought_train', corporation: 'TSI' }` ability on ST handles the closure; verify probe retirement is also triggered) *(PR6)*
- [ ] **6d. Inactive TSI fallback** — if TSI is not active, the owner of the Space Transportation Co. (ST) flies the probe from the TSI base *(PR6)*

---

## Phase 7: Independent Company Special Abilities

**Goal:** Wire up each independent's unique ability.

- [x] **Fast Buck (FB)** — $15/round added to treasury, implemented in `G2038::Round::Operating#setup` *(PR2)*
- [ ] **Ice Finder (IF)** — $10 bonus per Ice ore delivered; must draw a second tile when exploring if the first tile drawn has no Ice mines *(PR7)*
- [ ] **Drill Hound (DH)** — $10 bonus per Rare ore delivered; must draw a second tile when exploring if the first tile drawn has no Rare mines *(PR7)*
- [ ] **Ore Crusher (OC)** — $10 bonus per Nickel ore delivered *(PR7)*
- [ ] **Torch (TH)** — all Torch spaceships get +1 movement point *(PR7)*
- [ ] **Lucky (LY)** — draws 2 tiles when exploring a hex, then chooses which to place (discard the other) *(PR7)*
- [ ] **Pilot bonuses** — when an independent forms a Growth Corporation or merges into the AL, its pilot certificate transfers to the new corporation and provides the same bonuses to one assigned spaceship per OR *(PR8)*

---

## Phase 8: Growth Corporation Formation

**Goal:** Allow independents to convert into Growth Corporations.

Reference: `g_1835/step/form_prussian.rb` and `game.rb::merge_entity_to_prussian!()`.

- [ ] **8a. Trigger** — player announces conversion during their stock round turn (Phases 2 or 3, before the Asteroid League forms) *(PR8)*
- [ ] **8b. Create `step/form_growth_corporation.rb`** — handles the conversion sequence: *(PR8)*
  - [ ] Player selects an available Growth Corporation president's certificate (20%) *(PR8)*
  - [ ] Independent's spaceship(s) transfer to new Growth Corp *(PR8)*
  - [ ] Independent's base, claims, and remaining cash transfer to new Growth Corp *(PR8)*
  - [ ] Independent's certificate replaced by Growth Corp president's certificate *(PR8)*
  - [ ] Growth Corp starts with stock price $10, par $67 *(PR8)*
  - [ ] Growth Corp is immediately active *(PR8)*
  - [ ] Pilot certificate transfers to Growth Corp (placed in corp until Phase 5) *(PR8)*
  - [ ] Independent is removed from the game *(PR8)*
- [x] **8c. Corporation group unlocking** — `after_par` in game.rb fires `event_group_b/c_corps_available!` once all corps in the prior group have IPO'd; Groups A/B/C/D are correctly partitioned in `setup`. *(PR4)*
- [ ] **8d. Growth Corp stock round behavior** — Growth Corp shares purchased from the Growth share box go to its treasury; Public Corp shares go to bank *(PR8)*

---

## Phase 9: Asteroid League Formation

**Goal:** Model the AL formation, analogous to the Prussian in 1835.

Reference: `g_1835/step/form_prussian.rb` and `step/merge_to_prussian.rb`.

- [x] **9a. Formation trigger (event)** — `event_asteroid_league_can_form!` fires when a 5/4 or 7/3 is purchased; adds AL to `@corporations` and logs the announcement. The actual formation step is Phase 9b. *(PR4)*
- [ ] **9b. Create `step/form_asteroid_league.rb`**: *(PR9)*
  - [ ] AE owner declares formation, receiving the AL president's certificate (they already held AE) *(PR9)*
  - [ ] AL starts with $250 capital *(PR9)*
  - [ ] AL par value: $125 *(PR9)*
  - [ ] AE is removed from the game after AL acquires a spaceship (`close: { when: 'bought_train', corporation: 'AL' }` — already in entities.rb) *(PR9)*
- [ ] **9c. Voluntary mergers** — in clockwise order after AL forms, each independent may merge: *(PR9)*
  - [ ] Owner receives ½ of independent's treasury cash (rounded down) *(PR9)*
  - [ ] Owner receives 1 AL share (10%) *(PR9)*
  - [ ] Independent's spaceship(s), base, and claims transfer to AL *(PR9)*
  - [ ] Pilot certificate transfers to AL *(PR9)*
  - [ ] Independent is removed from the game *(PR9)*
- [ ] **9d. Create `step/merge_into_league.rb`** — handles the sequential merge offers per clockwise player order *(PR9)*
- [ ] **9e. Mandatory merger at Phase 5** — any independent still operating at the start of Phase 5 must join the AL; enforce this *(PR9)*
- [ ] **9f. Mandatory merger on bankruptcy** — an independent that cannot buy a required spaceship (7.39) must merge into the AL *(PR9)*
- [ ] **9g. AL ship limits** — AL may not buy its last spaceship (reducing it to zero); no one may buy the AL's last spaceship (7.37) *(PR9)*
- [ ] **9h. AL reserve bases/claims** — AL must reserve 1 base and 2 claims for each remaining independent that has not yet merged (8.12) *(PR9)*

---

## Phase 10: Private Company Special Abilities (Post-Auction)

**Goal:** Wire up TS, VA, RS special abilities when owned by corporations.

- [ ] **Tunnel Systems (TS)** — once per OR when owned by a corp: place 1 free base on any explored, unclaimed tile (anywhere on the map, not just within range) *(PR10)*
- [ ] **Vacuum Associates (VA)** — once per OR when owned by a corp: place 1 free refueling station within range of the owning corporation's spaceships *(PR10)*
- [ ] **Robot Smelters (RS)** — once per OR when owned by a corp: place 1 free claim within range of the owning corporation's spaceships *(PR10)*
- [ ] Replace placeholder ability types in entities.rb with the correct custom ability types for all three *(PR10)*

---

## Phase 11: Endgame & Scoring

**Goal:** Implement bankruptcy detection and final scoring.

- [ ] **11a. Bank depletion** — when the bank runs out during an OR, complete that OR; then play one more SR + 2 ORs; then end the game *(PR11)*
- [ ] **11b. Bankruptcy** — if a corporation president cannot fund a required spaceship purchase (even after selling all personal shares), the game ends immediately *(PR11)*
- [ ] **11c. Final scoring**: *(PR11)*
  - [ ] Each player's score = cash on hand + stock portfolio value (at current stock prices) + face value of any Private Companies still held (if game ends before Phase 5) *(PR11)*
  - [ ] Assets held in company/corporation treasuries do not count for players *(PR11)*
  - [ ] AL shares count at AL's current stock price *(PR11)*
  - [ ] Implement "spreadsheet" mode for final OR (see Let's Play! Figure 10) *(PR11)*

---

## Recommended Implementation Order

1. - [x] Phase 1 — Data fixes (foundation for everything) *(PR0/PR1/PR4)*
2. - [x] Phase 3a–3e — OR structure *(PR2/PR3)*
3. - [x] Phase 4a–4b — Basic routing: distance and connectivity validation *(PR4)*
4. - [ ] Phase 5 — Mine/claim/base state (needed for routing to earn real revenue) *(PR5)*
5. - [ ] Phase 4c remainder, 4d–4j — Full routing: pickup selection, exploration, refueling *(PR5/PR6)*
6. - [ ] Phase 7 — Independent special abilities *(PR7)*
7. - [ ] Phase 2 remainder — AE cert timing (2c), auction ordering verification (2e) *(PR9)*
8. - [ ] Phase 6 — TSI probe *(PR6)*
9. - [ ] Phase 8 — Growth Corp formation *(PR8)*
10. - [ ] Phase 9 — Asteroid League formation *(PR9)*
11. - [ ] Phase 10 — Private company post-auction abilities *(PR10)*
12. - [ ] Phase 11 — Endgame scoring *(PR11)*

---

## Key Architectural Decisions

### A. Mine revenue model
- [x] **Chosen approach:** Store mine state in a `@mine_state` hash on the game object; `revenue_for` looks up claimed/unclaimed values dynamically. Do **not** bake revenue into static tile codes (`revenue:42` in tile definitions is a display placeholder only). *(PR4)*
- [x] **`MINE_DATA` constant** maps each asteroid tile number (2001–2022) to an ordered array of mine hashes (`{ore:, unclaimed:, claimed:}`). `explore_hex!` merges these with `owner: nil, used: false` into `@mine_state` when a tile is placed. *(PR4)*
- [x] **Bases and mines are mutually exclusive on a hex.** Placing a base flips the tile to 2023 (no mines). `@mine_state` only ever tracks un-based explored hexes. *(PR5)*

### B. Exploration undo policy
- [x] **Chosen approach:** Stay fully faithful to the physical game — asteroid tiles are revealed immediately when explored, mid-route. Undo is **not** blocked. Instead, any undo action during an operating round is permanently logged to the game log with a visible announcement so other players can police suspected peeking. *(decision PR4; implementation PR6)*

  **How the engine works (important context):**
  - When an undo arrives, `Game::Base#process_action` immediately calls `return clone(@raw_actions)` — the game is completely rebuilt from scratch. No game-specific hooks (`preprocess_action`, etc.) fire for undo actions.
  - `@log` is rebuilt from scratch on every clone/undo.
  - `Action::Log` (which extends `Action::Message`) is **never** filtered out by `filtered_actions` — messages survive all undos and are replayed in the correct chronological position.
  - `initialize_actions` is overridable in a game subclass without touching engine code.

  **Implementation approach — override `initialize_actions` in `G2038::Game`:**
  - After calling `super` (which replays all actions and builds `@log`), scan `@raw_all_actions` for any `{ 'type' => 'undo' }` entries
  - For each undo found, look up the player via `action['user']`, identify the action ID range that was undone via `action['action_id']`
  - Append a styled log entry: `"⚠ [UNDO] PlayerName undid action(s) #Y–#Z"`
  - These entries appear at the bottom of the log (not inline), but are permanent — they survive all further undos because they are regenerated fresh on every rebuild

  **Implementation tasks:**
  - [ ] Override `initialize_actions` in `G2038::Game`; after `super`, scan `@raw_all_actions` for undo entries and build log entries *(PR6)*
  - [ ] Only emit undo log entries during Operating Rounds (check round type at the action's point in history, or always log and rely on the action ID range being self-explanatory) *(PR6)*
  - [ ] Format the log entry to include: player name, action ID range undone, and round/turn context if determinable *(PR6)*
  - [ ] Undo announcements must persist even if the player subsequently undoes further actions (guaranteed by the rebuild approach above) *(PR6)*
  - [ ] Investigate whether `self.filtered_actions` override could instead inject a synthetic `message`-type hash at the undo's chronological position, which would make the log entry appear in-order rather than at the bottom — this is a stretch goal if in-order logging matters *(PR6)*

### C. Spaceship distance model and pickup selection
- [x] **Chosen approach:** Keep spaceships in TRAINS for purchase/obsolescence tracking. `G2038::Step::Route` uses hex-traversal (cf. 18Ireland) with a separate cargo hold constraint. `hex_edge_cost` + `route_distance` are implemented in game.rb. *(PR4)*
- [x] **Pickup selection UX:** The player traces their full intended route path first. At the end, the player selects which mines to pick up (up to cargo hold limit). The list is pre-populated with the highest-scoring combination as the default. Until the UI is built, `revenue_for` auto-picks greedily. *(PR4)*
  - [x] `pickable_stops(route, existing_pickups)` — returns eligible mine stops for a route *(PR4)*
  - [x] `pickup_value(entity, hex_id, mine_idx)` — returns claimed or unclaimed value *(PR4)*
  - [ ] Implement pickup selection as a distinct UI interaction after path confirmation *(PR5)*
  - [ ] Apply Used Mine markers only after pickup selection is confirmed (not mid-route) *(PR5)*
- [x] **`deliverable_destination?(hex)`** — returns true if hex is a transshipment point or has any placed base token; used by `revenue_for` to gate pickup revenue *(PR4)*

### D. Unexplored hex representation
- [x] **Chosen approach:** Pre-generate all tile assignments at `setup` using a seeded shuffle of the full tile pool. Store in `@hex_assignments` (hex_id → tile_name, server-side only, never sent to clients). When a hex is explored via `Action::ExploreHex`, the server looks up the pre-assignment, places the tile, and reveals it to all players simultaneously. *(decision PR5)*

  **Why pre-generate rather than draw from a live bag:**
  - There are exactly **106 blue hexes and 106 mine tiles** — a perfect 1:1 match, so a complete pre-assignment is always possible.
  - `@hex_assignments` is derived deterministically from `@seed` in `setup`, so it is rebuilt identically on every clone/undo without being stored in `@raw_actions`.
  - Undoing an `ExploreHex` action naturally un-reveals the tile — the game rebuilds from `@raw_actions`, which no longer contains the explore action, so the hex reverts to blue. The pre-assignment in `@hex_assignments` is still intact for the next exploration.
  - `Action::ExploreHex` only needs a hex_id — no tile name, no bag state.
  - No "bag" shrinks over time; no bag state to maintain or serialize.

  **Implementation:**
  - [ ] In `setup`: collect all blue hex ids, sort them, build the full tile pool from `MINE_DATA` counts, shuffle with `Random.new(@seed)`, zip into `@hex_assignments = hex_ids.zip(tile_names).to_h` *(PR5)*
  - [ ] In `process_explore_hex`: look up `tile_name = @hex_assignments[hex_id]`, find the tile object, call `hex.lay(tile)`, update `@mine_state`, award $10 exploration bonus, log the event *(PR5)*
  - [ ] Verify that `hex.lay` during an OR (outside the normal `LayTile` step) works correctly and is reflected in the serialized game state *(PR5)*

### E. Infrastructure placement model
- [x] **Bases → Token system.** Tokens occupy a city slot (one base per hex), have placement costs, belong to a corporation, and establish route origins. The 13 pre-printed starting bases map to home tokens at each entity's starting coordinates. *(PR5)*
  - [x] **Independent companies have exactly one base — their home base.** One free home token, no additional tokens. `deliverable_destination?` returns true for any hex with a placed token, so independent bases correctly qualify as delivery destinations for any ship. *(PR4)*
- [x] **Refueling Stations → Modifier on a base.** Will be stored as a `@refueling_stations` hash (`hex_id → corporation`). When any ship owned by the station's corporation enters that hex, remaining MP is increased by 3, capped at the ship's original MP: `new_remaining = [remaining + 3, original_mp].min`. One refueling station per base; usable once per ship per OR. *(PR5)*
- [x] **Claims → Revenue modifier only.** Stored in `@mine_state` as `mine[:owner]`. A claim marks a mine as owned by a specific company; that company's ships earn `mine[:claimed]`, all others earn `mine[:unclaimed]`. Claims have no effect on routing or movement. *(PR4)*
  - [x] **Independent companies each have 2 claims** (not tokens — handled as custom claim state in `@mine_state`). *(PR5)*
- [x] **Bases and claims are mutually exclusive** — enforced by rule (bases require a tile without claims; the tile flip to 2023 removes mines). No code-level guards needed. *(PR5)*

---

## Reference: Key Files in Other Games

| Mechanism | Game | File |
|---|---|---|
| BY-share privates (shares ability) | 1835 | `g_1835/entities.rb` |
| Minor-to-major conversion (Prussian) | 1835 | `g_1835/step/form_prussian.rb`, `g_1835/game.rb` |
| Sequential merger step | 1835 | `g_1835/step/merge_to_prussian.rb` |
| Distance-based train routing | 18Ireland | `g_18_ireland/game.rb` (`route_distance`, `check_distance`) |
| Minor company operating model | 1835, 1861 | `g_1835/minor.rb`, `g_1861/game.rb` |
