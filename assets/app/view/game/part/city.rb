# frozen_string_literal: true

require 'view/game/runnable'
require 'view/game/part/base'
require 'view/game/part/city_slot'
require 'view/game/part/single_revenue'

module View
  module Game
    module Part
      class City < Base
        include Runnable

        SLOT_RADIUS = 25
        SLOT_DIAMETER = 2 * SLOT_RADIUS

        needs :tile
        needs :city
        needs :show_revenue

        # key is how many city slots are part of the city; value is the offset for
        # the first city slot
        CITY_SLOT_POSITION = {
          1 => [0, 0],
          2 => [-SLOT_RADIUS, 0],
          3 => [0, -29],
          4 => [-SLOT_RADIUS, -SLOT_RADIUS],
          5 => [0, -43],
          6 => [0, -50],
          7 => [0, -52],
          8 => [0, -54],
          9 => [0, -55],
        }.freeze

        BIG_CITY_SLOT_RADIUS = {
          7 => 22,
          8 => 20.5,
          9 => 19,
        }.freeze

        EDGE_CITY_REGIONS = {
          0 => [15, 20, 21, 22],
          0.5 => [13, 14, 15, 19, 20, 21],
          1 => [12, 13, 14, 19],
          1.5 => [5, 6, 7, 12, 13, 14],
          2 => [0, 5, 6, 7],
          2.5 => [0, 1, 2, 6, 7, 8],
          3 => [1, 2, 3, 8],
          3.5 => [2, 3, 4, 8, 9, 10],
          4 => [4, 9, 10, 11],
          4.5 => [9, 10, 11, 16, 17, 18],
          5 => [16, 17, 18, 23],
          5.5 => [15, 16, 17, 21, 22, 23],
        }.freeze

        EXTRA_SLOT_REGIONS = {
          0 => [13, 14, 16, 17, 19, 20, 22, 23],
          0.5 => [12, 22],
          1 => [5, 6, 7, 12, 15, 19, 20, 21],
          1.5 => [0, 19],
          2 => [0, 1, 2, 5, 8, 14, 13, 12],
          2.5 => [3, 5],
          3 => [0, 1, 3, 4, 6, 7, 9, 10],
          3.5 => [1, 11],
          4 => [17, 16, 18, 8, 2, 18, 3, 4],
          4.5 => [4, 17],
          5 => [21, 15, 22, 23, 9, 10, 11, 18],
          5.5 => [18, 20],
        }.freeze

        BORDER_REGIONS = {
          0 => [15, 7],
          0.5 => [7, 8, 9, 16],
          1 => [14, 8],
          1.5 => [8, 9, 15, 16],
          2 => [7, 9],
          2.5 => [9, 14, 15, 16],
          3 => [8, 16],
          3.5 => [7, 14, 15, 16],
          4 => [9, 15],
          4.5 => [7, 8, 14, 15],
          5 => [16, 14],
          5.5 => [7, 8, 9, 14],
        }.freeze
        # key: number of slots in city
        # value: [element name (sym), element attrs]
        BOX_ATTRS = {
          2 => [:rect, {
            fill: 'white',
            width: SLOT_DIAMETER,
            height: SLOT_DIAMETER,
            x: -SLOT_RADIUS,
            y: -SLOT_RADIUS,
          }],
          3 => [:polygon, {
            fill: 'white',
            # Hex::POINTS scaled by 0.458
            points: '45.8,0 22.9,-39.846 -22.9,-39.846 -45.8,0 -22.9,39.846 22.9,39.846',
          }],
          4 => [:rect, {
            fill: 'white',
            width: SLOT_DIAMETER * 2,
            height: SLOT_DIAMETER * 2,
            x: -SLOT_DIAMETER,
            y: -SLOT_DIAMETER,
            rx: SLOT_RADIUS,
          }],
          5 => [:circle, {
            fill: 'white',
            r: 1.36 * SLOT_DIAMETER,
          }],
          6 => [:circle, {
            fill: 'white',
            r: 1.5 * SLOT_DIAMETER,
          }],
          7 => [:circle, {
            fill: 'white',
            r: 1.5 * SLOT_DIAMETER,
          }],
          8 => [:circle, {
            fill: 'white',
            r: 1.5 * SLOT_DIAMETER,
          }],
          9 => [:circle, {
            fill: 'white',
            r: 1.5 * SLOT_DIAMETER,
          }],
        }.freeze

        # index corresponds to number of slots in the city
        REVENUE_DISPLACEMENT = {
          flat: [nil, 42, 67, 65, 67, 0, 0, 0, 0, 0],
          pointy: [nil, 42, 62, 57],
        }.freeze

        ANGLE_RIGHT = -5
        ANGLE_UPPER_RIGHT = -60
        ANGLE_LOWER_RIGHT = 10
        ANGLE_LOWER_LEFT = 170
        ANGLE_UPPER_LEFT = -120
        ANGLE_LEFT = -175

        REVENUE_LOCATIONS_BY_EDGE = {
          0 => [
            { regions: [19], angle: ANGLE_LOWER_LEFT },
            { regions: [14], angle: ANGLE_UPPER_LEFT },
            { regions: [23], angle: ANGLE_LOWER_RIGHT },
            { regions: [16], angle: ANGLE_UPPER_RIGHT },
          ],
          0.5 => [
            { regions: [12, 13], angle: ANGLE_LEFT },
            { regions: [7, 14], angle: ANGLE_UPPER_LEFT },
            { regions: [15, 16], angle: ANGLE_UPPER_RIGHT },
            { regions: [21, 22], angle: ANGLE_RIGHT },
          ],
          1 => [
            { regions: [5], angle: ANGLE_LOWER_LEFT },
            { regions: [7], angle: ANGLE_UPPER_LEFT },
            { regions: [15], angle: ANGLE_UPPER_RIGHT },
            { regions: [20], angle: ANGLE_LOWER_RIGHT },
          ],
          1.5 => [
            { regions: [0, 6], angle: ANGLE_LEFT },
            { regions: [13, 19], angle: ANGLE_RIGHT },
            { regions: [7, 8], angle: ANGLE_UPPER_LEFT },
            { regions: [14, 15], angle: ANGLE_UPPER_RIGHT },
          ],
          2 => [
            { regions: [12], angle: ANGLE_LOWER_RIGHT },
            { regions: [14], angle: ANGLE_UPPER_RIGHT },
            { regions: [8], angle: ANGLE_UPPER_LEFT },
            { regions: [1], angle: ANGLE_LOWER_LEFT },
          ],
          2.5 => [
            { regions: [5, 6], angle: ANGLE_RIGHT },
            { regions: [7, 14], angle: ANGLE_UPPER_RIGHT },
            { regions: [8, 9], angle: ANGLE_UPPER_LEFT },
            { regions: [2, 3], angle: ANGLE_LEFT },
          ],
          3 => [
            { regions: [4], angle: ANGLE_LOWER_LEFT },
            { regions: [0], angle: ANGLE_LOWER_RIGHT },
            { regions: [9], angle: ANGLE_UPPER_LEFT },
            { regions: [7], angle: ANGLE_UPPER_RIGHT },
          ],
          3.5 => [
            { regions: [10, 11], angle: ANGLE_LEFT },
            { regions: [9, 16], angle: ANGLE_UPPER_LEFT },
            { regions: [7, 8], angle: ANGLE_UPPER_RIGHT },
            { regions: [1, 2], angle: ANGLE_RIGHT },
          ],
          4 => [
            { regions: [18], angle: ANGLE_LOWER_LEFT },
            { regions: [16], angle: ANGLE_UPPER_LEFT },
            { regions: [8], angle: ANGLE_UPPER_RIGHT },
            { regions: [3], angle: ANGLE_LOWER_RIGHT },
          ],
          4.5 => [
            { regions: [4, 10], angle: ANGLE_RIGHT },
            { regions: [17, 23], angle: ANGLE_LEFT },
            { regions: [8, 9], angle: ANGLE_UPPER_RIGHT },
            { regions: [15, 16], angle: ANGLE_UPPER_LEFT },
          ],
          5 => [
            { regions: [11], angle: ANGLE_LOWER_RIGHT },
            { regions: [9], angle: ANGLE_UPPER_RIGHT },
            { regions: [15], angle: ANGLE_UPPER_LEFT },
            { regions: [22], angle: ANGLE_LOWER_LEFT },
          ],
          5.5 => [
            { regions: [17, 18], angle: ANGLE_RIGHT },
            { regions: [14, 15], angle: ANGLE_UPPER_LEFT },
            { regions: [9, 16], angle: ANGLE_UPPER_RIGHT },
            { regions: [20, 21], angle: ANGLE_LEFT },
          ],
        }.freeze

        OO_REVENUE_REGIONS = [
          [[19], true],
          [[5, 12], true],
          [[5, 12], false],
          [[4], true],
          [[11, 18], true],
          [[11, 18], false],
        ].freeze

        CENTER_REVENUE_REGIONS = [
          { [14, 15] => 1.0, [13, 21] => 0.5, [19, 20] => 0.25 },
          { [7, 14] => 1.0, [6, 13] => 0.5, [5, 12] => 0.25 },
          { [7, 8] => 1.0, [2, 6] => 0.5, [0, 1] => 0.25 },
          { [8, 9] => 1.0, [2, 10] => 0.5, [3, 4] => 0.25 },
          { [9, 16] => 1.0, [10, 17] => 0.5, [11, 18] => 0.25 },
          { [15, 16] => 1.0, [17, 21] => 0.5, [22, 23] => 0.25 },
        ].freeze

        CENTER_REVENUE_EDGE_PRIORITY = [1, 2, 3, 4, 0, 5].freeze

        PASS_RADIUS = {
          1 => 40,
          2 => 48,
          3 => 60,
        }.freeze

        MULTI_SLOT_PASS_FACTOR = 1.2
        MULTI_SLOT_PASS_OFFSET = 8
        PASS_OUTLINE = 4

        def preferred_render_locations
          if @edge
            weights = EDGE_CITY_REGIONS[@edge]
            weights += EXTRA_SLOT_REGIONS[@edge] unless @city.slots(all: true) == 1
            distance = 50
            # move in if city is on a "half" edge and has more that one slot
            distance -= 8 if @edge.to_i != @edge && @city.slots(all: true) > 1

            # If there's a border on this edge, move the city slightly
            # towards the center to ensure track is visible.
            if @tile.borders.any? { |border| border.edge == @edge }
              distance -= 15
              weights = {
                weights => 1.0,
                BORDER_REGIONS[@edge] => 0.1,
              }
            end
            return [
              {
                region_weights: weights,
                x: -Math.sin((@edge * 60) / 180 * Math::PI) * distance,
                y: Math.cos((@edge * 60) / 180 * Math::PI) * distance,
                angle: @edge * 60,
              },
            ]
          end

          region_weights =
            case @city.slots(all: true)
            when 0
              []
            when (2..4)
              {
                CENTER => 1.0,
                (LEFT_CENTER + LEFT_MID + RIGHT_CENTER + RIGHT_MID) => 0.75,
              }
            else
              CENTER
            end

          [
            {
              region_weights: region_weights,
              x: 0,
              y: 0,
              angle: angle_for_layout, # make center cities always horizontal even on pointy
            },
          ]
        end

        def load_from_tile
          @edge = @tile.preferred_city_town_edges[@city]
          @num_cts = @tile.cities.size + @tile.towns.size
        end

        def render_part
          num_slots = @city.slots(all: true)
          slot_radius = num_slots > 6 ? BIG_CITY_SLOT_RADIUS[num_slots] : SLOT_RADIUS

          slots = (0..(num_slots - 1)).zip(@city.tokens + @city.extra_tokens).map do |slot_index, token|
            slot_rotation = (360 / @city.slots(all: true)) * slot_index

            # use the rotation on the outer <g> to position the slot, then use
            # -rotation on the Slot so its contents are rendered without
            # rotation
            x, y = CITY_SLOT_POSITION[@city.slots(all: true)]

            revert_angle = render_location[:angle] + slot_rotation
            revert_angle -= angle_for_layout unless @edge
            h(:g, { attrs: { transform: "rotate(#{slot_rotation})" } }, [
              h(:g, { attrs: { transform: "translate(#{x.round(2)} #{y.round(2)}) rotate(#{-revert_angle})" } }, [
                h(CitySlot, city: @city,
                            edge: @edge,
                            token: token,
                            slot_index: slot_index,
                            extra_token: @city.extra_tokens.include?(token),
                            radius: slot_radius,
                            reservation: @city.reservations[slot_index],
                            tile: @tile,
                            city_render_location: render_location,
                            region_use: @region_use),
              ]),
            ])
          end

          children = []
          children << render_pass if @city.pass?
          children << render_box(slots.size) if slots.size.between?(2, 9)
          children.concat(slots)
          children << render_mine_color if mine_ore

          claim_owner = mine_claim_owner
          children << render_claim_ring(claim_owner) if claim_owner

          if @show_revenue && (@city&.paths&.any? || trackless_game?) && (revenue = render_revenue)
            children << revenue
          end

          overlays = []
          ore_letter = mine_ore_letter
          overlays << render_ore_letter(ore_letter) if ore_letter
          overlays << render_used_marker if mine_used?
          children << upright(overlays) if overlays.any?

          props = @city.solo? ? {} : { on: { click: -> { touch_node(@city) } } }

          props[:attrs] = { transform: "#{translate} #{rotation}" }

          h(:g, props, children)
        end

        def render_revenue
          bonus_ore, bonus_amount = delivery_bonus

          revenue = nil
          unless bonus_ore
            revenues = @city.uniq_revenues
            revenue =
              if revenues.size > 1
                # Normal games route this case to the tile-level Part::Revenue/
                # MultiRevenue (stacked "30/60"-style display), gated on
                # Tile#stops -- which is itself derived from @paths and so is
                # always empty here (see trackless_game?). Show just the
                # current phase's number instead of stacking every phase, same
                # visual language as every other G2038 revenue circle.
                return unless trackless_game?

                current_phase_revenue
              else
                revenues.first
              end
            return if revenue.zero? && (!@city.pass? || @tile.paths.empty?)
          end

          regions = []

          displacement = REVENUE_DISPLACEMENT[layout][@city.slots(all: true)]

          rotation = 0

          if @num_cts == 1
            rotation = angle_for_layout

            regions = if layout == :flat
                        @city.slots(all: true) == 1 ? { [9, 16] => 1.0, [10, 17] => 0.5, [11, 18] => 0.25 } : [11, 18]
                      else
                        @city.slots(all: true) == 1 ? { [8, 9] => 1.0, [2, 10] => 0.5, [3, 4] => 0.25 } : [3, 4]
                      end
          elsif @edge && @city.slots(all: true) == 1
            revenue_location = REVENUE_LOCATIONS_BY_EDGE[@edge].min_by { |loc| combined_cost(loc[:regions]) }
            regions = revenue_location[:regions]
            rotation = revenue_location[:angle]
          elsif @edge
            regions, negative_displacement = OO_REVENUE_REGIONS[@edge]
            displacement *= -1 if negative_displacement
          else
            # pick an edge where there isn't another stop
            edges = CENTER_REVENUE_EDGE_PRIORITY - @tile.city_towns.flat_map do |stop|
              next [] if stop == @city || !(edge = @tile.preferred_city_town_edges[stop])

              [edge, (edge - 1) % 6]
            end
            revenue_edge = edges[0] || 0
            rotation = (60 * revenue_edge) + 120
            regions = CENTER_REVENUE_REGIONS[revenue_edge]
          end

          region_weights = regions
          region_weights = { region_weights => 1.0 } if region_weights.is_a?(Array)
          region_weights.each do |r, w|
            increment_weight_for_regions(r, w)
          end

          revert_angle = render_location[:angle] + rotation
          content = if bonus_ore
                      render_delivery_bonus(bonus_ore, bonus_amount)
                    else
                      h(Part::SingleRevenue,
                        revenue: revenue,
                        transform: rotation_for_layout,
                        force: @city.pass?)
                    end

          h(:g, { attrs: { transform: "rotate(#{rotation})" } }, [
            h(:g, { attrs: { transform: "translate(#{displacement} 0) rotate(#{-revert_angle})" } }, [content]),
          ])
        end

        # This hex's [ore, amount] home-base delivery bonus (Phase 7b), if
        # any -- a corp's *fixed* home coordinates pay a flat bonus to
        # whoever delivers the matching ore there, so this is read straight
        # off Game#home_delivery_bonuses (keyed by hex id) rather than any
        # per-tile data; most gray home-base hexes have none.
        #
        # Detached preview tiles (e.g. Lucky's tile-choice popup, and the
        # standard TileSelector fan) are wrapped in a throwaway Engine::Hex
        # always named 'A1' (see hex_choice_popup.rb/tile_selector.rb) --
        # which coincidentally collides with a real corp's home coordinate
        # in this game (Mars Mining). The same identity check the shared
        # engine already uses to detect a fake preview hex (Game::Base
        # #update_tile_lists's own "TileSelector creates fake A1 hexes"
        # comment) rules that out here too, so a preview tile never shows a
        # real hex's delivery bonus badge in place of its mine value.
        def delivery_bonus
          return nil unless @game.respond_to?(:home_delivery_bonuses)
          return nil unless @tile.hex == @game.hex_by_id(@tile.hex.id)

          @game.home_delivery_bonuses[@tile.hex.id]
        end

        # Same colored-circle language as a mine's ore tint (Nickel red/Ice
        # blue/Rare green -- see MINE_ORE_COLOR/mine_color above), always at
        # the same shade since there's no per-hex value scale here, just a
        # flat bonus amount.
        DELIVERY_BONUS_TINT = 0.6
        DELIVERY_BONUS_RADIUS = 18
        DELIVERY_BONUS_FONT_SIZE = '15px'

        def render_delivery_bonus(ore, amount)
          base = MINE_ORE_COLOR[ore]
          r, g, b = base.map { |c| ((c * (1 - DELIVERY_BONUS_TINT)) + (255 * DELIVERY_BONUS_TINT)).round.clamp(0, 255) }
          fill = format('#%02x%02x%02x', r, g, b)

          h(:g, { attrs: { transform: rotation_for_layout } }, [
            h(:circle, attrs: { r: DELIVERY_BONUS_RADIUS, fill: fill, stroke: '#777777' }),
            h(:text, {
                attrs: {
                  fill: 'black',
                  'font-size': DELIVERY_BONUS_FONT_SIZE,
                  'text-anchor': 'middle',
                  'dominant-baseline': 'central',
                  transform: 'translate(0 -1)',
                },
              }, "+#{amount}"),
          ])
        end

        # Mirrors RevenueCenter#route_base_revenue's phase lookup, so the
        # displayed number always matches what a route would actually pay.
        def current_phase_revenue
          @game.phase.tiles.reverse_each { |color| return @city.revenue[color] if @city.revenue[color] }
          @city.revenue.values.first
        end

        def render_box(slots)
          element, attrs = BOX_ATTRS[slots]
          h(element, attrs: attrs)
        end

        # G2038's cities carry no track by design (see HIDE_TILE_TRACK in
        # track.rb) -- the revenue-display gate above otherwise requires
        # @city.paths.any?, a proxy for "connected to the track network"
        # that's meaningless here and would hide every mine's revenue.
        def trackless_game?
          @game&.class&.const_defined?(:HIDE_TILE_TRACK) && @game.class::HIDE_TILE_TRACK
        end

        # This city's index within its tile's cities array -- shared by all
        # the mine-overlay lookups below, so it's only ever scanned once.
        def mine_index
          @mine_index ||= @tile.cities.index(@city)
        end

        def mine_used?
          @game.respond_to?(:mine_used?) && @game.mine_used?(@tile.hex.id, mine_index)
        end

        # This city's mine ore type (:n/:i/:r), if any. Reads MINE_DATA
        # (keyed by tile name, always available) rather than mine_state
        # (keyed by hex id, only populated for hexes actually on the map)
        # so this also works for a detached preview tile -- e.g. Lucky's
        # tile-choice popup, which renders a tile that was never laid
        # anywhere.
        def mine_ore
          return nil unless @game.class.const_defined?(:MINE_DATA)

          @game.class::MINE_DATA.dig(@tile.name, mine_index, :ore)
        end

        # Shown inside the city circle itself rather than as a generic
        # tile-level label, since a double-mine tile can hold two
        # different ore types.
        def mine_ore_letter
          mine_ore&.to_s&.upcase
        end

        MINE_ORE_COLOR = { n: [200, 40, 40], i: [40, 100, 210], r: [40, 150, 70] }.freeze
        MINE_VALUE_RANGE = (10..70)

        # Tints the mine circle by ore type (Nickel red, Ice blue, Rare
        # green), darker for a higher unclaimed value -- capped so even the
        # darkest mines stay light enough for the ore letter to read
        # clearly on top. Always keyed off the unclaimed value (from
        # MINE_DATA, not the city's live revenue) so a mine's color doesn't
        # change once claimed -- place_claim! swaps @city.revenue to the
        # (higher) claimed rate, which would otherwise darken the circle.
        def mine_color
          base = MINE_ORE_COLOR[mine_ore]
          return nil unless base

          value = @game.class::MINE_DATA.dig(@tile.name, mine_index, :unclaimed) || MINE_VALUE_RANGE.min
          span = MINE_VALUE_RANGE.max - MINE_VALUE_RANGE.min
          t = ((value - MINE_VALUE_RANGE.min).to_f / span).clamp(0.0, 1.0)
          white_blend = 0.82 - (0.42 * t)

          r, g, b = base.map { |c| ((c * (1 - white_blend)) + (255 * white_blend)).round.clamp(0, 255) }
          format('#%02x%02x%02x', r, g, b)
        end

        def render_mine_color
          h(:circle, attrs: { r: SLOT_RADIUS - 1, fill: mine_color })
        end

        def render_ore_letter(letter)
          h(:text, {
              attrs: {
                fill: 'black',
                'font-size': '28px',
                'text-anchor': 'middle',
                'dominant-baseline': 'central',
              },
            }, letter)
        end

        def render_used_marker
          r = 14
          h(:g, [
            h(:line, attrs: { x1: -r, y1: -r, x2: r, y2: r, stroke: 'white', 'stroke-width': 5, 'stroke-linecap': 'round' }),
            h(:line, attrs: { x1: -r, y1: r, x2: r, y2: -r, stroke: 'white', 'stroke-width': 5, 'stroke-linecap': 'round' }),
          ])
        end

        # render_part wraps all children in a rotate(render_location[:angle])
        # transform (to orient edge-attached cities). Location names (base and
        # transshipment labels) intentionally land at rotate(angle_for_layout)
        # -- -30 deg for pointy hexes, vertex-aligned rather than edge-aligned
        # -- via Part::LocationName's own rotation_for_layout wrapper. Adjust
        # from whatever angle this city happens to render at back to that
        # same target angle, so mine overlays match that convention exactly.
        def upright(elements)
          adjustment = angle_for_layout - (render_location[:angle] || 0)
          h(:g, { attrs: { transform: "rotate(#{adjustment})" } }, elements)
        end

        # The corporation/independent holding a claim on this mine, if any.
        def mine_claim_owner
          return nil unless @game.respond_to?(:mine_claim_owner)

          @game.mine_claim_owner(@tile.hex.id, mine_index)
        end

        # Doubled while `owner` is the entity currently taking its turn --
        # confirmed with the user some ROUTE_COLORS reds are hard to tell
        # apart at the normal ring size, and the active company's own
        # claims are exactly what a player is scanning the map for while
        # running its ships (or its other steps -- not narrowed to Route
        # specifically, since there's nothing Route-specific about wanting
        # to spot your own claims).
        def render_claim_ring(owner)
          base_radius = SLOT_RADIUS + 5
          radius = owner == @game.round.current_entity ? base_radius * 2 : base_radius

          h(:circle, attrs: {
              r: radius,
              fill: 'none',
              stroke: owner.color,
              'stroke-width': 8,
            })
        end

        def triangle_points(radius, yoffset = 0)
          Array.new(3) do |idx|
            "#{Math.cos(((idx * 120) + 30) / 180 * Math::PI) * radius},"\
              "#{(Math.sin(((idx * 120) + 30) / 180 * Math::PI) * radius) + yoffset}"
          end.join
        end

        def render_pass
          if @city.slots == 1
            radius = (PASS_RADIUS[@city.size] || 40)
            yoffset = 0
          else
            radius =  (PASS_RADIUS[@city.size] || 40) * MULTI_SLOT_PASS_FACTOR
            yoffset = MULTI_SLOT_PASS_OFFSET
          end
          outer_pass_attrs = {
            fill: 'white',
            stroke: 'white',
            points: triangle_points(radius + PASS_OUTLINE, yoffset),
          }
          inner_pass_attrs = {
            fill: @city.color,
            color: 'black',
            points: triangle_points(radius, yoffset),
          }
          h(:g, [
            h(:polygon, attrs: outer_pass_attrs),
            h(:polygon, attrs: inner_pass_attrs),
          ])
        end
      end
    end
  end
end
