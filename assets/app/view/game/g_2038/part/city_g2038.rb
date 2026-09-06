# frozen_string_literal: true

module View
  module Game
    module Part
      # G2038-only City rendering: mine color/ore-letter/used-marker
      # overlays, claim ownership rings, home-delivery-bonus badges, and
      # the trackless-tile revenue/hide-city hooks. Mixed into the shared
      # Part::City component the same way HexG2038 is mixed into Hex --
      # every method here is only ever called from a
      # `@game.respond_to?(...)`-gated site in city.rb itself (or, for
      # `should_render?`/`trackless_game?`, only ever returns something
      # other than the prior default when the current game defines the
      # G2038-only hook/constant they check), so no other game's city
      # rendering is affected.
      module CityG2038
        def self.included(base)
          # Snabberb only populates an ivar for a `needs` key a
          # component's own class (or an ancestor) explicitly declares --
          # there's no implicit fallback to the global store just because
          # some *other* component already declared `:game`. Without
          # this, every `@game` reference below (mine-claim-owner
          # emphasis, home-delivery-bonus lookup, mine ore/value lookups)
          # was silently reading `nil` -- found live in browser chasing a
          # G2038 bug, but scoped here (not Part::Base) after confirming
          # other Part::* files use `@game` too, and one of them
          # (borders.rb's remove-border click handler, the sole trigger
          # for 18 India's gauge-change-marker removal -- confirmed via
          # its own code comment, "Triggered by on_click event in
          # View::Game::Part::Borders", with no other path to that
          # action) would have picked up a real behavior change for that
          # other game from a shared-base fix. That one's being left
          # alone and reported separately rather than silently changed as
          # a side effect of this G2038 session.
          base.needs :game, default: nil, store: true
        end

        # Opt-in hook: a game can hide a city part entirely -- e.g.
        # G2038's H10, whose empty AL-reserved token slot would
        # otherwise read as "a base is already here" well before the AL
        # actually exists to occupy it (H10 doubles as both a
        # transshipment point and the AL's future home base). The city
        # only needs to render once that stops being true -- see
        # Game#hide_city?/Game#transshipment_hex?.
        def should_render?
          !(@game.respond_to?(:hide_city?) && @game.hide_city?(@tile&.hex, @city))
        end

        # This hex's [ore, amount] home-base delivery bonus (Phase 7b), if
        # any -- a corp's *fixed* home coordinates pay a flat bonus to
        # whoever delivers the matching ore there, so this is read straight
        # off Game#home_delivery_bonuses (keyed by hex id) rather than any
        # per-tile data; most gray home-base hexes have none.
        #
        # Detached preview tiles (e.g. Lucky's tile-choice popup, and the
        # standard TileSelector fan) are wrapped in a throwaway Engine::Hex
        # always named 'A1' (see hex_choice_popup.rb/tile_selector.rb) --
        # which coincidentally collides with a real corp's home coordinate
        # in this game (Mars Mining). The same identity check the shared
        # engine already uses to detect a fake preview hex (Game::Base
        # #update_tile_lists's own "TileSelector creates fake A1 hexes"
        # comment) rules that out here too, so a preview tile never shows a
        # real hex's delivery bonus badge in place of its mine value.
        def delivery_bonus
          return nil unless @game.respond_to?(:home_delivery_bonuses)
          return nil unless @tile.hex == @game.hex_by_id(@tile.hex.id)

          @game.home_delivery_bonuses[@tile.hex.id]
        end

        # Same colored-circle language as a mine's ore tint (Nickel red/Ice
        # blue/Rare green -- see MINE_ORE_COLOR/mine_color above), always at
        # the same shade since there's no per-hex value scale here, just a
        # flat bonus amount.
        DELIVERY_BONUS_TINT = 0.6
        DELIVERY_BONUS_RADIUS = 18
        DELIVERY_BONUS_FONT_SIZE = '15px'
        # On the same local-unit scale as Part::City::SLOT_RADIUS (25,
        # the token's own radius) -- how much farther out from the
        # base's center the badge sits than a plain revenue circle
        # would, per the user.
        DELIVERY_BONUS_RADIAL_SHIFT = 3

        def render_delivery_bonus(ore, amount)
          base = MINE_ORE_COLOR[ore]
          r, g, b = base.map { |c| ((c * (1 - DELIVERY_BONUS_TINT)) + (255 * DELIVERY_BONUS_TINT)).round.clamp(0, 255) }
          fill = format('#%02x%02x%02x', r, g, b)

          h(:g, { attrs: { transform: rotation_for_layout } }, [
            h(:circle, attrs: { r: DELIVERY_BONUS_RADIUS, fill: fill, stroke: '#777777' }),
            h(:text, {
                attrs: {
                  fill: 'black',
                  'font-size': DELIVERY_BONUS_FONT_SIZE,
                  'text-anchor': 'middle',
                  'dominant-baseline': 'central',
                  transform: 'translate(0 -1)',
                },
              }, "+#{amount}"),
          ])
        end

        # Mirrors RevenueCenter#route_base_revenue's phase lookup, so the
        # displayed number always matches what a route would actually pay.
        def current_phase_revenue
          @game.phase.tiles.reverse_each { |color| return @city.revenue[color] if @city.revenue[color] }
          @city.revenue.values.first
        end

        # G2038's cities carry no track by design (see HIDE_TILE_TRACK in
        # track.rb) -- the revenue-display gate above otherwise requires
        # @city.paths.any?, a proxy for "connected to the track network"
        # that's meaningless here and would hide every mine's revenue.
        def trackless_game?
          @game&.class&.const_defined?(:HIDE_TILE_TRACK) && @game.class::HIDE_TILE_TRACK
        end

        # This city's index within its tile's cities array -- shared by all
        # the mine-overlay lookups below, so it's only ever scanned once.
        def mine_index
          @mine_index ||= @tile.cities.index(@city)
        end

        def mine_used?
          @game.respond_to?(:mine_used?) && @game.mine_used?(@tile.hex.id, mine_index)
        end

        # This city's mine ore type (:n/:i/:r), if any. Reads MINE_DATA
        # (keyed by tile name, always available) rather than mine_state
        # (keyed by hex id, only populated for hexes actually on the map)
        # so this also works for a detached preview tile -- e.g. Lucky's
        # tile-choice popup, which renders a tile that was never laid
        # anywhere.
        def mine_ore
          return nil unless @game.class.const_defined?(:MINE_DATA)

          @game.class::MINE_DATA.dig(@tile.name, mine_index, :ore)
        end

        # Shown inside the city circle itself rather than as a generic
        # tile-level label, since a double-mine tile can hold two
        # different ore types.
        def mine_ore_letter
          mine_ore&.to_s&.upcase
        end

        MINE_ORE_COLOR = { n: [200, 40, 40], i: [40, 100, 210], r: [40, 150, 70] }.freeze
        MINE_VALUE_RANGE = (10..70)

        # Tints the mine circle by ore type (Nickel red, Ice blue, Rare
        # green), darker for a higher unclaimed value -- capped so even the
        # darkest mines stay light enough for the ore letter to read
        # clearly on top. Always keyed off the unclaimed value (from
        # MINE_DATA, not the city's live revenue) so a mine's color doesn't
        # change once claimed -- place_claim! swaps @city.revenue to the
        # (higher) claimed rate, which would otherwise darken the circle.
        def mine_color
          base = MINE_ORE_COLOR[mine_ore]
          return nil unless base

          value = @game.class::MINE_DATA.dig(@tile.name, mine_index, :unclaimed) || MINE_VALUE_RANGE.min
          span = MINE_VALUE_RANGE.max - MINE_VALUE_RANGE.min
          t = ((value - MINE_VALUE_RANGE.min).to_f / span).clamp(0.0, 1.0)
          white_blend = 0.82 - (0.42 * t)

          r, g, b = base.map { |c| ((c * (1 - white_blend)) + (255 * white_blend)).round.clamp(0, 255) }
          format('#%02x%02x%02x', r, g, b)
        end

        # `pointer-events: none` on all three of these (this and the next
        # two methods) -- each paints on top of `slots` (added to
        # `children` earlier, so painted first/underneath), as a sibling
        # rather than a child of the actual clickable CitySlot circle. Left
        # clickable, any of the three would silently steal the click meant
        # for the mine underneath, bubbling it up to Part::City's own
        # touch_node handler instead (a no-op for G2038, since it never
        # has 'run_routes', but critically one that never stops
        # propagation) -- which then keeps bubbling all the way to the
        # hex's own click handler, always opening the disambiguation
        # popup instead of the intended direct single-mine pickup. Found
        # live: a direct click on a double-mine hex's own city circle
        # never worked, at all, confirmed by the user. Only ever painted
        # for a G2038 mine city (mine_ore/mine_used? both gate on G2038-
        # only game methods), so this can't affect any other game's city
        # rendering.
        def render_mine_color
          h(:circle, attrs: { r: City::SLOT_RADIUS - 1, fill: mine_color, 'pointer-events': 'none' })
        end

        def render_ore_letter(letter)
          h(:text, {
              attrs: {
                fill: 'black',
                'font-size': '28px',
                'text-anchor': 'middle',
                'dominant-baseline': 'central',
                'pointer-events': 'none',
              },
            }, letter)
        end

        def render_used_marker
          r = 14
          h(:g, { attrs: { 'pointer-events': 'none' } }, [
            h(:line, attrs: { x1: -r, y1: -r, x2: r, y2: r, stroke: 'white', 'stroke-width': 5, 'stroke-linecap': 'round' }),
            h(:line, attrs: { x1: -r, y1: r, x2: r, y2: -r, stroke: 'white', 'stroke-width': 5, 'stroke-linecap': 'round' }),
          ])
        end

        # render_part wraps all children in a rotate(render_location[:angle])
        # transform (to orient edge-attached cities). Location names (base and
        # transshipment labels) intentionally land at rotate(angle_for_layout)
        # -- -30 deg for pointy hexes, vertex-aligned rather than edge-aligned
        # -- via Part::LocationName's own rotation_for_layout wrapper. Adjust
        # from whatever angle this city happens to render at back to that
        # same target angle, so mine overlays match that convention exactly.
        def upright(elements)
          adjustment = angle_for_layout - (render_location[:angle] || 0)
          h(:g, { attrs: { transform: "rotate(#{adjustment})" } }, elements)
        end

        # The corporation/independent holding a claim on this mine, if any.
        def mine_claim_owner
          return nil unless @game.respond_to?(:mine_claim_owner)

          @game.mine_claim_owner(@tile.hex.id, mine_index)
        end

        # Doubled while `owner` is the entity currently taking its turn --
        # confirmed with the user some ROUTE_COLORS reds are hard to tell
        # apart at the normal ring size, and the active company's own
        # claims are exactly what a player is scanning the map for while
        # running its ships (or its other steps -- not narrowed to Route
        # specifically, since there's nothing Route-specific about wanting
        # to spot your own claims).
        def render_claim_ring(owner)
          base_radius = City::SLOT_RADIUS + 5
          radius = owner == @game.round.current_entity ? base_radius * 2 : base_radius

          h(:circle, attrs: {
              r: radius,
              fill: 'none',
              stroke: owner.color,
              'stroke-width': 8,
            })
        end
      end
    end
  end
end
