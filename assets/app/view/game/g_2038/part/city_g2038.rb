# frozen_string_literal: true

module View
  module Game
    module G2038
      module Part
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

          # A detached preview tile (e.g. a tile-choice popup) is wrapped in
          # a throwaway Engine::Hex always named 'A1' -- which coincidentally
          # collides with a real corp's home coordinate here (Mars Mining).
          # The identity check (not just an id match) rules that out.
          def delivery_bonus
            return nil unless @tile.hex == @game.hex_by_id(@tile.hex.id)

            @game.home_delivery_bonuses[@tile.hex.id]
          end

          DELIVERY_BONUS_TINT = 0.6
          DELIVERY_BONUS_RADIUS = 18
          DELIVERY_BONUS_FONT_SIZE = '15px'
          # Same local-unit scale as Part::City::SLOT_RADIUS.
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

          # Mirrors RevenueCenter#route_base_revenue's phase lookup.
          def current_phase_revenue
            @game.phase.tiles.reverse_each { |color| return @city.revenue[color] if @city.revenue[color] }
            @city.revenue.values.first
          end

          def mine_index
            @mine_index ||= @tile.cities.index(@city)
          end

          def mine_used?
            @game.mine_used?(@tile.hex.id, mine_index)
          end

          # Reads MINE_DATA (keyed by tile name) rather than mine_state
          # (keyed by hex id) so this also works for a detached preview
          # tile that was never laid anywhere.
          def mine_ore
            @game.class::MINE_DATA.dig(@tile.name, mine_index, :ore)
          end

          def mine_ore_letter
            mine_ore&.to_s&.upcase
          end

          MINE_ORE_COLOR = { n: [200, 40, 40], i: [40, 100, 210], r: [40, 150, 70] }.freeze
          MINE_VALUE_RANGE = (10..70)

          # Keyed off MINE_DATA's unclaimed value, not @city.revenue --
          # place_claim! swaps revenue to the claimed rate, which would
          # otherwise darken the circle once claimed.
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

          # pointer-events: none on this and the next two methods -- each
          # paints as a sibling of the clickable CitySlot circle, and left
          # clickable would steal the click meant for the mine underneath.
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

          # Explicit key required: this element toggles on/off by presence
          # (mine_used?), and without a key, Snabbdom's keyless
          # reconciliation matches siblings by position -- a claim change
          # that shifts which overlays exist can silently reassign this
          # line pair's DOM nodes to the wrong vnode instead of toggling.
          def render_used_marker
            r = 14
            h(:g, { key: 'g2038-used-marker', attrs: { 'pointer-events': 'none' } }, [
              h(:line, attrs: { x1: -r, y1: -r, x2: r, y2: r, stroke: 'white', 'stroke-width': 5, 'stroke-linecap': 'round' }),
              h(:line, attrs: { x1: -r, y1: r, x2: r, y2: -r, stroke: 'white', 'stroke-width': 5, 'stroke-linecap': 'round' }),
            ])
          end

          # Counter-rotates from render_part's per-city angle back to
          # Part::LocationName's angle_for_layout convention, so these
          # overlays stay upright the same way location-name labels do.
          def upright(elements)
            adjustment = @host.angle_for_layout - (@host.render_location[:angle] || 0)
            h(:g, { key: 'g2038-mine-overlays', attrs: { transform: "rotate(#{adjustment})" } }, elements)
          end

          def mine_claim_owner
            @game.mine_claim_owner(@tile.hex.id, mine_index)
          end

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
