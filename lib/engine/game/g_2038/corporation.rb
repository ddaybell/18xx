# frozen_string_literal: true

require_relative '../../corporation'

module Engine
  module Game
    module G2038
      class Corporation < Engine::Corporation
        # §13c rule 1: "A Growth Corporation's initial offering shares are
        # sold at the higher of its par price or its current stock price"
        # -- and per the user, this is the exact same rule redeemed
        # Treasury Shares already use (Game#bundles_for_corporation's own
        # [par_price, share_price].max, built earlier for the corp-
        # redeeming-shares-from-the-market case). That override only
        # reaches redemption, though: Share#price_per_share (the base
        # engine's own pricing for an ordinary player purchase straight
        # from a corp's IPO/treasury box, used by every par/buy_shares
        # path) hardcodes `owner == corporation.ipo_owner ? par_price :
        # share_price` with no per-game override point of its own --
        # only par_price itself is overridable, by subclassing
        # Corporation (CORPORATION_CLASS). Redefining par_price here to
        # already BE the ceiling, for a Growth Corp specifically, fixes
        # every consumer of it at once (ordinary IPO/treasury purchases,
        # par-time pricing, the corporation card's own par-price display)
        # without needing to touch Share itself. Only changes the reader
        # -- @par_price itself still stores whatever stock_market.set_par
        # actually set, so writes/comparisons elsewhere are unaffected.
        def par_price
          return super unless capitalization == :incremental

          [@par_price, @share_price].compact.max_by(&:price) || super
        end
      end
    end
  end
end
