# frozen_string_literal: true

module Lib
  # G2038-only: positions a warning + Confirm/Cancel popup near the hex
  # whose Explore choice would lock in every route already submitted this
  # OR (see Step::Route#explore_would_lock_other_routes?). Carries the same
  # {hex, coordinates, entity, role} shape Lib::HexChoiceSelector already
  # uses for map.rb's own positioning logic (near_right_edge/near_top_edge/
  # near_bottom_edge, computed the same way for either), plus the one thing
  # unique to this prompt: `dispatch`, the actual "go ahead and explore"
  # callback View::Game::HexChoiceSelector#choose had already built before
  # deciding this warning applies -- captured here instead of discarded, so
  # confirming can still run it.
  class ExploreLockPrompt
    attr_reader :entity, :hex, :x, :y, :role, :dispatch

    def initialize(hex, coordinates, entity, role, dispatch)
      @hex = hex
      @x, @y = coordinates
      @entity = entity
      @role = role
      @dispatch = dispatch
    end
  end
end
