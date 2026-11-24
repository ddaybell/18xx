# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G2038
      module Step
        # Bases, refueling stations, and claims (§7.4). The Sequence of
        # Play card enforces these as three strict, ordered sub-phases per
        # entity (:base -> :station -> :claim), not a free-for-all set.
        class BuyInfrastructure < Engine::Step::Base
          ACTIONS = %w[choose pass].freeze

          BASE = 'base_'
          STATION = 'station_'
          CLAIM = 'claim_'
          BUY_CLAIM = 'buy_claim_'
          SKIP_BASE = 'skip_base'
          SKIP_STATION = 'skip_station'

          ORE_NAMES = { n: 'Nickel', i: 'Ice', r: 'Rare' }.freeze

          def description
            'Buy Infrastructure'
          end

          def pass_description
            'Skip Infrastructure'
          end

          # Called unconditionally by assets/app/view/game/choose.rb, unlike
          # its other step hooks (all gated behind `respond_to?`).
          def choice_name
            entity = current_entity
            return nil unless entity

            case @sub_phase[entity]
            when :base then 'Place Base'
            when :station then 'Place Refueling Station'
            when :claim then 'Claim Mine'
            end
          end

          def setup
            @sub_phase = Hash.new { |h, entity| h[entity] = entity.corporation? ? :base : :claim }
            @base_placed = Hash.new(false)
            @station_placed = Hash.new(false)
            @claims_this_round = Hash.new(0)
          end

          # Opt-in hooks for assets/app/view/game/hex.rb.
          def highlight_base_hexes(entity)
            return [] unless entity&.operator?
            return [] unless %i[base station claim].include?(@sub_phase[entity])

            entity.tokens.filter_map { |t| t.city&.hex&.id }.uniq
          end

          def highlight_station_hexes(entity)
            return [] unless entity&.operator?
            return [] unless %i[base station claim].include?(@sub_phase[entity])

            @game.station_hexes(entity)
          end

          def actions(entity)
            return [] unless entity == current_entity
            return [] if choices(entity).empty?

            ACTIONS
          end

          def choices(entity = current_entity)
            return {} unless entity&.operator?

            advance_empty_phases!(entity)

            result =
              case @sub_phase[entity]
              when :base
                base_choices(entity)
              when :station
                station_choices(entity)
              when :claim
                claim_choices(entity)
              else
                {}
              end

            alias_unambiguous_hexes!(result)
          end

          def available_hex(entity, hex)
            return false unless entity == current_entity

            !choices_for_hex(entity, hex).empty?
          end

          # A single-match hex is already dispatchable directly via its
          # bare-hex-id alias (see alias_unambiguous_hexes!); only a 2+
          # match (a double-mine hex) needs this popup.
          def hex_choices(entity, hex)
            return nil unless entity == current_entity

            matches = choices_for_hex(entity, hex)
            matches.size > 1 ? matches : nil
          end

          # Opt-in hook Part::CitySlot prefers over the hex-level dispatch
          # (assets/app/view/game/part/city_slot.rb).
          def city_choice(entity, city)
            return nil unless entity == current_entity && @sub_phase[entity] == :claim

            key = "#{CLAIM}#{city.hex.id}_#{city.tile.cities.index(city)}"
            choices(entity)[key] ? key : nil
          end

          # round/operating.rb renders `h(Choose)` with no `entity:` prop
          # (always nil) -- the passed-in `entity` here can't be trusted,
          # or `choices(nil)` always returns {} and nothing ever appears.
          def entity_choices(_entity)
            entity = current_entity
            return {} unless entity

            choices(entity).select { |key, _label| key == SKIP_BASE || key == SKIP_STATION }
          end

          def process_choose(action)
            entity = action.entity
            choice = action.choice
            raise GameError, "Invalid infrastructure choice: #{choice}" unless choices(entity).key?(choice)

            choice = unalias(entity, choice)

            if choice == SKIP_BASE
              @sub_phase[entity] = :station
            elsif choice == SKIP_STATION
              @sub_phase[entity] = :claim
            elsif choice.start_with?(BASE)
              @game.place_base!(entity, @game.hex_by_id(choice.delete_prefix(BASE)))
              @base_placed[entity] = true
              @sub_phase[entity] = :station
            elsif choice.start_with?(STATION)
              @game.place_station!(entity, @game.hex_by_id(choice.delete_prefix(STATION)))
              @station_placed[entity] = true
              @sub_phase[entity] = :claim
            elsif choice.start_with?(BUY_CLAIM)
              hex_id, _sep, idx = choice.delete_prefix(BUY_CLAIM).rpartition('_')
              @game.buy_claim_from_independent!(entity, @game.hex_by_id(hex_id), idx.to_i)
            elsif choice.start_with?(CLAIM)
              hex_id, _sep, idx = choice.delete_prefix(CLAIM).rpartition('_')
              @game.place_claim!(entity, @game.hex_by_id(hex_id), idx.to_i, claim_cost(entity))
              @claims_this_round[entity] += 1
            end
          end

          def process_pass(action)
            log_pass(action.entity)
            pass!
          end

          def claim_seller_for(entity, choice)
            real_choice = unalias(entity, choice)
            return nil unless real_choice.start_with?(BUY_CLAIM)

            hex_id, _sep, idx = real_choice.delete_prefix(BUY_CLAIM).rpartition('_')
            mine = @game.mine_state.dig(hex_id, :mines, idx.to_i)
            mine && @game.minor_by_id(mine[:owner])
          end

          private

          def choices_for_hex(entity, hex)
            choices(entity).select do |key, _label|
              key == "#{BASE}#{hex.id}" || key == "#{STATION}#{hex.id}" ||
                key.start_with?("#{CLAIM}#{hex.id}_") || key.start_with?("#{BUY_CLAIM}#{hex.id}_")
            end
          end

          # hex.rb's dispatch is gated on `step.choices.include?(@hex.id)`
          # -- even an ambiguous (2+ choice) hex needs a bare-hex-id entry
          # here, as a placeholder, purely so that gate lets hex_choices
          # get asked for its popup at all. It's never itself dispatched
          # in that case.
          def alias_unambiguous_hexes!(result)
            by_hex = Hash.new { |h, k| h[k] = [] }
            result.each_key { |key| (id = hex_id_for(key)) && (by_hex[id] << key) }
            by_hex.each { |hex_id, keys| result[hex_id] ||= result[keys.first] }
            result
          end

          def hex_id_for(key)
            return key.delete_prefix(BASE) if key.start_with?(BASE)
            return key.delete_prefix(STATION) if key.start_with?(STATION)
            return key.delete_prefix(BUY_CLAIM).rpartition('_').first if key.start_with?(BUY_CLAIM)
            return key.delete_prefix(CLAIM).rpartition('_').first if key.start_with?(CLAIM)

            nil
          end

          def unalias(entity, choice)
            return choice if choice == SKIP_BASE || choice == SKIP_STATION ||
              choice.start_with?(BASE, STATION, BUY_CLAIM, CLAIM)

            choices(entity).keys.find { |key| hex_id_for(key) == choice } || choice
          end

          def advance_empty_phases!(entity)
            @sub_phase[entity] = :station if @sub_phase[entity] == :base && base_choices(entity).empty?
            @sub_phase[entity] = :claim if @sub_phase[entity] == :station && station_choices(entity).empty?
          end

          # Claims have no such gate on the Sequence of Play card -- only
          # bases/stations unlock after Phase I.
          def after_phase_1?
            @game.after_phase_1?
          end

          def base_choices(entity)
            result = {}
            return result if @base_placed[entity] || !after_phase_1?
            return result if @game.base_hexes(entity).size >= @game.base_limit(entity)

            cost = @game.base_cost(entity)
            return result if entity.cash < cost

            @game.hexes_in_range(entity).each do |hex|
              next unless @game.can_place_base?(hex)

              result["#{BASE}#{hex.id}"] = "Place base at #{hex.id} (#{@game.format_currency(cost)})"
            end
            result[SKIP_BASE] = 'Skip base purchase' unless result.empty?
            result
          end

          def station_choices(entity)
            result = {}
            return result if @station_placed[entity] || !after_phase_1?
            return result if @game.station_hexes(entity).size >= @game.station_limit(entity)

            cost = @game.station_cost(entity)
            return result if entity.cash < cost

            @game.hexes_in_range(entity).each do |hex|
              next unless @game.can_place_station?(hex)

              result["#{STATION}#{hex.id}"] = "Place refueling station at #{hex.id} (#{@game.format_currency(cost)})"
            end
            result[SKIP_STATION] = 'Skip refueling station purchase' unless result.empty?
            result
          end

          def claim_choices(entity)
            result = {}
            result.merge!(buy_independent_claim_choices(entity)) if entity.corporation?
            return result unless claimable_this_round?(entity)

            cost = claim_cost(entity)
            return result if entity.cash < cost

            @game.hexes_in_range(entity).each do |hex|
              state = @game.mine_state[hex.id]
              next unless state

              state[:mines].each_with_index do |mine, idx|
                next if mine[:owner]

                # A {ore:, value:} hash, not text -- HexChoiceSelector
                # renders this as an ore-colored icon instead of a button.
                result["#{CLAIM}#{hex.id}_#{idx}"] = { ore: mine[:ore], value: mine[:unclaimed] }
              end
            end
            result
          end

          # A flat-price transfer from an independent, not a new placement
          # -- counts against lifetime claim_limit but not the escalating
          # per-round @claims_this_round schedule. Gated on
          # can_buy_companies_or_claims?, not after_phase_1?, since it
          # stops once every independent has merged into the AL.
          def buy_independent_claim_choices(entity)
            result = {}
            return result unless @game.can_buy_companies_or_claims?
            return result unless claims_placed_lifetime(entity) < @game.claim_limit(entity)

            price = @game.independent_claim_price(entity)
            return result if entity.cash < price

            @game.hexes_in_range(entity).each do |hex|
              state = @game.mine_state[hex.id]
              next unless state

              state[:mines].each_with_index do |mine, idx|
                seller = mine[:owner] && @game.minor_by_id(mine[:owner])
                next unless seller

                result["#{BUY_CLAIM}#{hex.id}_#{idx}"] =
                  "Buy #{ORE_NAMES[mine[:ore]]} claim from #{seller.name} (#{@game.format_currency(price)})"
              end
            end
            result
          end

          # §7.4 lifetime cap; §7.43 per-round cost tier (corporations only).
          def claimable_this_round?(entity)
            return false unless claims_placed_lifetime(entity) < @game.claim_limit(entity)
            return true if entity.minor?

            @claims_this_round[entity] < @game.claim_cost_schedule(entity).size
          end

          def claims_placed_lifetime(entity)
            @game.claims_placed_lifetime(entity)
          end

          def claim_cost(entity)
            schedule = @game.claim_cost_schedule(entity)
            schedule[@claims_this_round[entity]] || schedule.last
          end
        end
      end
    end
  end
end
