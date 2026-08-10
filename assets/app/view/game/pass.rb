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
        # isn't shown two buttons doing the identical thing -- found live
        # in browser: a route pending Submit showed "Cancel" both here
        # and on its ship's own row. Every other game's step doesn't
        # implement suppress_standalone_pass?, so this is always false
        # for them and behavior is unchanged.
        suppressed = step.respond_to?(:suppress_standalone_pass?) && entity && step.suppress_standalone_pass?(entity)

        children = []
        if @actions.include?('pass') && !suppressed
          children << h(PassButton)
          # In hotseat mode there's no real "logged in as this specific
          # player" concept -- one local browser session plays every
          # seat -- so the real account id in @user has nothing to do
          # with the small sequential in-game player ids (0..n-1) and can
          # coincidentally collide with exactly one of them. That made
          # this button appear only for whichever player's id happened to
          # match the logged-in account's real id, regardless of whose
          # turn it actually was. process_action (actionable.rb) already
          # exempts hotseat from this exact kind of per-player identity
          # check for the same reason; mirror that here.
          children << h(PassAutoButton) if @game.round.show_auto? && (hotseat? || @game.active_players_id.include?(@user&.dig('id')))
        end
        h(:div, children.compact)
      end
    end
  end
end
