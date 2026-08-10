# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G2038
      module Step
        # Bases, refueling stations, and claims (§7.4) -- the "Purchases"
        # portion of the OR sequence, alongside G2038::Step::BuyTrain.
        # Reuses the same choose-per-target-hex pattern as Route, since
        # there's no existing "buy a marker" step compatible with G2038's
        # non-graph-based (hex-BFS) reachability model.
        #
        # The Sequence of Play card enumerates these as three strict,
        # ordered sub-phases per entity -- all bases before any refueling
        # stations, all refueling stations before any claims -- not a single
        # free-for-all choice set. Each entity tracks its own current
        # sub-phase (:base -> :station -> :claim), auto-advancing past any
        # sub-phase with nothing to offer (already used, nothing in range,
        # unaffordable, or -- for minors -- skipped entirely since they may
        # never buy bases/stations at all). If every sub-phase comes up
        # empty this way, `choices`/`actions` end up empty too, and the
        # round engine's generic `skip_steps` (lib/engine/round/base.rb)
        # auto-passes this entity with its own log entry -- no extra
        # plumbing needed here for that part.
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

          # Distinct from the per-sub-phase SKIP_BASE/SKIP_STATION choices
          # (which only advance past *one* sub-phase, letting the next one
          # still proceed): this is the step-wide `pass` action, ending
          # BuyInfrastructure entirely for this turn -- base, station, AND
          # claim -- since it's the last step in the OR sequence, that also
          # ends the entity's whole turn.
          def pass_description
            'Skip Infrastructure'
          end

          # The generic Choose view (assets/app/view/game/choose.rb) calls
          # this unconditionally, unlike its other optional step hooks (which
          # are all gated behind `respond_to?`). Doubles as the player-facing
          # signal for which of the three strict sub-phases (base -> station
          # -> claim) this entity is currently in -- otherwise nothing on
          # screen says so.
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

          def actions(entity)
            return [] unless entity == current_entity
            return [] if choices(entity).empty?

            ACTIONS
          end

          # Only ever returns choices for the entity's *current* sub-phase --
          # never a mix of base/station/claim options at once.
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

          # Greys out hexes that aren't a valid target for the entity's
          # *current* sub-phase, via the same opacity mechanism Route
          # already uses for reachable hexes during flight (Map#render
          # checks this per hex). Naturally phase-scoped since it just
          # reads `choices`.
          def available_hex(entity, hex)
            return false unless entity == current_entity

            !choices_for_hex(entity, hex).empty?
          end

          # Only needed to disambiguate a hex with 2+ possible actions (a
          # double-mine hex during the claim sub-phase, picking which ore).
          # A hex with exactly one relevant choice is already given a
          # bare-hex-id alias by `choices` (see `alias_unambiguous_hexes!`),
          # so hex.rb's existing `step.choices.include?(@hex.id)` dispatch
          # fires it directly with no popup needed -- same mechanism every
          # other game's hex clicks already use, no engine/view changes.
          def hex_choice_popup(entity, hex)
            return nil unless entity == current_entity

            matches = choices_for_hex(entity, hex)
            matches.size > 1 ? matches : nil
          end

          # Opt-in hook Part::CitySlot prefers over the hex-level dispatch
          # (see assets/app/view/game/part/city_slot.rb): clicking directly
          # on a specific mine's circle resolves its claim in one click,
          # rather than needing the popup above to disambiguate. Only
          # meaningful during the claim sub-phase -- a base/station hex's
          # single choice is already reachable via the ordinary bare-hex-id
          # click (hex_choice_popup only ever triggers for 2+ claim matches).
          def city_choice(entity, city)
            return nil unless entity == current_entity && @sub_phase[entity] == :claim

            key = "#{CLAIM}#{city.hex.id}_#{city.tile.cities.index(city)}"
            choices(entity)[key] ? key : nil
          end

          # Opt-in hook the generic Choose view prefers for its bottom-panel
          # button list (see assets/app/view/game/choose.rb). Base/station/
          # claim choices are all hex-based and fully redundant with
          # clicking the relevant hex directly (available_hex/
          # hex_choice_popup above) -- only the phase-skip choices have no
          # map equivalent, so those are all that's left here.
          #
          # assets/app/view/game/round/operating.rb renders `h(Choose)` with
          # no `entity:` prop (always nil), so the passed-in `entity` here
          # can't be trusted -- must resolve the real current_entity itself,
          # or `choices(nil)` always returns {} and SKIP_BASE/SKIP_STATION
          # never appear.
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

          # Public: resolves a (possibly bare-hex-alias) choice back to the
          # independent minor selling that claim, or nil for any other
          # choice -- used by Game#consenter_for_choice to determine whose
          # consent is needed for this cross-player purchase (buying a
          # claim from an independent owned by a different player).
          def claim_seller_for(entity, choice)
            real_choice = unalias(entity, choice)
            return nil unless real_choice.start_with?(BUY_CLAIM)

            hex_id, _sep, idx = real_choice.delete_prefix(BUY_CLAIM).rpartition('_')
            mine = @game.mine_state.dig(hex_id, :mines, idx.to_i)
            mine && @game.minor_by_id(mine[:owner])
          end

          private

          # All choices (in the entity's current sub-phase) that resolve to
          # this specific hex -- 0, 1 (base/station, or a single-mine claim),
          # or 2 (a double-mine hex's two unclaimed ores).
          def choices_for_hex(entity, hex)
            choices(entity).select do |key, _label|
              key == "#{BASE}#{hex.id}" || key == "#{STATION}#{hex.id}" ||
                key.start_with?("#{CLAIM}#{hex.id}_") || key.start_with?("#{BUY_CLAIM}#{hex.id}_")
            end
          end

          # Expose every hex with an applicable base/station/claim choice
          # keyed by its bare hex id too, so hex.rb's generic dispatch --
          # gated on `step.choices.include?(@hex.id)` before it even looks
          # for a popup -- has a key to find. For an unambiguous hex (one
          # choice) this is the real, directly-dispatchable action. For an
          # ambiguous hex (2+ choices, e.g. a double-mine's two unclaimed
          # ores) it's a placeholder that's never actually dispatched --
          # `hex_choice_popup` always intercepts first when there's more
          # than one match (see that method) -- but it still has to be
          # present, or hex.rb's dispatch gate never lets it ask for the
          # popup at all.
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

          # Translate a bare-hex-id alias (see `alias_unambiguous_hexes!`)
          # back to the real prefixed choice key process_choose dispatches
          # on. Non-alias choices (skip_base/skip_station, or an already-
          # prefixed key from a hex_choice_popup submission) pass through
          # unchanged.
          def unalias(entity, choice)
            return choice if choice == SKIP_BASE || choice == SKIP_STATION ||
              choice.start_with?(BASE, STATION, BUY_CLAIM, CLAIM)

            choices(entity).keys.find { |key| hex_id_for(key) == choice } || choice
          end

          # Skip forward past any sub-phase this entity has nothing to do
          # in -- already used this round, nothing in range/affordable, or
          # (for minors) not applicable at all -- without requiring an
          # explicit "Skip" click when there was never a real choice to make.
          def advance_empty_phases!(entity)
            @sub_phase[entity] = :station if @sub_phase[entity] == :base && base_choices(entity).empty?
            @sub_phase[entity] = :claim if @sub_phase[entity] == :station && station_choices(entity).empty?
          end

          # Bases and refueling stations are only buyable "after Phase I"
          # (Sequence of Play card) -- reuses the same phase status flag
          # that already gates private-company purchases and inter-company
          # train buying (@game.after_phase_1?), since all unlock at the
          # same Phase II transition. Claims have no such marker on the
          # card, so they're available from Phase 1.
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

                result["#{CLAIM}#{hex.id}_#{idx}"] =
                  "Claim #{ORE_NAMES[mine[:ore]]} mine, revenue #{@game.format_currency(mine[:unclaimed])} "\
                  "(#{@game.format_currency(cost)})"
              end
            end
            result
          end

          # Corporations may buy an already-claimed mine directly from the
          # independent holding it, at a flat price -- confirmed with the
          # user: available from Phase 2 on (same start as bases/stations,
          # since claims themselves have no such gate but this transfer
          # does), still counts against the buyer's lifetime claim_limit
          # like any other claim it ends up holding, but is NOT limited by
          # the per-round escalating schedule/count (@claims_this_round)
          # above since it's a flat-price transfer, not a new placement.
          # `minor_by_id` returns nil for a corp-owned mine (including one
          # this entity already owns itself), so this naturally only ever
          # offers independent-held claims. Gated on can_buy_companies_or_claims?
          # rather than after_phase_1? -- unlike bases/stations, this stops
          # at Phase 5 once every independent has merged into the AL and
          # there's no one left to sell a claim.
          def buy_independent_claim_choices(entity)
            result = {}
            return result unless @game.can_buy_companies_or_claims?
            return result unless claims_placed_lifetime(entity) < @game.claim_limit(entity)
            return result if entity.cash < @game.class::INDEPENDENT_CLAIM_PRICE

            @game.hexes_in_range(entity).each do |hex|
              state = @game.mine_state[hex.id]
              next unless state

              state[:mines].each_with_index do |mine, idx|
                seller = mine[:owner] && @game.minor_by_id(mine[:owner])
                next unless seller

                result["#{BUY_CLAIM}#{hex.id}_#{idx}"] =
                  "Buy #{ORE_NAMES[mine[:ore]]} claim from #{seller.name} "\
                  "(#{@game.format_currency(@game.class::INDEPENDENT_CLAIM_PRICE)})"
              end
            end
            result
          end

          # Every entity has a lifetime claim cap (§7.4) -- a flat 2 for
          # independents, a per-corp value from the Company/Corporation
          # Summary table otherwise (@game.claim_limit). Corporations also
          # follow the per-round cost tier schedule (§7.43, resets every OR);
          # independents don't have one of those, just the lifetime cap.
          def claimable_this_round?(entity)
            return false unless claims_placed_lifetime(entity) < @game.claim_limit(entity)
            return true if entity.minor?

            @claims_this_round[entity] < @game.claim_cost_schedule(entity).size
          end

          def claims_placed_lifetime(entity)
            @game.claims_placed_lifetime(entity)
          end

          # Price is always by this-round claim count and resets every OR
          # for every entity type -- independents' *eligibility* is capped
          # separately by lifetime count (claimable_this_round? above), but
          # that's a distinct rule from pricing.
          def claim_cost(entity)
            schedule = @game.claim_cost_schedule(entity)
            schedule[@claims_this_round[entity]] || schedule.last
          end
        end
      end
    end
  end
end
