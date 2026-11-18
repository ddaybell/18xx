# frozen_string_literal: true

require_relative '../meta'

module Engine
  module Game
    module G2038
      module Meta
        include Game::Meta

        DEV_STAGE = :prealpha

        GAME_DESIGNER = 'James Hlavaty, Thomas Lehmann'
        GAME_LOCATION = 'Outer Space'
        GAME_PUBLISHER = :timjim_games
        GAME_RULES_URL = {
          'Rules' => 'https://boardgamegeek.com/filepage/135017/2038-english-rules-and-supplements',
          'Expansion Set Rules' => 'https://boardgamegeek.com/filepage/90180/2038-expansion-set',
        }.freeze

        PLAYER_RANGE = [2, 6].freeze

        OPTIONAL_RULES = [
          {
            sym: :optional_variant_start_pack,
            short_name: 'Variant Start Packet',
            desc: 'Includes New Corporations and Stock Repurchases.  Not compatible with the Short Game.  '\
                  'See Expansion Set rules for details.',
          },
          {
            sym: :optional_new_corporations,
            short_name: 'New Corporations',
            desc: 'Adds On-Site Refining and Mining Robotics (Group C).  Full Game only, '\
                  'not compatible with the Short Game.  Always included when the Variant Start Packet is used.',
          },
          {
            sym: :optional_stock_repurchases,
            short_name: 'Stock Repurchases',
            desc: 'A Growth Corporation\'s initial offering shares are bought at the higher of '\
                  'par or current price into its own treasury. A corporation may redeem its own shares from the '\
                  'market into its treasury.  Always included when the Variant Start Packet is used.',
          },
          {
            sym: :optional_short_game,
            short_name: 'Short Game',
            desc: 'Bank: $4,000.  TSI par: $67.  OPC and RCC removed.  Lower cert. limits.  '\
                  'Independent owners receive half-cash only on initial AL formation conversion.  '\
                  'Game typically ends in Phase III.  Not compatible with the New Corporations or '\
                  'Variant Start Packet expansion rules.',
          },
          {
            sym: :optional_weaker_tsi,
            short_name: 'Weaker TSI',
            desc: 'Full Game only, reduces TSI par value.',
          },
          {
            sym: :optional_weaker_tsi_89,
            short_name: '$89 TSI par value',
            parent: :optional_weaker_tsi,
          },
          {
            sym: :optional_weaker_tsi_78,
            short_name: '$78 TSI par value',
            parent: :optional_weaker_tsi,
          },
          {
            sym: :optional_weaker_tsi_67,
            short_name: '$67 TSI par value',
            parent: :optional_weaker_tsi,
          },
          {
            sym: :optional_cutthroat_game,
            short_name: 'Cutthroat Game',
            desc: 'Play with only four Phase IV spaceships instead of five. Guarantees that at least one '\
                  'Corporation must buy a Phase VI spaceship at full price (assuming the game enters Phase VI).',
          },
        ].freeze

        # Weaker TSI's three price options are a single printed choice ("choose
        # one"), so checking any one of them unchecks the other two.
        MUTEX_RULES = [
          %i[optional_weaker_tsi_89 optional_weaker_tsi_78 optional_weaker_tsi_67],
        ].freeze
      end
    end
  end
end
