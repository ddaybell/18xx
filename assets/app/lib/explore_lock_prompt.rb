# frozen_string_literal: true

module Lib
  # See Step::Route#explore_would_lock_other_routes?. `dispatch` is the
  # "go ahead and explore" callback HexChoiceSelector#choose already built.
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
