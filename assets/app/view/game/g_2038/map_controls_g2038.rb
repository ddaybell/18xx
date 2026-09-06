# frozen_string_literal: true

module View
  module Game
    # G2038-only "Show Last Route" support for MapControls: G2038 has no
    # track, so the standard tile-based route history has nothing to draw
    # -- this builds the equivalent from Game#last_route's per-ship hex
    # lists instead. Mixed into the shared MapControls component the same
    # way HexG2038 is mixed into Hex -- every method here only changes
    # behavior when `@game` implements the specific opt-in hook it checks
    # (`last_route`), so no other game's map controls are affected.
    module MapControlsG2038
      def self.included(base)
        # G2038-specific "Show Last Route" data: an array of hex-id
        # arrays, one per ship -- see Map#historical_ship_routes (the
        # same store key, populated from here) for the full rationale.
        base.needs :historical_ship_routes, default: [], store: true
      end

      def g2038_ship_routes?
        @game.respond_to?(:last_route)
      end

      # "Show Last Route and Tile" draws colored segments along printed
      # track lanes (Engine::Route#connection_hexes/#halts, both
      # track-connectivity concepts) -- meaningless for a trackless game
      # (HIDE_TILE_TRACK), which has no lanes to draw along at all.
      def hide_tile_track?
        @game.class.const_defined?(:HIDE_TILE_TRACK) && @game.class::HIDE_TILE_TRACK
      end

      # G2038 equivalent of generate_last_route above -- one hex-id array
      # per ship, straight from Game#last_route (already maintained for
      # the ship-selector's own "Last" button), rather than
      # connection_hexes/halts/nodes, which G2038 never populates. No
      # "tile" counterpart -- per the user, only the route lines are
      # wanted here, not last_laid_hexes' highlight-box effect.
      def generate_last_ship_routes(entity)
        entity.trains.filter_map { |train| @game.last_route(train)&.dig(:hexes) }
      end
    end
  end
end
