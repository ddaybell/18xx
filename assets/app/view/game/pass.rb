# frozen_string_literal: true

require 'view/game/pass_button'
require 'view/game/pass_auto_button'

module View
  module Game
    class Pass < Snabberb::Component
      include Actionable
      needs :actions, default: []

      def render
        children = []
        if @actions.include?('pass')
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
