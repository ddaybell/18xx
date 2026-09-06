# frozen_string_literal: true

require_relative '../../corporation'

module Engine
  module Game
    module G2038
      class Corporation < Engine::Corporation
        # §13c rule 1: "A Growth Corporation's initial offering shares are
        # sold at the higher of its par price or its current stock price"
        # For a Growth Corporation (incremental cap) returns the max of
        # the current share price and the original par price, implementing
        # this rule.  If neither price is defined yet, relies on the parent class.
        def par_price
          return super unless capitalization == :incremental

          [@par_price, @share_price].compact.max_by(&:price) || super
        end
      end
    end
  end
end
