# frozen_string_literal: true

require 'user_manager'
require 'lib/settings'
require 'lib/storage'
require 'view/form'

module View
  module Game
    module G2038
      # G2038's autorouter is a single-phase ship-route search with no
      # separate path-building phase, and its final per-ship pass always
      # runs to full proof regardless of a route timeout -- neither of
      # the base AutoRouterSettings' fields (Path timeout, Route timeout)
      # ever does anything for this game. Ranking timeout (the per-ship
      # budget for deciding what order to fly multiple ships in) is the
      # one real timing control G2038 has, so it gets its own settings
      # panel entirely, instead of the base component showing two dead
      # fields alongside it.
      class AutoRouterSettings < View::Form
        include Lib::Settings
        include UserManager

        needs :ranking_timeout, store: true, default: 4

        def render_content
          h(:div, [
            h(:h3, 'Auto Router Settings'),
            render_input(
              'Ranking timeout:',
              id: :ranking_timeout,
              type: :number,
              input_style: { width: '5rem' },
              attrs: {
                # No entry in Lib::Settings::SETTINGS (a shared, cross-
                # game hash) for a value only this game reads -- the
                # `|| 4` fallback mirrors ship_selector.rb's own default
                # (matching Step::Route::TRIAL_TIMEOUT), so the field
                # shows a sane starting number rather than blank before
                # the player has ever touched it.
                value: setting_for(:ranking_timeout) || 4,
              },
              on: { change: -> { submit_ranking_timeout } }
            ),
            h(:label, 'seconds'),
            h(:div, 'Per-ship budget (2+ ships) for ranking which order to auto-route them in -- raising this '\
                    'makes the chosen order more likely to be truly optimal, at the cost of a longer wait before '\
                    'ships start building routes.'),
          ])
        end

        def submit_ranking_timeout
          store(:ranking_timeout, params['ranking_timeout'], skip: true)
          edit_user(params)
        end
      end
    end
  end
end
