# frozen_string_literal: true

require 'view/game/actionable'

module View
  module Game
    class RestartTurnButton < Snabberb::Component
      include Actionable

      # Whether the current entity's turn has real, undo-worthy progress
      # that never made it into the action log -- e.g. G2038's routes
      # are built entirely client-side and stay unrecorded until Submit
      # (Step::Route#local_undo?, the same opt-in hook the ordinary
      # Undo button already consults via actionable.rb). Without this,
      # turn_start_action_id == last_game_action_id looks identical
      # whether the turn genuinely hasn't started yet or the player has
      # hand-flown most of a route without submitting anything real.
      # `local_undo?` is only ever defined by G2038's Route step, so
      # this returns false for every other game.
      def local_turn_pending?
        step = @game.round.active_step
        entity = @game.round.current_entity
        step.respond_to?(:local_undo?) && entity && step.local_undo?(entity)
      end

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
          # always checks local_undo? first, and local_undo! only
          # steps back one hex at a time (right for the ordinary Undo
          # button, but not for this one). Without this, clicking
          # Restart Turn while mid-Modify got silently reduced to that
          # same single-hex step.
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
