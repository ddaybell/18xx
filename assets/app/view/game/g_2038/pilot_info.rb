# frozen_string_literal: true

module View
  module Game
    module G2038
      # A Growth Corp's inherited pilot ability/abilities (Phase 8),
      # displayed the same way View::Game::Company shows an owned private
      # company on a corp's charter (see Company#render_company_on_card):
      # just the pilot's name, clickable to toggle a hidden description
      # div open/closed, rather than one long string dumped onto the
      # card. Reuses that exact toggle mechanism -- a plain DOM style
      # flip on click (not a Snabberb store update) -- so an expanded
      # description survives the next unrelated re-render the same way
      # Company's own hidden company-description divs do (their `style:
      # { display: 'none' }` prop never itself changes between renders,
      # so Snabbdom's diff never patches the live-toggled value back).
      class PilotInfo < Snabberb::Component
        needs :corporation
        needs :game

        def render
          pilots = @game.pilot_details(@corporation)
          return h(:div) if pilots.empty?

          @hidden_divs = {}

          table_props = {
            style: {
              padding: '0 0.5rem 0.2rem',
              grid: 'auto / 1fr',
              gap: '0 0.3rem',
            },
          }

          h('div.company_table', table_props, [
            h('div.bold', 'Pilots'),
            *pilots.flat_map { |pilot| render_pilot_row(pilot) },
          ])
        end

        def toggle_desc(event, name)
          event.JS.stopPropagation
          elm = Native(@hidden_divs[name]).elm
          elm.style.display = elm.style.display == 'none' ? 'block' : 'none'
        end

        def render_pilot_row(pilot)
          name_props = {
            attrs: { title: "#{pilot[:name]}, click to toggle description" },
            style: { cursor: 'pointer' },
            on: { click: ->(event) { toggle_desc(event, pilot[:name]) } },
          }
          hidden_props = {
            style: {
              display: 'none',
              marginBottom: '0.5rem',
              padding: '0.1rem 0.2rem',
              fontSize: '80%',
            },
          }
          @hidden_divs[pilot[:name]] = h(:div, hidden_props, pilot[:description])

          [h('div.nowrap', name_props, pilot[:name]), @hidden_divs[pilot[:name]]]
        end
      end
    end
  end
end
