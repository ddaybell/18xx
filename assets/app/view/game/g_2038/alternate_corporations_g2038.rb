# frozen_string_literal: true

module View
  module Game
    module G2038
      # A delegate object, not a mixin, so View::Game::Corporation's own
      # method table never carries these.
      class AlternateCorporationsG2038
        def initialize(host, game, corporation)
          @host = host
          @game = game
          @corporation = corporation
        end

        def h(...)
          @host.h(...)
        end

        def infrastructure_tokens_body
          home = @corporation.tokens.first
          logo = @host.logo_for_user(@corporation)
          tokens_body = [[logo, home&.used, @corporation.coordinates]]
          tokens_body.concat(infra_entries(:bases, @game.base_hexes(@corporation), logo,
                                           reserved: @game.reserved_base_count(@corporation)))
          tokens_body.concat(@game.extra_base_hexes(@corporation).map { |hex_id| [logo, true, hex_id] })
          tokens_body.concat(infra_entries(:stations, @game.station_hexes(@corporation), @game.station_logo(@corporation)))
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

        # Mirrors Part::City::MINE_ORE_COLOR -- kept as its own copy rather
        # than reaching into that view class for three fixed colors.
        CLAIM_MINE_COLOR = { n: [200, 40, 40], i: [40, 100, 210], r: [40, 150, 70] }.freeze
        # Mirrors Part::City::MINE_VALUE_RANGE/#mine_color's white-blend tint.
        CLAIM_VALUE_RANGE = (10..70)

        # Free claims (Robot Smelters' ability) don't count against limit,
        # but still need their own placed column.
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

          # Required, not stylistic: without stable keys, Snabbdom's
          # positional reconciliation can hand one column's DOM nodes to a
          # different column when `entries`' re-sort shifts positions.
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
