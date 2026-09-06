# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module Infrastructure
        DEFAULT_CLAIM_COSTS = [60, 100].freeze

        # Flat price for a corporation buying an already-placed claim
        # directly from the independent holding it (§7.4x).
        INDEPENDENT_CLAIM_PRICE = 60

        # Raw CORPORATIONS config for this entity -- `bases:`/`stations:`/
        # `claim_costs:` are custom per-corp fields (§7.4) that the base
        # engine's Corporation/Operator classes don't consume or store, so
        # they're looked up here rather than added to shared engine code.
        def corp_data(entity)
          Entities::CORPORATIONS.find { |c| c[:sym] == entity.id }
        end

        # Same idea as corp_data, but for fields that can appear on either
        # an independent's MINORS entry or a corp's CORPORATIONS one (e.g.
        # claim_limit) -- lets callers read that data the same way for any
        # operating entity, without needing to know or care which array it
        # actually lives in.
        def entity_data(entity)
          (Entities::MINORS + Entities::CORPORATIONS).find { |c| c[:sym] == entity.id }
        end

        # Cost of the *next* base/station this entity places, indexed by how
        # many it's already placed over the whole game (lifetime, not
        # per-round) -- costs aren't always constant across the array (e.g.
        # Outer Planet Consortium's first station is free, the rest aren't).
        def base_cost(entity)
          costs = corp_data(entity)&.dig(:bases) || [50]
          costs[@base_hexes[entity].size] || costs.last
        end

        def station_cost(entity)
          costs = corp_data(entity)&.dig(:stations) || [50]
          costs[@station_hexes[entity].size] || costs.last
        end

        # Hex ids where this entity has placed a base/refueling station so
        # far, in placement order -- the source of truth for both cost
        # indexing above and the corporation card's token-style display
        # (View::Game::Corporation#render_infrastructure_tokens).
        def base_hexes(entity)
          @base_hexes[entity]
        end

        def station_hexes(entity)
          @station_hexes[entity]
        end

        # Extra, uncounted bases already placed for this entity -- see the
        # comment on @extra_base_hexes in #setup for what lands here.
        def extra_base_hexes(entity)
          @extra_base_hexes[entity]
        end

        # Extra, uncounted refueling stations already placed for this
        # entity -- see the comment on @extra_station_hexes in #setup for
        # what lands here.
        def extra_station_hexes(entity)
          @extra_station_hexes[entity]
        end

        # Lifetime cap on total bases/stations a corp may ever place -- the
        # length of its own `bases:`/`stations:` cost array (base_cost/
        # station_cost fall back to the array's last entry past that count,
        # which previously meant "keep paying the last price forever" with
        # no actual cap; ROADMAP's Phase 5c note flagged this as an
        # intentional simplification, since revisited after live play).
        # §8.12/Phase 9h: the AL must hold back 1 base for each independent
        # that hasn't merged in yet -- its *own* new-placement capacity
        # shrinks while any remain, growing back by 1 each time one merges
        # or is forced in. This reservation is what keeps the combined
        # total (self-placed + inherited) capped at the true allotment: a
        # merged-in base counts against @base_hexes too (see
        # transfer_independent_base!, counted: true for AL), consuming
        # exactly the capacity this formula just gave back. Claims
        # inherited via merger also count, against claim_limit -- see
        # transfer_independent_mine_claims!'s own comment; that one was
        # never in question, only bases were.
        def base_limit(entity)
          limit = corp_data(entity)&.dig(:bases)&.size || Float::INFINITY
          return limit unless entity == @al_corporation

          [limit - remaining_independents.size, 0].max
        end

        def station_limit(entity)
          corp_data(entity)&.dig(:stations)&.size || Float::INFINITY
        end

        # Placeholder refueling-station token art (public/logos/g_2038/
        # *_station.svg, one per corp) so the corporation card's token strip
        # can show a distinct icon for stations vs bases, same as any other
        # game's per-corp logo files -- no shared view/engine code involved.
        def station_logo(entity)
          "/logos/g_2038/#{entity.id}_station.svg"
        end

        # Placeholder claim token art (public/logos/g_2038/*_claim.svg, one
        # per corp/independent) for the corporation card's claims display.
        def claim_logo(entity)
          "/logos/g_2038/#{entity.id}_claim.svg"
        end

        # Hex ids this entity holds a claim on, one entry per claimed mine
        # (a double-mine hex claimed twice by the same entity appears
        # twice) -- derived from @mine_state directly rather than tracked
        # separately, same source claims_placed_lifetime already reads.
        def claim_hexes(entity)
          @mine_state.flat_map { |hex_id, state| [hex_id] * state[:mines].count { |m| m[:owner] == entity.id } }
        end

        # Same one-entry-per-claimed-mine list as claim_hexes above, but
        # with the specific ore/claimed-value each entry needs to render
        # as its own mine-colored circle on the corporation card (see
        # View::Game::Corporation#render_claim_column) rather than a
        # generic flag icon -- claim_hexes alone only has the hex id,
        # which isn't enough to know which of a double-mine hex's two
        # (possibly differently-valued/ore'd) mines a given slot is.
        # `free` (Robot Smelters' one-time ability, Phase 10) is surfaced
        # here too -- it's an uncounted extra beyond claims_placed_
        # lifetime/claim_limit (see those methods' own comments), but it's
        # still a real, physically-placed claim the charter needs to show
        # and mark, not silently drop.
        def claim_details(entity)
          @mine_state.flat_map do |hex_id, state|
            state[:mines].select { |m| m[:owner] == entity.id }
                          .map { |m| { hex_id: hex_id, ore: m[:ore], value: m[:claimed], used: m[:used],
                                        free: m[:free] || false } }
          end
        end

        def claim_cost_schedule(entity)
          corp_data(entity)&.dig(:claim_costs) || DEFAULT_CLAIM_COSTS
        end

        # Per-ore claim-value bonus (Map tab's "Claim upgrade" chart) --
        # every mine of a given ore gains the same fixed amount once
        # claimed, regardless of which tile it's on (see MINE_DATA: e.g.
        # every :n mine goes unclaimed 10/claimed 50, unclaimed 20/claimed
        # 60, always +40). Derived from MINE_DATA itself rather than a
        # separate hardcoded table, so it can never drift out of sync with
        # the real tile data.
        def claim_ore_upgrade_amounts
          self.class::MINE_DATA.values.flatten.each_with_object({}) do |mine, h|
            h[mine[:ore]] ||= mine[:claimed] - mine[:unclaimed]
          end
        end

        def show_map_legend?
          true
        end

        def map_legends
          [:claim_upgrade_legend]
        end

        CLAIM_UPGRADE_ORE_NAMES = { n: 'Nickel', i: 'Ice', r: 'Rare' }.freeze
        # Same RGB values as Part::City::MINE_ORE_COLOR/View::Game::
        # Corporation's CLAIM_MINE_COLOR -- kept as its own copy rather
        # than a shared reference, same reasoning as those constants' own
        # comments.
        CLAIM_UPGRADE_ORE_COLOR = { n: '#c82828', i: '#2864d2', r: '#289646' }.freeze

        # Map tab legend (see Game::Base#map_legends/View::Game::
        # MapLegend#render_legend for the shape this returns) -- one row
        # per ore, showing the fixed value bonus claiming a mine of that
        # ore grants (see claim_ore_upgrade_amounts above).
        def claim_upgrade_legend(font_color, _yellow, green, _brown, _gray, _red, action_processor: nil)
          cell_style = {
            border: '1px solid',
            color: font_color,
            'font-weight': 'bold',
            'text-align': 'center',
            'vertical-align': 'middle',
            height: '33px',
          }

          rows = claim_ore_upgrade_amounts.sort.map do |ore, amount|
            [
              { text: CLAIM_UPGRADE_ORE_NAMES[ore],
                props: { style: cell_style.merge(backgroundColor: CLAIM_UPGRADE_ORE_COLOR[ore], color: 'white') } },
              { text: format_currency(amount), props: { style: cell_style } },
            ]
          end

          [
            {
              style: {
                margin: '0.5rem 0 0.5rem 0',
                border: '1px solid',
                borderCollapse: 'collapse',
              },
            },
            [
              {
                text: 'Claim upgrade',
                props: { attrs: { colspan: 2 }, style: cell_style.merge(backgroundColor: green, color: 'black') },
              },
            ],
            *rows,
          ]
        end

        # Every entity's lifetime claim cap comes straight from its own
        # entities.rb entry's claim_limit (independents: a flat 2, §7.4;
        # corporations: Company/Corporation Summary table) -- Float::
        # INFINITY for the (currently none) corps without one on record
        # rather than silently capping. A claim_limit value that itself
        # depends on the game's optional rules (Mars Mining's own entry,
        # §13b) is stored as a Proc rather than a plain number, since
        # entities.rb's arrays are built once at load time before any
        # specific game's rules are known -- called with `self` here, the
        # one place that IS known. Same reservation idea as base_limit
        # above, but 2 claims per remaining independent instead of 1 base
        # (§8.12/Phase 9h).
        def claim_limit(entity)
          limit = entity_data(entity)&.dig(:claim_limit) || Float::INFINITY
          limit = limit.call(self) if limit.respond_to?(:call)
          return limit unless entity == @al_corporation

          [limit - (remaining_independents.size * 2), 0].max
        end

        # Overrides Game::Base's own token-availability count/string --
        # both used only by the Spreadsheet view's "Tokens" column.
        # G2038's corp.tokens are bases, a small fixed count (1-3) that
        # says little on its own; claims (lifetime-capped, escalating cost,
        # the resource players actually track over a game) are what's
        # meaningful there instead.
        def count_available_tokens(entity)
          claim_limit(entity) - claims_placed_lifetime(entity)
        end

        def token_string(entity)
          "#{count_available_tokens(entity)}/#{claim_limit(entity)}"
        end

        def trains_label
          'Ships'
        end

        def tokens_label
          'Claims'
        end

        # How many of AL's base/claim slots are currently held back for
        # independents that haven't merged in yet -- 0 for anyone else.
        # Purely derived from remaining_independents.size (the same count
        # base_limit/claim_limit already subtract), so it shrinks on its
        # own the instant an independent merges or closes for good -- no
        # separate "release" step needed, just re-render. Used by the
        # corporation card to mark held-back slots as "Res." instead of
        # leaving them looking like any other still-open, unreserved slot.
        def reserved_base_count(entity)
          return 0 unless entity == @al_corporation

          [remaining_independents.size, corp_data(entity)&.dig(:bases)&.size || 0].min
        end

        def reserved_claim_count(entity)
          return 0 unless entity == @al_corporation

          [remaining_independents.size * 2, corp_data(entity)&.dig(:claim_limit) || 0].min
        end

        # Used both to enforce lifetime claim caps (BuyInfrastructure) and to
        # display "claims remaining" on the corporation/minor card. Excludes
        # free claims (Robot Smelters' one-time ability, Phase 10) -- those
        # are an uncounted extra, same as a Growth Corp's inherited base.
        def claims_placed_lifetime(entity)
          @mine_state.values.sum { |s| s[:mines].count { |m| m[:owner] == entity.id && !m[:free] } }
        end

        def refueling_station_owner(hex_id)
          @refueling_stations[hex_id]
        end

        # Hexes reachable by at least one of entity's own spaceships from any
        # of its placed bases (§7.4), refueling at entity's own stations
        # along the way. BFS over hex neighbors, mirroring how ships actually
        # move in `G2038::Step::Route` -- "in range" is the same reachability
        # question as "could a ship fly there."
        def hexes_in_range(entity)
          base_hexes = entity.tokens.filter_map { |t| t.city&.hex }.uniq
          max_mp = entity.trains.map { |t| ship_distance(entity, t) }.max || 0
          return [] if base_hexes.empty? || max_mp.zero?

          best = {}
          base_hexes.each { |h| best[h.id] = max_mp }
          queue = base_hexes.dup

          until queue.empty?
            hex = queue.shift
            remaining = best[hex.id]
            hex.neighbors.each_value do |neighbor|
              next_remaining = remaining - 1
              next if next_remaining.negative?

              next_remaining = [next_remaining + 3, max_mp].min if refueling_station_owner(neighbor.id) == entity
              next if best[neighbor.id] && best[neighbor.id] >= next_remaining

              best[neighbor.id] = next_remaining
              queue << neighbor
            end
          end

          best.keys.map { |id| hex_by_id(id) }
        end

        # A base may be placed on any explored hex with no claimed mine (§7.4,
        # §7.41). Bases and mines are mutually exclusive on a hex -- laying
        # the base tile replaces whatever mines were there.
        def can_place_base?(hex)
          state = @mine_state[hex.id]
          return false unless state

          state[:mines].none? { |m| m[:owner] }
        end

        # `free:` is Tunnel Systems' one-time ability (Phase 10) -- placed at
        # no cost and never pushed into @base_hexes, so it's an uncounted
        # extra beyond the corp's own base allotment (same idea as a Growth
        # Corp's inherited base, Phase 8).
        def place_base!(entity, hex, free: false)
          token = entity.tokens.find { |t| !t.used }
          raise GameError, "#{entity.name} has no tokens left" unless token

          cost = free ? 0 : base_cost(entity)
          entity.spend(cost, bank) if cost.positive?
          if free
            @extra_base_hexes[entity] << hex.id
          else
            @base_hexes[entity] << hex.id
          end
          @mine_state.delete(hex.id)

          tile = @tiles.find { |t| t.name == '2023' && !t.hex }
          raise GameError, 'No base tiles available' unless tile

          # '2023' is an 'unlimited'-count tile (init_tile only ever pools a
          # single instance for those) -- add_extra_tile is the engine's
          # existing mechanism for replenishing it (duplicates a fresh
          # instance back into @tiles) every time one is actually laid.
          # Without this call, only the very first base placed in the whole
          # game would ever find an unused '2023' instance; every later one
          # would crash laying a nil tile.
          #
          # Not update_tile_lists (the normal tile-laying counterpart to
          # this) -- that also returns the *replaced* tile to @tiles, which
          # is right for an ordinary upgrade (the old tile goes back into
          # circulation) but wrong here: the mine tile a base covers is
          # gone for good, not available to be drawn again.
          add_extra_tile(tile) if tile.unlimited
          @tiles.delete(tile)
          hex.lay(tile)
          tile.cities.first.place_token(entity, token, check_tokenable: false)
          @log << "#{entity.name} places a #{free ? 'free ' : ''}base at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        # Hex ids for every entity's starting home base (corp + independent +
        # AL) -- only used to know which hexes the edge-touching exclusion
        # below applies to. A base a company creates later via place_base!
        # is never in this set, so it's unconditionally eligible. OSR/MR's
        # own home hexes (B14/O13) are excluded here unless New Corporations
        # is active -- otherwise base_tile? below would still treat them as
        # a placed base (and hex.rb would draw the ring-station art on an
        # otherwise-ordinary, unexplored blue hex) even with the rule off.
        def starting_base_hexes
          @starting_base_hexes ||= (Entities::CORPORATIONS + Entities::MINORS).map { |data| data[:coordinates] }
          return @starting_base_hexes if optional_new_corporations

          @starting_base_hexes - OSR_MR_HOME_HEXES
        end

        # Which bases may ever receive a refueling station (§7.42): every
        # interior (non-edge) starting base except AL's, plus any base a
        # company creates later via place_base! (always eligible, regardless
        # of position). Edge-touching starting bases (VP/LE/MM/OPC/RCC, all
        # with fewer than 6 neighbors) never get one. §13b: OSR's/MR's own
        # starting bases (B14/O13) are an explicit exception on top of
        # that -- "Refueling Stations may not be placed at either of these
        # two starting bases".
        OSR_MR_HOME_HEXES = %w[B14 O13].freeze

        def station_eligible?(hex)
          return false if optional_new_corporations && OSR_MR_HOME_HEXES.include?(hex.id)
          return true unless starting_base_hexes.include?(hex.id)
          return hex.all_neighbors.size == 6 unless Array(@al_corporation.coordinates).include?(hex.id)

          # AL's home only becomes "just like any other base" -- including
          # eligible for a station -- once the League actually forms.
          # Before that it's just a placeholder
          # token with no corporation behind it yet.
          @asteroid_league_formed && hex.all_neighbors.size == 6
        end

        # A refueling station may be placed on any base within range that
        # doesn't already have one -- including a base owned by a *different*
        # corporation (§7.42 is explicit about this). "Has a base" reuses the
        # same token-presence check as `deliverable_destination?`.
        def can_place_station?(hex)
          hex_has_base?(hex) && !refueling_station_owner(hex.id) && station_eligible?(hex)
        end

        # `free:` is Vacuum Associates' one-time ability (Phase 10) -- see
        # place_base! above for the same "free, uncounted extra" pattern.
        def place_station!(entity, hex, free: false)
          cost = free ? 0 : station_cost(entity)
          entity.spend(cost, bank) if cost.positive?
          if free
            @extra_station_hexes[entity] << hex.id
          else
            @station_hexes[entity] << hex.id
          end
          @refueling_stations[hex.id] = entity

          @log << "#{entity.name} places a #{free ? 'free ' : ''}refueling station at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        # `free:` is Robot Smelters' one-time ability (Phase 10) -- the
        # claim still shows up in claim_hexes (the corp card's claim-flag
        # display), but claims_placed_lifetime excludes it, so it's an
        # uncounted extra rather than eating into the corp's claim_limit.
        def place_claim!(entity, hex, mine_idx, cost, free: false)
          entity.spend(cost, bank) if cost.positive?
          mine = @mine_state[hex.id][:mines][mine_idx]
          mine[:owner] = entity.id
          mine[:free] = true if free

          # The claimed value is now the only one that matters on the map --
          # only the claim owner may pick up here, always at the claimed rate.
          # A plain integer tile revenue parses to the same value under every
          # phase color (see Part::RevenueCenter#parse_revenue), so mirror
          # that shape directly rather than re-parsing a string. That bypass
          # skips `uniq_revenues`'s memoization too, though -- clear it by
          # hand or the map keeps showing the stale unclaimed value until
          # something else (e.g. a full reload) rebuilds the tile from
          # scratch.
          city = hex.tile.cities[mine_idx]
          city.revenue = Part::RevenueCenter::PHASES.to_h { |phase| [phase, mine[:claimed]] }
          city.instance_variable_set(:@uniq_revenues, nil)

          @log << "#{entity.name} claims a #{free ? 'free ' : ''}mine (#{claim_label(mine)}) at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        # "R:30"-style identifier for a mine -- the ore's one-letter code,
        # a colon, its claimed value -- used in claim-related log lines
        # so the log itself says what was actually claimed, not just
        # where.
        def claim_label(mine)
          "#{mine[:ore].to_s.upcase}:#{mine[:claimed]}"
        end

        # §13b: OSR's own entities.rb entry carries the +$20 surcharge it
        # alone pays when buying an already-placed claim off an
        # Independent -- 0 for every other entity. Reading this from data
        # (rather than a hardcoded entity.id == 'OSR' check) keeps the
        # actual charge (below) and the affordability check that gates the
        # purchase choice (Step::BuyInfrastructure#buy_independent_claim_
        # choices) both computed from the exact same number, rather than
        # two hand-kept-in-sync copies -- found live in browser: the
        # choice was offered (and let a player click it) using only the
        # base INDEPENDENT_CLAIM_PRICE as its own affordability check,
        # crashing OSR with "cannot spend $20" the instant it actually
        # tried to pay the surcharge on top of that base price.
        def independent_claim_surcharge(entity)
          entity_data(entity)&.dig(:independent_claim_surcharge) || 0
        end

        # The real, total cost THIS entity pays to buy an independent's
        # already-placed claim -- the flat INDEPENDENT_CLAIM_PRICE plus
        # whatever entity-specific surcharge (OSR only, today) applies.
        def independent_claim_price(entity)
          INDEPENDENT_CLAIM_PRICE + independent_claim_surcharge(entity)
        end

        # A corporation buying an already-placed claim off the independent
        # holding it. This is a flat INDEPENDENT_CLAIM_PRICE, paid to the
        # independent, not the bank.
        # The mine's revenue was already set to its claimed value back when
        # the independent originally claimed it (place_claim! above), so
        # only ownership needs to change here.
        def buy_claim_from_independent!(entity, hex, mine_idx)
          mine = @mine_state[hex.id][:mines][mine_idx]
          seller = minor_by_id(mine[:owner])
          entity.spend(INDEPENDENT_CLAIM_PRICE, seller)

          surcharge = independent_claim_surcharge(entity)
          entity.spend(surcharge, bank) if surcharge.positive?
          mine[:owner] = entity.id

          total = independent_claim_price(entity)
          @log << "#{entity.name} buys #{seller.name}'s claim (#{claim_label(mine)}) at #{hex.id} "\
                  "(#{format_currency(total)})"
        end

        # A corp buying an independent's claim is a cross-player
        # transaction whenever that independent belongs to a different
        # player than the buying corp's president -- same caution other
        # games show for share exchanges/purchases between players, via
        # the shared consent-popup mechanism (Actionable#check_consent in
        # the view layer). Only BuyInfrastructure's BUY_CLAIM choice ever
        # needs consent THROUGH THIS HOOK; every other `choose` action in
        # the game returns nil here (no consent required for it via this
        # path), the same as the engine default. This is scoped to the
        # custom `choose` action machinery specifically -- it says nothing
        # about cross-player transactions outside it. Buying a ship from
        # another player, for instance, already gets its own consent
        # popup for free from the base engine's own generic ownership
        # check in assets/app/view/game/buy_trains.rb (a real
        # Action::BuyTrain, not a `choose`), with no G2038 code involved
        # at all.
        def consenter_for_choice(entity, choice, _label)
          step = @round.active_step(entity)
          return unless step.is_a?(G2038::Step::BuyInfrastructure)

          seller = step.claim_seller_for(entity, choice)
          owner = seller&.owner
          owner if owner&.player? && owner != entity.owner
        end
      end
    end
  end
end
