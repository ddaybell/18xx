# frozen_string_literal: true

require 'view/game/part/base'
require 'view/game/part/multi_revenue'
require 'view/game/part/small_item'

module View
  module Game
    module Part
      class Revenue < Base
        include SmallItem

        # See Part::City's identical declaration for why this is here
        # (Snabberb needs an explicit `needs :game` per class, no
        # implicit fallback) and why it's scoped to this file rather
        # than Part::Base.
        needs :game, default: nil, store: true

        FLAT_MULTI_REVENUE_LOCATIONS =
          [
            {
              region_weights: { CENTER => 1.5 },
              x: 0,
              y: 0,
            },
            {
              region_weights: { TOP_MIDDLE_ROW => 1.5 },
              x: 0,
              y: -48,
            },
            {
              region_weights: { BOTTOM_MIDDLE_ROW => 1.5 },
              x: 0,
              y: 45,
            },
          ].freeze

        POINTY_MULTI_REVENUE_LOCATIONS =
          [
            {
              region_weights: { CENTER => 1.5 },
              x: 0,
              y: 0,
            },
            {
              region_weights: { [2, 6, 7, 8] => 1.5, [3, 5] => 0.5 },
              x: 0,
              y: -55,
            },
            {
              region_weights: { [15, 16, 21, 17] => 1.5, [18, 20] => 0.5 },
              x: 0,
              y: 55,
            },
          ].freeze

        SIX_CITY_CENTER_REVENUE = [
          {
            region_weights: CENTER,
            x: 0,
            y: 0,
          },
        ].freeze

        # Opt-in hook: a game can force this hex's revenue box to the
        # bottom-of-hex candidate location instead of whatever the
        # region-occupancy algorithm below would otherwise pick (e.g.
        # G2038's transshipment points, which have nothing else on the
        # tile competing for space, so the default always lands at
        # dead-center -- exactly where that game wants to draw its own
        # centered satellite icon instead, see hex.rb#satellite_icon).
        # Every other game doesn't implement this, so behavior is
        # unchanged for them.
        def forced_to_bottom?
          @tile&.hex && @game.respond_to?(:offboard_forced_bottom?) && @game.offboard_forced_bottom?(@tile.hex)
        end

        def preferred_render_locations
          if multi_revenue? && forced_to_bottom?
            [layout == :flat ? FLAT_MULTI_REVENUE_LOCATIONS[2] : POINTY_MULTI_REVENUE_LOCATIONS[2]]
          elsif multi_revenue?
            if layout == :flat
              FLAT_MULTI_REVENUE_LOCATIONS
            else
              POINTY_MULTI_REVENUE_LOCATIONS
            end
          elsif @cities == 6
            SIX_CITY_CENTER_REVENUE
          elsif layout == :flat
            SMALL_ITEM_LOCATIONS
          else
            POINTY_SMALL_ITEM_LOCATIONS
          end
        end

        def load_from_tile
          @slots = @tile.cities.sum(&:slots) + @tile.towns.size
          @cities = @tile.cities.size
          stops = @tile.stops
          @hide = stops.any?(&:hide)
          @rows = (@tile.offboards&.first&.rows || 1)
          @revenue = @tile.revenue_to_render.first
        end

        # Opt-in hook: a game can force this hex's revenue box to never
        # render at all, regardless of its printed value (e.g. G2038's
        # H10 transshipment point, whose printed value becomes stale/
        # meaningless the moment the Asteroid League forms and takes
        # the hex over as its own base -- see Game#hide_revenue?).
        # Every other game doesn't implement this, so behavior is
        # unchanged for them.
        def hidden_by_game?
          @tile&.hex && @game.respond_to?(:hide_revenue?) && @game.hide_revenue?(@tile.hex)
        end

        def should_render?
          !hidden_by_game? && !@hide && ![nil, 0].include?(@revenue)
        end

        def multi_revenue?
          !@revenue.is_a?(Numeric)
        end

        def render_part
          transform = "#{rotation_for_layout} #{translate}"

          if multi_revenue?
            h(MultiRevenue, revenues: display_revenues, transform: transform, rows: @rows)
          else
            h(SingleRevenue, revenue: @revenue, transform: transform)
          end
        end

        # Opt-in hook: a game can override the *displayed* text for a
        # specific phase-color box without touching the real revenue
        # value underneath (e.g. G2038's H10 transshipment point, whose
        # "gray" $0 entry can never actually be paid -- the hex becomes
        # the Asteroid League's home base the moment gray phase makes it
        # possible to reach that value -- showing "AL" there instead of
        # a misleading "$0"). MultiRevenue's own text/width computation
        # is generic string interpolation, so a String value here
        # renders exactly as-is with no other side effects; the engine's
        # real RevenueCenter#revenue (what routes actually pay) is
        # untouched, since only this display-only copy is modified.
        def display_revenues
          return @revenue unless @game.respond_to?(:revenue_text_override)

          @revenue.to_h do |phase, revenue|
            override = @tile&.hex && @game.revenue_text_override(@tile.hex, phase)
            [phase, override || revenue]
          end
        end
      end
    end
  end
end
