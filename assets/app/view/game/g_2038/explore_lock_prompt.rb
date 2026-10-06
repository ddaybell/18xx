# frozen_string_literal: true

require 'lib/settings'
require 'view/game/actionable'

module View
  module Game
    module G2038
      # Hex-anchored replacement for the shared top-banner Confirm (see
      # View::Confirm) specifically for Step::Route#explore_would_lock_
      # other_routes? -- per the user: a warning this consequential
      # (exploring locks in every route already submitted this OR)
      # shouldn't share the generic banner's fixed 3-second auto-dismiss,
      # which silently abandons the click with no way back except
      # clicking the hex again. This popup instead sits right where the
      # Explore button was clicked (same positioning technique as
      # HexChoicePopup, same EDGE_MARGIN/BOTTOM_EDGE_MARGIN values kept in
      # sync with it by hand rather than referenced, so this file has no
      # load-order dependency on that one) and persists until the player
      # picks one of its own two buttons -- no timeout at all.
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

          # No per-button drop-shadow here (unlike HexChoicePopup's
          # buttons) -- the card itself now casts one as a whole (see
          # style[:filter] below), so a second shadow per button would
          # just double up on top of that.
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
            # An opaque card, not just floating text/buttons over the map
            # -- without this the message (white text) sat directly on
            # whatever hex colors happened to be underneath it, unreadable
            # depending on the map (found live: exactly that, reported by
            # the user).
            backgroundColor: 'rgba(0, 0, 0, 0.85)',
            borderRadius: '6px',
            padding: '8px',
            filter: 'drop-shadow(3px 3px 4px #888)',
          }
          # Same edge-flip technique HexChoicePopup uses -- grows back
          # toward the hex (and the rest of the map) instead of past
          # whichever boundary it's close to.
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

        # Confirm actually explores -- runs the dispatch callback
        # View::Game::HexChoicePopup#choose had already built (the real
        # process_action, plus its own follow-up-popup chaining) before
        # this prompt intercepted it. Cleared first so a slow double-click
        # can't re-fire it. Also marks the warning acknowledged (see
        # Step::Route#acknowledge_lock_warning!) so it doesn't pop up
        # again before every later explore this same turn -- purely
        # local, same as the rest of this step's per-turn UI state, so
        # it needs no process_action of its own; dispatch.call's real
        # action re-renders everything, this included.
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
