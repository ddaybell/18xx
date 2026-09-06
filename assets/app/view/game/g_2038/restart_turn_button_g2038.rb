# frozen_string_literal: true

module View
  module Game
    # G2038-only local-turn-state detection for the Restart Turn button.
    # Mixed into the shared RestartTurnButton component the same way
    # HexG2038 is mixed into Hex -- `local_undo?` is only ever defined by
    # G2038's Route step, so this returns false (its old, pre-existing
    # behavior) for every other game.
    module RestartTurnButtonG2038
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
