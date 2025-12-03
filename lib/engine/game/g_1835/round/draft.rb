# frozen_string_literal: true

require_relative '../../../round/draft'
# This file appears to run the turn order for the inital auction.
# subclasses from engine.  
# Engine defines three draft orders other than normal: reverse, snake, rotating.
# Engine then runs the draft, based on the specified turn order.  
# If turn order is not specified then draft appears to be regular.

module Engine
  module Game
    module G1835
      module Round
        class Draft < Engine::Round::Draft #Draft is subclassed from E-R-D
          # overwrites ERD function to hardcode definition to players in regular order.
          # I assume that the Clemens varient code will further change this, but presumably was implemented in another module. (Or hasn't been implemented yet.)
          def select_entities 
            @game.players
          end
        end
      end
    end
  end
end
