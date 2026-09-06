# frozen_string_literal: true

module View
  module Game
    # G2038-only tile-name text color override. Mixed into the shared
    # Tile component the same way HexG2038 is mixed into Hex -- returns
    # {} (no override) for every other game, since none of them define
    # the `map_text_color` hook this checks.
    module TileG2038
      # Same pattern/reasoning as Part::LocationName's own
      # location_name_text_color -- a hardcoded fill: 'black' suits every
      # other game's light hex backgrounds but is illegible against
      # G2038's dark starfield. An inline `style:` override (not
      # `attrs: { fill: }`) is required, not optional -- a plain SVG
      # presentation attribute loses to a stylesheet class rule, an
      # inline style wins over both.
      def map_text_color_style
        return {} unless @game.respond_to?(:map_text_color) && (color = @game.map_text_color)

        { fill: color }
      end
    end
  end
end
