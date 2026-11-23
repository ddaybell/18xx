# frozen_string_literal: true

module View
  module Game
    module G2038
      # G2038-only map overlays: hex-list ship route lines (in place of
      # track-based routes, which G2038 never has) and the transient
      # currently-flying ship marker. Delegate object (not a mixin) so
      # View::Game::Map's own method table never carries these --
      # instantiated once per Map#render.
      class MapDecorations
        def initialize(host, game, start_pos, historical_ship_routes)
          @host = host
          @game = game
          @start_pos = start_pos
          @historical_ship_routes = historical_ship_routes
        end

        def h(...)
          @host.h(...)
        end

        # Draws a colored polyline hex-center to hex-center for routes that
        # aren't track/path-based (route.paths.empty? with 2+ stops) --
        # G2038's hex-list spaceship routes have no tile paths for
        # Part::Track to color. Also draws the current entity's
        # in-progress trace (`live_route_hexes`) and its already-finished
        # routes still pending this OR turn (`current_turn_routes`).
        # Looked up by scanning `round.steps` rather than `round.
        # active_step`, since the step offering these hooks (Route) may no
        # longer be the *active* one by the time later steps in the same
        # turn (Dividend, BuyShip, ...) take over, but its finished routes
        # should stay visible until the turn ends.
        def render_route_lines
          step = @game.round.steps.find { |s| s.respond_to?(:live_route_hexes) }
          return [] if !step && @historical_ship_routes.empty?

          routes = []

          # "Show Last Route For" (MapControls#route_controls, G2038 branch)
          # -- one entry per ship, from Game#last_route via the
          # :historical_ship_routes store. Not gated on `step` existing --
          # a player might want to check last OR's routes during a Stock
          # round, where G2038's Route step isn't even in the round's step
          # list. No ship on hand here, so these fall back to plain
          # draw-order coloring rather than route_color_index.
          @historical_ship_routes.each do |hex_ids|
            hexes = hex_ids.map { |id| @game.hex_by_id(id) }.compact
            routes << [hexes, routes.size] if hexes.size > 1
          end

          return finish_route_lines(routes) unless step

          # Not @active_routes -- that store leaks every G2038 route in
          # here too (View::Game::Dividend#render unconditionally does
          # `store(:routes, @step.routes)`, which returns the exact same
          # array current_turn_routes below already reads), double-
          # drawing each route under a second color index and making it
          # look bordered by an unrelated color. current_turn_routes is
          # already the complete, authoritative source here.
          entity = @game.round.current_entity
          color_index_for = lambda do |ship|
            next routes.size if !ship || !step.respond_to?(:route_color_index)

            step.route_color_index(entity, ship) || routes.size
          end

          if step.respond_to?(:current_turn_routes)
            step.current_turn_routes(entity).each do |route|
              next if route.hexes.size <= 1 || !route.paths.empty?

              routes << [route.hexes, color_index_for.call(route.train)]
            end
          end

          live_hexes = step.live_route_hexes(entity)
          if live_hexes && live_hexes.size > 1
            live_ship = step.respond_to?(:current_ship) ? step.current_ship(entity) : nil
            # Undo, directly on the route line: a third, more precise click
            # target alongside the existing two (the mine circle itself,
            # and the rest of the hex for the disambiguation popup).
            # Gating the mine-click shortcut on "Undo is available"
            # instead was rejected: undo_last_hex_available? is true for
            # nearly the whole flight, which would kill that shortcut
            # almost entirely. Only ever attached to THIS route's final
            # hop (see hex_route_elements' on_last_hop_click).
            undo_click =
              if step.respond_to?(:undo_last_hex_available?) && step.undo_last_hex_available?(entity)
                lambda do
                  choice = step.class::UNDO_HEX
                  @host.process_action(Engine::Action::Choose.new(entity, choice: choice))
                end
              end
            routes << [live_hexes, color_index_for.call(live_ship), false, undo_click]
          end

          # Each unrun ship's own passively-previewed prior route (see
          # Step::Route#previewed_ship_routes/ship_rows), keyed by ship so
          # its color matches that ship's row swatch (route_color_index)
          # rather than drifting with draw-order position.
          if step.respond_to?(:previewed_ship_routes)
            step.previewed_ship_routes(entity).each do |ship, hexes|
              routes << [hexes, color_index_for.call(ship)] if hexes.size > 1
            end
          end

          # A live Auto-all run's CURRENT best for whichever ship it's
          # actively searching -- drawn dashed (see finish_route_lines'
          # `dashed:` param) so it reads as "still under test," not a
          # settled route. Only refreshed when @best actually improves
          # (ship_selector.rb's run_auto_route_all_tick!), not on a timer,
          # since a full map re-render is genuinely expensive.
          if step.respond_to?(:auto_route_all_preview_hexes)
            preview_ship, preview_hexes = step.auto_route_all_preview_hexes(entity)
            routes << [preview_hexes, color_index_for.call(preview_ship), true] if preview_hexes && preview_hexes.size > 1
          end

          finish_route_lines(routes)
        end

        # Side-by-side lanes, not stacked widths -- a ship can double back
        # over the very edge it just flew (out to a mine, home to refuel,
        # back out the same way), so the same route can share an edge
        # with *itself* more than once, on top of however many other
        # ships also cross it. Nesting reads fine for two lines but has
        # no way to show three-plus distinct passes.
        def finish_route_lines(routes)
          edge_routes = hex_route_edge_indexes(routes)

          routes.each_with_index.flat_map do |(hexes, color_index, dashed, on_last_hop_click), slot|
            hex_route_elements(hexes, slot, color_index, edge_routes, dashed: dashed, on_last_hop_click: on_last_hop_click)
          end
        end

        # {edge_key => [slot, slot, ...]} for every hex-to-hex hop across
        # all routes being drawn this pass -- direction-independent (A-B
        # and B-A are the same physical edge). Keyed by draw-order slot,
        # not color_index -- lane-sharing is about how many routes touch
        # this edge this pass, unrelated to which color each one gets.
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
        # own lane whenever this edge sees more than one crossing (see
        # hex_route_segment_offset). `slot` is this route's draw-order
        # position this pass (used only for lane sharing/keys);
        # `color_index` is its stable per-ship color, kept separate so a
        # route's color never drifts just because the number of routes
        # drawn this pass happened to change.
        def hex_route_elements(hexes, slot, color_index, edge_routes, dashed: false, on_last_hop_click: nil)
          color = @host.route_prop(color_index, :color)
          width = @host.route_prop(color_index, :width)
          seen = Hash.new(0)

          hexes.each_cons(2).flat_map do |hex_a, hex_b|
            key = edge_key(hex_a, hex_b)
            occurrence = seen[key]
            seen[key] += 1

            offset = hex_route_segment_offset(slot, occurrence, edge_routes[key])
            (ox1, oy1), (ox2, oy2) = offset_points(hex_a, hex_b, offset)
            elem_key = "route_#{slot}_#{key}_#{occurrence}"
            # Only the route's actual final hop -- hex_b reaches hexes.last
            # exactly once, on the last iteration of each_cons(2) -- gets
            # the click handler, regardless of how many other hops this
            # same edge might otherwise share a lane with.
            click = on_last_hop_click if on_last_hop_click && hex_b.equal?(hexes.last)

            [hex_route_polyline(ox1, oy1, ox2, oy2, color, width, "#{elem_key}_line", dashed: dashed, on_click: click),
             hex_route_arrow(ox1, oy1, ox2, oy2, color, "#{elem_key}_arrow", on_click: click)]
          end
        end

        # Perpendicular distance to shift this specific hop -- 0 unless
        # this edge sees more than one crossing total. `occurrence` is
        # which crossing *of this edge, by this route* this hop is;
        # combined with edge_routes' strict per-route ordering,
        # nth_occurrence_index finds which of the edge's N lanes this hop
        # belongs in. Direction is handled entirely in offset_points, not
        # here.
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
        # canonical direction (sorted hex-id order), not this hop's own
        # travel direction -- using the hop's own direction would flip the
        # perpendicular's sign for a reversed hop, silently cancelling out
        # the separation a backtrack (out one way, back the other, same
        # edge) is supposed to produce.
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

        # `dashed:` -- a live Auto-all search's current best should read
        # visibly differently from a settled route, not just share its
        # ship's solid-line color.
        # A visible stroke a few px wide is too thin a target to reliably
        # click -- `on_click` adds an invisible, much wider sibling line
        # carrying the actual hit area/cursor/handler, with the real,
        # thin visible line drawn on top of it unchanged.
        HIT_AREA_STROKE_WIDTH = 24

        # Fixed, absolute clearance from EACH endpoint, not a fraction of
        # the segment -- adjacent hexes are only ~173 units apart, but a
        # base's own ring-station art alone reaches ~58-63 units out from
        # its own center (RING_STATION_RING_R, hex_g2038.rb). A fraction-
        # based trim bought barely more clearance than the ring's own
        # radius, so a click on a base hex was still landing on the hit
        # area instead of its own refuel popup. Below this, a hop simply
        # gets no line-click target at all (HIT_AREA_MIN_SPAN).
        HIT_AREA_END_CLEARANCE = 75
        HIT_AREA_MIN_SPAN = 20

        def hex_route_polyline(x1, y1, x2, y2, color, width, key, dashed: false, on_click: nil)
          attrs = {
            points: "#{x1},#{y1} #{x2},#{y2}",
            fill: 'none',
            stroke: color,
            'stroke-width': width,
            'stroke-linecap': 'round',
            'stroke-linejoin': 'round',
          }
          attrs['stroke-dasharray'] = "#{width * 2},#{width * 1.5}" if dashed
          line = h(:polyline, key: key, attrs: attrs)
          return line unless on_click

          length = Math.sqrt(((x2 - x1)**2) + ((y2 - y1)**2))
          safe_span = length - (2 * HIT_AREA_END_CLEARANCE)
          return line if safe_span < HIT_AREA_MIN_SPAN

          t1 = HIT_AREA_END_CLEARANCE / length
          t2 = 1 - t1
          hx1 = x1 + ((x2 - x1) * t1)
          hy1 = y1 + ((y2 - y1) * t1)
          hx2 = x1 + ((x2 - x1) * t2)
          hy2 = y1 + ((y2 - y1) * t2)
          hit_attrs = attrs.merge(points: "#{hx1},#{hy1} #{hx2},#{hy2}", stroke: 'transparent',
                                  'stroke-width': HIT_AREA_STROKE_WIDTH, cursor: 'pointer')
          hit_attrs.delete('stroke-dasharray')
          hit_area = h(:polyline, {
                         key: "#{key}_hit_area",
                         attrs: hit_attrs,
                         on: {
                           click: lambda { |event|
                             event.JS.stopPropagation
                             on_click.call
                           },
                         },
                       })
          h(:g, {}, [hit_area, line])
        end

        ROUTE_ARROW_POSITION = 0.4 # fraction along each hop, biased just short of the shared edge
        # Hexes are drawn ~150-200 units wide in this same coordinate
        # space -- the original 12x9 arrow was under 10% of that and
        # effectively invisible against a real map.
        ROUTE_ARROW_LENGTH = 36
        ROUTE_ARROW_WIDTH = 24

        def hex_route_arrow(x1, y1, x2, y2, color, key, on_click: nil)
          cx = x1 + ((x2 - x1) * ROUTE_ARROW_POSITION)
          cy = y1 + ((y2 - y1) * ROUTE_ARROW_POSITION)
          angle = Math.atan2(y2 - y1, x2 - x1)

          attrs = { points: arrow_triangle_points(cx, cy, angle), fill: color }
          props = { key: key, attrs: attrs }
          if on_click
            attrs[:cursor] = 'pointer'
            props[:on] = {
              click: lambda { |event|
                event.JS.stopPropagation
                on_click.call
              },
            }
          end
          h(:polygon, props)
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

        # Draws the currently-flying ship's marker as its own top-level
        # overlay (using the hex's real center coordinates) rather than
        # through the small-icon system, which used to clip/shrink/
        # reposition it to avoid overlapping other icons.
        # A bit below the hex's dead center by default -- leaves the top
        # (standardized location-name position, Part::LocationName) and
        # the single mine circle clear. A double-mine hex instead centers
        # the marker exactly, since both mine circles already sit
        # symmetrically around center.
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

          # pointer-events: none -- a click on its hex should reach
          # whatever's underneath (the hex itself, a mine circle, a
          # token) exactly as if the marker weren't there.
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
end
