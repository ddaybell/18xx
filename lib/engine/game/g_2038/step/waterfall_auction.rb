# frozen_string_literal: true

require_relative '../../../step/waterfall_auction'

module Engine
  module Game
    module G2038
      module Step
        class WaterfallAuction < Engine::Step::WaterfallAuction
          # Round::Stock re-runs every step's `setup` at the start of EACH
          # entity's turn (Round::Stock#start_entity), not just once per
          # round -- harmless for steps with no state that spans multiple
          # turns, but the base `setup` (`setup_auction` -> `@bids =
          # Hash.new{...}`) would silently wipe out bids placed by earlier
          # players in this same round every time a new player's turn
          # begins. Only the very first call for a given step instance
          # (fresh off Round::Base#initialize, @bids still unset) should
          # actually initialize anything; @companies/@bids/@bidders are
          # already self-maintaining after that via direct mutation
          # (buy_company's @companies.delete, add_bid, etc.), so later
          # calls within the same round must be a no-op.
          def setup
            return if @bids

            super
            # Base sorts @companies by value (cheapest-first) -- correct
            # for every other game, but wrong here under the Variant
            # Start Packet: it swaps in cheaper certificates for some
            # companies *in their original deck slot*, not a re-sort
            # (e.g. Tunnel Systems drops to $20 but stays dealt after
            # $100 companies like Lucky). Restoring the game's own
            # declared order is a no-op at baseline and correct under
            # the variant.
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

          # View::Game::Round::Stock picks `round.active_step` (no
          # entity arg) as *the* step to render corp-buying UI against,
          # and calls `.ipo_type` on it unconditionally -- true for
          # every other game, where a Stock round's only ever-blocking
          # step is a BuySellParShares-family one that defines this. Now
          # that WaterfallAuction is folded directly into Game#
          # stock_round, it can ALSO win that no-arg active_step slot
          # while any company remains unsold, crashing the stock round
          # view with a NoMethodError until this existed. round/
          # auction.rb already guards the same call with `respond_to?
          # (:ipo_type) ? ... : :par` for the equivalent reason in a
          # plain Engine::Round::Auction.
          def ipo_type(_entity)
            nil
          end

          # A fresh WaterfallAuction instance gets folded into EVERY
          # later Stock round too, and once all 12 Private/Independent
          # Companies are sold, `@companies` stays permanently empty --
          # but Round::Base#skip_steps still called `step.skip!` on it
          # once per entity per turn for the rest of the game, logging
          # "X skips bid on companies" every single time (pure noise
          # once nothing's left to sell). Reporting blocks? as false
          # here doesn't change `blocking?` (already false) -- it only
          # changes skip_steps's path to a silent `next`.
          def blocks?
            !@companies.empty?
          end

          def buy_company(player, company, price)
            super

            return unless (minor = @game.minor_by_id(company.id))

            minor.owner = player
            minor.float!
            # $100 plus half of whatever was bid over $100. `price` can
            # never actually be less than 100: every independent's face
            # value is a fixed $100, and this game has no rule that ever
            # discounts a company below face value.
            # (price - 100) / 2.0 .floor -- Integer#/ is Opal/browser
            # float division, not Ruby's, so bids in $5 increments over
            # $100 ($105, $115, ...) would otherwise produce a literal
            # fractional dollar in the browser. §5.11: round down.
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
                # A bid-upon company had 2+ bids and is now a live
                # mini-auction (@auctioning set) still waiting on its
                # bidders -- Round::Stock#finished? reads every entity's
                # OWN passed? flag, still true from the all-pass that
                # got us here, so without this the round would look
                # "finished" and end right out from under the pending
                # resolution.
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

          # Everything left in @companies at this point never got a
          # single bid. This is just an ordinary Stock round
          # (WaterfallAuction folded into Game#stock_round, not a
          # dedicated Auction round), so:
          #  - leftover companies simply stay in @companies, unowned, to
          #    be offered again later -- no clearing.
          #  - every entity is (re-)passed so Round::Stock's ordinary
          #    all-entities-passed `finished?` check can fire right
          #    after this. Without it, when resolve_bids had to unpass
          #    everyone first for a live mini-auction to play out,
          #    nothing ever re-passed them once that resolved down to
          #    here, and the round just silently kept going.
          #  - payout_companies/or_set_finished are NOT called here --
          #    Round::Operating#setup already pays out companies at the
          #    start of the OR set that follows; calling it again here
          #    would double-pay every owned company's revenue.
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
