# frozen_string_literal: true

require_relative '../../../step/discard_train'

module Engine
  module Game
    module G2038
      module Step
        class DiscardShip < Engine::Step::DiscardTrain
          # Sorts cheapest ship first, so the discard choice
          # reads left-to-right by price rather than whatever order the
          # corporation happened to buy its ships in.
          def trains(corporation)
            super.sort_by(&:price)
          end
        end
      end
    end
  end
end
