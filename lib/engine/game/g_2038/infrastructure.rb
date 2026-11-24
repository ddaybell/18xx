# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module Infrastructure
        DEFAULT_CLAIM_COSTS = [60, 100].freeze

        # Flat price for a corporation buying an already-placed claim
        # directly from the independent holding it (§7.4x).
        INDEPENDENT_CLAIM_PRICE = 60

        # §7.4.
        def corp_data(entity)
          Entities::CORPORATIONS.find { |c| c[:sym] == entity.id }
        end

        # Memoized -- called from claim_limit and autorouter_support on
        # every entity check; otherwise reallocates and rescans both
        # arrays every call.
        def entity_data(entity)
          @entity_data_by_sym ||= (Entities::MINORS + Entities::CORPORATIONS).to_h { |c| [c[:sym], c] }
          @entity_data_by_sym[entity.id]
        end

        def base_cost(entity)
          costs = corp_data(entity)&.dig(:bases) || [50]
          costs[@base_hexes[entity].size] || costs.last
        end

        def station_cost(entity)
          costs = corp_data(entity)&.dig(:stations) || [50]
          costs[@station_hexes[entity].size] || costs.last
        end

        def base_hexes(entity)
          @base_hexes[entity]
        end

        def station_hexes(entity)
          @station_hexes[entity]
        end

        def extra_base_hexes(entity)
          @extra_base_hexes[entity]
        end

        def extra_station_hexes(entity)
          @extra_station_hexes[entity]
        end

        # §8.12/Phase 9h: AL holds back 1 base-placement slot for each
        # independent that hasn't merged in yet.
        def base_limit(entity)
          limit = corp_data(entity)&.dig(:bases)&.size || Float::INFINITY
          return limit unless entity == @al_corporation

          [limit - remaining_independents.size, 0].max
        end

        def station_limit(entity)
          corp_data(entity)&.dig(:stations)&.size || Float::INFINITY
        end

        def station_logo(entity)
          "/logos/g_2038/#{entity.id}_station.svg"
        end

        def claim_logo(entity)
          "/logos/g_2038/#{entity.id}_claim.svg"
        end

        # A double-mine hex claimed twice by the same entity appears twice.
        def claim_hexes(entity)
          @mine_state.flat_map { |hex_id, state| [hex_id] * state[:mines].count { |m| m[:owner] == entity.id } }
        end

        # `free` (Robot Smelters' one-time ability, Phase 10) is surfaced
        # here too -- an uncounted extra, but still a real claim to show.
        def claim_details(entity)
          @mine_state.flat_map do |hex_id, state|
            state[:mines].each_with_index.select { |m, _idx| m[:owner] == entity.id }
                          .map do |m, idx|
              {
                hex_id: hex_id,
                mine_idx: idx,
                ore: m[:ore],
                value: m[:claimed],
                used: m[:used],
                free: m[:free] || false,
              }
            end
          end
        end

        def claim_cost_schedule(entity)
          corp_data(entity)&.dig(:claim_costs) || DEFAULT_CLAIM_COSTS
        end

        # Derived from MINE_DATA itself, not a separate hardcoded table,
        # so it can't drift out of sync with the real tile data.
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
        CLAIM_UPGRADE_ORE_COLOR = { n: '#c82828', i: '#2864d2', r: '#289646' }.freeze

        def claim_upgrade_legend(font_color, _yellow, green, _brown, _gray, _red, action_processor: nil)
          cell_style = {
            border: '1px solid',
            color: font_color,
            'font-weight': 'bold',
            'text-align': 'center',
            'vertical-align': 'middle',
            height: '33px',
          }

          rows = claim_ore_upgrade_amounts.sort_by { |_ore, amount| amount }.map do |ore, amount|
            [
              {
                text: CLAIM_UPGRADE_ORE_NAMES[ore],
                props: { style: cell_style.merge(backgroundColor: CLAIM_UPGRADE_ORE_COLOR[ore], color: 'white') },
              },
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

        # §7.4; independents: a flat 2. A claim_limit that depends on
        # optional rules (§13b) is stored as a Proc, since entities.rb's
        # arrays are built before any specific game's rules are known.
        # §8.12/Phase 9h: AL holds back 2 claims per remaining independent.
        def claim_limit(entity)
          limit = entity_data(entity)&.dig(:claim_limit) || Float::INFINITY
          limit = limit.call(self) if limit.respond_to?(:call)
          return limit unless entity == @al_corporation

          [limit - (remaining_independents.size * 2), 0].max
        end

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

        def reserved_base_count(entity)
          return 0 unless entity == @al_corporation

          [remaining_independents.size, corp_data(entity)&.dig(:bases)&.size || 0].min
        end

        def reserved_claim_count(entity)
          return 0 unless entity == @al_corporation

          [remaining_independents.size * 2, corp_data(entity)&.dig(:claim_limit) || 0].min
        end

        def claims_placed_lifetime(entity)
          @mine_state.values.sum { |s| s[:mines].count { |m| m[:owner] == entity.id && !m[:free] } }
        end

        def refueling_station_owner(hex_id)
          @refueling_stations[hex_id]
        end

        # §7.4.
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

        # Opt-in hook for assets/app/view/game/map.rb: the active entity's
        # claim ring can extend past this hex's own boundary into a
        # neighbor's, so map.rb uses this to render the hex last --
        # SVG siblings paint in array order regardless of overlap, so an
        # opaque neighbor painted later would otherwise clip it.
        def hex_has_active_claim?(hex)
          return false unless (entity = round.current_entity)

          @mine_state.dig(hex.id, :mines)&.any? { |m| m[:owner] == entity.id } || false
        end

        # §7.4, §7.41.
        def can_place_base?(hex)
          state = @mine_state[hex.id]
          return false unless state

          state[:mines].none? { |m| m[:owner] }
        end

        # `free:` is Tunnel Systems' one-time ability (Phase 10).
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

          # '2023' is 'unlimited'-count, so init_tile only pools one
          # instance -- without replenishing it here, only the first base
          # placed in the game would ever find an unused instance.
          # Not update_tile_lists: that returns the *replaced* tile to
          # @tiles, but the mine tile a base covers is gone for good.
          add_extra_tile(tile) if tile.unlimited
          @tiles.delete(tile)

          # Hex#lay's move_tokens_to_new_tile_multi_city! crashes
          # (`undefined method 'token'`) when laying a single-city tile
          # over a double-mine hex with no tokens to migrate. Drop to a
          # single city first to sidestep that path entirely.
          hex.tile.cities.slice!(1..) if hex.tile.cities.size > 1
          hex.lay(tile)
          tile.cities.first.place_token(entity, token, check_tokenable: false)
          @log << "#{entity.name} places a #{free ? 'free ' : ''}base at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        # OSR/MR's home hexes (B14/O13) are excluded unless New
        # Corporations is active, or an otherwise-ordinary unexplored
        # blue hex would render station-ring art.
        def starting_base_hexes
          @starting_base_hexes ||= (Entities::CORPORATIONS + Entities::MINORS).map { |data| data[:coordinates] }
          return @starting_base_hexes if optional_new_corporations?

          @starting_base_hexes - OSR_MR_HOME_HEXES
        end

        # §7.42: edge-touching starting bases never get a station. §13b:
        # OSR's/MR's own starting bases are excluded outright.
        OSR_MR_HOME_HEXES = %w[B14 O13].freeze

        def station_eligible?(hex)
          return false if optional_new_corporations? && OSR_MR_HOME_HEXES.include?(hex.id)
          return true unless starting_base_hexes.include?(hex.id)
          return hex.all_neighbors.size == 6 unless Array(@al_corporation.coordinates).include?(hex.id)

          @asteroid_league_formed && hex.all_neighbors.size == 6
        end

        # §7.42: may be placed on a base owned by a different corporation.
        def can_place_station?(hex)
          hex_has_base?(hex) && !refueling_station_owner(hex.id) && station_eligible?(hex)
        end

        # `free:` is Vacuum Associates' one-time ability (Phase 10).
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

        # `free:` is Robot Smelters' one-time ability (Phase 10).
        def place_claim!(entity, hex, mine_idx, cost, free: false)
          entity.spend(cost, bank) if cost.positive?
          mine = @mine_state[hex.id][:mines][mine_idx]
          mine[:owner] = entity.id
          mine[:free] = true if free

          # Must also clear @uniq_revenues by hand -- this bypasses its
          # memoization, which would otherwise keep showing the stale
          # unclaimed value.
          city = hex.tile.cities[mine_idx]
          city.revenue = Part::RevenueCenter::PHASES.to_h { |phase| [phase, mine[:claimed]] }
          city.instance_variable_set(:@uniq_revenues, nil)

          @log << "#{entity.name} claims a #{free ? 'free ' : ''}mine (#{claim_label(mine)}) at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        def claim_label(mine)
          "#{mine[:ore].to_s.upcase}:#{mine[:claimed]}"
        end

        # §13b: OSR's own entities.rb entry carries the +$20 surcharge it
        # alone pays here; 0 for every other entity.
        def independent_claim_surcharge(entity)
          entity_data(entity)&.dig(:independent_claim_surcharge) || 0
        end

        def independent_claim_price(entity)
          INDEPENDENT_CLAIM_PRICE + independent_claim_surcharge(entity)
        end

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

        # Only BuyInfrastructure's BUY_CLAIM choice needs consent through
        # this hook -- a cross-player transaction whenever the selling
        # independent belongs to a different player.
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
