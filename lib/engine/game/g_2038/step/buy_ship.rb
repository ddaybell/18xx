# frozen_string_literal: true

require_relative '../../../step/buy_train'

module Engine
  module Game
    module G2038
      module Step
        class BuyShip < Engine::Step::BuyTrain
          # Base engine blocks minors from buying trains by default.
          def can_entity_buy_train?(entity)
            entity.minor? || super
          end

          # §7.37/Phase 9g: the AL may never be left with zero spaceships.
          def other_trains(entity)
            super.reject { |t| t.owner == @game.al_corporation && @game.al_corporation.trains.one? }
          end

          # A traded-in ship is retired outright (not returned to the bank
          # pool, unlike an over-limit discard). Must go through
          # Game::Base#rust, not a manual @discarded.delete + owner=nil --
          # rust resets Depot's @depot_trains memo, which a raw delete
          # would skip, leaking a stale nil-owner entry into
          # buyable_trains once Phase#buying_train! recomputes it later
          # in this same call.
          def process_buy_train(action)
            exchanged = action.exchange
            super
            return unless exchanged

            @game.rust(exchanged)
          end

          # §13b: with OSR/MR in play, '9/7' needs two Phase V ships sold
          # first, not one -- a count TRAINS' `available_on:` can't express.
          def buyable_trains(entity)
            trains = super
            return trains if @game.phase_vi_unlocked?

            trains.reject { |t| t.name == '9/7' }
          end

          # EBUY_DEPOT_TRAIN_MUST_BE_CHEAPEST should only apply when the
          # corp could have afforded the cheapest ship on its own treasury
          # -- if it genuinely can't afford anything, president funding
          # may go toward any purchasable ship.
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
