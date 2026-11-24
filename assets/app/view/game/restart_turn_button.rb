# frozen_string_literal: true

require 'view/game/actionable'

module View
  module Game
    class RestartTurnButton < Snabberb::Component
      include Actionable

      # Without this, turn_start_action_id == last_game_action_id looks
      # identical whether the turn hasn't started, or the player has
      # hand-flown most of a route (see Step::Route#local_undo?) without
      # submitting anything real yet.
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
          # local_pass! discards all local progress at once; local_undo!
          # (what process_action checks first) only steps back one hex.
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
