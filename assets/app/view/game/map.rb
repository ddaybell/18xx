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
              width, = map_size
              # Same edge-proximity idea TileSelector already uses below
              # (right_col/top_row) so the popup flips to extend toward
              # the opposite side instead of overflowing past the map's
              # own boundary -- found live in browser: hexes near the
              # right edge (e.g. column G/H) had their buttons clipped by
              # the map's own scrolling container, since the popup always
              # extended rightward (and upward) from its anchor with no
              # edge awareness. Checked against the *top* edge, not the
              # bottom -- the popup always extends upward from its hex, so
              # that's the direction that can run out of room.
              h(HexChoicePopup, zoom: map_zoom,
                                 near_right_edge: width - left < HexChoicePopup::EDGE_MARGIN,
                                 near_top_edge: top < HexChoicePopup::EDGE_MARGIN)
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
        return [] unless step

        lines = []
        (@active_routes || []).each_with_index do |route, index|
          next unless route.hexes.size > 1 && route.paths.empty?

          lines << hex_route_polyline(route.hexes, index)
        end

        if step.respond_to?(:current_turn_routes)
          step.current_turn_routes(@game.round.current_entity).each do |route|
            next unless route.hexes.size > 1 && route.paths.empty?

            lines << hex_route_polyline(route.hexes, lines.size)
          end
        end

        live_hexes = step.live_route_hexes(@game.round.current_entity)
        lines << hex_route_polyline(live_hexes, lines.size) if live_hexes && live_hexes.size > 1

        lines
      end

      def hex_route_polyline(hexes, index)
        points = hexes.map { |hex| Hex.coordinates(hex, @start_pos) }

        h(:polyline, attrs: {
            points: points.map { |x, y| "#{x},#{y}" }.join(' '),
            fill: 'none',
            stroke: route_prop(index, :color),
            'stroke-width': route_prop(index, :width),
            'stroke-linecap': 'round',
            'stroke-linejoin': 'round',
          })
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
