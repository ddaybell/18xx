# frozen_string_literal: true

module View
  module Game
    module G2038
      # Its autorouter is a single-phase ship-route search with no separate
      # path-building phase, and its final per-ship pass always runs to
      # full proof regardless of a route timeout -- neither of the base
      # AutoRouterSettings' fields (Path timeout, Route timeout) ever does
      # anything for this game. Ranking timeout (the per-ship budget for
      # deciding what order to fly multiple ships in) is the one real
      # timing control it has, so its settings panel shows only that field
      # instead of two dead ones alongside it.
      #
      # Delegate object (not a mixin) so View::Game::AutoRouterSettings'
      # own method table never carries these -- instantiated by
      # AutoRouterSettings#render_content only when @game.respond_to?
      # (:autorouter), handed the host for render_input/setting_for/
      # params/store/edit_user access (all public on Form/Lib::Settings/
      # UserManager, which the host already includes/extends).
      class AutoRouterSettingsG2038
        def initialize(host)
          @host = host
        end

        def h(...)
          @host.h(...)
        end

        def render_single_phase_content
          h(:div, [
            h(:h3, 'Auto Router Settings'),
            @host.render_input(
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
                value: @host.setting_for(:ranking_timeout) || 4,
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
          @host.store(:ranking_timeout, @host.params['ranking_timeout'], skip: true)
          @host.edit_user(@host.params)
        end
      end
    end
  end
end
