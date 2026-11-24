# frozen_string_literal: true

module View
  module Game
    module G2038
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

        # Scans round.steps rather than round.active_step: Route may no
        # longer be the active step by the time later steps in the same
        # turn (Dividend, BuyShip) take over, but its routes should stay
        # visible until the turn ends.
        def render_route_lines
          step = @game.round.steps.find { |s| s.respond_to?(:live_route_hexes) }
          return [] if !step && @historical_ship_routes.empty?

          routes = []

          # Not gated on `step` existing -- a player may check last OR's
          # routes during a Stock round, where Route isn't in the step list.
          @historical_ship_routes.each do |hex_ids|
            hexes = hex_ids.map { |id| @game.hex_by_id(id) }.compact
            routes << [hexes, routes.size] if hexes.size > 1
          end

          return finish_route_lines(routes) unless step

          # Not @active_routes: Dividend#render stores the same routes
          # there too, which would double-draw each one under a second
          # color index.
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
            undo_click =
              if step.respond_to?(:undo_last_hex_available?) && step.undo_last_hex_available?(entity)
                lambda do
                  choice = step.class::UNDO_HEX
                  @host.process_action(Engine::Action::Choose.new(entity, choice: choice))
                end
              end
            routes << [live_hexes, color_index_for.call(live_ship), false, undo_click]
          end

          if step.respond_to?(:previewed_ship_routes)
            step.previewed_ship_routes(entity).each do |ship, hexes|
              routes << [hexes, color_index_for.call(ship)] if hexes.size > 1
            end
          end

          # Only refreshed when @best improves, not on a timer -- a full
          # map re-render is expensive.
          if step.respond_to?(:auto_route_all_preview_hexes)
            preview_ship, preview_hexes = step.auto_route_all_preview_hexes(entity)
            routes << [preview_hexes, color_index_for.call(preview_ship), true] if preview_hexes && preview_hexes.size > 1
          end

          finish_route_lines(routes)
        end

        def finish_route_lines(routes)
          edge_routes = hex_route_edge_indexes(routes)

          routes.each_with_index.flat_map do |(hexes, color_index, dashed, on_last_hop_click), slot|
            hex_route_elements(hexes, slot, color_index, edge_routes, dashed: dashed, on_last_hop_click: on_last_hop_click)
          end
        end

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
            click = on_last_hop_click if on_last_hop_click && hex_b.equal?(hexes.last)

            [hex_route_polyline(ox1, oy1, ox2, oy2, color, width, "#{elem_key}_line", dashed: dashed, on_click: click),
             hex_route_arrow(ox1, oy1, ox2, oy2, color, "#{elem_key}_arrow", on_click: click)]
          end
        end

        LANE_SPACING = 14

        def hex_route_segment_offset(index, occurrence, sharing)
          return 0 if sharing.size <= 1

          lane = nth_occurrence_index(sharing, index, occurrence)
          (lane - ((sharing.size - 1) / 2.0)) * LANE_SPACING
        end

        def nth_occurrence_index(array, value, n)
          count = -1
          array.each_with_index do |v, i|
            next unless v == value

            count += 1
            return i if count == n
          end
          nil
        end

        # Perpendicular is computed from the edge's canonical (sorted)
        # direction, not this hop's travel direction -- otherwise a
        # reversed hop flips the sign and cancels out a backtrack's offset.
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

        HIT_AREA_STROKE_WIDTH = 24

        # Fixed clearance, not a fraction of the segment -- a fraction-
        # based trim left a click near a base hex landing on the hit area
        # instead of its own refuel popup (base art reaches ~58-63 units
        # out from center; see RING_STATION_RING_R in hex_g2038.rb).
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

        ROUTE_ARROW_POSITION = 0.4
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

        SHIP_MARKER_SIZE = 90
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
