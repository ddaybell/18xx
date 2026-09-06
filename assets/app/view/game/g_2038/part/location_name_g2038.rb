# frozen_string_literal: true

module View
  module Game
    module Part
      # G2038-only LocationName hooks: forcing consistent name placement
      # on trackless single-city hexes, and dark-starfield text/background
      # color overrides. Mixed into the shared Part::LocationName
      # component the same way HexG2038 is mixed into Hex -- every method
      # here only ever changes behavior when `@game` implements the
      # specific opt-in hook it checks, so no other game's location-name
      # rendering is affected.
      module LocationNameG2038
        def self.included(base)
          # See Part::City's identical declaration for why this is here
          # (Snabberb needs an explicit `needs :game` per class, no
          # implicit fallback) and why it's scoped to this file rather
          # than Part::Base.
          base.needs :game, store: true, default: nil
        end

        def hide_tile_track?
          @game&.class&.const_defined?(:HIDE_TILE_TRACK) && @game.class::HIDE_TILE_TRACK
        end

        # Opt-in hook: .tile__text's own `fill: black` (main.css) suits
        # every other game's light hex backgrounds, but is illegible on
        # G2038's dark starfield -- an inline `style:` attribute is
        # needed, not `attrs: { fill: }`, since a plain SVG presentation
        # attribute loses to a stylesheet class rule; an inline style
        # wins over both.
        def location_name_text_props
          return {} unless @game.respond_to?(:location_name_text_color) && (color = @game.location_name_text_color)

          { style: { fill: color } }
        end

        # Opt-in hook: pairs with location_name_text_props above -- a
        # white background box behind white text would be illegible, so
        # a game overriding the text color gets to override this too
        # (G2038 uses a dark box, matching its starfield).
        def location_name_background_color
          return LocationName::BACKGROUND_COLOR unless @game.respond_to?(:location_name_background_color) &&
            (color = @game.location_name_background_color)

          color
        end
      end
    end
  end
end
