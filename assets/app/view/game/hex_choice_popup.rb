# frozen_string_literal: true

require 'lib/settings'
require 'view/game/actionable'
require 'view/game/hex'

module View
  module Game
    # Generic hex-anchored popup rendering one button per staged choice, plus
    # a dismiss button. Mirrors TileConfirmation's positioning/style but is
    # driven by an arbitrary Lib::HexChoicePopup instead of a single tile.
    # A choice's value is a text label (rendered as a button, as before),
    # an Engine::Tile (rendered as a small clickable tile preview instead),
    # or a {ore:, value:} Hash (rendered as a small ore-colored icon
    #  -- G2038's double-mine claim popup, so the two mines on a hex read at a
    # glance instead of needing to parse an abbreviated text label).
    class HexChoicePopup < Snabberb::Component
      include Actionable
      include Lib::Settings

      CLAIM_MINE_COLOR = { n: [200, 40, 40], i: [40, 100, 210], r: [40, 150, 70] }.freeze
      MINE_VALUE_RANGE = (10..70)

      def tinted_mine_color(ore, value)
        base = CLAIM_MINE_COLOR[ore]
        span = MINE_VALUE_RANGE.max - MINE_VALUE_RANGE.min
        t = ((value - MINE_VALUE_RANGE.min).to_f / span).clamp(0.0, 1.0)
        white_blend = 0.82 - (0.42 * t)

        r, g, b = base.map { |c| ((c * (1 - white_blend)) + (255 * white_blend)).round.clamp(0, 255) }
        format('#%02x%02x%02x', r, g, b)
      end

      needs :tile_selector, store: true
      needs :zoom, default: 1
      needs :near_right_edge, default: false
      needs :near_top_edge, default: false
      needs :near_bottom_edge, default: false

      # Roughly matches the popup's own max-width (POPUP_MAX_WIDTH) plus
      # its drop shadow, so the edge flip below kicks in before any
      # clipping would actually occur, not right at the point it already
      # has.
      EDGE_MARGIN = 260

      # Same idea as EDGE_MARGIN but for the vertical axis -- large enough
      # to flip before a popup stacking several choice buttons actually
      # runs off the bottom of the map.
      BOTTOM_EDGE_MARGIN = 220

      # Bounds how wide the popup can grow regardless of label length --
      # long choice text wraps onto additional lines instead of
      # extending the row sideways past this width.
      POPUP_MAX_WIDTH = 220

      def render
        button_style = {
          display: 'inline-block',
          cursor: 'pointer',
          fontSize: '14px',
          color: '#FFFFFF',
          filter: 'drop-shadow(3px 3px 2px #888)',
          padding: '4px 8px',
          whiteSpace: 'normal',
          maxWidth: "#{POPUP_MAX_WIDTH}px",
        }

        buttons = @tile_selector.choices.map do |choice, label|
          if label.is_a?(Engine::Tile)
            render_tile_choice(choice, label)
          elsif label.is_a?(Hash)
            render_claim_choice(choice, label)
          else
            h('button.no_margin', {
                props: { innerHTML: label },
                style: { backgroundColor: default_for(:green), **button_style },
                on: { click: -> { choose(choice) } },
              })
          end
        end

        cancel = h('button.no_margin', {
                     props: { innerHTML: '✖' },
                     style: { backgroundColor: default_for(:red), **button_style },
                     on: { click: -> { store(:tile_selector, nil) } },
                   })

        style = {
          display: 'flex',
          flexWrap: 'wrap',
          gap: '5px',
          maxWidth: "#{POPUP_MAX_WIDTH}px",
          position: 'absolute',
        }
        # Flips which edge the offset is measured from -- not just the
        # sign of the value -- so the button row grows back toward the
        # hex (and the rest of the map) instead of past whichever
        # boundary it's close to.
        if @near_right_edge
          style[:right] = '-60px'
        else
          style[:left] = '-60px'
        end
        # Same flip idea as near_right_edge above, but anchoring from the
        # bottom instead of the top so the box grows upward, away from
        # the map's own bottom edge, instead of downward past it.
        if @near_bottom_edge
          style[:bottom] = '8px'
        elsif @near_top_edge
          style[:top] = '8px'
        else
          style[:top] = "#{-68 * @zoom}px"
        end

        div_props = { style: style }

        h(:div, div_props, [*buttons, cancel])
      end

      # Same scale/technique as View::Game::TileSelector's own preview
      # hexes (the standard tile-upgrade fan), just a single static tile
      # rather than a radial fan of them.
      PREVIEW_SCALE = 0.3
      PREVIEW_SIZE = 60

      def render_tile_choice(choice, tile)
        preview_hex = Engine::Hex.new('A1', layout: @tile_selector.hex.layout, tile: tile)
        wrapper_props = {
          style: {
            display: 'inline-block',
            cursor: 'pointer',
            filter: 'drop-shadow(3px 3px 2px #888)',
          },
          on: { click: -> { choose(choice) } },
        }

        h(:div, wrapper_props, [
          h(:svg, { style: { width: "#{PREVIEW_SIZE}px", height: "#{PREVIEW_SIZE}px" } }, [
            h(:g, { attrs: { transform: "scale(#{PREVIEW_SCALE})" } }, [
              h(Hex, hex: preview_hex, clickable: false, role: :tile_selector),
            ]),
          ]),
        ])
      end

      # A claim option's ore-colored icon (ore letter inside a colored
      # circle, unclaimed value above it) -- same visual language as
      # View::Game::Corporation#render_claim_column's already-placed
      # claims, so a player who's seen one recognizes the other.
      def render_claim_choice(choice, data)
        color = tinted_mine_color(data[:ore], data[:value])
        wrapper_props = {
          style: {
            display: 'inline-block',
            cursor: 'pointer',
            textAlign: 'center',
            filter: 'drop-shadow(3px 3px 2px #888)',
          },
          on: { click: -> { choose(choice) } },
        }
        circle_props = {
          style: {
            width: '1.8rem',
            height: '1.8rem',
            margin: '0 auto',
            borderRadius: '50%',
            background: color,
            color: '#000000',
            fontWeight: 'bold',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          },
        }

        h(:div, wrapper_props, [
          h('div.no_margin', { style: { color: '#FFFFFF', fontSize: '14px' } }, @game.format_currency(data[:value])),
          h(:div, circle_props, data[:ore].to_s.upcase),
        ])
      end

      def choose(choice)
        entity = @tile_selector.entity
        hex = @tile_selector.hex
        coordinates = [@tile_selector.x, @tile_selector.y]
        root = @tile_selector.root
        role = @tile_selector.role
        step = @game.round.active_step
        label = @tile_selector.choices[choice]

        dispatch = lambda do
          # Only chain straight into a follow-up popup when the step opts
          # in for this specific choice (e.g. G2038's Lucky: choosing
          # "Explore" here triggers the tile-redraw power, which needs its
          # own popup with no extra click). Other transitions -- e.g.
          # picking a tile and then having ore available to pick up -- are
          # deliberately left requiring a fresh click on the hex, since
          # they're a separate decision, not a continuation of this one.
          should_chain = step.respond_to?(:chain_hex_choice_popup?) && step.chain_hex_choice_popup?(entity, hex, choice)

          store(:tile_selector, nil, skip: true)
          process_action(Engine::Action::Choose.new(entity, choice: choice))

          next unless should_chain
          next unless step.respond_to?(:hex_choice_popup)

          next_popup = step.hex_choice_popup(entity, hex)
          next unless next_popup

          store(:tile_selector, Lib::HexChoicePopup.new(hex, next_popup, coordinates, root, entity, role))
        end

        if step.respond_to?(:explore_would_lock_other_routes?) &&
           step.explore_would_lock_other_routes?(entity, hex, choice)
          # Closes the Explore/Skip popup itself here, rather than
          # leaving it open alongside the warning banner (dispatch below
          # only closes it once actually confirmed) -- two simultaneous,
          # independent prompts (one hex-anchored, one a top banner) read
          # as "which one do I answer first," and clicking Explore again
          # in the still-open popup wouldn't have skipped the warning
          # anyway, only re-shown an equivalent one. One prompt at a
          # time: Confirm in the banner explores for real: anything else
          # (the banner's own 3s auto-dismiss, or clicking away) abandons
          # the click entirely, same as dismissing any other popup --
          # clicking the hex again offers a fresh Explore/Skip choice.
          store(:tile_selector, nil, skip: true)
          store(:confirm_opts, { message: '⚠️ Explore locks all submitted routes', click: dispatch }, skip: false)
        elsif (consenter = @game.consenter_for_choice(entity, choice, label))
          check_consent(entity, consenter, dispatch)
        else
          dispatch.call
        end
      end
    end
  end
end
