# frozen_string_literal: true

module View
  module Game
    # G2038-only Corporation-card rendering: the claims strip, the mine-
    # colored claim circles, the base/station infrastructure strip, and
    # the inherited-pilot-ability line. Mixed into the shared Corporation
    # component the same way HexG2038 is mixed into Hex -- every method
    # here is only ever called from a `@game.respond_to?(...)`-gated site
    # in corporation.rb itself, so no other game's Corporation card
    # exercises any of this.
    module CorporationG2038
      # G2038-only: bases and refueling stations are drawn from the same
      # pre-allocated $0-cost token pool (see Game#place_base!/
      # #place_station!), so a placed token's own price/hex can't tell you
      # its *type* -- Game#base_hexes/#station_hexes track placement order
      # and location separately, which is what this builds the whole strip
      # from instead (home token aside), so cost and base-vs-station type
      # are both always right regardless of placement order or skipped
      # sub-phases. Stations get their own logo (Game#station_logo, a
      # per-corp static SVG under public/logos/g_2038/) so they read
      # distinctly from bases in the same strip.
      def infrastructure_tokens_body
        home = @corporation.tokens.first
        tokens_body = [[logo_for_user(@corporation), home&.used, @corporation.coordinates]]
        tokens_body.concat(infra_entries(:bases, @game.base_hexes(@corporation), logo_for_user(@corporation),
                                          reserved: @game.reserved_base_count(@corporation)))
        # Extra bases beyond the corp's own lifetime allotment -- inherited
        # from a Growth Corp conversion or an AL merger (Phase 8/9), or
        # granted by Tunnel Systems' free-base ability (Phase 10). Always
        # already placed (never a future cost placeholder), at the
        # original independent's home hex (or wherever TS's ability was
        # used) -- previously invisible on the charter entirely, since
        # they're deliberately excluded from base_hexes/base_limit.
        tokens_body.concat(@game.extra_base_hexes(@corporation).map { |hex_id| [logo_for_user(@corporation), true, hex_id] })
        tokens_body.concat(infra_entries(:stations, @game.station_hexes(@corporation), @game.station_logo(@corporation)))
        # Extra stations beyond the corp's own placement list -- granted by
        # Vacuum Associates' free-station ability (Phase 10). Same "always
        # already placed, previously invisible on the charter" situation
        # as extra_base_hexes just above.
        tokens_body.concat(@game.extra_station_hexes(@corporation).map { |hex_id| [@game.station_logo(@corporation), true, hex_id] })
        tokens_body.sort_by! { |t| t[1] ? 1 : -1 }
      end

      # `reserved` (AL only, bases only -- see Game#reserved_base_count)
      # counts how many of the not-yet-placed slots below are actually
      # held back for independents still outside the League, marked
      # "Res." instead of looking like any other open, unclaimed slot.
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
      # value -- found live in browser alongside the same issue in
      # HexChoicePopup's claim icons.
      CLAIM_VALUE_RANGE = (10..70)

      # One column per lifetime claim slot (@game.claim_limit), plus one
      # more for each free claim actually placed (Robot Smelters' one-time
      # ability, Phase 10) -- those don't consume a counted slot (see
      # Game#claims_placed_lifetime's own comment) but are still real,
      # placed claims that need to actually show up here, not silently
      # drop off the end. A played claim gets its own mine-colored circle
      # (render_claim_column), an unplaced/reserved slot still gets the
      # generic flag look (render_token_column, same as the base/station
      # strip above, since there's no specific mine to show yet) -- unlike
      # bases/stations, a claim's cost isn't fixed per lifetime slot, it's
      # set by this round's tier, already spelled out in the header text.
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
        entries.concat([limit.to_i - counted_placed.size, 0].max.times.map do
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

        columns = entries.map do |kind, data|
          if kind == :placed
            render_claim_column(data[:ore], data[:value], data[:hex_id], data[:used], data[:free])
          else
            render_token_column(*data)
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
        format('#%02x%02x%02x', r, g, b)
      end

      # No ore letter -- color alone carries the ore type (per the user),
      # so the circle just holds the value, with the hex location below
      # it rather than only as a hover tooltip. `free` claims (Robot
      # Smelters' one-time ability) are visually tagged "(RSI)" next to
      # the hex id -- per the user, so it's clear at the table this one
      # is an uncounted extra, not eating into the corp's own claim_limit.
      def render_claim_column(ore, value, hex_id, used, free = false)
        color = tinted_claim_color(ore, value)
        props = {
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

      # Same white-X-over-the-mine look the map itself uses once a claim
      # is used this OR (Part::City#render_used_marker), reading the same
      # @mine_state[:used] flag (via Game#claim_details) -- so it resets
      # right alongside the map's own X, at or_round_finished, with no
      # separate logic needed here.
      USED_MINE_MARK_LINE = {
        position: 'absolute', top: '50%', left: '50%',
        width: '85%', height: '2px', background: '#ffffff',
      }.freeze

      def render_used_mine_mark
        h(:div, {}, [
          h(:div, { style: USED_MINE_MARK_LINE.merge(transform: 'translate(-50%, -50%) rotate(45deg)') }),
          h(:div, { style: USED_MINE_MARK_LINE.merge(transform: 'translate(-50%, -50%) rotate(-45deg)') }),
        ])
      end

      # Growth Corp conversion (Phase 8) inherits an independent's special
      # ability, assignable to one ship per OR via Step::Route's own choose
      # UI -- nil (no display) for a normally-floated corp or an
      # unconverted independent. The "(assignable to one ship per OR)"
      # note itself is per-pilot now (see Game#pilot_description/
      # DELIVERY_BONUS_PILOTS), not appended blanket here.
      def render_pilot_info
        description = @game.pilot_description(@corporation)
        return nil unless description

        h(:div, description)
      end
    end
  end
end
