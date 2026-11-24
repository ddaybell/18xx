# frozen_string_literal: true

module View
  module Game
    module G2038
      # A delegate object, not a mixin, so View::Game::Hex's own method
      # table never carries these.
      class HexDecorations
        def initialize(host, game, hex, tile, show_starting_map)
          @host = host
          @game = game
          @hex = hex
          @tile = tile
          @show_starting_map = show_starting_map
        end

        def h(...)
          @host.h(...)
        end

        # [x, y, radius, opacity] within an 80x80 pattern tile.
        STARFIELD_STARS = [
          [6, 12, 1.2, 0.9], [18, 5, 0.8, 0.6], [25, 22, 1.5, 1.0], [34, 9, 0.6, 0.5],
          [42, 28, 1.0, 0.8], [51, 14, 0.7, 0.6], [60, 32, 1.3, 0.9], [68, 6, 0.9, 0.7],
          [75, 24, 1.1, 0.85], [12, 38, 0.7, 0.55], [29, 45, 1.4, 0.95], [46, 41, 0.6, 0.5],
          [58, 50, 1.0, 0.75], [71, 44, 0.8, 0.65], [5, 58, 1.2, 0.9], [22, 63, 0.7, 0.6],
          [37, 70, 1.5, 1.0], [50, 66, 0.6, 0.45], [64, 72, 1.0, 0.8], [77, 60, 0.9, 0.7],
          [14, 76, 0.8, 0.6], [33, 15, 0.5, 0.4], [55, 78, 1.1, 0.85], [8, 25, 0.6, 0.5]
        ].freeze

        STARFIELD_WARM_STARS = [
          [15, 20, 1.0, 0.8],
          [63, 55, 0.8, 0.7],
          [40, 62, 0.9, 0.75],
        ].freeze

        STARFIELD_NEBULAE = [
          [20, 50, 22, '#6a5acd'],
          [60, 20, 18, '#4682b4'],
        ].freeze

        def starfield_pattern_id
          "g2038-starfield-#{@hex.id}"
        end

        # Derived from the hex's own id, not a real random call, so the
        # rotation is stable across re-renders and identical on every client.
        def starfield_rotation
          (@hex.id.each_char.sum(&:ord) * 47) % 360
        end

        # `<defs>` content is looked up by id document-wide regardless of
        # where in the DOM it sits, so nesting one per hex here is enough.
        def starfield_defs
          stars = STARFIELD_STARS.map do |x, y, r, o|
            h(:circle, attrs: { cx: x, cy: y, r: r, fill: '#ffffff', opacity: o })
          end
          warm_stars = STARFIELD_WARM_STARS.map do |x, y, r, o|
            h(:circle, attrs: { cx: x, cy: y, r: r, fill: '#e8a06e', opacity: o })
          end
          nebulae = STARFIELD_NEBULAE.map do |x, y, r, color|
            h(:circle, attrs: { cx: x, cy: y, r: r, fill: color, opacity: 0.06 })
          end

          h(:defs, { key: 'g2038-starfield-defs' }, [
              h(:pattern, {
                  attrs: {
                    id: starfield_pattern_id,
                    patternUnits: 'userSpaceOnUse',
                    width: 80,
                    height: 80,
                    patternTransform: "rotate(#{starfield_rotation} 40 40)",
                  },
                },
                # Overshoots the 80x80 tile by half a unit on every side --
                # an exactly-tile-sized rect leaves a faint antialiased
                # seam between repeats under a rotated patternTransform.
                [h(:rect, attrs: { x: -0.5, y: -0.5, width: 81, height: 81, fill: '#0a1128' })] +
                  nebulae + stars + warm_stars),
            ])
        end

        # See Game#offboard_forced_bottom? (part/revenue.rb) for why the
        # printed revenue box is pushed to the bottom instead of center.
        #
        # Counter-rotated by -30 for pointy layout: this is a raw sibling
        # of Tile within the hex's own <g>, so it doesn't get Hex#transform's
        # rotate(30) cancelled out via Part::Base::rotation_for_layout the
        # way normal tile content does.
        SATELLITE_SCALE = 1.3 * 1.3

        def satellite_icon
          rotation = @hex.layout == :pointy ? -30 : 0
          h(:g, { key: 'g2038-satellite', attrs: { transform: "rotate(#{rotation}) scale(#{SATELLITE_SCALE})" } }, [
              h(:rect, attrs: {
                  x: -32,
                  y: -4,
                  width: 64,
                  height: 8,
                  fill: '#c9ccd1',
                  stroke: '#5a5f66',
                  'stroke-width': 1.25,
                }),
              h(:rect, attrs: {
                  x: -32,
                  y: -4,
                  width: 14,
                  height: 8,
                  fill: '#3a6b8a',
                  stroke: '#1a3a4a',
                  'stroke-width': 1,
                }),
              h(:rect, attrs: {
                  x: 18,
                  y: -4,
                  width: 14,
                  height: 8,
                  fill: '#3a6b8a',
                  stroke: '#1a3a4a',
                  'stroke-width': 1,
                }),
              h(:rect, attrs: {
                  x: -6,
                  y: -9,
                  width: 12,
                  height: 18,
                  rx: 2,
                  fill: '#c9ccd1',
                  stroke: '#5a5f66',
                  'stroke-width': 1.5,
                }),
              h(:line, attrs: { x1: 0, y1: -9, x2: 0, y2: -18, stroke: '#c9ccd1', 'stroke-width': 1.5 }),
              h(:ellipse, attrs: {
                  cx: 0,
                  cy: -25,
                  rx: 12,
                  ry: 7,
                  fill: 'none',
                  stroke: '#e8ecef',
                  'stroke-width': 2.25,
                }),
              h(:circle, attrs: { cx: 0, cy: -25, r: 1.5, fill: '#e8ecef' }),
            ])
        end

        # [x, y, radius], relative to hex-center.
        ASTEROID_BUMPS = [
          [0, -42, 52], [-36, -12, 46], [34, -16, 44], [-22, 28, 46], [24, 32, 42], [0, 6, 50]
        ].freeze

        ASTEROID_CRATERS = [
          [-16, -24, 11], [22, -10, 8], [-6, 16, 12], [30, 18, 7], [-32, 8, 7], [8, -40, 7], [-40, -30, 6],
          [40, -22, 15], [-30, 40, 13], [48, 22, 11]
        ].freeze

        MINE_SINGLE_SCALE = 0.55
        MINE_DOUBLE_SCALE = 0.38

        # Same edge numbering as Part::Borders::EDGES.
        MINE_EDGE_MIDPOINTS = {
          0 => [0, 87],
          1 => [-75, 43.5],
          2 => [-75, -43.5],
          3 => [0, -87],
          4 => [75, -43.5],
          5 => [75, 43.5],
        }.freeze

        # Approximation, not yet visually confirmed against the engine's
        # own city placement.
        MINE_CITY_OFFSET_FRACTION = 0.45

        def mine_city_position(city)
          edge = @tile.preferred_city_town_edges[city]
          x, y = MINE_EDGE_MIDPOINTS[edge&.to_i]
          return [0, 0] unless x

          [x * MINE_CITY_OFFSET_FRACTION, y * MINE_CITY_OFFSET_FRACTION]
        end

        # Counter-rotated for pointy layout, same reason as satellite_icon.
        def asteroid_rock(scale: 1.0, offset: [0, 0], key: 'g2038-asteroid-0')
          rotation = @hex.layout == :pointy ? -30 : 0
          bumps = ASTEROID_BUMPS.map { |x, y, r| h(:circle, attrs: { cx: x, cy: y, r: r }) }
          craters = ASTEROID_CRATERS.map do |x, y, r|
            h(:circle, attrs: { cx: x, cy: y, r: r, fill: '#4a453e', opacity: 0.6 })
          end

          ox, oy = offset
          h(:g, { key: key, attrs: { transform: "translate(#{ox} #{oy}) rotate(#{rotation}) scale(#{scale})" } }, [
              h(:g, { attrs: { fill: '#5c574f', transform: 'translate(3 4)' } }, bumps),
              h(:g, { attrs: { fill: '#8a8378' } }, bumps),
              h(:g, { attrs: { fill: '#a39c8e', opacity: 0.5, transform: 'translate(-8 -8) scale(0.6)' } }, bumps),
              *craters,
            ])
        end

        # The tile's own city/token slot is drawn on top of this -- see
        # Hex#render's ordering.
        RING_STATION_CORE_R = 28
        RING_STATION_HUB_R = 18
        RING_STATION_RING_R = 58
        RING_STATION_RING_WIDTH = 9
        RING_STATION_SPOKE_WIDTH = 6
        RING_STATION_SPOKE_COUNT = 8
        # Same path as the map's station-slot marker/per-corp station icons
        # (public/icons/g_2038/station_slot.svg and *_station.svg).
        REFUEL_TEARDROP_PATH = 'M50 12 C38 30 25 48 25 65 A25 25 0 1 0 75 65 C75 48 62 30 50 12 Z'

        def refuel_teardrop_shape
          owner = !@show_starting_map && @game.respond_to?(:refueling_station_owner) &&
                  @game.refueling_station_owner(@hex.id)
          fill = owner ? owner.color : '#ffffff'
          stroke = owner ? '#000000' : '#3d4047'
          shape = [h(:path, attrs: { d: REFUEL_TEARDROP_PATH, fill: fill, stroke: stroke, 'stroke-width': 3 })]
          return shape unless owner

          text_attrs = {
            x: 50,
            y: 76,
            'text-anchor': 'middle',
            'font-weight': 700,
            'font-size': 26,
            'font-family': 'Arial',
            fill: '#000000',
          }
          shape << h(:text, { attrs: text_attrs }, owner.id)
          shape
        end

        REFUEL_TEARDROP_SLOT = 5

        def ring_station
          rotation = @hex.layout == :pointy ? -30 : 0
          slot_angle = 360 / (2 * RING_STATION_SPOKE_COUNT)
          spoke_inner = RING_STATION_CORE_R
          spoke_outer = RING_STATION_RING_R - (RING_STATION_RING_WIDTH / 2.0)
          spokes = (0...RING_STATION_SPOKE_COUNT).map do |i|
            h(:rect, attrs: {
                x: -RING_STATION_SPOKE_WIDTH / 2.0,
                y: -spoke_outer,
                width: RING_STATION_SPOKE_WIDTH,
                height: spoke_outer - spoke_inner,
                fill: '#888d96',
                stroke: '#4a4e57',
                'stroke-width': 0.75,
                transform: "rotate(#{i * (360 / RING_STATION_SPOKE_COUNT)})",
              })
          end
          modules = (0...RING_STATION_SPOKE_COUNT).map do |i|
            h(:rect, attrs: {
                x: -5,
                y: -(RING_STATION_RING_R + 3),
                width: 10,
                height: 8,
                rx: 1.5,
                fill: '#6b6f78',
                stroke: '#3d4047',
                'stroke-width': 0.75,
                transform: "rotate(#{(i * (360 / RING_STATION_SPOKE_COUNT)) + slot_angle})",
              })
          end
          # Omitted entirely for a base that can never have a refueling
          # station (see Game#station_eligible?) -- the white "unclaimed
          # slot" teardrop would wrongly imply one could still be bought.
          station_eligible = !@game.respond_to?(:station_eligible?) || @game.station_eligible?(@hex)
          teardrop =
            if station_eligible
              teardrop_angle = REFUEL_TEARDROP_SLOT * (360 / RING_STATION_SPOKE_COUNT)
              teardrop_transform = "rotate(#{teardrop_angle}) translate(0 #{-RING_STATION_RING_R}) rotate(180) " \
                                   'scale(0.767875) translate(-50 -50)'
              h(:g, { attrs: { transform: teardrop_transform } }, refuel_teardrop_shape)
            end

          h(:g, { key: 'g2038-ring-station', attrs: { transform: "rotate(#{rotation})" } }, [
              h(:circle, attrs: {
                  cx: 0,
                  cy: 0,
                  r: RING_STATION_RING_R,
                  fill: 'none',
                  stroke: '#5c6068',
                  'stroke-width': RING_STATION_RING_WIDTH,
                }),
              h(:circle, attrs: {
                  cx: 0,
                  cy: 0,
                  r: RING_STATION_RING_R + (RING_STATION_RING_WIDTH / 2.0),
                  fill: 'none',
                  stroke: '#a7abb3',
                  'stroke-width': 1,
                }),
              h(:circle, attrs: {
                  cx: 0,
                  cy: 0,
                  r: RING_STATION_RING_R - (RING_STATION_RING_WIDTH / 2.0),
                  fill: 'none',
                  stroke: '#3d4047',
                  'stroke-width': 1,
                }),
              *modules,
              *spokes,
              *[teardrop].compact,
              h(:circle, attrs: {
                  cx: 0,
                  cy: 0,
                  r: RING_STATION_CORE_R,
                  fill: '#9aa0aa',
                  stroke: '#4a4e57',
                  'stroke-width': 2,
                }),
              h(:circle, attrs: {
                  cx: 0,
                  cy: 0,
                  r: RING_STATION_HUB_R,
                  fill: 'none',
                  stroke: '#6b6f78',
                  'stroke-width': 1.5,
                }),
            ])
        end

        # Opt-in hooks for BuyInfrastructure.
        def existing_base_hex?
          step = @game.round&.active_step
          return false unless step.respond_to?(:highlight_base_hexes)

          step.highlight_base_hexes(@game.current_entity).include?(@hex.id)
        end

        def existing_station_hex?
          step = @game.round&.active_step
          return false unless step.respond_to?(:highlight_station_hexes)

          step.highlight_station_hexes(@game.current_entity).include?(@hex.id)
        end

        def existing_infrastructure_highlight
          # Full View::Game::Hex:: qualification is required: a bare
          # reference resolves via this class's own lexical scope, not Hex's.
          h(:polygon, {
              key: 'g2038-existing-infra-highlight',
              attrs: {
                points: View::Game::Hex::HIGHLIGHT_POINTS,
                'fill-opacity': 0,
                pathLength: 576,
                'stroke-dasharray': 16,
                'stroke-dashoffset': 8,
                'stroke-width': View::Game::Hex::HIGHLIGHT_STROKE_WIDTH,
                stroke: '#ffd700',
              },
            })
        end

        # A literal numeric point, not a transform string like
        # ring_station uses -- a highlight circle needs an actual center.
        def teardrop_position
          rotation = @hex.layout == :pointy ? -30 : 0
          angle = (rotation + (REFUEL_TEARDROP_SLOT * (360 / RING_STATION_SPOKE_COUNT))) * Math::PI / 180
          [RING_STATION_RING_R * Math.sin(angle), -RING_STATION_RING_R * Math.cos(angle)]
        end

        STATION_HIGHLIGHT_RADIUS = 35

        def existing_station_highlight
          ox, oy = teardrop_position
          h(:circle, {
              key: 'g2038-existing-station-highlight',
              attrs: {
                cx: ox,
                cy: oy,
                r: STATION_HIGHLIGHT_RADIUS,
                'fill-opacity': 0,
                pathLength: 100,
                'stroke-dasharray': 8,
                'stroke-dashoffset': 4,
                'stroke-width': 5,
                stroke: '#ffd700',
              },
            })
        end

        # See Step::Route#suggested_pickups_for_hex.
        def suggested_pickup_entries
          step = @game.round&.active_step
          return [] unless step.respond_to?(:suggested_pickups_for_hex)

          step.suggested_pickups_for_hex(@game.current_entity, @hex.id)
        end

        PICKUP_HIGHLIGHT_SIZE = 40

        def pickup_highlight_square(entry)
          offset =
            if entry != :transship && @tile&.cities&.size == 2 && @tile.cities[entry]
              mine_city_position(@tile.cities[entry])
            else
              [0, 0]
            end
          ox, oy = offset

          h(:rect, {
              key: "g2038-pickup-highlight-#{entry}",
              attrs: {
                x: ox - (PICKUP_HIGHLIGHT_SIZE / 2.0),
                y: oy - (PICKUP_HIGHLIGHT_SIZE / 2.0),
                width: PICKUP_HIGHLIGHT_SIZE,
                height: PICKUP_HIGHLIGHT_SIZE,
                fill: 'none',
                stroke: '#ffd700',
                'stroke-width': 3,
              },
            })
        end
      end
    end
  end
end
