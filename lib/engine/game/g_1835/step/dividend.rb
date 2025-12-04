# frozen_string_literal: true

require_relative '../../../step/dividend'

module Engine
  module Game
    module G1835
      module Step
        class Dividend < Engine::Step::Dividend
          def dividends_for_entity(entity, holder, per_share)
            num_shares = num_paying_shares(entity, holder)
            (num_shares * per_share).floor
          end

          def round_state
            super.merge(
              {
                non_paying_shares: Hash.new { |h, k| h[k] = Hash.new(0) },
              }
            )
          end

          private

          def num_paying_shares(entity, holder)
            holder.num_shares_of(entity) - @round.non_paying_shares[holder][entity]
          end
        end
      end
    end
  end
end
