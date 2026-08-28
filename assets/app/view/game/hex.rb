# frozen_string_literal: true

require 'lib/hex'
require 'lib/hex_choice_popup'
require 'lib/settings'
require 'lib/tile_selector'
require 'view/game/actionable'
require 'view/game/runnable'
require 'view/game/tile'
require 'view/game/triangular_grid'
require 'view/game/tile_unavailable'

module View
  module Game
    class Hex < Snabberb::Component
      include Actionable
      include Runnable
      include Lib::Settings

      SIZE = 100

      FRAME_COLOR_STROKE_WIDTH = 10
      FRAME_COLOR_POINTS = Lib::Hex.points(scale: 1 - (((FRAME_COLOR_STROKE_WIDTH + 1) / 2) / Lib::Hex::Y_B)).freeze

      HIGHLIGHT_STROKE_WIDTH = 6
      HIGHLIGHT_POINTS = Lib::Hex.points(scale: 1 - (((HIGHLIGHT_STROKE_WIDTH + 1) / 2) / Lib::Hex::Y_B)).freeze

      LAYOUT = {
        flat: [SIZE * 3 / 2, SIZE * Math.sqrt(3) / 2],
        pointy: [SIZE * Math.sqrt(3) / 2, SIZE * 3 / 2],
      }.freeze

      needs :hex
      needs :tile_selector, default: nil, store: true
      needs :role, default: :map
      needs :opacity, default: nil
      needs :user, default: nil, store: true

      needs :clickable, default: false
      needs :actions, default: []
      needs :entity, default: nil
      needs :unavailable, default: nil
      needs :routes, default: []
      needs :start_pos, default: [1, 1]
      needs :highlight, default: false

      def render
        return '' if @hex.empty

        @selected = @hex == @tile_selector&.hex || @selected_route&.last_node&.hex == @hex
        @tile =
          if @selected && @actions.include?('lay_tile') && @tile_selector&.tile
            @tile_selector.tile
          else
            @hex.tile
          end

        children = hex_outline
        if (color = @tile&.frame&.color)
          attrs = {
            stroke: color,
            'stroke-width': FRAME_COLOR_STROKE_WIDTH,
            points: FRAME_COLOR_POINTS,
          }
          children << h(:polygon, attrs: attrs)

          if (color2 = @tile&.frame&.color2)
            attrs = {
              stroke: color2,
              'stroke-width': FRAME_COLOR_STROKE_WIDTH,
              pathLength: 576,
              'stroke-dasharray': 32,
              'stroke-dashoffset': 16,
              'fill-opacity': 0,
              points: FRAME_COLOR_POINTS,
            }
            children << h(:polygon, attrs: attrs)
          end
        end
        children << hex_highlight if @highlight
        children << existing_infrastructure_highlight if existing_base_hex?
        children << existing_station_highlight if existing_station_hex?
        suggested_pickup_entries.each { |entry| children << pickup_highlight_square(entry) }

        if (color = @tile&.stripes&.color)
          stripes = Lib::Hex.stripe_points.map do |stripe|
            attrs = {
              fill: Lib::Hex::COLOR[color],
              points: stripe,
            }
            h(:polygon, attrs: attrs)
          end
          attrs = @hex.layout == :flat ? { attrs: { transform: 'rotate(60)' } } : {}
          children << h(:g, attrs, stripes)
        end

        # Opt-in hooks: a game can paint a hex with something richer than
        # a flat color (e.g. G2038's starfield pattern for still-
        # unexplored hexes, explored mines, base stations, and
        # transshipment points -- see Game#hex_fill_override/mine_tile?/
        # base_tile?/transshipment_hex?/starfield_defs below) and/or
        # draw extra art behind the tile's own city/revenue circle (the
        # asteroid rock for a mine, the ring station for a base, the
        # satellite for a transshipment point). Every other game doesn't
        # implement these, so behavior is unchanged for them. Each hex
        # that wants the starfield gets its own <defs><pattern>
        # (starfield_defs), rotated by its own angle, so adjacent hexes
        # don't visibly share the same tiling grid.
        is_mine = @game.respond_to?(:mine_tile?) && @game.mine_tile?(@tile)
        is_base = @game.respond_to?(:base_tile?) && @game.base_tile?(@tile)
        is_transshipment = @game.respond_to?(:transshipment_hex?) && @game.transshipment_hex?(@hex.id)
        wants_starfield = (@game.respond_to?(:hex_fill_override) && @game.hex_fill_override(@tile)) || is_transshipment
        children << starfield_defs if wants_starfield
        # Drawn before Tile below so the tile's own city/revenue
        # circle(s) -- the printed mine value(s) -- paint on top of the
        # rock(s), exactly like the physical tiles' own art (per the
        # user). A single-mine tile gets one rock at hex-center, scaled
        # down (its city already sits there with no offset needed); a
        # double-mine tile gets one smaller rock per city, each
        # centered on that city's own position (see
        # mine_city_position) instead of one big shared rock.
        if is_mine
          if @game.mine_count(@tile) == 2 && @tile.cities.size == 2
            @tile.cities.each_with_index do |city, index|
              children << asteroid_rock(scale: MINE_DOUBLE_SCALE, offset: mine_city_position(city),
                                         key: "g2038-asteroid-#{index}")
            end
          else
            children << asteroid_rock(scale: MINE_SINGLE_SCALE, key: 'g2038-asteroid-0')
          end
        end
        # Same reasoning: drawn before Tile so the base's own token
        # (its one city, always hex-centered -- see '2023' in map.rb)
        # paints on top, sitting in the station's central core.
        children << ring_station if is_base

        if @tile
          children << h(
            Tile,
            tile: @tile,
            show_coords: setting_for(:show_coords, @game) && (@role == :map),
            show_tiles: setting_for(:show_tiles, @game) && (@role == :map),
            routes: @routes,
            game: @game
          )
        end
        children << h(TriangularGrid) if Lib::Params['grid']
        children << h(TileUnavailable, unavailable: @unavailable, layout: @hex.layout) if @unavailable

        children << satellite_icon if is_transshipment

        props = {
          key: @hex.id,
          attrs: {
            transform: transform,
            fill: (wants_starfield ? "url(##{starfield_pattern_id})" : nil) ||
              color_for(@tile&.color) || (Lib::Hex::COLOR[@tile&.color || 'white']),
            stroke: 'black',
          },
        }

        props[:attrs][:opacity] = @opacity if @opacity
        props[:attrs][:cursor] = 'pointer' if @clickable

        props[:on] = { click: ->(e) { on_hex_click(e) } }
        props[:attrs]['stroke-width'] = 5 if @selected

        h(:g, props, children)
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
        [14, 76, 0.8, 0.6], [33, 15, 0.5, 0.4], [55, 78, 1.1, 0.85], [8, 25, 0.6, 0.5],
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

      # A simple generative satellite -- body, ring-dish antenna on a
      # stalk, and two paneled solar wings -- echoing the relay-station
      # art on the physical transshipment-point tiles (a ring-shaped
      # dish is the distinctive feature there), not a reproduction of
      # it. Sits at hex-center (0, 0 in this component's own local
      # coordinate space); the printed revenue box is pushed to the
      # bottom of the hex instead (see Game#offboard_forced_bottom?,
      # part/revenue.rb) so the two don't collide. Drawn after Tile in
      # the children order so it layers over the starfield background.
      #
      # Counter-rotated by -30 for pointy layout: this whole icon is a
      # sibling of Tile within the hex's own <g>, which itself carries
      # a `rotate(30)` for pointy hexes (see `transform` above) --
      # normal tile content (cities, revenue boxes) renders through
      # Part::Base's own rotation_for_layout, which already cancels
      # that out, but a raw sibling shape like this one doesn't get
      # that for free and was rendering visibly tilted as a result.
      # 30% larger than the icon's own natural (drawn-at-1x) size, then
      # another 30% on top of that (1.3 * 1.3).
      SATELLITE_SCALE = 1.3 * 1.3

      def satellite_icon
        rotation = @hex.layout == :pointy ? -30 : 0
        h(:g, { key: 'g2038-satellite', attrs: { transform: "rotate(#{rotation}) scale(#{SATELLITE_SCALE})" } }, [
            # horizontal boom, spanning most of the width, with darker
            # paneled segments at each end -- closer to the physical
            # tiles' own compact, integrated satellite silhouette than
            # the earlier separate-wings-and-boxy-body layout
            h(:rect, attrs: { x: -32, y: -4, width: 64, height: 8, fill: '#c9ccd1', stroke: '#5a5f66',
                               'stroke-width': 1.25 }),
            h(:rect, attrs: { x: -32, y: -4, width: 14, height: 8, fill: '#3a6b8a', stroke: '#1a3a4a',
                               'stroke-width': 1 }),
            h(:rect, attrs: { x: 18, y: -4, width: 14, height: 8, fill: '#3a6b8a', stroke: '#1a3a4a',
                               'stroke-width': 1 }),
            # central hub
            h(:rect, attrs: { x: -6, y: -9, width: 12, height: 18, rx: 2, fill: '#c9ccd1', stroke: '#5a5f66',
                               'stroke-width': 1.5 }),
            # short stalk up to the ring dish, mounted centrally above
            # the boom rather than off to one side
            h(:line, attrs: { x1: 0, y1: -9, x2: 0, y2: -18, stroke: '#c9ccd1', 'stroke-width': 1.5 }),
            # ring dish, viewed at an angle (a flattened ellipse), with a
            # small center hub -- the "ring" look, per the physical tiles
            h(:ellipse, attrs: { cx: 0, cy: -25, rx: 12, ry: 7, fill: 'none', stroke: '#e8ecef',
                                  'stroke-width': 2.25 }),
            h(:circle, attrs: { cx: 0, cy: -25, r: 1.5, fill: '#e8ecef' }),
          ])
      end

      # A large, roughly circular silhouette built from overlapping
      # circles (a common, simple way to get an organic/irregular blob
      # outline out of plain SVG shapes rather than hand-authored path
      # data) -- not randomized, same reasoning as the starfield's own
      # star positions: pure decoration, no determinism/replay concern,
      # hand-placed to avoid an obviously-regular outline. [x, y,
      # radius], all relative to hex-center.
      ASTEROID_BUMPS = [
        [0, -42, 52], [-36, -12, 46], [34, -16, 44], [-22, 28, 46], [24, 32, 42], [0, 6, 50],
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
        [40, -22, 15], [-30, 40, 13], [48, 22, 11],
      ].freeze

      # Single-mine tiles: one rock at hex-center, shrunk to 55% (per
      # the user: the original full size was too dominant next to the
      # single revenue circle; +10% from an initial 50% once seen live).
      # Double-mine tiles: two smaller rocks, each centered on its own
      # city/circle instead of hex-center -- sized enough to actually
      # be visible around the circle without the two rocks overlapping
      # (the two cities sit ~78 units apart, see MINE_CITY_OFFSET_
      # FRACTION below; a first pass at ~1.2x the circle radius came out
      # far too small/fully hidden behind the circle once seen live).
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
      # approximation (not yet visually confirmed against the engine's
      # own city placement) -- adjust if the rocks don't land centered
      # on their circles once deployed.
      MINE_CITY_OFFSET_FRACTION = 0.45

      def mine_city_position(city)
        edge = @tile.preferred_city_town_edges[city]
        x, y = MINE_EDGE_MIDPOINTS[edge&.to_i]
        return [0, 0] unless x

        [x * MINE_CITY_OFFSET_FRACTION, y * MINE_CITY_OFFSET_FRACTION]
      end

      # Explored mine tiles' asteroid-rock background, behind whatever
      # the tile itself draws on top (its city/revenue circle -- the
      # printed mine value, see hex.rb#render's own ordering). A soft
      # offset shadow, the main gray body, an offset lighter highlight
      # (a simple fixed "light source" rather than anything per-hex-
      # varied), and the craters on top, in that paint order.
      # Counter-rotated for pointy layout for the same reason as
      # satellite_icon -- this is a raw sibling of Tile, not tile
      # content that goes through Part::Base's own rotation handling.
      # `scale` shrinks the whole rock (single- vs double-mine sizing);
      # `offset` recenters it on a specific city instead of hex-center.
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
      # on top of this -- see render()'s ordering), eight spokes out to
      # an outer habitat ring, grey-toned throughout per the user.
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

      # The teardrop's own fill/label -- white and unlabeled while the
      # base's refueling slot is still unclaimed, the owning corp's own
      # color and initials once someone actually buys a station there
      # (see Game#place_station!/refueling_station_owner). This is now
      # the *only* refueling-station indicator on a base hex -- the
      # older generic Part::Icon-based marker (public/icons/g_2038/
      # station_slot.svg / *_station.svg) was removed as redundant once
      # this existed. Read live off game state (not baked in at render
      # time) so it stays in sync as the station changes hands/gets
      # bought.
      def refuel_teardrop_shape
        owner = @game.respond_to?(:refueling_station_owner) && @game.refueling_station_owner(@hex.id)
        fill = owner ? owner.color : '#ffffff'
        stroke = owner ? '#000000' : '#3d4047'
        shape = [h(:path, attrs: { d: REFUEL_TEARDROP_PATH, fill: fill, stroke: stroke, 'stroke-width': 3 })]
        return shape unless owner

        text_attrs = {
          x: 50, y: 76, 'text-anchor': 'middle', 'font-weight': 700, 'font-size': 26,
          'font-family': 'Arial', fill: '#ffffff',
        }
        shape << h(:text, { attrs: text_attrs }, owner.id)
        shape
      end

      # Slot index whose gap the teardrop sits in -- spokes land at
      # every 45 degrees starting from 12 o'clock (i * 45), which
      # happens to put spoke 5 exactly at 7:30 and spoke 6 exactly at
      # 9:00, so the gap *between* those two spokes (slot index 5, the
      # module gap immediately clockwise of spoke 5) is the 7:30-9:00
      # gap the user asked for -- chosen so the teardrop doesn't
      # overlap the core/token, the other modules, or (for pointy-
      # layout hexes, which get an extra whole-group -30 degree
      # rotation) the hex's own edges.
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
              x: -5, y: -(RING_STATION_RING_R + 3), width: 10, height: 8, rx: 1.5,
              fill: '#6b6f78', stroke: '#3d4047', 'stroke-width': 0.75,
              transform: "rotate(#{(i * (360 / RING_STATION_SPOKE_COUNT)) + slot_angle})",
            })
        end
        # Centered directly on spoke REFUEL_TEARDROP_SLOT (7:30) rather
        # than a module gap, superimposed over that ring segment --
        # rotated 180 degrees around its own center (between the
        # ring-position translate and the path's own recentering
        # translate, so the pivot is the teardrop's own visual center,
        # not the ring-anchor point). Scale history, tuned live in
        # browser: 0.55 -> +50% -> 0.825 (too big, crossed the hex's own
        # edge) -> -5% -> 0.78375 -> -2% -> 0.767875.
        # Omitted entirely for a base that can never have a refueling
        # station at all (the edge-touching starting bases -- VP/LE/MM/
        # OPC/RCC -- see Game#station_eligible?) -- drawing the white
        # "unclaimed slot" teardrop there implied a station could still
        # be bought, which it never can. Found live in browser: those
        # bases showed the teardrop with no way to ever fill it.
        station_eligible = !@game.respond_to?(:station_eligible?) || @game.station_eligible?(@hex)
        teardrop =
          if station_eligible
            teardrop_angle = REFUEL_TEARDROP_SLOT * (360 / RING_STATION_SPOKE_COUNT)
            teardrop_transform = "rotate(#{teardrop_angle}) translate(0 #{-RING_STATION_RING_R}) rotate(180) " \
                                 'scale(0.767875) translate(-50 -50)'
            h(:g, { attrs: { transform: teardrop_transform } }, refuel_teardrop_shape)
          end

        h(:g, { key: 'g2038-ring-station', attrs: { transform: "rotate(#{rotation})" } }, [
            h(:circle, attrs: { cx: 0, cy: 0, r: RING_STATION_RING_R, fill: 'none',
                                 stroke: '#5c6068', 'stroke-width': RING_STATION_RING_WIDTH }),
            h(:circle, attrs: { cx: 0, cy: 0, r: RING_STATION_RING_R + (RING_STATION_RING_WIDTH / 2.0),
                                 fill: 'none', stroke: '#a7abb3', 'stroke-width': 1 }),
            h(:circle, attrs: { cx: 0, cy: 0, r: RING_STATION_RING_R - (RING_STATION_RING_WIDTH / 2.0),
                                 fill: 'none', stroke: '#3d4047', 'stroke-width': 1 }),
            *modules,
            *spokes,
            *[teardrop].compact,
            h(:circle, attrs: { cx: 0, cy: 0, r: RING_STATION_CORE_R, fill: '#9aa0aa',
                                 stroke: '#4a4e57', 'stroke-width': 2 }),
            h(:circle, attrs: { cx: 0, cy: 0, r: RING_STATION_HUB_R, fill: 'none',
                                 stroke: '#6b6f78', 'stroke-width': 1.5 }),
          ])
      end

      def hex_outline
        polygon_props = { attrs: { points: Lib::Hex::POINTS } }
        # Opt-in hook: only the hex boundary itself (this polygon), not
        # the ambient stroke every other child (mine/revenue/type-letter
        # circles) would otherwise inherit from the wrapping <g> in
        # render -- found live in browser: setting the <g>'s own stroke
        # to white turned every one of those circles' borders white too,
        # since none of them set an explicit stroke of their own and were
        # relying on inheriting the (previously black, so invisible-
        # looking) ambient value.
        if @game.respond_to?(:hex_border_color)
          polygon_props[:attrs][:stroke] = @game.hex_border_color
        end

        invisible_edges = @tile.borders.select { |b| b.type.nil? }.map(&:edge) if @tile
        if invisible_edges&.any?
          polygon_props[:attrs][:stroke] = 'none'
          shapes = [h(:polygon, polygon_props)]

          (Engine::Tile::ALL_EDGES - invisible_edges).each do |edge|
            shapes << h(:path, attrs: { d: Lib::Hex::EDGE_PATHS[edge] })
          end

          shapes
        else
          [h(:polygon, polygon_props)]
        end
      end

      def hex_highlight
        polygon_props = {
          attrs: {
            points: HIGHLIGHT_POINTS,
            'fill-opacity': 0,
            pathLength: 576, # 6*96, total length of polygon border => easier dasharray arithmetic
            'stroke-dasharray': 16,
            'stroke-dashoffset': 8,
            'stroke-width': HIGHLIGHT_STROKE_WIDTH,
          },
        }
        if (color = @tile&.frame&.color)
          polygon_props[:attrs]['stroke'] = contrast_on(color)
        end

        h(:polygon, polygon_props)
      end

      # Opt-in hooks: while a step is actively choosing where to place a
      # base or refueling station (G2038's BuyInfrastructure), the
      # entity's own already-placed bases/stations light up, so the
      # player can see at a glance where they already have
      # infrastructure before picking a new hex -- per the user. Reads
      # the active step directly rather than needing a dedicated per-hex
      # prop threaded through Map (the same respond_to?-gated pattern
      # used throughout this file), so every other game/step is
      # unaffected. Bases and stations use different marker shapes (see
      # existing_infrastructure_highlight/existing_station_highlight) so
      # the two read as different things at a glance rather than both
      # drawing the same generic hex-border highlight -- per the user, a
      # base hex that also happens to have a station gets both at once.
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
        h(:polygon, {
            key: 'g2038-existing-infra-highlight',
            attrs: {
              points: HIGHLIGHT_POINTS,
              'fill-opacity': 0,
              pathLength: 576,
              'stroke-dasharray': 16,
              'stroke-dashoffset': 8,
              'stroke-width': HIGHLIGHT_STROKE_WIDTH,
              stroke: '#ffd700',
            },
          })
      end

      # Center point of the ring station's own teardrop icon (see
      # ring_station/REFUEL_TEARDROP_SLOT), in the same unrotated local
      # coordinate frame every other raw sibling shape in this file uses
      # -- derived the same way that art positions itself: rotate(rotation)
      # composed with rotate(teardrop_angle), applied to the point
      # straight "up" from center at RING_STATION_RING_R, since a pure
      # rotation composition is just the sum of the angles. Needed here
      # (rather than reusing a transform string like ring_station does)
      # because a highlight circle needs its actual numeric center, not
      # just a transform to nest inside.
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
              cx: ox, cy: oy, r: STATION_HIGHLIGHT_RADIUS,
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

      def translation
        x, y = coordinates
        "translate(#{x}, #{y})"
      end

      def self.coordinates(hex, start_pos = [1, 1])
        t_x, t_y = LAYOUT[hex.layout]
        [((t_x * (hex.x - start_pos[0] + 1)) + SIZE).round(2), ((t_y * (hex.y - start_pos[1] + 1)) + SIZE).round(2)]
      end

      def coordinates
        self.class.coordinates(@hex, @start_pos)
      end

      def transform
        "#{translation}#{@hex.layout == :pointy ? ' rotate(30)' : ''}"
      end

      def on_hex_click
        return if @actions.empty? && @role != :tile_page

        if !@clickable || (@hex == @tile_selector&.hex && !(@tile_selector.respond_to?(:tile) && @tile_selector.tile))
          return store(:tile_selector, nil)
        end

        nodes = @hex.tile.nodes

        if @actions.include?('run_routes')
          touch_node(nodes[0]) if nodes.one?
          disambiguate_node(nodes) if nodes.count(&:offboard?) > 1
          return
        end

        case @role
        when :map
          if @actions.include?('assign')
            step = @game.round.active_step(@entity)
            if step.respond_to?(:needs_city_selection?) && @entity && step.needs_city_selection?(@entity, @hex)
              # First click on Atlanta: dispatch action (logs message, sets pending state).
              # Re-store selected_company before rAF fires so player can immediately click a city.
              process_action(Engine::Action::Assign.new(@entity, target: @hex))
              store(:selected_company, @entity, skip: true)
              return
            end

            if step.respond_to?(:pending_city_selection?) && @entity && step.pending_city_selection?(@entity, @hex)
              return # already pending; city slot clicks handle the city choice
            end

            process_action(Engine::Action::Assign.new(@entity, target: @hex))
            return store(:selected_company, nil, skip: true)
          end

          step = @game.round.active_step
          if @actions.include?('remove_hex_token') &&
              step.can_remove_hex_token?(@entity, @hex)
            return process_action(Engine::Action::RemoveHexToken.new(
              @entity,
              hex: @hex,
            ))
          end
          if @actions.include?('hex_token')
            return if step.available_tokens(@entity).empty?

            next_token = step.available_tokens(@entity)[0].type
            return process_action(Engine::Action::HexToken.new(
              @entity,
              hex: @hex,
              cost: step.token_cost_override(@entity, @hex, nil, @entity.find_token_by_type(next_token&.to_sym)),
              token_type: next_token
            ))
          end
          if @actions.include?('choose') && step.choices.include?(@hex.id)
            if step.respond_to?(:hex_choice_popup) && @entity && (popup = step.hex_choice_popup(@entity, @hex))
              return store(:tile_selector, Lib::HexChoicePopup.new(@hex, popup, coordinates, root, @entity, @role))
            end

            choice = @hex.id
            dispatch = lambda do
              process_action(Engine::Action::Choose.new(@entity, choice: choice))
            end

            if (consenter = @game.consenter_for_choice(@entity, choice, step.choices[choice]))
              return check_consent(@entity, consenter, dispatch)
            end

            return dispatch.call
          end
          return unless @actions.include?('lay_tile')

          if @selected && (tile = @tile_selector&.tile)
            @tile_selector.rotate! if tile.hex != @hex
          else
            store(:tile_selector, Lib::TileSelector.new(@hex, @tile, coordinates, root, @entity, @role))
          end
        when :tile_page
          store(:tile_selector, Lib::TileSelector.new(@hex, @tile, coordinates, root, @entity, @role))
        when :tile_selector
          @tile_selector.tile = @tile
        end
      end
    end
  end
end
