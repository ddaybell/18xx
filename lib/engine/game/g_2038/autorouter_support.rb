# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module Autorouting
        # The "optimal set" ship-route search engine (see autorouter.rb) --
        # reused across calls since it holds no state of its own between
        # searches beyond one in-flight run's own progress.
        def autorouter
          @autorouter ||= Autorouter.new(self)
        end

        # Public: whether ship_selector.rb's four_ship_warning should ever
        # show for this entity -- data-driven (entities.rb's own
        # warn_on_four_ships flag, AL only today) rather than a hardcoded
        # entity.id == 'AL' check here, so nothing in this file needs to
        # know which specific corp that is. Every non-AL corp can only
        # ever reach 4 ships early (short routes, a sparse, barely-
        # explored map), where the ranking phase's ordering count is
        # never actually the bottleneck -- unlike AL, which only reaches 4
        # in Phases IV-V, once routes are long and the map is developed,
        # exactly when that ordering count (4! = 24) can make a single
        # Auto click genuinely slow.
        def warn_on_four_ships?(entity)
          entity_data(entity)&.dig(:warn_on_four_ships) || false
        end

        # Cheap, admissible upper bound on one ship's best possible
        # revenue, ignoring ordering entirely (as if it had the whole
        # board to itself) -- every hold filled with the single best mine
        # or transshipment value reachable anywhere, ignoring MP cost and
        # ignoring that an earlier ship in the same ordering may have
        # already claimed the best of it. Deliberately loose (a real
        # search would find less), never tight -- but safe for Step::
        # Route#try_ordering!'s own cross-ordering pruning, where an
        # over-estimate can only ever fail to prune a hopeless ordering
        # early, never wrongly discard a genuinely-better one.
        #
        def solo_ceiling(entity, ship)
          holds = cargo_holds_for_ship(ship)
          per_slot = [max_reachable_mine_value(entity), max_transshipment_value(ship)].max
          holds * per_slot
        end

        # An admissible (never-too-low) upper bound on the single best
        # mine value reachable anywhere on the map for this entity --
        # ignores distance/MP entirely, deliberately loose (see
        # solo_ceiling above).
        def max_reachable_mine_value(entity)
          best = 0
          mine_state.each do |hex_id, state|
            state[:mines].each_index do |idx|
              mine = state[:mines][idx]
              next if mine[:used]
              next if mine[:owner] && mine[:owner] != entity.id

              value = pickup_value(entity, hex_id, idx)
              best = value if value > best
            end
          end
          best
        end

        # Same idea as max_reachable_mine_value above, but for
        # transshipment credit -- needs no exploration or claim ownership
        # at all, so it can be the entire reason a route is worth taking
        # even when nothing is explored yet.
        def max_transshipment_value(ship)
          best = 0
          Map::TRANSSHIPMENT_HEXES.each do |hex_id|
            next unless transshipment_hex?(hex_id)

            value = transshipment_value(hex_by_id(hex_id), ship)
            best = value if value > best
          end
          best
        end

        # no bonus assumption baked in -- the feasibility solver (Game::
        # Autorouter's own component) needs this to build a real
        # cargo list and let Game#trace_revenue compute actual bonuses
        # for whatever destination a specific route really reaches, since
        # `value`'s bonus assumption is only a safe over-estimate for
        # ranking, not necessarily achievable for any single combo.
        CandidateSlot = Struct.new(:hex_id, :mine_idx, :ore, :value, :raw_value, keyword_init: true)

        # Public: every slot this entity+ship could currently pick up --
        # every unclaimed-or-entity-owned, not-yet-used-this-OR mine, plus
        # every currently-paying transshipment hex -- each tagged with an
        # admissible (never too low) ceiling on what a single unit there
        # could ever contribute: its own pickup/transshipment value, plus
        # #best_case_ore_bonus for whatever ore it is. The alternative-
        # ordering search (component 2 of the "optimal set" autorouter --
        # see also Game#solo_ceiling, the earlier per-ship version
        # of this same idea) ranks candidate cargo combinations by summing
        # these values, highest first.
        def candidate_slots(entity, ship)
          slots = []

          @mine_state.each do |hex_id, state|
            state[:mines].each_with_index do |mine, idx|
              next if mine[:used]
              next if mine[:owner] && mine[:owner] != entity.id

              bonus = best_case_ore_bonus(entity, ship, mine[:ore], claimed: mine[:owner] == entity.id)
              raw = pickup_value(entity, hex_id, idx)
              slots << CandidateSlot.new(hex_id: hex_id, mine_idx: idx, ore: mine[:ore],
                                          value: raw + bonus, raw_value: raw)
            end
          end

          Map::TRANSSHIPMENT_HEXES.each do |hex_id|
            next unless transshipment_hex?(hex_id)

            value = transshipment_value(hex_by_id(hex_id), ship)
            next unless value.positive?

            slots << CandidateSlot.new(hex_id: hex_id, mine_idx: nil, ore: nil, value: value, raw_value: value)
          end

          slots
        end

        # The best-case additional bonus (beyond raw pickup/transshipment
        # value) a single unit of `ore` could ever contribute for this
        # entity+ship -- entity's own company_ore_bonuses entry, its assigned
        # pilot's ore bonus, OSR's own claim-delivery bonus (if this unit
        # is a mine OSR itself has claimed), and whichever home_delivery_
        # bonuses hex pays the MOST for this ore.
        #
        # Deliberately loose, not exact: a real route only ever ends at
        # ONE hex, so at most one home_delivery_bonus can actually be
        # realized across the whole cargo -- crediting every slot its own
        # independently-best bonus assumes they could all somehow deliver
        # to their own ideal destination at once, which overstates the
        # true achievable total if two slots' best-paying hexes differ.
        # That's fine and intentional here, the same admissible-bound
        # philosophy Game#solo_ceiling already uses for ranking/
        # pruning candidates against each other -- it can only ever fail
        # to prune something early, never wrongly discard a genuinely-
        # better combination. transshipment slots (ore nil) never get a
        # bonus -- none of these bonus types key off a nil ore.
        def best_case_ore_bonus(entity, ship, ore, claimed:)
          return 0 unless ore

          entity_fixed_ore_bonus(entity, ship, ore, claimed: claimed) + best_home_delivery_amount(ore)
        end

        # Just the destination-INDEPENDENT slice of #best_case_ore_bonus
        # -- entity's own company_ore_bonuses entry, its assigned pilot's ore
        # bonus, and OSR's own claim-delivery bonus -- every one of these
        # applies no matter where the route ends, unlike the home_
        # delivery_bonus portion. Pulled out so Autorouter's per-
        # destination-ore-focused sweeps (see that file's own comment on
        # why summing every slot's own independently-best home bonus made
        # the search's stopping point too slow to reach on a rich board)
        # can credit this exact, non-estimated part unconditionally, and
        # only add a home bonus when a slot's ore matches that sweep's
        # one assumed destination -- keeping each sweep's own per-slot
        # values genuinely additive/separable, unlike the combined bound.
        def entity_fixed_ore_bonus(entity, ship, ore, claimed:)
          return 0 unless ore

          bonus = 0
          own_ore, own_amount = company_ore_bonuses[entity.id]
          bonus += own_amount if own_ore == ore
          pilot_ore, pilot_amount = company_ore_bonuses[pilot_source_for_ship(entity, ship)]
          bonus += pilot_amount if pilot_ore == ore
          bonus += (claim_delivery_bonuses[entity.id] || 0) if claimed
          bonus
        end

        # The most any single home_delivery_bonuses hex pays for `ore` --
        # 0 if none do.
        def best_home_delivery_amount(ore)
          home_delivery_bonuses.values.select { |bonus_ore, _| bonus_ore == ore }.map { |_, amt| amt }.max.to_i
        end
      end
    end
  end
end
