# frozen_string_literal: true

require_relative '../meta'

module Engine
  module Game
    module G1835
      # Metadata for the 1835 game implementation
      module Meta
        include Game::Meta

        # Game is in pre-alpha stage
        DEV_STAGE = :prealpha

        # consider adding game title and variations here, if any come to mind.  May not be any.
        # see superclass file for examples.

        GAME_DESIGNER = 'Michael Meier-Bachl'
        GAME_LOCATION = 'Germany'
        # There's something wrong with the following line, so I commented it out.  Perhaps publisher requires a URL or a pre-defined value for the publisher?  HiG doesn't currently offer the game, so this designation might not make sense here
        #GAME_PUBLISHER = 'Hans im Glück'
        # Try to find a way to update this to something better than just "Google"
        GAME_INFO_URL = 'https://google.com'
        # Try to find the rules somewhere on the Internet
        GAME_RULES_URL = 'http://google.com'

        PLAYER_RANGE = [3, 7].freeze
        # Thsi is where the start packet varients get listed (presumably for the game creation screen)
        OPTIONAL_RULES = [
          {
            # need to find where this varient is implemented, if it actually is yet
            sym: :clemens,
            short_name: 'Clemens Variant',
            desc: 'all Privates and minors are available, Playerorder for the SR 4-3-2-1-1-2-3-4-1-2-3-4, '\
                  'Minors start when Bayerische Eisenbahn floats',
          },
          {
            # Todd's auction varient, need to define this symbol elsewhere to implement the varient
            sym: :vanderpluym,
            short_name: 'Vanderpluym Auction Variant',
            desc: 'privates and minors are available in start packet order, all assets are auctioned,'\
                  'not purchased, when selected.  Starting bid values are assigned.  BY operates when '\
                  'president\'s certificate purchased.',
          }
        ].freeze
      end
    end
  end
end
