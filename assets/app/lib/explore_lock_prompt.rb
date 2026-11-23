# frozen_string_literal: true

module Lib
  # G2038-only: positions a warning + Confirm/Cancel popup near the hex
  # whose Explore choice would lock in every route already submitted this
  # OR (see Step::Route#explore_would_lock_other_routes?). `dispatch` is
  # the "go ahead and explore" callback HexChoiceSelector#choose had
  # already built before deciding this warning applies.
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
