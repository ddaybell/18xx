# frozen_string_literal: true

require 'lib/settings'
require 'view/game/actionable'

module View
  module Game
    module G2038
      # Unlike View::Confirm, persists until the player picks a button --
      # see Step::Route#explore_would_lock_other_routes?.
      class ExploreLockPrompt < Snabberb::Component
        include Actionable
        include Lib::Settings

        needs :tile_selector, store: true
        needs :game, store: true
        needs :zoom, default: 1
        needs :near_right_edge, default: false
        needs :near_top_edge, default: false
        needs :near_bottom_edge, default: false

        EDGE_MARGIN = 260
        BOTTOM_EDGE_MARGIN = 220
        POPUP_MAX_WIDTH = 240

        def render
          message = h('div.no_margin', {
                        style: { color: '#FFFFFF', fontSize: '14px', marginBottom: '4px' },
                      }, '⚠️ Exploring locks in every route already submitted this turn.')

          button_style = {
            display: 'inline-block',
            cursor: 'pointer',
            fontSize: '14px',
            color: '#FFFFFF',
            padding: '4px 8px',
            whiteSpace: 'normal',
          }

          confirm = h('button.no_margin', {
                        style: { backgroundColor: default_for(:green), **button_style, marginRight: '5px' },
                        on: { click: -> { confirm! } },
                      }, 'Confirm')

          cancel = h('button.no_margin', {
                       style: { backgroundColor: default_for(:red), **button_style },
                       on: { click: -> { store(:tile_selector, nil) } },
                     }, 'Cancel Explore')

          style = {
            display: 'flex',
            flexDirection: 'column',
            gap: '5px',
            maxWidth: "#{POPUP_MAX_WIDTH}px",
            position: 'absolute',
            backgroundColor: 'rgba(0, 0, 0, 0.85)',
            borderRadius: '6px',
            padding: '8px',
            filter: 'drop-shadow(3px 3px 4px #888)',
          }
          if @near_right_edge
            style[:right] = '-60px'
          else
            style[:left] = '-60px'
          end
          if @near_bottom_edge
            style[:bottom] = '8px'
          elsif @near_top_edge
            style[:top] = '8px'
          else
            style[:top] = "#{-68 * @zoom}px"
          end

          h(:div, { style: style }, [message, h(:div, [confirm, cancel])])
        end

        def confirm!
          step = @game.round.active_step
          step.acknowledge_lock_warning! if step.respond_to?(:acknowledge_lock_warning!)
          dispatch = @tile_selector.dispatch
          store(:tile_selector, nil, skip: true)
          dispatch.call
        end
      end
    end
  end
end
