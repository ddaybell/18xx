# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G1835
      module Step
        class Draft < Engine::Step::Base
          attr_reader :companies, :choices, :grouped_companies

          ACTIONS = %w[bid pass].freeze

          def setup
            @companies = setup_start_packet
          end

          def setup_start_packet
            # Build a hash mapping symbols to entities
            entity_map = (@game.companies + @game.minors + @game.corporations).to_h do |e|
              [entity_sym(e), e]
            end

            # Create the grid structure
            @game.class::START_PACKET.map do |sym, row, col|
              entity = entity_map[sym]
              raise GameError, "START_PACKET references unknown entity: #{sym}" unless entity

              { entity: entity, row: row, col: col, available: false }
            end
          end

          def entity_sym(entity)
            # Companies have sym, Minors and Corporations use name as their sym
            entity.respond_to?(:sym) ? entity.sym : entity.name
          end

          def available
            update_availability
            @companies.select { |item| item[:available] }.map { |item| item[:entity] }
          end

          def update_availability
            # Find the topmost row with unpurchased entities
            remaining = @companies.reject { |item| entity_owned?(item[:entity]) }
            remaining_rows = remaining.group_by { |item| item[:row] }
            return if remaining_rows.empty?

            # Reset availability
            @companies.each { |item| item[:available] = false }

            topmost_row = remaining_rows.keys.min
            topmost_entities = remaining_rows[topmost_row]

            # Rule 1: All entities in topmost row are available
            topmost_entities.each { |item| item[:available] = true }

            # Rule 2: If only one entity left in topmost row, make leftmost of next row available
            if topmost_entities.size == 1 && remaining_rows[topmost_row + 1]
              next_row_entities = remaining_rows[topmost_row + 1].sort_by { |item| item[:col] }
              next_row_entities.first[:available] = true if next_row_entities.any?
            end
          end

          def entity_owned?(entity)
            if entity.corporation?
              entity.presidents_share.owner&.player?
            else
              entity.owner&.player?
            end
          end

          def may_purchase?(_company)
            true
          end

          def auctioning; end

          def bids
            {}
          end

          def visible?
            true
          end

          def players_visible?
            true
          end

          def name
            'Draft'
          end

          def description
            'Draft Companies and Minors from Grid'
          end

          def finished?
            all_drafted? || entities.all?(&:passed?)
          end

          def all_drafted?
            @companies.all? { |item| entity_owned?(item[:entity]) }
          end

          def actions(entity)
            return [] if finished?

            avail = available
            unless avail.any? { |e| current_entity.cash >= min_bid(e) }
              @log << "#{current_entity.name} has no valid actions and passes"
              return []
            end

            entity == current_entity ? ACTIONS : []
          end

          def process_bid(action)
            entity = action.company
            player = action.entity
            price = action.price

            # Handle different entity types
            if entity.company?
              entity.owner = player
              player.companies << entity
            elsif entity.minor?
              entity.owner = player
              entity.float!
            elsif entity.corporation?
              # For corporations like SX and BY, the player becomes the director
              buy_director_share(player, entity, price)
            end

            player.spend(price, @game.bank)

            @log << "#{player.name} buys #{entity.name} for #{@game.format_currency(price)}"

            # Unpass all players after a purchase
            entities.each(&:unpass!)
            @round.next_entity_index!
            action_finalized
          end

          def buy_director_share(player, corporation, _price)
            share = corporation.presidents_share
            @game.share_pool.buy_shares(player, share.to_bundle)
          end

          def process_pass(action)
            @log << "#{action.entity.name} passes"
            action.entity.pass!
            @round.next_entity_index!

            # Check if everyone passed
            @log << 'All players passed' if entities.all?(&:passed?)

            action_finalized
          end

          def action_finalized
            return unless finished?

            @round.reset_entity_index!
          end

          def committed_cash(_player, _show_hidden = false)
            0
          end

          def min_bid(entity)
            return unless entity

            if entity.corporation?
              # For corporations, use the president's share price (par price * president share percent / 10)
              par_price = entity.par_price&.price || 0
              (par_price * entity.presidents_share.percent) / 10
            elsif entity.respond_to?(:value)
              entity.value
            elsif entity.minor?
              # Minors without a value attribute - use default value of 0 (free)
              0
            else
              0
            end
          end
        end
      end
    end
  end
end
