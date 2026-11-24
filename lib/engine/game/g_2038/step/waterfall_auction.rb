# frozen_string_literal: true

require_relative '../../../step/waterfall_auction'

module Engine
  module Game
    module G2038
      module Step
        class WaterfallAuction < Engine::Step::WaterfallAuction
          # Round::Stock re-runs `setup` at the start of EVERY entity's
          # turn, not just once per round -- without this guard, the base
          # setup would wipe out bids placed earlier in this same round.
          def setup
            return if @bids

            super
            # Base sorts @companies cheapest-first -- wrong under the
            # Variant Start Packet, which swaps in cheaper certificates
            # in their original deck slot rather than re-sorting.
            @companies = @game.initial_auction_companies
            @cheapest = @companies.first
          end

          def may_purchase?(company)
            return false unless super
            return true if @purchasing_first_minor

            !minor?(company)
          end

          def can_auction?(company)
            return true if @process_round_end_auction && @bids[company].size > 1

            super
          end

          def min_bid(company)
            return unless company
            return company.min_bid if may_purchase?(company)

            high_bid = highest_bid(company)
            high_bid ? high_bid.price + min_increment : company.min_bid
          end

          def bid_str(company)
            !auctioning && company && minor?(company) && company == @companies.first ? 'Buy' : 'Place Bid'
          end

          def placement_bid(bid)
            @purchasing_first_minor = bid.company && bid.company == @companies.first
            super
            @purchasing_first_minor = false
          end

          def minor?(company)
            @game.minors.any? { |m| m.id == company.id }
          end

          # View::Game::Round::Stock calls `.ipo_type` unconditionally on
          # `round.active_step` -- this step can win that slot while any
          # company remains unsold, crashing the view without this.
          def ipo_type(_entity)
            nil
          end

          # Once @companies is permanently empty, this stops skip_steps
          # from logging a "skips bid on companies" noise line every turn
          # for the rest of the game.
          def blocks?
            !@companies.empty?
          end

          def buy_company(player, company, price)
            super

            return unless (minor = @game.minor_by_id(company.id))

            minor.owner = player
            minor.float!
            # §5.11: $100 plus half of any bid over $100, rounded down.
            # Explicit `.floor`, not relying on integer division -- Opal's
            # Integer#/ returns a float, unlike native Ruby's.
            capital = ((price - 100) / 2.0).floor
            @game.bank.spend(100 + capital, minor)
          end

          def resolve_bids
            if @process_round_end_auction
              @companies.dup.each do |company|
                resolve_bids_for_company(company)
                break if @auctioning == company
              end

              if all_bids_processed?
                round_end_auction_complete
              else
                # Round::Stock#finished? reads passed?, still true from
                # the all-pass that got us here -- without this the
                # round would end out from under the pending mini-auction.
                entities.each(&:unpass!)
              end
            else
              super
            end
          end

          def all_passed!
            @process_round_end_auction = true
            resolve_bids
          end

          # Re-passes everyone, since resolve_bids may have had to
          # unpass them for a live mini-auction to play out. Doesn't call
          # payout_companies -- Round::Operating#setup does that at the
          # start of the OR set that follows; calling it here too would
          # double-pay every owned company's revenue.
          def round_end_auction_complete
            @process_round_end_auction = false
            entities.each(&:pass!)
          end

          def all_bids_processed?
            @bids.values.flatten.empty?
          end
        end
      end
    end
  end
end
