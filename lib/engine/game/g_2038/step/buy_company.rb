# frozen_string_literal: true

require_relative '../../../step/buy_company'

module Engine
  module Game
    module G2038
      module Step
        # Adds TS/VA/RS's one-time free-placement abilities (§7.4x, Phase
        # 10) on top of the normal buy-a-private-company step: once a corp
        # owns Tunnel Systems/Vacuum Associates/Robot Smelters, it may use
        # the matching free base/station/claim exactly once, in any Buy
        # Companies step from then until Phase 5 (Ability::Base's own
        # count:/remove: handle the one-time-use and phase-cutoff parts --
        # see entities.rb). Independent of, and doesn't count against, the
        # corp's normal paid BuyInfrastructure placements.
        class BuyCompany < Engine::Step::BuyCompany
          FREE = 'free_'
          BASE_ABILITY = :free_base
          STATION_ABILITY = :free_station
          CLAIM_ABILITY = :free_claim

          ORE_NAMES = { n: 'Nickel', i: 'Ice', r: 'Rare' }.freeze

          def actions(entity)
            result = super
            return result if choices(entity).empty?

            result = result.dup
            result << 'choose' unless result.include?('choose')
            result
          end

          # Only ever hex-based choices (base/station/claim), aliased for
          # hex.rb's direct-click dispatch -- mirrors BuyInfrastructure's
          # own choices/alias_unambiguous_hexes! pattern exactly.
          def choices(entity = current_entity)
            return {} unless entity&.corporation?

            result = {}
            free_base_choices(entity, result) if @game.abilities(entity, BASE_ABILITY)
            free_station_choices(entity, result) if @game.abilities(entity, STATION_ABILITY)
            free_claim_choices(entity, result) if @game.abilities(entity, CLAIM_ABILITY)
            alias_unambiguous_hexes!(result)
          end

          def available_hex(entity, hex)
            return false unless entity == current_entity

            !choices_for_hex(entity, hex).empty?
          end

          def hex_choice_popup(entity, hex)
            return nil unless entity == current_entity

            matches = choices_for_hex(entity, hex)
            matches.size > 1 ? matches : nil
          end

          def city_choice(entity, city)
            return nil unless entity == current_entity

            key = "#{FREE}claim_#{city.hex.id}_#{city.tile.cities.index(city)}"
            choices(entity)[key] ? key : nil
          end

          # All interaction is hex-based (map clicks) -- no bottom-panel
          # text list, matching BuyInfrastructure's own pattern (Tunnel
          # Systems' "any explored hex" could be dozens of entries).
          def entity_choices(_entity)
            {}
          end

          # assets/app/view/game/choose.rb calls this unconditionally (no
          # respond_to? guard) whenever 'choose' is an active action --
          # nil here just means no label line renders, consistent with
          # entity_choices above having nothing to show either.
          def choice_name
            nil
          end

          def process_choose(action)
            entity = action.entity
            choice = unalias(entity, action.choice)
            raise GameError, "Invalid choice: #{choice}" unless choices(entity).key?(choice)

            if choice.start_with?("#{FREE}base_")
              @game.place_base!(entity, @game.hex_by_id(choice.delete_prefix("#{FREE}base_")), free: true)
              @game.abilities(entity, BASE_ABILITY).use!
            elsif choice.start_with?("#{FREE}station_")
              @game.place_station!(entity, @game.hex_by_id(choice.delete_prefix("#{FREE}station_")), free: true)
              @game.abilities(entity, STATION_ABILITY).use!
            elsif choice.start_with?("#{FREE}claim_")
              hex_id, _sep, idx = choice.delete_prefix("#{FREE}claim_").rpartition('_')
              @game.place_claim!(entity, @game.hex_by_id(hex_id), idx.to_i, 0, free: true)
              @game.abilities(entity, CLAIM_ABILITY).use!
            end
          end

          # Opt-in hooks for assets/app/view/game/hex.rb -- same reasoning
          # as Step::BuyInfrastructure's own highlight_base_hexes/
          # highlight_station_hexes (placing a free TS/VA/RS base, station,
          # or claim wants the same "where do I already have infrastructure"
          # context, per the user). No sub_phase gate needed here -- unlike
          # BuyInfrastructure, this step only ever runs while a corp
          # actually has a usable free-placement ability, per its own
          # class comment.
          def highlight_base_hexes(entity)
            return [] unless entity&.corporation?

            entity.tokens.filter_map { |t| t.city&.hex&.id }.uniq
          end

          def highlight_station_hexes(entity)
            return [] unless entity&.corporation?

            @game.station_hexes(entity)
          end

          private

          # Tunnel Systems: map-wide, not range-limited -- the one real
          # difference from Vacuum Associates/Robot Smelters, both of which
          # use hexes_in_range like their paid BuyInfrastructure equivalents.
          def free_base_choices(entity, result)
            @game.hexes.each do |hex|
              next unless @game.can_place_base?(hex)

              result["#{FREE}base_#{hex.id}"] = "Use Tunnel Systems: free base at #{hex.id}"
            end
          end

          def free_station_choices(entity, result)
            @game.hexes_in_range(entity).each do |hex|
              next unless @game.can_place_station?(hex)

              result["#{FREE}station_#{hex.id}"] = "Use Vacuum Associates: free refueling station at #{hex.id}"
            end
          end

          def free_claim_choices(entity, result)
            @game.hexes_in_range(entity).each do |hex|
              state = @game.mine_state[hex.id]
              next unless state

              state[:mines].each_with_index do |mine, idx|
                next if mine[:owner]

                result["#{FREE}claim_#{hex.id}_#{idx}"] =
                  "Use Robot Smelters: free #{ORE_NAMES[mine[:ore]]} claim at #{hex.id}"
              end
            end
          end

          # All hex-based choices (in any of the three kinds) that resolve
          # to this specific hex.
          def choices_for_hex(entity, hex)
            choices(entity).select do |key, _label|
              key == "#{FREE}base_#{hex.id}" || key == "#{FREE}station_#{hex.id}" ||
                key.start_with?("#{FREE}claim_#{hex.id}_")
            end
          end

          # Expose every hex with an applicable choice keyed by its bare hex
          # id too, so hex.rb's generic dispatch (gated on
          # `step.choices.include?(@hex.id)`) has a key to find -- same
          # idiom as BuyInfrastructure's own alias_unambiguous_hexes!.
          def alias_unambiguous_hexes!(result)
            by_hex = Hash.new { |h, k| h[k] = [] }
            result.each_key { |key| (id = hex_id_for(key)) && (by_hex[id] << key) }
            by_hex.each { |hex_id, keys| result[hex_id] ||= result[keys.first] }
            result
          end

          def hex_id_for(key)
            return key.delete_prefix("#{FREE}base_") if key.start_with?("#{FREE}base_")
            return key.delete_prefix("#{FREE}station_") if key.start_with?("#{FREE}station_")
            return key.delete_prefix("#{FREE}claim_").rpartition('_').first if key.start_with?("#{FREE}claim_")

            nil
          end

          # Translate a bare-hex-id alias back to the real prefixed choice
          # key process_choose dispatches on. Non-alias choices (already a
          # real prefixed key from a hex_choice_popup submission) pass
          # through unchanged.
          def unalias(entity, choice)
            return choice if choice.start_with?("#{FREE}base_", "#{FREE}station_", "#{FREE}claim_")

            choices(entity).keys.find { |key| hex_id_for(key) == choice } || choice
          end
        end
      end
    end
  end
end
