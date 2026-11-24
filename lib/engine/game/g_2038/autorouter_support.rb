# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module Autorouting
        def autorouter
          @autorouter ||= Autorouter.new(self)
        end

        # AL only reaches 4 ships in Phases IV-V, once routes are long and
        # the map is developed -- exactly when the ordering count (4! =
        # 24) can make a single Auto click genuinely slow. Other corps
        # reach 4 ships too early for that to be the bottleneck.
        def warn_on_four_ships?(entity)
          entity_data(entity)&.dig(:warn_on_four_ships) || false
        end

        # Admissible upper bound (deliberately loose, never tight) --
        # safe for Step::Route#try_ordering!'s pruning, since an
        # over-estimate can only fail to prune early, never wrongly
        # discard a genuinely-better ordering.
        def solo_ceiling(entity, ship)
          holds = cargo_holds_for_ship(ship)
          per_slot = [max_reachable_mine_value(entity), max_transshipment_value(ship)].max
          holds * per_slot
        end

        # Ignores distance/MP entirely -- deliberately loose, see
        # solo_ceiling above.
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

        def max_transshipment_value(ship)
          best = 0
          Map::TRANSSHIPMENT_HEXES.each do |hex_id|
            next unless transshipment_hex?(hex_id)

            value = transshipment_value(hex_by_id(hex_id), ship)
            best = value if value > best
          end
          best
        end

        # `value` is a safe over-estimate used only for ranking;
        # `raw_value` keeps no bonus assumption baked in, for the
        # feasibility solver to let Game#trace_revenue compute the real
        # bonus for wherever a specific route actually ends.
        CandidateSlot = Struct.new(:hex_id, :mine_idx, :ore, :value, :raw_value, keyword_init: true)

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

        # Deliberately loose, not exact: a real route only ends at ONE
        # hex, so at most one home_delivery_bonus can be realized across
        # the whole cargo -- crediting every slot its own
        # independently-best bonus can overstate the true total. That's
        # intentional, the same admissible-bound philosophy as
        # solo_ceiling above.
        def best_case_ore_bonus(entity, ship, ore, claimed:)
          return 0 unless ore

          entity_fixed_ore_bonus(entity, ship, ore, claimed: claimed) + best_home_delivery_amount(ore)
        end

        # The destination-independent slice of #best_case_ore_bonus --
        # pulled out so Autorouter's per-destination sweeps can credit
        # this part unconditionally and add a home bonus only when a
        # slot's ore matches that sweep's assumed destination.
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

        def best_home_delivery_amount(ore)
          home_delivery_bonuses.values.select { |bonus_ore, _| bonus_ore == ore }.map { |_, amt| amt }.max.to_i
        end
      end
    end
  end
end
