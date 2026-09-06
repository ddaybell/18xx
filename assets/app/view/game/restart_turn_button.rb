# frozen_string_literal: true

require 'view/game/actionable'
require 'view/game/g_2038/restart_turn_button_g2038'

module View
  module Game
    class RestartTurnButton < Snabberb::Component
      include Actionable
      # For G2038: local-turn-state detection.
      include RestartTurnButtonG2038

      def render
        button_text, turn_start_action_id =
          if local_turn_pending? || @game.turn_start_action_id != @game.last_game_action_id
            ['Restart Turn', @game.turn_start_action_id]
          else
            ['Restart Last Turn', @game.last_turn_start_action_id]
          end

        action = lambda do
          # Discard any local, unsubmitted progress in one shot before
          # dispatching the real Undo -- process_action (actionable.rb)
          # always checks local_undo? first, for *any* caller, and
          # local_undo! only steps back one hex at a time (the right
          # granularity for the ordinary Undo button/ctrl+z, but not for
          # this one). Without this, clicking Restart Turn while mid-
          # Modify got silently reduced to that same single-hex step --
          # the real Undo (which would have jumped straight to
          # turn_start_action_id) never even ran until enough repeat
          # clicks had walked the whole local route back by hand.
          step = @game.round.active_step
          entity = @game.current_entity
          step.local_pass!(entity) if local_turn_pending? && step.respond_to?(:local_pass!)
          process_action(Engine::Action::Undo.new(entity, action_id: turn_start_action_id))
        end

        h('button',
          { style: { marginTop: :inherit }, on: { click: action }, attrs: { disabled: button_disabled? } },
          button_text)
      end

      def button_disabled?
        !@game.undo_possible || !@game.turn_start_action_id || @game.round.is_a?(Engine::Round::Auction)
      end
    end
  end
end
