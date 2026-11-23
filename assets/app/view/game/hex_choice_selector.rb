# frozen_string_literal: true

require 'lib/radial_selector'
require 'lib/settings'
require 'lib/explore_lock_prompt'
require 'view/game/actionable'
require 'view/game/hex'

module View
  module Game
    # Hex-anchored popup of staged choices, fanned radially around the hex
    # (Lib::RadialSelector) with Cancel at its center -- the third selector
    # alongside TileSelector and TokenSelector. A choice value is a text
    # label (a button), an Engine::Tile (a small clickable tile preview),
    # or a {ore:, value:} Hash (G2038's double-mine claim icon).
    class HexChoiceSelector < Snabberb::Component
      include Actionable
      include Lib::RadialSelector
      include Lib::Settings

      CLAIM_MINE_COLOR = { n: [200, 40, 40], i: [40, 100, 210], r: [40, 150, 70] }.freeze
      MINE_VALUE_RANGE = (10..70)

      def tinted_mine_color(ore, value)
        base = CLAIM_MINE_COLOR[ore]
        span = MINE_VALUE_RANGE.max - MINE_VALUE_RANGE.min
        t = ((value - MINE_VALUE_RANGE.min).to_f / span).clamp(0.0, 1.0)
        white_blend = 0.82 - (0.42 * t)

        r, g, b = base.map { |c| ((c * (1 - white_blend)) + (255 * white_blend)).round.clamp(0, 255) }
        format('#%<r>02x%<g>02x%<b>02x', r: r, g: g, b: b)
      end

      needs :tile_selector, store: true
      needs :zoom, default: 1
      needs :near_left_edge, default: false
      needs :near_right_edge, default: false
      needs :near_top_edge, default: false
      needs :near_bottom_edge, default: false

      EDGE_MARGIN = 260
      BOTTOM_EDGE_MARGIN = 220

      # Fan radius at 1x zoom. Wide enough that the widest expected label
      # ("Transshipment ($XX)") and Cancel, landing on the same horizontal
      # line, don't overlap -- centers need ~89px of separation plus a gap.
      BASE_DISTANCE = 100

      BASE_FONT_SIZE = 14
      BASE_PAD_V = 4
      BASE_PAD_H = 8

      # Caps the spread between adjacent choices -- without it,
      # list_coordinates' own angle stretch doubles a 2-choice half-circle
      # fan into a full circle, landing them diametrically opposite instead
      # of together.
      MAX_ANGLE_PER_CHOICE = 70

      # Same scale/technique as View::Game::TileSelector's own preview
      # hexes, just a single static tile rather than a radial fan of them.
      PREVIEW_SCALE = 0.3
      BASE_PREVIEW_SIZE = 60

      BASE_CLAIM_CIRCLE_SIZE = 28

      def render
        angle, rotation = calc_angle_rotation(@near_left_edge, @near_right_edge, @near_top_edge, @near_bottom_edge)
        count = @tile_selector.choices.size
        if count > 1
          capped = [(count - 1) * MAX_ANGLE_PER_CHOICE, angle].min
          rotation += (angle - capped) / 2.0 if angle < FULL_CIRCLE
          angle = capped
        end
        distance = BASE_DISTANCE * @zoom

        choices = list_coordinates(@tile_selector.choices.to_a, distance, 0, angle, rotation).map do |pair, left, bottom|
          choice, label = pair
          case label
          when Engine::Tile
            render_tile_choice(choice, label, left, bottom)
          when Hash
            render_claim_choice(choice, label, left, bottom)
          else
            render_button_choice(choice, label, left, bottom)
          end
        end

        h(:div, { style: { position: 'absolute' } }, [*choices, render_cancel])
      end

      # Anchored at (left, bottom) and centered on that point via
      # `transform`, rather than given an explicit width -- so the button
      # shrinks to fit its own label instead of stretching to match
      # whichever other choice in the fan happens to have the longest one.
      def render_button_choice(choice, label, left, bottom)
        h('button.no_margin', {
            props: { innerHTML: label },
            style: fanned_style(left, bottom).merge(
              backgroundColor: default_for(:green),
              color: '#FFFFFF',
              fontSize: "#{BASE_FONT_SIZE * @zoom}px",
              padding: "#{BASE_PAD_V * @zoom}px #{BASE_PAD_H * @zoom}px",
              whiteSpace: 'nowrap',
            ),
            on: { click: -> { choose(choice) } },
          })
      end

      def render_cancel
        h('button.no_margin', {
            props: { innerHTML: '✖' },
            style: fanned_style(0, 0).merge(
              backgroundColor: default_for(:red),
              color: '#FFFFFF',
              fontSize: "#{BASE_FONT_SIZE * @zoom}px",
              padding: "#{BASE_PAD_V * @zoom}px #{BASE_PAD_H * @zoom}px",
            ),
            on: { click: -> { store(:tile_selector, nil) } },
          })
      end

      # Common positioning for every fanned choice (including Cancel, at
      # distance 0): absolutely placed at the computed (left, bottom), then
      # centered on that point regardless of the element's own rendered
      # size -- a button sized to its text, a tile preview, and a claim
      # icon all land on their fan position the same way.
      def fanned_style(left, bottom)
        {
          position: 'absolute',
          left: "#{left}px",
          bottom: "#{bottom}px",
          transform: 'translate(-50%, 50%)',
          display: 'inline-block',
          width: 'max-content',
          cursor: 'pointer',
          filter: 'drop-shadow(3px 3px 2px #888)',
        }
      end

      def render_tile_choice(choice, tile, left, bottom)
        preview_size = BASE_PREVIEW_SIZE * @zoom
        preview_hex = Engine::Hex.new('A1', layout: @tile_selector.hex.layout, tile: tile)
        wrapper_props = {
          style: fanned_style(left, bottom),
          on: { click: -> { choose(choice) } },
        }

        h(:div, wrapper_props, [
          h(:svg, { style: { width: "#{preview_size}px", height: "#{preview_size}px" } }, [
            h(:g, { attrs: { transform: "scale(#{PREVIEW_SCALE * @zoom})" } }, [
              h(Hex, hex: preview_hex, clickable: false, role: :tile_selector),
            ]),
          ]),
        ])
      end

      # A claim option's ore-colored icon (ore letter inside a colored
      # circle, unclaimed value above it) -- same visual language as
      # View::Game::Corporation#render_claim_column's already-placed
      # claims, so a player who's seen one recognizes the other.
      def render_claim_choice(choice, data, left, bottom)
        color = tinted_mine_color(data[:ore], data[:value])
        circle_size = BASE_CLAIM_CIRCLE_SIZE * @zoom
        wrapper_props = {
          style: fanned_style(left, bottom).merge(textAlign: 'center'),
          on: { click: -> { choose(choice) } },
        }
        circle_props = {
          style: {
            width: "#{circle_size}px",
            height: "#{circle_size}px",
            margin: '0 auto',
            borderRadius: '50%',
            background: color,
            color: '#000000',
            fontWeight: 'bold',
            fontSize: "#{BASE_FONT_SIZE * @zoom}px",
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          },
        }

        h(:div, wrapper_props, [
          h('div.no_margin', { style: { color: '#FFFFFF', fontSize: "#{BASE_FONT_SIZE * @zoom}px" } },
            @game.format_currency(data[:value])),
          h(:div, circle_props, data[:ore].to_s.upcase),
        ])
      end

      def choose(choice)
        entity = @tile_selector.entity
        hex = @tile_selector.hex
        coordinates = [@tile_selector.x, @tile_selector.y]
        role = @tile_selector.role
        step = @game.round.active_step
        label = @tile_selector.choices[choice]

        dispatch = lambda do
          # Only chain straight into a follow-up popup when the step opts
          # in for this specific choice (e.g. G2038's Lucky: choosing
          # "Explore" here triggers the tile-redraw power, which needs its
          # own popup with no extra click).
          should_chain = step.respond_to?(:chain_hex_choices?) && step.chain_hex_choices?(entity, hex, choice)

          store(:tile_selector, nil, skip: true)
          process_action(Engine::Action::Choose.new(entity, choice: choice))

          next unless should_chain
          next unless step.respond_to?(:hex_choices)

          next_popup = step.hex_choices(entity, hex)
          next unless next_popup

          store(:tile_selector, Lib::HexChoiceSelector.new(hex, next_popup, coordinates, entity, role))
        end

        if step.respond_to?(:explore_would_lock_other_routes?) &&
           step.explore_would_lock_other_routes?(entity, hex, choice)
          # Replaces the Explore/Skip popup itself with the warning, same
          # as the old top-banner Confirm this prompt replaced -- see
          # View::Game::G2038::ExploreLockPrompt. `dispatch` (the real
          # process_action, plus its own chaining) is carried into that
          # prompt rather than run now.
          store(:tile_selector, Lib::ExploreLockPrompt.new(hex, coordinates, entity, role, dispatch))
        elsif (consenter = @game.consenter_for_choice(entity, choice, label))
          check_consent(entity, consenter, dispatch)
        else
          dispatch.call
        end
      end
    end
  end
end
