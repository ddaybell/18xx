# frozen_string_literal: true

module View
  module Game
    module Part
      # G2038-only Revenue-box positioning/visibility hooks: forcing a
      # transshipment hex's revenue box to the bottom position, hiding a
      # stale printed value once a hex becomes the Asteroid League's home
      # base, and swapping in display-only text overrides. Mixed into the
      # shared Part::Revenue component the same way HexG2038 is mixed
      # into Hex -- every method here only ever changes behavior when
      # `@game` implements the specific opt-in hook it checks, so no
      # other game's revenue-box rendering is affected.
      module RevenueG2038
        def self.included(base)
          # See Part::City's identical declaration for why this is here
          # (Snabberb needs an explicit `needs :game` per class, no
          # implicit fallback) and why it's scoped to this file rather
          # than Part::Base.
          base.needs :game, default: nil, store: true
        end

        # Opt-in hook: a game can force this hex's revenue box to the
        # bottom-of-hex candidate location instead of whatever the
        # region-occupancy algorithm below would otherwise pick (e.g.
        # G2038's transshipment points, which have nothing else on the
        # tile competing for space, so the default always lands at
        # dead-center -- exactly where that game wants to draw its own
        # centered satellite icon instead, see hex.rb#satellite_icon).
        # Every other game doesn't implement this, so behavior is
        # unchanged for them.
        def forced_to_bottom?
          @tile&.hex && @game.respond_to?(:offboard_forced_bottom?) && @game.offboard_forced_bottom?(@tile.hex)
        end

        # Opt-in hook: a game can force this hex's revenue box to never
        # render at all, regardless of its printed value (e.g. G2038's
        # H10 transshipment point, whose printed value becomes stale/
        # meaningless the moment the Asteroid League forms and takes
        # the hex over as its own base -- see Game#hide_revenue?).
        # Every other game doesn't implement this, so behavior is
        # unchanged for them.
        def hidden_by_game?
          @tile&.hex && @game.respond_to?(:hide_revenue?) && @game.hide_revenue?(@tile.hex)
        end

        # Opt-in hook: a game can override the *displayed* text for a
        # specific phase-color box without touching the real revenue
        # value underneath (e.g. G2038's H10 transshipment point, whose
        # "gray" $0 entry can never actually be paid -- the hex becomes
        # the Asteroid League's home base the moment gray phase makes it
        # possible to reach that value -- showing "AL" there instead of
        # a misleading "$0"). MultiRevenue's own text/width computation
        # is generic string interpolation, so a String value here
        # renders exactly as-is with no other side effects; the engine's
        # real RevenueCenter#revenue (what routes actually pay) is
        # untouched, since only this display-only copy is modified.
        def display_revenues
          return @revenue unless @game.respond_to?(:revenue_text_override)

          @revenue.to_h do |phase, revenue|
            override = @tile&.hex && @game.revenue_text_override(@tile.hex, phase)
            [phase, override || revenue]
          end
        end
      end
    end
  end
end
