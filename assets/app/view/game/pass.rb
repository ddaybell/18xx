# frozen_string_literal: true

require 'view/game/pass_button'
require 'view/game/pass_auto_button'

module View
  module Game
    class Pass < Snabberb::Component
      include Actionable
      needs :actions, default: []

      def render
        step = @game.round.active_step
        entity = @game.round.current_entity
        # Opt-in hook: a step whose own UI already surfaces an equivalent
        # Cancel button (e.g. G2038::Step::Route's per-row Cancel, right
        # next to Submit) can suppress this standalone one so the player
        # isn't shown two buttons doing the identical thing.
        suppressed = step.respond_to?(:suppress_standalone_pass?) && entity && step.suppress_standalone_pass?(entity)

        children = []
        if @actions.include?('pass') && !suppressed
          children << h(PassButton)
          children << h(PassAutoButton) if @game.round.show_auto? && @game.active_players_id.include?(@user&.dig('id'))
        end
        h(:div, children.compact)
      end
    end
  end
end
