# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G1835
      module Step
        # Subclasses from E-S-B.
        # ESB is the generic code for managing a phase in the game (e.g. drafting, buy/selling shares, operating a company). 
        class Draft < Engine::Step::Base
          # exposes these values for being read by methods outside this class (reader allows reads, writer allows writes, accessor allows both)
          # not sure we need any of these.
          attr_reader :companies, :minors, :grouped_companies, :grouped_minors

          # defines the ACTIONS constant to include "bid" and "pass"
          # overwrites superclass definition, which is blank.
          ACTIONS = %w[bid pass].freeze

          # Creates the start packet for the draft.
          def setup
            @companies = @game.companies
            @minors = @game.minors
            @grouped_companies = @companies.group_by(&:auction_row)
            @grouped_minors = @minors.group_by(&:auction_row)

            auction_rows = (grouped_companies.keys + grouped_minors.keys).uniq.sort

            start_packet = []
            auction_rows.each do |row|
              # Combine companies and minors in this row, then sort by row_position
              items = []
              items.concat(grouped_companies[row]) if grouped_companies[row]
              items.concat(grouped_minors[row]) if grouped_minors[row]
              start_packet.concat(items.sort_by { |item| item.row_position })
            end

            # Optionally store start_packet for later use
            @start_packet = start_packet
           
          end

          # def available
          #   (@companies + @minors).select { |item| item.owner.nil? }
          # end
          
          def available
            # Only consider items that have not been purchased (owner is nil)
            unpurchased = @start_packet.select { |item| item.owner.nil? }

            # Group unpurchased items by auction_row
            grouped = unpurchased.group_by(&:auction_row)
            rows = grouped.keys.sort

            return [] if rows.empty?

            top_row = rows.first
            top_items = grouped[top_row]

            # If only one item left in top row, include first item from next row (if any)
            if top_items.size == 1 && rows.size > 1
              next_row = rows[1]
              next_item = grouped[next_row]&.first
              top_items + (next_item ? [next_item] : [])
            else
              top_items
            end
          end       
          
          # checks to make sure that all compaines and minors are available for purchase.
          # Any entity passed to this method may be purchased.  I assume that some engine code calls this method.  
          # Added the same def for minors, since they are also available for purchase.
          def may_purchase?(_item)
            true
          end

          # defines an empty method titled "auctioning".  I think this is to overwrite the auctioning method in the superclass, such that auctions are not available.
          def auctioning; end

          # Same for bids, since bidding is not available.  
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

          # overwrites superclass, which generates a not-implemented error.  suggests that description is mandatory for each subclass.
          def description
            'Draft Private Companies and minors'
          end

          # draft is finished when all companies are sold, or everyone has passed.
          # Need to add @minors and @corporations_BY to this once we figure out how to include them in the draft.
          def finished?
            (@companies.empty? && @minors.empty?) || entities.all?(&:passed?)
          end

          # checks to see if the current player has enough cash to take an action.
          # If so, allows current player to take an action.  If not, skips player.
          # Also ends if the "finished" condition is satisfied.
          def actions(entity)
            return [] if finished?

            unless @companies.any? { |c| current_entity.cash >= min_bid(c) } ||
                  @minors.any? { |m| current_entity.cash >= min_bid(m) }
              @log << "#{current_entity.name} has no valid actions and passes"
              return []
            end

            entity == current_entity ? ACTIONS : []
          end

          # Processes the "bid" action.
          def process_bid(action)
            item = action.company || action.minor # Support both company and minor
            player = action.entity
            price = action.price

            # sets the item owner to be the player.
            # adds the item to the player's list of companies.
            # subtracts the purchase price from the player's cash and adds it to the bank.
            # removes the item from the list of available choices.
            item.owner = player
            player.companies << item
            player.spend(price, @game.bank)
            @companies.delete(item) if item.is_a?(Engine::Company)
            @minors.delete (item) if item.is_a?(Engine::Minor)

            @log << "#{player.name} buys #{item.name} for #{@game.format_currency(price)}"

            # calls the unpass method on each player.  This resets their pass status. 
            entities.each(&:unpass!)
            # moves to the next player
            @round.next_entity_index!
            # checks the "finished" condition. If finished, then resets the next player (I assume based on the pass order for the game)
            action_finalized
          end

          # process the "pass" action.
          def process_pass(action)
            @log << "#{action.entity.name} passes"
            action.entity.pass!
            @round.next_entity_index!
            action_finalized
          end

          # checks the "finished" condition. If finished, then resets the next player
          # (I assume based on the pass order for the game)
          def action_finalized
            return unless finished?

            @round.reset_entity_index!
          end

          # displays the cash the player has committed? (Should be zero since there is no bidding).
          def committed_cash(_player, _show_hidden = false)
            0
          end

          # sets the minimum bid to be the value for the entity (company or minor).  
          # This is one thing that will change for bidding variants.
          def min_bid(entity)
           entity.value
          end

        end
      end
    end
  end
end
