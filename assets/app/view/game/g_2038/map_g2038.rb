# frozen_string_literal: true

module View
  module Game
    # G2038-only map overlays: hex-list ship route lines (in place of
    # track-based routes, which G2038 never has), the transient
    # currently-flying ship marker, and the "dim only for the active
    # player" viewing behavior. Mixed into the shared Map component the
    # same way HexG2038 is mixed into Hex -- every method here is only
    # ever reached via a `step.respond_to?(...)` guard or
    # `@game.dim_only_active_player?` check at its call site in map.rb
    # itself, so no other game's map rendering exercises any of this.
    module MapG2038
      def self.included(base)
        # G2038-specific "Show Last Route" data: an array of hex-id
        # arrays, one per ship, straight from Game#last_route -- the
        # standard :historical_routes store holds Engine::Route objects
        # keyed on connection_hexes/halts/nodes, none of which G2038 ever
        # populates (see route_controls' own comment), so this is a
        # parallel, G2038-only store MapControls fills in instead. No
        # tile/highlight counterpart (:historical_laid_hexes) -- per the
        # user, only the route lines themselves are wanted here, not a
        # tile-reveal effect.
        base.needs :historical_ship_routes, default: [], store: true
        # Needed for dim_by_hex_validity? below -- Map doesn't otherwise
        # track the viewing browser's own identity or hotseat status.
        base.needs :user, store: true, default: nil
        base.needs :game_data, default: {}, store: true
      end

      # Whether the CURRENT VIEWER should see hex-validity dimming at all
      # (see Game#dim_only_active_player?'s own comment for why this
      # exists). Hotseat has no real distinct "logged in as this seat"
      # identity -- one browser plays every seat, so @user's real account
      # id has nothing to do with the small sequential in-game player ids
      # and would otherwise make this always false there -- hotseat gets
      # the traditional dimming instead, same as any other opt-out case.
      def dim_by_hex_validity?
        return true unless @game.dim_only_active_player?

        @game_data[:mode] == :hotseat || @game.active_players_id.include?(@user&.dig('id'))
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
      # done, while later steps in the same turn (Dividend, BuyShip, ...)
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
        # ship on hand here (just a stored hex list), so these fall back
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
        color_index_for = lambda do |ship|
          return routes.size unless ship && step.respond_to?(:route_color_index)

          step.route_color_index(entity, ship) || routes.size
        end

        if step.respond_to?(:current_turn_routes)
          step.current_turn_routes(entity).each do |route|
            next unless route.hexes.size > 1 && route.paths.empty?

            routes << [route.hexes, color_index_for.call(route.train)]
          end
        end

        live_hexes = step.live_route_hexes(entity)
        if live_hexes && live_hexes.size > 1
          live_ship = step.respond_to?(:current_ship) ? step.current_ship(entity) : nil
          routes << [live_hexes, color_index_for.call(live_ship)]
        end

        # "Show every unrun ship's own passively-previewed prior route"
        # (see Step::Route#previewed_ship_routes/ship_rows) -- each keyed
        # by its own ship, so its color always matches that ship's own
        # row swatch (route_color_index) regardless of how many routes
        # are drawn this pass, rather than drifting with draw-order
        # position -- found live in browser: an already-submitted route
        # and a ship's own in-progress route swapped colors the moment
        # the drawn set's size changed shape between renders.
        if step.respond_to?(:previewed_ship_routes)
          step.previewed_ship_routes(entity).each do |ship, hexes|
            routes << [hexes, color_index_for.call(ship)] if hexes.size > 1
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
        # rarer as a search goes on (see Autorouter#found_at_ratio).
        if step.respond_to?(:auto_route_all_preview_hexes)
          preview_ship, preview_hexes = step.auto_route_all_preview_hexes(entity)
          if preview_hexes && preview_hexes.size > 1
            routes << [preview_hexes, color_index_for.call(preview_ship), true]
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
    end
  end
end
