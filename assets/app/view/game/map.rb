# frozen_string_literal: true

require '../lib/storage'
require '../lib/settings'
require 'view/game/axis'
require 'view/game/hex'
require 'view/game/hex_choice_popup'
require 'view/game/map_legend'
require 'view/game/tile_confirmation'
require 'view/game/tile_selector'
require 'view/game/token_selector'

module View
  module Game
    class Map < Snabberb::Component
      include Lib::Settings
      needs :game, store: true
      needs :tile_selector, default: nil, store: true
      needs :selected_route, default: nil, store: true
      needs :selected_company, default: nil, store: true
      needs :selected_combos, default: nil, store: true
      needs :opacity, default: nil
      needs :show_starting_map, default: false, store: true
      needs :routes, default: [], store: true
      needs :historical_laid_hexes, default: nil, store: true
      needs :historical_routes, default: [], store: true
      # G2038-specific "Show Last Route" data: an array of hex-id arrays,
      # one per ship, straight from Game#last_route -- the standard
      # :historical_routes store holds Engine::Route objects keyed on
      # connection_hexes/halts/nodes, none of which G2038 ever populates
      # (see route_controls' own comment), so this is a parallel,
      # G2038-only store MapControls fills in instead. No tile/highlight
      # counterpart (:historical_laid_hexes) -- per the user, only the
      # route lines themselves are wanted here, not a tile-reveal effect.
      needs :historical_ship_routes, default: [], store: true
      needs :map_zoom, default: nil, store: true

      EDGE_LENGTH = 50
      SIDE_TO_SIDE = 87
      FONT_SIZE = 25
      GAP = 25 # GAP between the row/col labels and the map hexes
      SCALE = 0.5 # Scale for the map

      def compute_axes(hexes)
        min, max = hexes.minmax
        ((min.next)..(max.next)).to_a
      end

      def render
        return h(:div, []) if (@layout = @game.layout) == :none

        @hexes = @show_starting_map ? @game.clone([]).hexes : @game.hexes.dup

        axes_hexes = @hexes.reject(&:ignore_for_axes)
        @cols = compute_axes(axes_hexes.map(&:x))
        @rows = compute_axes(axes_hexes.map(&:y))

        @start_pos = [@cols.first, @rows.first]

        @scale = SCALE * map_zoom

        step = @game.round.active_step(@selected_company)
        current_entity = @selected_company || step&.current_entity
        combo_entities = (@selected_combos || []).map { |id| @game.company_by_id(id) }
        entity_or_entities = combo_entities.empty? ? current_entity : [current_entity, *combo_entities]
        actions = step&.actions(current_entity) || []

        unless (laid_hexes = @historical_laid_hexes)
          laid_hexes = @game.round.respond_to?(:laid_hexes) ? @game.round.laid_hexes : []
        end
        selected_hex = @tile_selector&.hex
        # Move the selected hex to the back so they render highest in z space
        @hexes << @hexes.delete(selected_hex) if @hexes.include?(selected_hex)

        @active_routes = @routes
        @active_routes = @historical_routes if @active_routes.none?

        @hexes.map! do |hex|
          clickable = @show_starting_map ? false : step&.available_hex(entity_or_entities, hex)
          opacity = clickable ? 1.0 : 0.5
          h(
            Hex,
            hex: hex,
            opacity: @show_starting_map ? 1.0 : (@opacity || opacity),
            entity: current_entity,
            clickable: clickable,
            actions: actions,
            routes: @active_routes,
            start_pos: @start_pos,
            highlight: laid_hexes.include?(hex),
          )
        end
        @hexes.compact!

        children = [render_map]

        if current_entity && @tile_selector
          left = (@tile_selector.x + map_x) * @scale
          top = (@tile_selector.y + map_y) * @scale
          selector =
            if @tile_selector.is_a?(Lib::TokenSelector)
              # 1882
              h(TokenSelector, zoom: map_zoom)
            elsif @tile_selector.is_a?(Lib::HexChoicePopup)
              width, height = map_size
              # Same edge-proximity idea TileSelector already uses below
              # (right_col/top_row/bottom_row) so the popup flips to
              # extend toward the opposite side instead of overflowing
              # past the map's own boundary -- found live in browser:
              # hexes near the right edge (e.g. column G/H) had their
              # buttons clipped by the map's own scrolling container,
              # since the popup always extended rightward (and upward)
              # from its anchor with no edge awareness. near_bottom_edge
              # uses a wider margin than the others -- a popup's *width*
              # is capped (POPUP_MAX_WIDTH), but wrapping means its
              # height grows with however many choices there are, so a
              # hex near the bottom needs more headroom to reliably avoid
              # clipping than one near the top/right ever does.
              h(HexChoicePopup, zoom: map_zoom,
                                 near_right_edge: width - left < HexChoicePopup::EDGE_MARGIN,
                                 near_top_edge: top < HexChoicePopup::EDGE_MARGIN,
                                 near_bottom_edge: height - top < HexChoicePopup::BOTTOM_EDGE_MARGIN)
            elsif @tile_selector.role != :map
              # Tile selector not for the map
            elsif @tile_selector.hex.tile != @tile_selector.tile
              h(TileConfirmation, zoom: map_zoom)
            else
              tiles = step.upgradeable_tiles(entity_or_entities, @tile_selector.hex)
              all_upgrades = @game.all_potential_upgrades(@tile_selector.hex.tile, selected_company: @selected_company)
              phase_colors = step.potential_tile_colors(current_entity, @tile_selector.hex)
              select_tiles = all_upgrades.map do |tile|
                real_tile = tiles.find { |t| t.name == tile.name }
                if real_tile
                  tiles.delete(real_tile)
                  [real_tile, nil]
                elsif !@game.tile_valid_for_phase?(tile, hex: @tile_selector.hex, phase_color_cache: phase_colors)
                  [tile, 'Later Phase']
                elsif @game.tiles.none? { |t| t.name == tile.name }
                  [tile, 'None Left']
                end
              end.compact

              # Add tiles that aren't part of all_upgrades (Mitsubishi ferry)
              select_tiles.append(*tiles.map { |t| [t, nil] })

              if select_tiles.empty?
                h(:div)
              else
                distance = TileSelector::DISTANCE * map_zoom
                width, height = map_size
                ts_ds = [TileSelector::DROP_SHADOW_SIZE - 5, 0].max # ignore up to 5px of ds (< 2vmin padding of #app)
                left_col = left < distance
                right_col = width - left < distance + ts_ds
                top_row = top < distance
                bottom_row = height - top < distance + ts_ds

                h(TileSelector, layout: @layout, tiles: select_tiles, actions: actions, zoom: map_zoom,
                                top_row: top_row, left_col: left_col, right_col: right_col, bottom_row: bottom_row)
              end
            end

          # Move the position to the middle of the hex
          props = {
            style: {
              position: 'absolute',
              left: "#{left}px",
              top: "#{top}px",
            },
          }
          # This needs to be before the map, so that the relative positioning works
          children.unshift(h(:div, props, [selector]))
        end

        props = {
          style: {
            overflow: 'auto',
            margin: '0.5rem 0 0 0',
            position: 'relative',
          },
        }

        map_elements = [h(MapZoom, map_zoom: map_zoom), h(:div, props, children), h(MapControls)]
        map_elements << h(MapLegend, game: @game) if @game.show_map_legend? && !@game.show_map_legend_on_left?

        h(:div, { style: { marginBottom: '1rem' } }, map_elements)
      end

      def map_x
        GAP + FONT_SIZE
      end

      def map_y
        GAP + (@layout == :flat ? (FONT_SIZE / 2) : FONT_SIZE)
      end

      def map_size
        if @layout == :flat
          [((((@cols.size * 1.5) + 0.5) * EDGE_LENGTH) + (2 * GAP)) * map_zoom,
           ((((@rows.size / 2) + 0.5) * SIDE_TO_SIDE) + (2 * GAP)) * map_zoom]
        else
          [(((((@cols.size / 2) + 0.5) * SIDE_TO_SIDE) + (2 * GAP)) + 1) * map_zoom,
           ((((@rows.size * 1.5) + 0.5) * EDGE_LENGTH) + (2 * GAP)) * map_zoom]
        end
      end

      def render_map
        width, height = map_size

        props = {
          attrs: {
            id: 'map',
            width: width.to_s,
            height: height.to_s,
          },
        }

        h(:svg, props, [
          h(:g, { attrs: { transform: "scale(#{@scale})" } }, [
            h(:g, { attrs: { id: 'map-hexes', transform: "translate(#{map_x} #{map_y})" } }, @hexes),
            h(:g, { attrs: { transform: "translate(#{map_x} #{map_y})" } }, render_route_lines),
            h(:g, { attrs: { transform: "translate(#{map_x} #{map_y})" } }, render_ship_marker),
            h(Axis,
              cols: @cols,
              rows: @rows,
              axes: @game.axes,
              layout: @layout,
              font_size: FONT_SIZE,
              gap: GAP,
              map_x: map_x,
              map_y: map_y,
              start_pos: @start_pos),
          ]),
        ])
      end

      # Draws a colored polyline hex-center to hex-center for routes that
      # aren't track/path-based (route.paths.empty? with 2+ stops) -- e.g.
      # G2038's hex-list spaceship routes, which have no tile paths for
      # Part::Track to color. Reuses the same ROUTE_COLORS palette as track
      # highlighting so the look is consistent with standard train routes.
      # Also draws the current entity's in-progress trace live, before it's
      # finished into a real route, via the optional `live_route_hexes` hook,
      # and any of the current entity's already-finished routes still
      # pending for this OR turn via the optional `current_turn_routes`
      # hook, so a multi-ship corp's earlier flights don't vanish from the
      # map the instant each one lands. Looked up by scanning `round.steps`
      # rather than `round.active_step`, since the step offering these hooks
      # (Route) may no longer be the *active* one -- it stops blocking once
      # done, while later steps in the same turn (Dividend, BuyTrain, ...)
      # become active in its place -- but its already-finished routes
      # should stay visible until the turn actually ends. Both hooks are
      # gated the same opt-in way (only G2038's Route step defines them
      # today), matching the convention used by ShipSelector/HexChoicePopup.
      def render_route_lines
        step = @game.round.steps.find { |s| s.respond_to?(:live_route_hexes) }
        return [] if !step && @historical_ship_routes.empty?

        routes = []

        # "Show Last Route For" (MapControls#route_controls, G2038 branch)
        # -- one entry per ship, straight from Game#last_route via the
        # :historical_ship_routes store. Drawn the exact same way live
        # routes are (below), just from a different, player-selected
        # source rather than the current turn's own state. Unlike the
        # live data below, not gated on `step` existing -- a player might
        # want to check last OR's routes during a Stock round, where
        # G2038's Route step isn't even in the round's step list. No
        # train on hand here (just a stored hex list), so these fall back
        # to plain draw-order coloring rather than route_color_index.
        @historical_ship_routes.each do |hex_ids|
          hexes = hex_ids.map { |id| @game.hex_by_id(id) }.compact
          routes << [hexes, routes.size] if hexes.size > 1
        end

        return finish_route_lines(routes) unless step

        # Not @active_routes -- that's the generic engine's own :routes/
        # :historical_routes store, meant for the standard path-based
        # RouteSelector. G2038's routes are always paths.empty? (a plain
        # hex list, see hex_route_elements' own comment), so the only real
        # way they'd show up there is a leak, and there is one:
        # View::Game::Dividend#render unconditionally does
        # `store(:routes, @step.routes)`, and Engine::Step::Dividend#routes
        # just returns @round.routes -- the exact same array
        # current_turn_routes below already reads. That put every G2038
        # route in @active_routes AND current_turn_routes at once, each
        # under a different color index, which made a route look bordered
        # by a color that had nothing to do with the other real route --
        # found live in browser as an unexplained "border" on ships whose
        # paths didn't actually overlap. current_turn_routes is already
        # the complete, authoritative source for this entity's routes this
        # turn; @active_routes has never had anything to add for a
        # G2038-style step (this whole method is unreachable for any other
        # game -- see the live_route_hexes guard above).
        entity = @game.round.current_entity
        color_index_for = lambda do |train|
          return routes.size unless train && step.respond_to?(:route_color_index)

          step.route_color_index(entity, train) || routes.size
        end

        if step.respond_to?(:current_turn_routes)
          step.current_turn_routes(entity).each do |route|
            next unless route.hexes.size > 1 && route.paths.empty?

            routes << [route.hexes, color_index_for.call(route.train)]
          end
        end

        live_hexes = step.live_route_hexes(entity)
        if live_hexes && live_hexes.size > 1
          live_train = step.respond_to?(:current_train) ? step.current_train(entity) : nil
          routes << [live_hexes, color_index_for.call(live_train)]
        end

        # "Show every unrun ship's own passively-previewed prior route"
        # (see Step::Route#previewed_ship_routes/ship_rows) -- each keyed
        # by its own train, so its color always matches that ship's own
        # row swatch (route_color_index) regardless of how many routes
        # are drawn this pass, rather than drifting with draw-order
        # position -- found live in browser: an already-submitted route
        # and a ship's own in-progress route swapped colors the moment
        # the drawn set's size changed shape between renders.
        if step.respond_to?(:previewed_ship_routes)
          step.previewed_ship_routes(entity).each do |train, hexes|
            routes << [hexes, color_index_for.call(train)] if hexes.size > 1
          end
        end

        # A live Auto-all run's CURRENT best for whichever ship it's
        # actively searching -- drawn dashed (see finish_route_lines'
        # `dashed:` param) so it visibly reads as "still under test," not
        # a settled route. Only ever refreshed when @best actually
        # improves (see ship_selector.rb's run_auto_route_all_tick!),
        # never on a timer or every combo -- a full map re-render is
        # genuinely expensive (see start_auto_route_clock!'s own comment
        # on why the live counter avoids one every tick), so this only
        # costs what a real improvement is worth, and improvements get
        # rarer as a search goes on (see OptimalAutorouter#found_at_ratio).
        if step.respond_to?(:auto_route_all_preview_hexes)
          preview_train, preview_hexes = step.auto_route_all_preview_hexes(entity)
          if preview_hexes && preview_hexes.size > 1
            routes << [preview_hexes, color_index_for.call(preview_train), true]
          end
        end

        finish_route_lines(routes)
      end

      # Side-by-side lanes, not stacked widths -- a ship can double back
      # over the very edge it just flew (out to a mine, home to refuel,
      # back out the same way), so the same route can share an edge with
      # *itself* more than once, on top of however many other ships also
      # cross it. Nesting reads fine for two lines but has no way to show
      # three-plus distinct passes; a hex is wide enough to hold several
      # equal-width lanes side by side instead. Confirmed with the user
      # via a worked triple-back/double-back example before building
      # this. Shared by both the live-turn path and the historical-only
      # (no active Route step, e.g. viewing last OR's routes during a
      # Stock round) early return above.
      def finish_route_lines(routes)
        edge_routes = hex_route_edge_indexes(routes)

        routes.each_with_index.flat_map do |(hexes, color_index, dashed), slot|
          hex_route_elements(hexes, slot, color_index, edge_routes, dashed: dashed)
        end
      end

      # {edge_key => [slot, slot, ...]} for every hex-to-hex hop across
      # all routes being drawn this pass, one entry per traversal --
      # direction-independent (A-B and B-A are the same physical edge)
      # and in strict processing order (every one of route 0's own hops
      # before any of route 1's), so a route's own repeated crossings of
      # the same edge (a backtrack) always land in adjacent lanes rather
      # than interleaved with another route's. Keyed by draw-order slot,
      # not color_index -- lane-sharing is about "how many routes touch
      # this edge this pass," unrelated to which color each one gets.
      def hex_route_edge_indexes(routes)
        edges = Hash.new { |h, k| h[k] = [] }
        routes.each_with_index do |(hexes, _color_index), slot|
          hexes.each_cons(2) { |a, b| edges[edge_key(a, b)] << slot }
        end
        edges
      end

      def edge_key(hex_a, hex_b)
        [hex_a.id, hex_b.id].sort.join('-')
      end

      # One polyline (plus one direction arrow) per hop, offset into its
      # own lane whenever this edge sees more than one crossing -- from
      # this route backtracking over itself, a different route sharing the
      # same edge, or both at once (see hex_route_segment_offset). `slot`
      # is this route's draw-order position this pass (used only for lane
      # sharing/keys); `color_index` is its stable per-ship color (see
      # render_route_lines' color_index_for) -- kept separate so a route's
      # color never drifts just because the number of routes drawn this
      # pass happened to change. Also the only case (today) with no tile
      # paths to already show a direction implicitly via tile orientation
      # -- confirmed with the user other games' station-to-station routes
      # don't need arrows.
      def hex_route_elements(hexes, slot, color_index, edge_routes, dashed: false)
        color = route_prop(color_index, :color)
        width = route_prop(color_index, :width)
        seen = Hash.new(0)

        hexes.each_cons(2).flat_map do |hex_a, hex_b|
          key = edge_key(hex_a, hex_b)
          occurrence = seen[key]
          seen[key] += 1

          offset = hex_route_segment_offset(slot, occurrence, edge_routes[key])
          (ox1, oy1), (ox2, oy2) = offset_points(hex_a, hex_b, offset)
          elem_key = "route_#{slot}_#{key}_#{occurrence}"

          [hex_route_polyline(ox1, oy1, ox2, oy2, color, width, "#{elem_key}_line", dashed: dashed),
           hex_route_arrow(ox1, oy1, ox2, oy2, color, "#{elem_key}_arrow")]
        end
      end

      # Perpendicular distance (in the same coordinate units as
      # Hex.coordinates) to shift this specific hop -- 0 unless this edge
      # sees more than one crossing total. `occurrence` is which crossing
      # *of this edge, by this route* this hop is (0 the first time this
      # route touches it, 1 the second/backtrack, ...); combined with
      # edge_routes' strict per-route ordering, nth_occurrence_index finds
      # exactly which of the edge's N lanes this hop belongs in, and every
      # lane gets spread evenly around the edge's own centerline. Direction
      # is handled entirely in offset_points, not here -- this is a plain
      # lane number, the same regardless of which way any particular hop
      # happens to travel.
      LANE_SPACING = 14

      def hex_route_segment_offset(index, occurrence, sharing)
        return 0 if sharing.size <= 1

        lane = nth_occurrence_index(sharing, index, occurrence)
        (lane - ((sharing.size - 1) / 2.0)) * LANE_SPACING
      end

      # Position of the (0-indexed) `n`th occurrence of `value` in `array`.
      def nth_occurrence_index(array, value, n)
        count = -1
        array.each_with_index do |v, i|
          next unless v == value

          count += 1
          return i if count == n
        end
        nil
      end

      # Shifts this hop's own two endpoints perpendicular to the edge by
      # `offset` units. The perpendicular is computed from the edge's
      # canonical direction (sorted hex-id order) rather than this hop's
      # own travel direction, and applied identically either way -- using
      # each hop's own direction instead would flip the perpendicular's
      # sign for a reversed hop, silently cancelling out the very
      # separation the lane number was supposed to produce. That's exactly
      # what a backtrack does (out one way, back the other, same edge):
      # with a direction-dependent perpendicular, the outbound and return
      # passes collapsed onto the same offset instead of landing on
      # opposite sides -- found by hand-checking the lane math against a
      # real triple-back before wiring this into the renderer.
      def offset_points(hex_a, hex_b, offset)
        (x1, y1) = Hex.coordinates(hex_a, @start_pos)
        (x2, y2) = Hex.coordinates(hex_b, @start_pos)
        return [[x1, y1], [x2, y2]] if offset.zero?

        canon_a, canon_b = hex_a.id <= hex_b.id ? [hex_a, hex_b] : [hex_b, hex_a]
        (cx1, cy1) = Hex.coordinates(canon_a, @start_pos)
        (cx2, cy2) = Hex.coordinates(canon_b, @start_pos)
        dx = cx2 - cx1
        dy = cy2 - cy1
        length = Math.sqrt((dx * dx) + (dy * dy))
        return [[x1, y1], [x2, y2]] if length.zero?

        perp_x = -dy / length * offset
        perp_y = dx / length * offset
        [[x1 + perp_x, y1 + perp_y], [x2 + perp_x, y2 + perp_y]]
      end

      # `dashed:` -- per the user, a live Auto-all search's current best
      # (still being improved on/proven, not yet a settled route) should
      # read visibly differently from a real route on the map, not just
      # share its ship's solid-line color. A dash pattern in the same
      # stroke-width units as the line itself, so it stays proportional
      # at any zoom level rather than a fixed pixel dash looking
      # inconsistently chunky or fine.
      def hex_route_polyline(x1, y1, x2, y2, color, width, key, dashed: false)
        attrs = {
          points: "#{x1},#{y1} #{x2},#{y2}",
          fill: 'none',
          stroke: color,
          'stroke-width': width,
          'stroke-linecap': 'round',
          'stroke-linejoin': 'round',
        }
        attrs['stroke-dasharray'] = "#{width * 2},#{width * 1.5}" if dashed
        h(:polyline, key: key, attrs: attrs)
      end

      ROUTE_ARROW_POSITION = 0.4 # fraction along each hop, biased just short of the shared edge
      # Hexes are drawn ~150-200 units wide (Hex::SIZE = 100) in this same
      # coordinate space -- the original 12x9 arrow was under 10% of that
      # and effectively invisible against a real map. Sized to be clearly
      # readable at a normal zoom level without swallowing the hex it
      # sits in. Fixed size regardless of lane count -- unlike the earlier
      # stacked-width approach this replaced, every lane renders at the
      # same width, so there's no per-hop scale to match anymore.
      ROUTE_ARROW_LENGTH = 36
      ROUTE_ARROW_WIDTH = 24

      def hex_route_arrow(x1, y1, x2, y2, color, key)
        cx = x1 + ((x2 - x1) * ROUTE_ARROW_POSITION)
        cy = y1 + ((y2 - y1) * ROUTE_ARROW_POSITION)
        angle = Math.atan2(y2 - y1, x2 - x1)

        h(:polygon, key: key, attrs: { points: arrow_triangle_points(cx, cy, angle), fill: color })
      end

      # A small triangle pointing along +x by default (tip at
      # +half-length, base centered on the origin), rotated to `angle`
      # and translated to (cx, cy) -- standard 2D rotation matrix, done
      # by hand since Snabberb/SVG has no built-in "rotate this shape"
      # primitive for a plain polygon (unlike a `transform` on a whole
      # group, which would also rotate anything else sharing it).
      def arrow_triangle_points(cx, cy, angle)
        cos_a = Math.cos(angle)
        sin_a = Math.sin(angle)
        half_len = ROUTE_ARROW_LENGTH / 2.0
        half_width = ROUTE_ARROW_WIDTH / 2.0

        [[half_len, 0], [-half_len, half_width], [-half_len, -half_width]].map do |x, y|
          rx = ((x * cos_a) - (y * sin_a) + cx).round(2)
          ry = ((x * sin_a) + (y * cos_a) + cy).round(2)
          "#{rx},#{ry}"
        end.join(' ')
      end

      # Deliberately bigger than a per-hex small-icon slot would allow.
      SHIP_MARKER_SIZE = 90

      # Opt-in hook (currently only G2038's Route step defines
      # `ship_marker`): draws the currently-flying ship's marker as its
      # own top-level overlay, in the same painted-last-so-it's-on-top
      # spot as the route lines above, using the hex's real center
      # coordinates (Hex.coordinates) rather than a per-hex icon slot.
      # Confirmed with the user: since the marker is transient, it's fine
      # for it to spill into a neighboring hex or cover part of its own --
      # that's the whole point of rendering it here instead of through the
      # small-icon system, which used to clip/shrink/reposition it to
      # avoid overlapping other icons and could get visually covered by a
      # later-drawn neighboring hex.
      # A bit below the hex's dead center by default -- leaves the top
      # (standardized location-name position, see Part::LocationName) and
      # the single mine circle clear. A double-mine hex instead centers
      # the marker exactly (both mine circles already sit symmetrically
      # around center, so there's no single-mine position to favor).
      SHIP_MARKER_Y_OFFSET = 40

      def render_ship_marker
        step = @game.round.steps.find { |s| s.respond_to?(:ship_marker) }
        return [] unless step

        marker = step.ship_marker(@game.round.current_entity)
        return [] unless marker

        hex, icon_name, position = marker
        cx, cy = Hex.coordinates(hex, @start_pos)
        half = SHIP_MARKER_SIZE / 2.0
        y_offset = position == :center ? 0 : SHIP_MARKER_Y_OFFSET

        # pointer-events: none -- the marker is purely a transient visual
        # indicator; a click on its hex should reach whatever's underneath
        # (the hex itself, a mine circle, a token) exactly as if the
        # marker weren't there. Confirmed with the user.
        [h(:image, attrs: {
             href: "/icons/#{icon_name}.svg",
             x: (cx - half).round(2),
             y: (cy - half + y_offset).round(2),
             width: SHIP_MARKER_SIZE,
             height: SHIP_MARKER_SIZE,
           }, style: { pointerEvents: 'none' })]
      end

      def map_zoom
        Lib::Storage['map_zoom'] || 1
      end
    end
  end
end
