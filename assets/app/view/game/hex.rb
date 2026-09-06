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
require 'view/game/hex_g2038'

module View
  module Game
    class Hex < Snabberb::Component
      include Actionable
      include Runnable
      include Lib::Settings
      # For G2038: hex starfield/asteroid/ring-station/satellite art plus its
      # BuyInfrastructure highlights.
      include HexG2038

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
        # For G2038: highlights G2038 infrastructure if it exists
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
        # a flat color, and/or draw extra art behind the tile's own city/
        # revenue circle -- see hex_g2038.rb (starfield_defs/asteroid_rock/
        # ring_station/satellite_icon and Game#hex_fill_override/
        # mine_tile?/base_tile?/transshipment_hex? for how each gets
        # triggered).
        is_mine = @game.respond_to?(:mine_tile?) && @game.mine_tile?(@tile)
        is_base = @game.respond_to?(:base_tile?) && @game.base_tile?(@tile)
        is_transshipment = @game.respond_to?(:transshipment_hex?) && @game.transshipment_hex?(@hex.id)
        wants_starfield = (@game.respond_to?(:hex_fill_override) && @game.hex_fill_override(@tile)) || is_transshipment
        children << starfield_defs if wants_starfield
        # Drawn before Tile below so the tile's own city/revenue
        # circle(s) -- in G2038 the printed mine value(s) -- paint on top of the
        # tile art (e.g. rocks).
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
        children << ring_station if is_base
        children << satellite_icon if is_transshipment

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

      def hex_outline
        polygon_props = { attrs: { points: Lib::Hex::POINTS } }
        # Opt-in hook: Paints only the hex boundary itself (this polygon), not
        # the ambient stroke every other child (mine/revenue/type-letter
        # circles) would otherwise inherit from the wrapping <g> in
        # render.
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
            #For G2038: provides multi-choice popup if enabled
            if step.respond_to?(:hex_choice_popup) && @entity && (popup = step.hex_choice_popup(@entity, @hex))
              return store(:tile_selector, Lib::HexChoicePopup.new(@hex, popup, coordinates, root, @entity, @role))
            end

            choice = @hex.id
            dispatch = lambda do
              process_action(Engine::Action::Choose.new(@entity, choice: choice))
            end

            #For 2038: checks consent for hex action
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
