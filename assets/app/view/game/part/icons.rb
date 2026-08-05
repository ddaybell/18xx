# frozen_string_literal: true

require 'view/game/part/base'
require 'view/game/part/small_item'

module View
  module Game
    module Part
      class Icons < Base
        include SmallItem

        ICON_RADIUS = 16
        DELTA_X = (ICON_RADIUS * 2) + 2

        def preferred_render_locations
          if layout == :pointy && @icons.one?
            POINTY_SMALL_ITEM_LOCATIONS
          elsif layout == :pointy
            POINTY_WIDE_ITEM_LOCATIONS
          elsif layout == :flat && @icons.one?
            SMALL_ITEM_LOCATIONS
          else
            WIDE_ITEM_LOCATIONS
          end
        end

        def parts_for_loc
          @icons
        end

        def load_from_tile
          @icons = @tile.icons.select { |i| !i.large && (i.loc == @loc) }
          @num_cities = @tile.cities.size
        end

        def render_part
          # A lone icon with its own explicit `radius` (opt-in, see
          # Part::Icon) renders at that size instead of the shared
          # ICON_RADIUS default, centered on its own translate -- every
          # other case (multiple icons, or no custom radius set) renders
          # exactly as before.
          if @icons.one? && @icons.first.radius
            radius = @icons.first.radius
            return h(:g, { attrs: { transform: "#{rotation_for_layout} translate(#{-radius} #{-radius})" } }, [
                h(:g, { attrs: { transform: translate } }, [
                  h(:image, attrs: { href: @icons.first.image, width: "#{radius * 2}px", height: "#{radius * 2}px" }),
                ]),
              ])
          end

          children = @icons.map.with_index do |icon, index|
            h(:image,
              attrs: {
                href: icon.image,
                x: ((index - ((@icons.size - 1) / 2.0)) * -DELTA_X).round(2),
                width: "#{ICON_RADIUS * 2}px",
                height: "#{ICON_RADIUS * 2}px",
              })
          end

          h(:g, { attrs: { transform: "#{rotation_for_layout} translate(#{-ICON_RADIUS} #{-ICON_RADIUS})" } }, [
              h(:g, { attrs: { transform: translate } }, children),
            ])
        end
      end
    end
  end
end
