# frozen_string_literal: true

require 'view/game/actionable'

module View
  module Game
    class RestartTurnButton < Snabberb::Component
      include Actionable

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
          # clicks had walked the whole local route back by hand. Found
          # live in browser: had to click Restart Turn 3-4 times after
          # Modify-ing a route before it actually reached the start of
          # the turn.
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

      # Whether the current entity's turn has real, undo-worthy progress
      # that never made it into the action log -- e.g. G2038's routes are
      # built entirely client-side and stay unrecorded until Submit (see
      # Step::Route#local_undo?, the same opt-in hook the ordinary Undo
      # button already consults via actionable.rb). Without this,
      # turn_start_action_id == last_game_action_id looks identical
      # whether the turn genuinely hasn't started yet or the player has
      # spent several minutes hand-flying most of a route without
      # submitting anything real -- found live in browser: mid-route on
      # DH with nothing submitted yet, the button read "Restart Last
      # Turn" and would have targeted the *previous* entity's turn start,
      # not DH's own, since nothing of DH's was in the action log to
      # distinguish the two.
      def local_turn_pending?
        step = @game.round.active_step
        entity = @game.round.current_entity
        step.respond_to?(:local_undo?) && entity && step.local_undo?(entity)
      end
    end
  end
end
