# frozen_string_literal: true

require_relative '../../../step/buy_train'

module Engine
  module Game
    module G2038
      module Step
        class BuyTrain < Engine::Step::BuyTrain
          # In 2038, independent companies (minors) can buy spaceships just like
          # corporations. The base engine blocks minors from buying trains by default.
          def can_entity_buy_train?(entity)
            entity.minor? || super
          end

          # §7.37/Phase 9g: the AL may never be left with zero spaceships --
          # no one (AL included, though AL is never both buyer and seller of
          # its own ship) may buy its last remaining one off it.
          def other_trains(entity)
            super.reject { |t| t.owner == @game.al_corporation && @game.al_corporation.trains.one? }
          end

          # A ship traded in for the 9/7's discount is retired outright, not
          # returned to the bank pool for resale -- confirmed with the user
          # (unlike an over-the-ship-limit discard, which does go back to
          # the pool via the normal DiscardTrain flow). The base engine's
          # exchange handling always routes through Depot#reclaim_train,
          # which parks the traded-in train in @discarded/depot_trains.
          # Must reverse that via Game::Base#rust (not a manual
          # @discarded.delete + owner=nil): rust's remove_train call routes
          # through Depot#remove_train, which resets the @depot_trains
          # memo. A raw @discarded.delete bypasses that reset -- and
          # Phase#buying_train! (invoked later in the same super call, for
          # the newly bought train's events) forces an eager recompute of
          # that memo while the exchanged train is still sitting in
          # @discarded, caching a stale nil-owner entry that then leaks
          # into buyable_trains (crashed live in browser for a traded-in
          # ship whose type doesn't also rust naturally, e.g. 6/5, which
          # unlike 5/4 has no rusts_on: '9/7').
          def process_buy_train(action)
            exchanged = action.exchange
            super
            return unless exchanged

            @game.rust(exchanged)
          end

          # §13b: with OSR/MR in play, Phase VI ('9/7') needs *two* Phase V
          # ships bought first, not one -- the base game's own exception
          # (TRAINS' `available_on: '5'` on '9/7') already covers the
          # base-game "one" case via the standard phase-name mechanism,
          # but a phase name can't express a count, so this filters '9/7'
          # back out of the depot list until the second one's sold. See
          # Game#phase_vi_unlocked? (shared with #discountable_trains_for,
          # the separate exchange-discount UI) for the actual count logic.
          def buyable_trains(entity)
            trains = super
            return trains if @game.phase_vi_unlocked?

            trains.reject { |t| t.name == '9/7' }
          end

          # The base engine's EBUY_DEPOT_TRAIN_MUST_BE_CHEAPEST restricts a
          # president-funded purchase to strictly the cheapest depot train.
          # Confirmed with the user this should only apply when the
          # corporation could actually have afforded that cheapest ship on
          # its own treasury -- if it genuinely can't afford anything, the
          # president's contribution may go toward any currently
          # purchasable ship, not just the cheapest. (When the corporation
          # *can* afford the cheapest, this check never actually fires for
          # that purchase in the first place -- buying_power alone covers
          # it, no president funds needed -- so the restriction still
          # correctly blocks using the president's money to skip straight
          # to a pricier ship in that case.)
          def check_for_cheapest_train(train)
            cheapest = @depot.min_depot_train
            return if cheapest && buying_power(current_entity) < cheapest.price

            super
          end
        end
      end
    end
  end
end
