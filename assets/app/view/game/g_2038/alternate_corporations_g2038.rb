# frozen_string_literal: true

module View
  module Game
    module G2038
      # G2038-only corporation-card rendering: the claims strip (mine-colored
      # claim circles) and the base/station infrastructure strip. Delegate
      # object (not a mixin) so View::Game::Corporation's own method table
      # never carries these -- instantiated per-render by Corporation#g2038,
      # handed `self` for `h`/`logo_for_user` access since Snabberb's `needs`
      # only sets ivars, not public readers.
      class AlternateCorporationsG2038
        def initialize(host, game, corporation)
          @host = host
          @game = game
          @corporation = corporation
        end

        def h(...)
          @host.h(...)
        end

        # `reserved` (AL only, bases only) counts how many of
        # the not-yet-placed slots below are actually held back for
        # independents still outside the League, marked "Res." instead of
        # looking like any other open, unclaimed slot.
        def infrastructure_tokens_body
          home = @corporation.tokens.first
          logo = @host.logo_for_user(@corporation)
          tokens_body = [[logo, home&.used, @corporation.coordinates]]
          tokens_body.concat(infra_entries(:bases, @game.base_hexes(@corporation), logo,
                                           reserved: @game.reserved_base_count(@corporation)))
          # Extra bases beyond the corp's own lifetime allotment -- inherited
          # from a Growth Corp conversion or an AL merger, or
          # granted by Tunnel Systems' free-base ability.
          tokens_body.concat(@game.extra_base_hexes(@corporation).map { |hex_id| [logo, true, hex_id] })
          tokens_body.concat(infra_entries(:stations, @game.station_hexes(@corporation), @game.station_logo(@corporation)))
          # Extra stations beyond the corp's own placement list -- granted by
          # Vacuum Associates' free-station ability.
          tokens_body.concat(@game.extra_station_hexes(@corporation).map do |hex_id|
            [@game.station_logo(@corporation), true, hex_id]
          end)
          tokens_body.sort_by! { |t| t[1] ? 1 : -1 }
        end

        def infra_entries(cost_key, placed_hexes, logo, reserved: 0)
          schedule = @game.corp_data(@corporation)&.dig(cost_key) || []
          schedule.each_index.map do |i|
            hex_id = placed_hexes[i]
            next [logo, true, hex_id] if hex_id

            if reserved.positive?
              reserved -= 1
              [logo, true, 'Res.']
            else
              [logo, false, @game.format_currency(schedule[i])]
            end
          end
        end

        # A played claim's column shows its own mine -- a circle in that
        # mine's ore color, the ore letter inside it, the claimed value
        # above it -- instead of a generic flag icon, per the user. Same
        # RGB values as Part::City::MINE_ORE_COLOR (the mine-tile art's own
        # ore tint), kept as its own copy rather than reaching into that
        # view class from this one for three fixed colors.
        CLAIM_MINE_COLOR = { n: [200, 40, 40], i: [40, 100, 210], r: [40, 150, 70] }.freeze
        # Mirrors Part::City::MINE_VALUE_RANGE/#mine_color's white-blend
        # tint exactly, so a claim's circle here looks like the same mine
        # did on the hex (pale for a low value, more saturated for a high
        # one) instead of a flat, fully-saturated color regardless of
        # value.
        CLAIM_VALUE_RANGE = (10..70)

        # One column per claim slot, plus one more for each
        # free claim actually placed (Robot Smelters' one-time ability) --
        # those don't consume a counted slot (see Game#claims_placed_
        # lifetime's own comment) but are still real, placed claims that
        # need to actually show up here. A played claim gets its own
        # mine-colored circle, an unplaced/reserved slot still gets the
        # generic flag look.
        def render_claims_display
          limit = @game.claim_limit(@corporation)
          return if limit.infinite?

          schedule = @game.claim_cost_schedule(@corporation)
          header = "Claims: #{schedule.map { |c| @game.format_currency(c) }.join('/')} per turn"

          placed = @game.claim_details(@corporation)
          counted_placed = placed.reject { |detail| detail[:free] }
          logo = @game.claim_logo(@corporation)
          reserved = @game.reserved_claim_count(@corporation)
          entries = placed.map { |detail| [:placed, detail] }
          entries.concat(Array.new([limit.to_i - counted_placed.size, 0].max) do
            if reserved.positive?
              reserved -= 1
              [:unplaced, [logo, true, 'Res.']]
            else
              [:unplaced, [logo, false, '']]
            end
          end)
          entries.sort_by! { |kind, _| kind == :placed ? 1 : -1 }

          token_list_props = {
            style: {
              grid: '1fr / auto-flow',
              justifyContent: 'start',
              gap: '0 0.2rem',
              width: '100%',
              overflow: 'auto',
            },
          }

          # Explicit, stable keys on every column -- required, not just
          # stylistic. `entries` gets re-sorted (placed always after
          # unplaced) on every single render, and the *count* of each kind
          # shifts the instant a claim is acquired/placed (one fewer
          # unplaced slot, one more placed column, inserted mid-list) --
          # Snabbdom's keyless reconciliation matches list children by
          # position, so without a key here a claim changing hands mid-OR
          # can silently hand one column's DOM nodes (including its used-
          # marker) to a completely different column instead of updating
          # them, which reads to the player as the charter's own white X
          # vanishing even though claim_details' own `used` value never
          # actually changed underneath it.
          columns = entries.each_with_index.map do |(kind, data), i|
            if kind == :placed
              render_claim_column(data[:ore], data[:value], data[:hex_id], data[:used], data[:free],
                                  key: "g2038-claim-#{data[:hex_id]}-#{data[:mine_idx]}")
            else
              h(:div, { key: "g2038-claim-unplaced-#{i}", style: { display: 'contents' } }, [@host.render_token_column(*data)])
            end
          end

          h(:div, [
            h(:div, header),
            h(:div, token_list_props, columns),
          ])
        end

        def tinted_claim_color(ore, value)
          base = CLAIM_MINE_COLOR[ore]
          span = CLAIM_VALUE_RANGE.max - CLAIM_VALUE_RANGE.min
          t = ((value - CLAIM_VALUE_RANGE.min).to_f / span).clamp(0.0, 1.0)
          white_blend = 0.82 - (0.42 * t)

          r, g, b = base.map { |c| ((c * (1 - white_blend)) + (255 * white_blend)).round.clamp(0, 255) }
          format('#%<r>02x%<g>02x%<b>02x', r: r, g: g, b: b)
        end

        def render_claim_column(ore, value, hex_id, used, free = false, key: nil)
          color = tinted_claim_color(ore, value)
          props = {
            key: key,
            attrs: { title: "claim location: #{hex_id}#{free ? ' (free claim, Robot Smelters, Inc.)' : ''}" },
            style: { grid: '1fr auto / 1fr', textAlign: 'center' },
          }
          circle_props = {
            style: {
              position: 'relative',
              width: '1.2rem',
              height: '1.2rem',
              margin: '0 auto',
              borderRadius: '50%',
              background: color,
              color: '#000000',
              fontWeight: 'bold',
              fontSize: '0.45rem',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            },
          }
          hex_props = { style: { fontSize: '0.65rem' } }

          circle_children = [@game.format_currency(value)]
          circle_children << render_used_mine_mark if used

          hex_label = free ? "#{hex_id} (RSI)" : hex_id

          h(:div, props, [h(:div, circle_props, circle_children), h(:div, hex_props, hex_label)])
        end

        USED_MINE_MARK_LINE = {
          position: 'absolute',
          top: '50%',
          left: '50%',
          width: '85%',
          height: '2px',
          background: '#ffffff',
        }.freeze

        def render_used_mine_mark
          h(:div, { key: 'g2038-used-mine-mark' }, [
            h(:div, { style: USED_MINE_MARK_LINE.merge(transform: 'translate(-50%, -50%) rotate(45deg)') }),
            h(:div, { style: USED_MINE_MARK_LINE.merge(transform: 'translate(-50%, -50%) rotate(-45deg)') }),
          ])
        end
      end
    end
  end
end
