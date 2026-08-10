# frozen_string_literal: true

require 'lib/settings'
require 'view/game/actionable'
require 'view/game/hex'

module View
  module Game
    # Generic hex-anchored popup rendering one button per staged choice, plus
    # a dismiss button. Mirrors TileConfirmation's positioning/style but is
    # driven by an arbitrary Lib::HexChoicePopup instead of a single tile.
    # A choice's value is either a text label (rendered as a button, as
    # before) or an Engine::Tile (rendered as a small clickable tile
    # preview instead) -- the latter for G2038's Lucky redraw, which needs
    # to show real tile art rather than a text description.
    class HexChoicePopup < Snabberb::Component
      include Actionable
      include Lib::Settings

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
      # long choice text (e.g. BuyInfrastructure's "Claim Rare mine,
      # revenue $20 ($60)") wraps onto additional lines instead of
      # extending the row sideways past this width. Found live in
      # browser: a fixed-width single-row layout meant EDGE_MARGIN would
      # have needed to track the *longest possible label any step might
      # ever show* to guarantee no clipping -- wrapping sidesteps that
      # entirely, since the popup's width is now bounded independent of
      # content.
      POPUP_MAX_WIDTH = 220

      def render
        button_style = {
          display: 'inline-block',
          cursor: 'pointer',
          fontSize: '14px',
          color: '#FFFFFF',
          filter: 'drop-shadow(3px 3px 2px #888)',
          padding: '4px 8px',
          # Not nowrap -- a long label (e.g. BuyInfrastructure's "Claim
          # Rare mine, revenue $20 ($60)") needs to wrap onto a second
          # line within its own button rather than forcing the whole
          # popup wider than POPUP_MAX_WIDTH to fit one unbroken line.
          whiteSpace: 'normal',
          maxWidth: "#{POPUP_MAX_WIDTH}px",
        }

        buttons = @tile_selector.choices.map do |choice, label|
          if label.is_a?(Engine::Tile)
            render_tile_choice(choice, label)
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

        if (consenter = @game.consenter_for_choice(entity, choice, label))
          check_consent(entity, consenter, dispatch)
        else
          dispatch.call
        end
      end
    end
  end
end
