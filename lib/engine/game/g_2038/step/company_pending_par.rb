# frozen_string_literal: true

require_relative '../../../step/company_pending_par'

module Engine
  module Game
    module G2038
      module Step
        # Fixes the base class's `process_par` to pull the president's
        # share from `corporation.ipo_shares` rather than `corporation.
        # shares` -- the same fix (and same reason) as G2038::Step::
        # BuySellParShares's own can_buy_any_from_ipo?/can_ipo_any?
        # overrides: `optional_stock_repurchases` (always implied by
        # `optional_variant_start_pack`, this step's only real use here --
        # see Game#after_buy_company's ST handling) relocates every
        # not-yet-parred full-cap corp's shares to the bank at setup,
        # leaving `corporation.shares` (shares literally owned by the
        # corporation object) permanently empty. `ipo_shares` tracks
        # wherever `ipo_owner` actually points, so it finds the right
        # share regardless.
        class CompanyPendingPar < Engine::Step::CompanyPendingPar
          # Same two special-cased market cells G2038::Step::
          # BuySellParShares already excludes from the ordinary par ladder
          # -- $10/par_2 is Growth Corp conversion's own fixed start,
          # $125/par_1 is the Asteroid League's fixed par; neither should
          # ever appear as a choice here either.
          def get_par_prices(entity, corp)
            super.reject { |p| [10, 125].include?(p.price) }
          end

          def process_par(action)
            share_price = action.share_price
            corporation = action.corporation
            @game.stock_market.set_par(corporation, share_price)
            @game.share_pool.buy_shares(action.entity, corporation.ipo_shares.first, exchange: :free)
            @game.after_par(corporation)
            @round.companies_pending_par.shift
          end
        end
      end
    end
  end
end
