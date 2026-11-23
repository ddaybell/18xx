# frozen_string_literal: true

module View
  module Game
    module G2038
      module Part
        # G2038-only City rendering: mine color/ore-letter/used-marker
        # overlays, claim ownership rings, and home-delivery-bonus badges.
        # Delegate object (not a mixin) so View::Game::Part::City's own
        # method table never carries these -- instantiated once per City
        # render via City#g2038.
        class CityDecorations
          def initialize(host, game, tile, city)
            @host = host
            @game = game
            @tile = tile
            @city = city
          end

          def h(...)
            @host.h(...)
          end

          # This hex's [ore, amount] home-base delivery bonus (Phase 7b), if
          # any -- a corp's *fixed* home coordinates pay a flat bonus to
          # whoever delivers the matching ore there, so this is read straight
          # off Game#home_delivery_bonuses (keyed by hex id) rather than any
          # per-tile data; most gray home-base hexes have none.
          #
          # Detached preview tiles (e.g. Lucky's tile-choice popup, the
          # standard TileSelector fan) are wrapped in a throwaway
          # Engine::Hex always named 'A1' (see hex_choice_selector.rb/
          # tile_selector.rb) -- which coincidentally collides with a real
          # corp's home coordinate in this game (Mars Mining). The same
          # identity check used to detect a fake preview hex (Game::Base
          # #update_tile_lists) rules that out here too.
          def delivery_bonus
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
          # the token's own radius).
          DELIVERY_BONUS_RADIAL_SHIFT = 3

          def render_delivery_bonus(ore, amount)
            base = MINE_ORE_COLOR[ore]
            r, g, b = base.map { |c| ((c * (1 - DELIVERY_BONUS_TINT)) + (255 * DELIVERY_BONUS_TINT)).round.clamp(0, 255) }
            fill = format('#%<r>02x%<g>02x%<b>02x', r: r, g: g, b: b)

            h(:g, { attrs: { transform: @host.rotation_for_layout } }, [
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

          # This city's index within its tile's cities array -- shared by all
          # the mine-overlay lookups below, so it's only ever scanned once.
          def mine_index
            @mine_index ||= @tile.cities.index(@city)
          end

          def mine_used?
            @game.mine_used?(@tile.hex.id, mine_index)
          end

          # This city's mine ore type (:n/:i/:r), if any. Reads MINE_DATA
          # (keyed by tile name, always available) rather than mine_state
          # (keyed by hex id, only populated for hexes actually on the map)
          # so this also works for a detached preview tile -- e.g. Lucky's
          # tile-choice popup, which renders a tile that was never laid
          # anywhere.
          def mine_ore
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
            format('#%<r>02x%<g>02x%<b>02x', r: r, g: g, b: b)
          end

          # `pointer-events: none` on all three of these (this and the
          # next two methods) -- each paints as a sibling, not a child,
          # of the actual clickable CitySlot circle. Left clickable, any
          # of the three would silently steal the click meant for the
          # mine underneath, bubbling up to Part::City's own touch_node
          # handler (a no-op for G2038, but one that never stops
          # propagation) and on to the hex's click handler, always
          # opening the disambiguation popup instead of the intended
          # direct single-mine pickup.
          def render_mine_color
            h(:circle, key: 'g2038-mine-color',
                       attrs: { r: View::Game::Part::City::SLOT_RADIUS - 1, fill: mine_color, 'pointer-events': 'none' })
          end

          def render_ore_letter(letter)
            h(:text, {
                key: 'g2038-ore-letter',
                attrs: {
                  fill: 'black',
                  'font-size': '28px',
                  'text-anchor': 'middle',
                  'dominant-baseline': 'central',
                  'pointer-events': 'none',
                },
              }, letter)
          end

          # Explicit key -- required, not just stylistic: this element's
          # very presence toggles on/off between renders (only shown
          # while mine_used?), and without a key Snabbdom's keyless
          # reconciliation matches children by sibling position, not
          # identity -- the instant a claim changes hands mid-OR (which
          # shifts which overlays exist/how many), a positional mismatch
          # can silently reassign this line pair's DOM nodes to the wrong
          # vnode instead of toggling them off, reading to the player as
          # "the white X disappeared" even though mine_used? itself never
          # changed.
          def render_used_marker
            r = 14
            h(:g, { key: 'g2038-used-marker', attrs: { 'pointer-events': 'none' } }, [
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
            adjustment = @host.angle_for_layout - (@host.render_location[:angle] || 0)
            h(:g, { key: 'g2038-mine-overlays', attrs: { transform: "rotate(#{adjustment})" } }, elements)
          end

          # The corporation/independent holding a claim on this mine, if any.
          def mine_claim_owner
            @game.mine_claim_owner(@tile.hex.id, mine_index)
          end

          # Doubled while `owner` is the entity currently taking its turn
          # -- some ROUTE_COLORS reds are hard to tell apart at the
          # normal ring size, and the active entity's own claims are what
          # a player is scanning the map for.
          def render_claim_ring(owner)
            base_radius = View::Game::Part::City::SLOT_RADIUS + 5
            radius = owner == @game.round.current_entity ? base_radius * 2 : base_radius

            h(:circle, key: 'g2038-claim-ring', attrs: {
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
end
