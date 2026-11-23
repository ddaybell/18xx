# frozen_string_literal: true

module View
  module Game
    module G2038
      # G2038's own additions to the shared Hex component -- starfield
      # backgrounds, asteroid-rock/ring-station/satellite art, and the
      # BuyInfrastructure existing-base/station/pickup highlights. Delegate
      # object (not a mixin) so View::Game::Hex's own method table never
      # carries these -- instantiated once per Hex render via Hex#g2038.
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

        # Hand-placed (not randomized -- pure decoration, no determinism/
        # replay concern) star positions within an 80x80 pattern tile:
        # [x, y, radius, opacity]. Scattered off any obvious grid so a
        # single tile doesn't read as a repeating unit on its own.
        STARFIELD_STARS = [
          [6, 12, 1.2, 0.9], [18, 5, 0.8, 0.6], [25, 22, 1.5, 1.0], [34, 9, 0.6, 0.5],
          [42, 28, 1.0, 0.8], [51, 14, 0.7, 0.6], [60, 32, 1.3, 0.9], [68, 6, 0.9, 0.7],
          [75, 24, 1.1, 0.85], [12, 38, 0.7, 0.55], [29, 45, 1.4, 0.95], [46, 41, 0.6, 0.5],
          [58, 50, 1.0, 0.75], [71, 44, 0.8, 0.65], [5, 58, 1.2, 0.9], [22, 63, 0.7, 0.6],
          [37, 70, 1.5, 1.0], [50, 66, 0.6, 0.45], [64, 72, 1.0, 0.8], [77, 60, 0.9, 0.7],
          [14, 76, 0.8, 0.6], [33, 15, 0.5, 0.4], [55, 78, 1.1, 0.85], [8, 25, 0.6, 0.5]
        ].freeze

        # A handful of warm-tinted specks among the white stars, matching
        # the physical tiles' own starfield art (a few reddish/orange dots
        # scattered among the white ones): [x, y, radius, opacity].
        STARFIELD_WARM_STARS = [
          [15, 20, 1.0, 0.8],
          [63, 55, 0.8, 0.7],
          [40, 62, 0.9, 0.75],
        ].freeze

        # Two soft, low-opacity tinted circles per tile -- a faint nebula
        # wisp behind the stars, echoing the cloudy smudges on the
        # physical tiles' own starfield art: [x, y, radius, color].
        STARFIELD_NEBULAE = [
          [20, 50, 22, '#6a5acd'],
          [60, 20, 18, '#4682b4'],
        ].freeze

        # A unique id per hex, not one shared pattern -- each hex needs its
        # own <pattern> so it can carry its own rotation (see
        # starfield_rotation) without affecting any other hex's.
        def starfield_pattern_id
          "g2038-starfield-#{@hex.id}"
        end

        # Deterministic per-hex rotation angle (0-359), derived from the
        # hex's own id rather than a real per-render random -- stable
        # across re-renders (and identical on every client), so the
        # pattern doesn't visibly jump around every time this component
        # redraws; only which hex gets which angle looks arbitrary.
        def starfield_rotation
          (@hex.id.each_char.sum(&:ord) * 47) % 360
        end

        # <defs><pattern> for this one hex's starfield fill, rotated by
        # its own angle so adjacent hexes -- which would otherwise reveal
        # adjacent windows onto the exact same underlying tiling -- don't
        # read as an obvious repeating grid. `<defs>` content is looked up
        # by id document-wide regardless of where in the DOM it sits, so
        # nesting one per hex inside that hex's own <g> is enough; no
        # separate map-level collection point is needed.
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
                # x/y/width/height overshoot the 80x80 tile by half a unit
                # on every side -- with a rotated patternTransform, an
                # exactly-tile-sized background rect leaves a faint
                # antialiased seam between repeats (visible as thin
                # straight lines cutting across the starfield); the
                # overlap hides it. The circles (stars) aren't affected --
                # they're small and sparse enough that a seam running
                # through one is imperceptible.
                [h(:rect, attrs: { x: -0.5, y: -0.5, width: 81, height: 81, fill: '#0a1128' })] +
                  nebulae + stars + warm_stars),
            ])
        end

        # A simple generative satellite -- body, ring-dish antenna, two
        # paneled solar wings -- echoing the relay-station art on the
        # physical transshipment-point tiles. Sits at hex-center; the
        # printed revenue box is pushed to the bottom instead (see
        # Game#offboard_forced_bottom?, part/revenue.rb) so the two don't
        # collide.
        #
        # Counter-rotated by -30 for pointy layout: this icon is a raw
        # sibling of Tile within the hex's own <g>, which carries a
        # `rotate(30)` for pointy hexes (Hex#transform) that normal tile
        # content cancels out via Part::Base's rotation_for_layout, but a
        # raw sibling shape doesn't get that for free.
        SATELLITE_SCALE = 1.3 * 1.3

        def satellite_icon
          rotation = @hex.layout == :pointy ? -30 : 0
          h(:g, { key: 'g2038-satellite', attrs: { transform: "rotate(#{rotation}) scale(#{SATELLITE_SCALE})" } }, [
              # horizontal boom, spanning most of the width, with darker
              # paneled segments at each end -- closer to the physical
              # tiles' own compact, integrated satellite silhouette than
              # the earlier separate-wings-and-boxy-body layout
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
              # central hub
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
              # short stalk up to the ring dish, mounted centrally above
              # the boom rather than off to one side
              h(:line, attrs: { x1: 0, y1: -9, x2: 0, y2: -18, stroke: '#c9ccd1', 'stroke-width': 1.5 }),
              # ring dish, viewed at an angle (a flattened ellipse), with a
              # small center hub -- the "ring" look, per the physical tiles
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

        # An irregular blob outline built from overlapping circles rather
        # than hand-authored path data, hand-placed (not randomized --
        # pure decoration, no determinism/replay concern) to avoid an
        # obviously-regular outline. [x, y, radius], relative to
        # hex-center.
        ASTEROID_BUMPS = [
          [0, -42, 52], [-36, -12, 46], [34, -16, 44], [-22, 28, 46], [24, 32, 42], [0, 6, 50]
        ].freeze

        # Small darker craters scattered across the rock's face: [x, y,
        # radius]. The first 7 sit close enough to hex-center that at the
        # single-mine tile's own 55% scale (MINE_SINGLE_SCALE below) most
        # of them land underneath the printed revenue circle and never
        # actually show -- leaving the outer, still-visible band of rock
        # looking flat/"doughy" (per the user). The last 3 sit farther out
        # specifically so at least a couple always survive into that
        # visible band regardless of scale.
        ASTEROID_CRATERS = [
          [-16, -24, 11], [22, -10, 8], [-6, 16, 12], [30, 18, 7], [-32, 8, 7], [8, -40, 7], [-40, -30, 6],
          [40, -22, 15], [-30, 40, 13], [48, 22, 11]
        ].freeze

        # Single-mine tiles: one rock at hex-center, shrunk to 55% so it
        # doesn't dominate next to the revenue circle. Double-mine tiles:
        # two smaller rocks, each centered on its own city/circle instead
        # of hex-center (see MINE_CITY_OFFSET_FRACTION below).
        MINE_SINGLE_SCALE = 0.55
        MINE_DOUBLE_SCALE = 0.38

        # Hex-edge midpoints in Lib::Hex's local (pre-pointy-rotation)
        # coordinate frame -- same frame/edge numbering Part::Borders::
        # EDGES already uses. Edge 0 is the bottom edge, going clockwise.
        MINE_EDGE_MIDPOINTS = {
          0 => [0, 87],
          1 => [-75, 43.5],
          2 => [-75, -43.5],
          3 => [0, -87],
          4 => [75, -43.5],
          5 => [75, 43.5],
        }.freeze

        # A double-mine city sits some fraction of the way from its edge
        # midpoint toward hex-center; this fraction is an analytical
        # approximation, not yet visually confirmed against the engine's
        # own city placement.
        MINE_CITY_OFFSET_FRACTION = 0.45

        def mine_city_position(city)
          edge = @tile.preferred_city_town_edges[city]
          x, y = MINE_EDGE_MIDPOINTS[edge&.to_i]
          return [0, 0] unless x

          [x * MINE_CITY_OFFSET_FRACTION, y * MINE_CITY_OFFSET_FRACTION]
        end

        # Explored mine tiles' asteroid-rock background, behind the
        # tile's own city/revenue circle. Counter-rotated for pointy
        # layout for the same reason as satellite_icon. `scale` shrinks
        # the whole rock (single- vs double-mine sizing); `offset`
        # recenters it on a specific city instead of hex-center.
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

        # A placed base's own art: a top-down rotating-ring station -- a
        # central core (where the tile's own city/token slot sits, drawn
        # on top of this -- see Hex#render's ordering), eight spokes out
        # to an outer habitat ring, grey-toned throughout per the user.
        RING_STATION_CORE_R = 28
        RING_STATION_HUB_R = 18
        RING_STATION_RING_R = 58
        RING_STATION_RING_WIDTH = 9
        RING_STATION_SPOKE_WIDTH = 6
        RING_STATION_SPOKE_COUNT = 8
        # The same refueling-station teardrop used for the map's station-
        # slot marker/per-corp station icons (see public/icons/g_2038/
        # station_slot.svg and *_station.svg), reused here superimposed on
        # one ring segment instead of a plain docking-module rectangle --
        # per the user, ties the base's own art back to the same station
        # iconography used everywhere else on the map.
        REFUEL_TEARDROP_PATH = 'M50 12 C38 30 25 48 25 65 A25 25 0 1 0 75 65 C75 48 62 30 50 12 Z'

        # White and unlabeled while the base's refueling slot is still
        # unclaimed, the owning corp's own color and initials once
        # someone buys a station there (Game#place_station!/
        # refueling_station_owner). Read live off game state so it stays
        # in sync as the station changes hands.
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

        # Spoke index the teardrop sits on (spokes land every 45 degrees
        # from 12 o'clock) -- chosen so it lands in the 7:30-9:00 gap,
        # clear of the core/token, the other modules, and (for pointy
        # layout, which adds a whole-group -30 degree rotation) the
        # hex's own edges.
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
          # Centered directly on spoke REFUEL_TEARDROP_SLOT (7:30) rather
          # than a module gap, superimposed over that ring segment --
          # rotated 180 degrees around its own center so the pivot is the
          # teardrop's own visual center, not the ring-anchor point.
          # Omitted entirely for a base that can never have a refueling
          # station at all (the edge-touching starting bases -- VP/LE/MM/
          # OPC/RCC -- see Game#station_eligible?) -- drawing the white
          # "unclaimed slot" teardrop there would imply a station could
          # still be bought, which it never can.
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

        # Opt-in hooks: while BuyInfrastructure is actively choosing where
        # to place a base or refueling station, the entity's own
        # already-placed bases/stations light up so the player can see at
        # a glance where they already have infrastructure. Bases and
        # stations use different marker shapes (existing_infrastructure_
        # highlight/existing_station_highlight) so a hex with both reads
        # as both, not one generic highlight.
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
          # HIGHLIGHT_POINTS/HIGHLIGHT_STROKE_WIDTH are Hex's own constants
          # (hex.rb), not this class's -- a bare reference here resolves
          # via HexDecorations' OWN lexical scope, not the host's, so it
          # would never find them. Full View::Game::Hex:: qualification is
          # required, not just stylistic.
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

        # Center point of the ring station's own teardrop icon (see
        # ring_station/REFUEL_TEARDROP_SLOT) -- needed as an actual
        # numeric point, not a transform string like ring_station uses,
        # because a highlight circle needs a literal center.
        def teardrop_position
          rotation = @hex.layout == :pointy ? -30 : 0
          angle = (rotation + (REFUEL_TEARDROP_SLOT * (360 / RING_STATION_SPOKE_COUNT))) * Math::PI / 180
          [RING_STATION_RING_R * Math.sin(angle), -RING_STATION_RING_R * Math.cos(angle)]
        end

        STATION_HIGHLIGHT_RADIUS = 35

        # A dashed yellow circle around the base's own teardrop icon,
        # instead of existing_infrastructure_highlight's hex-border --
        # deliberately a different shape so a highlighted station reads as
        # visibly different from a highlighted base at a glance, per the
        # user.
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

        # Opt-in hook: which pending Auto/Suggest Route pickups (if any)
        # land on this hex -- one entry per mine_idx claimed here, or
        # :transship for a transshipment credit -- see Step::Route#
        # suggested_pickups_for_hex. Empty for every other game/step.
        def suggested_pickup_entries
          step = @game.round&.active_step
          return [] unless step.respond_to?(:suggested_pickups_for_hex)

          step.suggested_pickups_for_hex(@game.current_entity, @hex.id)
        end

        PICKUP_HIGHLIGHT_SIZE = 40

        # A yellow square centered on the specific mine (or, for a
        # transshipment credit, hex-center) a pending suggested route
        # plans to pick up here -- double-mine tiles need the same per-
        # city offset asteroid_rock/mine_city_position already use, since
        # "this hex" isn't precise enough once it has two separate mines.
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
