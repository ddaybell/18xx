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

          # View::Game::Round::Stock (round/stock.rb, shared) picks
          # `round.active_step` (no entity arg) as *the* step to render
          # corp-buying UI against, and calls `.ipo_type` on it
          # unconditionally for any not-yet-IPO'd corporation -- true for
          # every other game, where a Stock round's only ever-blocking
          # step is a BuySellParShares-family one that defines this. Now
          # that WaterfallAuction is folded directly into Game#stock_round
          # (see that method's comment) it can ALSO win that no-arg
          # active_step slot while any company remains unsold, and it
          # crashed the entire stock round view with a NoMethodError until
          # this existed (found live in browser, not caught by any script
          # test). `nil` correctly renders no pre-IPO UI for that
          # corporation while this step is genuinely blocking the
          # entity -- accurate, since Round::Base#process_action would
          # reject a `par` action right now anyway (WaterfallAuction, not
          # BuySellParShares, is what's actually blocking this entity's
          # turn). Confirmed round/auction.rb already guards this same
          # call with `respond_to?(:ipo_type) ? ... : :par` for the
          # equivalent reason in a plain Engine::Round::Auction -- this
          # is the same fix, just contained to G2038's own step instead of
          # the shared view file.
          def ipo_type(_entity)
            nil
          end

          # A fresh WaterfallAuction instance gets folded into EVERY later
          # Stock round too (see Game#stock_round's comment), and once all
          # 12 Private/Independent Companies are sold, `@companies` stays
          # permanently empty for that instance's whole lifetime --
          # `actions` already returns [] unconditionally at that point, so
          # this step was never actually going to block anyone again. But
          # Round::Base#skip_steps still called `step.skip!` on it once
          # per entity per turn for the rest of the game (it's `active?`
          # until explicitly passed, and blocks? defaults to true), and
          # skip! logs "X skips bid on companies" every single time since
          # `@acted` is never set for a step nobody ever acts on again --
          # pure noise once nothing's left to sell (found live in browser:
          # the log fills up with these for the rest of the game).
          # Reporting blocks? as false here doesn't change `blocking?`
          # (already false in this case, since `actions` is already empty)
          # -- it only changes skip_steps's path from "call skip! and log"
          # to a silent `next`, so the auction phase itself is untouched.
          def blocks?
            !@companies.empty?
          end

          def buy_company(player, company, price)
            super

            return unless (minor = @game.minor_by_id(company.id))

            minor.owner = player
            minor.float!
            # $100 plus half of whatever was bid over $100 -- floored at 0,
            # not just floor-divided, since the waterfall discount can push
            # a winning price below the $100 face value (increase_discount!
            # knocks $5 off every time all players pass on the cheapest
            # company), and a below-$100 win should still capitalize at a
            # flat $100, not less.
            capital = [(price - 100) / 2, 0].max
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
                # OWN passed? flag, which is still true from the all-pass
                # that got us here, so without this the round would look
                # "finished" and end right out from under the pending
                # resolution. Unpassing keeps it open until the
                # mini-auction (and any companies still queued behind it)
                # actually resolves down to round_end_auction_complete.
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

          # Everything left in @companies at this point never got a single
          # bid (every bid-upon company was already resolved, above, in
          # value order, via buy_company's own @companies.delete). Nothing
          # else to do here -- confirmed with the user this is just an
          # ordinary Stock round (WaterfallAuction folded into
          # Game#stock_round, not a dedicated Auction round), so:
          #  - leftover companies simply stay in @companies, unowned, to
          #    be offered again on a later turn/round exactly as before --
          #    no clearing.
          #  - every entity is (re-)passed so Round::Stock's ordinary
          #    all-entities-passed `finished?` check can actually fire
          #    right after this, ending the round into the OR set the same
          #    way any SR ending ever does. Found live in browser: when
          #    resolve_bids had to unpass everyone first for a live
          #    mini-auction (2+ bids on some company) to play out, nothing
          #    ever re-passed them once that resolved down to here -- the
          #    round just silently kept going as if nothing had happened,
          #    requiring a second full round of everyone passing again
          #    before it would actually transition. Explicitly passing
          #    here is a no-op in the simple case (nothing ever unpassed
          #    entities to begin with) and the fix in the mini-auction
          #    case.
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
