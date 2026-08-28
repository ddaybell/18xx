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

        PLAYER_RANGE = [3, 6].freeze

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
                  'par or current price into its own treasury; a corporation may redeem its own shares from the '\
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
        ].freeze

        # Checking Variant Start Packet on the launch screen also checks
        # New Corporations and Stock Repurchases -- matches Game#
        # optional_new_corporations/#optional_stock_repurchases, which
        # already treat the Start Packet as implying both (their own desc
        # text above already says so; this just makes the checkboxes
        # reflect that visually instead of leaving them unchecked while
        # still behaviorally active).
        IMPLIES_RULES = [
          [:optional_variant_start_pack, %i[optional_new_corporations optional_stock_repurchases]],
        ].freeze

        # No G2038-specific "disable autorouter" optional rule -- the
        # "Suggest Route"/"Accept Route" assistant is gated on the same
        # site-wide auto_routing game setting every other game's own
        # AutoRouter-backed Auto button already uses (see
        # assets/app/view/game/ship_selector.rb#autorouting_allowed?,
        # matching route_selector.rb's own gating exactly), not a custom
        # per-game-type opt-out. Confirmed with the user: respect the
        # site's existing design rather than reinvent a parallel one.
      end
    end
  end
end
