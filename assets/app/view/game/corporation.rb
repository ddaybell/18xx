# frozen_string_literal: true

require 'lib/settings'
require 'view/game/actionable'
require 'view/game/alternate_corporations'
require 'view/game/companies'

module View
  module Game
    class Corporation < Snabberb::Component
      include Actionable
      include AlternateCorporations
      include Lib::Settings

      needs :user, default: nil, store: true
      needs :bids, default: nil
      needs :corporation
      needs :selected_company, default: nil, store: true
      needs :selected_corporation, default: nil, store: true
      needs :game, store: true
      needs :display, default: 'inline-block'
      needs :selectable, default: true
      needs :interactive, default: true
      needs :show_companies, default: true

      def render
        # use alternate view of corporation if needed
        if @game.respond_to?(:corporation_view) && (view = @game.corporation_view(@corporation))
          return send("render_#{view}")
        end

        @hidden_divs = {}

        select_corporation = lambda do
          if @selectable
            selected_corporation = selected? ? nil : @corporation
            store(:selected_corporation, selected_corporation)
          end

          if can_assign_corporation?
            company = @selected_company
            target = @corporation
            store(:selected_corporation, nil, skip: true)
            store(:selected_company, nil, skip: true)
            process_action(Engine::Action::Assign.new(company, target: target))
          end
        end

        card_style = {
          cursor: 'pointer',
        }

        card_style[:display] = @display

        unless @interactive
          factor = color_for(:bg2).to_s[1].to_i(16) > 7 ? 0.3 : 0.6
          card_style[:backgroundColor] = convert_hex_to_rgba(color_for(:bg2), factor)
          card_style[:border] = '1px dashed'
        end

        card_style[:border] = '4px solid' if @game.round.can_act?(@corporation)

        if selected?
          card_style[:backgroundColor] = 'lightblue'
          card_style[:color] = 'black'
          card_style[:border] = '1px solid'
        end

        children = [render_title, render_holdings]

        if @game.corporation_show_shares?(@corporation)
          children << render_shares unless @corporation.hide_shares?
          if @game.corporation_show_individual_reserved_shares? && !@corporation.reserved_shares.empty?
            children << render_reserved
          end
          children << render_owned_other_shares unless @corporation.corporate_shares.empty?
          children << h(Companies, owner: @corporation, game: @game) unless @corporation.companies.empty?
          if @game.respond_to?(:corporate_card_minors) && !(ms = @game.corporate_card_minors(@corporation)).empty?
            children << render_minors(ms)
          end
        end
        abilities_to_display = @corporation.all_abilities.select(&:description)
        children << render_abilities(abilities_to_display) if abilities_to_display.any?
        children << render_bidders if @bids && !@bids.empty?

        extras = []
        if @game.corporation_show_loans?(@corporation)
          if @game.total_loans&.nonzero?
            extras.concat(render_loans)
            extras.concat(render_interest) if @game.corporation_show_interest?
          end
          if @corporation.corporation? && @corporation.floated? &&
            @game.total_loans.positive? && @corporation.can_buy?
            extras << render_buying_power
          end
        end
        extras << render_capitalization_type if @corporation.corporation? && @corporation.respond_to?(:capitalization_type_desc)
        extras << render_escrow_account if @corporation.corporation? && @corporation.respond_to?(:escrow) && @corporation.escrow
        if extras.any?
          props = { style: { borderCollapse: 'collapse' } }
          children << h('table.center', props, [h(:tbody, extras)])
        end

        # Never push a bare nil into `children` -- render_claims_display/
        # render_pilot_info both legitimately return nil for most corps
        # (no finite claim limit / not a Growth Corp), and a real nil vnode
        # child reaching snabbdom's createElm crashed with "Cannot add
        # property elm, object is not extensible" (only surfaced once
        # render_pilot_info's nil-path started actually firing -- every
        # corp in this ruleset has a finite claim_limit, so
        # render_claims_display's own nil-path was apparently never
        # exercised before).
        if @game.respond_to?(:claim_hexes) && (claims_display = render_claims_display)
          children << claims_display
        end
        if @game.respond_to?(:growth_corp_pilots) && (pilot_info = render_pilot_info)
          children << pilot_info
        end

        if @corporation.owner
          props = {
            style: {
              grid: '1fr / repeat(2, max-content)',
              justifyContent: 'center',
              backgroundColor: color_for(:bg2),
              color: color_for(:font2),
            },
          }

          subchildren = render_operating_order
          subchildren << render_revenue_history if @game.render_revenue_history?(@corporation)
          children << h(:div, props, subchildren)
        end

        status_props = {
          style: {
            justifyContent: 'center',
            backgroundColor: color_for(:bg2),
            color: color_for(:font2),
          },
        }
        status_array_props = {
          style: {
            display: 'inline-block',
            width: '100%',
            textAlign: 'center',
            backgroundColor: color_for(:bg2),
            color: color_for(:font2),
          },
        }
        item_props = {
          style: {
            display: 'inline-block',
            padding: '0 0.5rem',
          },
        }

        children << h(:div, status_props, @game.float_str(@corporation)) if @corporation.trains.any? && !@corporation.floated?
        children << h(:div, status_props, @game.status_str(@corporation)) if @game.status_str(@corporation)
        if @game.status_array(@corporation)
          children << h(:div, status_array_props,
                        @game.status_array(@corporation).map { |text, klass| h("div.#{klass}", item_props, text) })
        end

        h('div.corp.card', { style: card_style, on: { click: select_corporation } }, children)
      end

      def render_bidders
        table_props = {
          style: {
            margin: '0 auto',
            borderSpacing: '0 1px',
            fontWeight: 'normal',
          },
        }

        # almost identical to render_bidders in view/game/company
        # except for  minor CSS tweaks for padding/text alignment
        header_props = {
          style: {
            clear: 'both',
            textAlign: 'center',
            fontWeight: 'bold',
            padding: '0.5rem',
          },
        }

        rows = @bids
          .sort_by(&:price)
          .reverse.map.with_index do |bid, i|
            bg_color =
              if setting_for(:show_player_colors, @game)
                player_colors(@game.players)[bid.entity]
              elsif @user && bid.entity.name == @user['name']
                color_for(i.zero? ? :green : :yellow)
              else
                color_for(:bg)
              end
            props = {
              style: {
                backgroundColor: bg_color,
                color: contrast_on(bg_color),
              },
            }
            h(:tr, props, [
              h('td.left', bid.entity.name.truncate(20)),
              h('td.right', bid.price >= 0 ? @game.format_currency(bid.price) : '--'),
            ])
          end

        h(:div, header_props, [
           h(:label, 'Bidders:'),
           h(:table, table_props, [
             h(:tbody, [
               *rows,
             ]),
           ]),
        ])
      end

      def render_title(bg = nil)
        title_row_props = {
          style: {
            grid: '1fr / auto 1fr auto',
            gap: '0 0.4rem',
            padding: '0.2rem 0.35rem',
            background: @corporation.color,
            color: @corporation.text_color,
            'min-height': '2.4rem',
          },
        }
        logo_props = {
          attrs: { src: logo_for_user(@corporation) },
          style: {
            height: '1.6rem',
            width: '1.6rem',
            padding: '1px',
            border: '2px solid currentColor',
            borderRadius: '0.5rem',
          },
        }
        logo_props[:style][:background] = bg if bg
        children = [h(:img, logo_props), h('div.title', @corporation.full_name)]

        if @corporation.system?
          logo_props[:attrs][:src] = logo_for_user(@corporation.corporations.last)
          children << h(:img, logo_props)
        end

        if @game.second_icon(@corporation)
          logo_props[:attrs][:src] = logo_for_user(@game.second_icon(@corporation))
          children << h(:img, logo_props)
        end

        h('div.corp__title', title_row_props, children)
      end

      def render_holdings
        holdings_row_props = {
          style: {
            grid: '1fr / max-content minmax(max-content, 1fr) minmax(4rem, max-content)',
            gap: '0 0.5rem',
            padding: '0.2rem 0.2rem 0.2rem 0.35rem',
            backgroundColor: color_for(:bg2),
            color: color_for(:font2),
          },
        }
        sym_props = {
          attrs: {
            title: 'Corporation Symbol',
          },
          style: {
            fontSize: '1.5rem',
            fontWeight: 'bold',
          },
        }
        holdings_props = {
          style: {
            grid: '1fr / repeat(auto-fit, auto)',
            gridAutoFlow: 'column',
            gap: '0 0.5rem',
            justifyContent: 'space-evenly',
            justifySelf: 'normal',
          },
        }

        holdings =
          if !@corporation.corporation? || @corporation.floated? || @corporation.trains.any?
            h(:div, holdings_props, [render_trains, render_cash])
          elsif @corporation.cash.positive?
            h(:div, holdings_props, [render_to_float, render_cash])
          else
            h(:div, [render_to_float])
          end

        h('div.corp__holdings', holdings_row_props, [
          h(:div, sym_props, @corporation.name),
          holdings,
          render_tokens,
        ])
      end

      def render_cash
        render_header_segment(@game.format_currency(@corporation.cash), 'Cash')
      end

      def render_to_float
        props = { style: { textAlign: 'center' } }
        props[:style][:maxWidth] = '3.5rem' if @corporation.cash.positive? && @corporation.tokens.size > 3
        h(:div, props, @game.float_str(@corporation))
      end

      def render_trains
        render_header_segment(@game.trains_str(@corporation), 'Trains')
      end

      def render_header_segment(values, key)
        values = [values] unless values.is_a?(Array)

        value_props = {
          style: {},
          attrs: {
            title: key,
          },
        }
        value_props[:style][:fontSize] = '80%' if values.max_by(&:size).size > 10

        h('div.bold', values.map { |v| h('div.nowrap', value_props, v) })
      end

      def render_tokens
        token_list_props = {
          style: {
            grid: '1fr / auto-flow',
            gap: '0 0.2rem',
            width: '100%',
            overflow: 'auto',
          },
        }

        tokens_body =
          if @game.respond_to?(:base_hexes) && @corporation.corporation?
            infrastructure_tokens_body
          else
            default_tokens_body
          end

        @corporation.assignments.each do |assignment, _active|
          img = @game.assignment_tokens(assignment)
          tokens_body << [img, true, assignment]
        end

        h(:div, token_list_props, tokens_body.map { |logo, used, text| render_token_column(logo, used, text) })
      end

      def default_tokens_body
        tokens_body = @corporation.tokens.map.with_index do |token, i|
          token_text =
            if i.zero? && @corporation.coordinates
              @corporation.coordinates.is_a?(Array) ? @corporation.coordinates.join('/') : @corporation.coordinates
            else
              token.hex ? token.hex.name : token.price
            end
          [logo_for_user(token), token.used, token_text]
        end
        tokens_body.sort_by! { |t| t[1] ? 1 : -1 }
      end

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

      def render_token_column(logo, used, text)
        props = {
          attrs: { title: "token #{used ? 'location: ' : 'cost: '}#{text}" },
          style: { grid: '1fr auto / 1fr' },
        }
        img_props = { attrs: { src: logo }, style: { width: '1.5rem' } }
        img_props[:style][:filter] = 'contrast(50%) grayscale(100%)' if used

        h(:div, props, [h(:img, img_props), h(:div, text)])
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

      # One column per lifetime claim slot (@game.claim_limit) -- a
      # played claim gets its own mine-colored circle (render_claim_column),
      # an unplaced/reserved slot still gets the generic flag look
      # (render_token_column, same as the base/station strip above,
      # since there's no specific mine to show yet) -- unlike bases/
      # stations, a claim's cost isn't fixed per lifetime slot, it's set
      # by this round's tier, already spelled out in the header text.
      def render_claims_display
        limit = @game.claim_limit(@corporation)
        return if limit.infinite?

        schedule = @game.claim_cost_schedule(@corporation)
        header = "Claims: #{schedule.map { |c| @game.format_currency(c) }.join('/')} per turn"

        placed = @game.claim_details(@corporation)
        logo = @game.claim_logo(@corporation)
        reserved = @game.reserved_claim_count(@corporation)
        entries = limit.to_i.times.map do |i|
          detail = placed[i]
          next [:placed, detail] if detail

          if reserved.positive?
            reserved -= 1
            [:unplaced, [logo, true, 'Res.']]
          else
            [:unplaced, [logo, false, '']]
          end
        end
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
            render_claim_column(data[:ore], data[:value], data[:hex_id], data[:used])
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
      # it rather than only as a hover tooltip.
      def render_claim_column(ore, value, hex_id, used)
        color = tinted_claim_color(ore, value)
        props = {
          attrs: { title: "claim location: #{hex_id}" },
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

        h(:div, props, [h(:div, circle_props, circle_children), h(:div, hex_props, hex_id)])
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

      def share_price_str(share_price)
        share_price ? @game.format_currency(share_price.price) : ''
      end

      def share_number_str(number)
        return '' if number.zero?

        result = number.to_s
        return result unless @corporation.fraction_shares

        result.index('.') ? result : "#{result}.0"
      end

      def entities_rows(entities, pres_transfer_order = false)
        step = @game.round.active_step

        if pres_transfer_order
          # For player rows, create an array of names, rotate that array so
          # the president is at index 0, and use the resulting order to sort
          # player names when they have the same number of shares. This results
          # in the listed order showing the correct transfer of presidency.
          players_in_order = entities.map(&:name)
          if @corporation.owner
            player_index = players_in_order.index(@corporation.owner.name)
            players_in_order = players_in_order.rotate(player_index) if player_index
          end
        end

        entity_info = entities.map do |entity|
          [
            entity,
            @corporation.president?(entity),
            entity.num_shares_of(@corporation, ceil: false),
            step&.did_sell?(@corporation, entity),
            pres_transfer_order ? players_in_order.index(entity.name) : 0,
            step&.last_acted_upon?(@corporation, entity),
            !@corporation.holding_ok?(entity, 1),
            entity.shares_of(@corporation).count(&:double_cert),
            @game&.share_flags(entity.shares_of(@corporation)),
          ]
        end

        shares_props = {
          style: {
            paddingRight: '1.3rem',
          },
        }

        entity_info
        .select { |_, _, num_shares, did_sell| !num_shares.zero? || did_sell }
        .sort_by { |_, president, num_shares, _, transfer_index| [president ? 0 : 1, -num_shares, transfer_index] }
        .map do |entity, president, num_shares, did_sell, _, last_acted_upon, at_limit, double_certs, other_flags|
          flags = (president ? '*' : '') + ('d' * double_certs) + (at_limit ? 'L' : '') + (other_flags || '')

          type = entity.player? ? 'tr.player' : 'tr.corp'
          type += '.bold' if last_acted_upon
          name = entity.player? ? entity.name : "© #{entity.name}"
          show_percent = @game.class::SHOW_SHARE_PERCENT_OWNERSHIP
          percent_shares = num_shares * @corporation.share_percent
          percent_shares_str = percent_shares.positive? && show_percent ? " (#{percent_shares}%)" : ''

          h(type, [
            h("td.left.name.nowrap.#{president ? 'president' : ''}", name),
            h('td.right', shares_props, "#{flags.empty? ? '' : flags + ' '}#{share_number_str(num_shares)}#{percent_shares_str}"),
            did_sell ? h('td.italic', 'Sold') : '',
          ])
        end
      end

      def render_shares
        shares_props = {
          style: {
            paddingRight: '1.3rem',
          },
        }

        if @game.corporations_can_ipo?
          player_rows = entities_rows(@game.share_owning_players + @game.operating_order.reject do |c|
                                                                     c == @corporation && !c.treasury_as_holding
                                                                   end.sort, true)
          other_corp_rows = []
        else
          player_rows = entities_rows(@game.share_owning_players, true)
          other_corp_rows = entities_rows(@game.corporations.reject { |c| c == @corporation && !c.treasury_as_holding })
        end

        other_minor_rows = entities_rows(@game.minors) if @game.class::MINORS_CAN_OWN_SHARES

        num_ipo_shares = share_number_str(@corporation.num_ipo_shares - @corporation.num_ipo_reserved_shares)
        if @game.respond_to?(:reissued?) && @game.reissued?(@corporation) && !num_ipo_shares.empty?
          num_ipo_shares = '* ' + num_ipo_shares
        end
        num_dc_all = @corporation.shares_of(@corporation).count(&:double_cert)
        num_dc_reserved = @corporation.reserved_shares.count(&:double_cert)
        num_dc_avail = num_dc_all - num_dc_reserved

        num_treasury_shares = share_number_str(@corporation.num_treasury_shares)

        pool_rows = []
        if !num_ipo_shares.empty? ||
           num_dc_avail.positive? ||
           !%i[full none].include?(@corporation.capitalization) ||
           @game.class::ALWAYS_SHOW_PAR_PRICE
          pool_rows << h('tr.ipo', [
            h('td.left', @game.ipo_name(@corporation)),
            h('td.right', shares_props, ('d' * num_dc_avail) + num_ipo_shares),
            h('td.padded_number', share_price_str(@corporation.par_price)),
          ])
        end

        if !num_treasury_shares.empty? && !@corporation.ipo_is_treasury? && !@corporation.treasury_as_holding
          pool_rows << h('tr.ipo', [
            h('td.left', 'Treasury'),
            h('td.right', shares_props, num_treasury_shares),
            h('td.padded_number', share_price_str(@corporation.share_price)),
          ])
        end

        if @corporation.reserved_shares.any?
          flags = ('d' * num_dc_reserved) + 'R'
          pool_rows << h('tr.reserved', [
            h('td.left', @game.ipo_reserved_name),
            h('td.right', shares_props, flags + ' ' + share_number_str(@corporation.num_ipo_reserved_shares)),
            h('td.padded_number', share_price_str(@corporation.par_price)),
          ])
        end

        market_tr_props = {
          style: {
            borderBottom: player_rows.any? ? '1px solid currentColor' : '0',
          },
        }

        if player_rows.any? && @corporation.share_price&.highlight? &&
            (color = StockMarket::COLOR_MAP[@game.class::STOCKMARKET_COLORS[@corporation.share_price.type]])
          market_tr_props[:style][:backgroundColor] = color
          market_tr_props[:style][:color] = contrast_on(color)
        end

        if player_rows.any? || @corporation.num_market_shares.positive?
          at_limit = @game.share_pool.bank_at_limit?(@corporation)
          double_certs = @game.share_pool.shares_of(@corporation).count(&:double_cert)
          other_flags = @game.share_flags(@game.share_pool.shares_of(@corporation))

          flags = (@corporation.receivership? ? '*' : '') + ('d' * double_certs) + (at_limit ? 'L' : '') + (other_flags || '')

          pool_rows << h('tr.market', market_tr_props, [
            h('td.left', 'Market'),
            h('td.right', shares_props,
              flags + ' ' +
              share_number_str(@corporation.num_market_shares)),
            h('td.padded_number', share_price_str(@corporation.share_price)),
          ])
        end

        rows = [
          *pool_rows,
          *player_rows,
          *other_corp_rows,
          *other_minor_rows,
        ]

        props = { style: { borderCollapse: 'collapse' } }

        h('table.center', props, [
          h(:thead, [
            h(:tr, [
              h(:th, 'Shareholder'),
              h(:th, 'Shares'),
              h(:th, 'Price'),
            ]),
          ]),
          h(:tbody, [
            *rows,
          ]),
        ])
      end

      def render_owned_other_shares
        shares = @corporation
          .shares_by_corporation.reject { |c, s| s.empty? || (c == @corporation && !@corporation.treasury_as_holding) }
          .sort_by { |c, s| [s.sum(&:percent), c.president?(@corporation) ? 1 : 0, c.name] }
          .reverse
          .map { |c, s| render_owned_other_corp(c, s) }

        h(:table, shares)
      end

      def render_owned_other_corp(corporation, shares)
        td_props = {
          style: {
            padding: '0 0.2rem',
          },
        }
        div_props = {
          style: {
            height: '20px',
          },
        }
        logo_props = {
          attrs: {
            src: logo_for_user(corporation),
          },
          style: {
            height: '20px',
          },
        }

        president_marker = corporation.president?(@corporation) ? '*' : ''
        h('tr.row', [
          h('td.center', td_props, [h(:div, div_props, [h(:img, logo_props)])]),
          h(:td, td_props, corporation.name + president_marker),
          h('td.right', td_props, "#{shares.sum(&:percent)}%"),
        ])
      end

      def render_reserved
        bold = { style: { fontWeight: 'bold' } }
        h('table.center', [
          h(:tbody, [
            h('tr.reserved', [
              h('td.left', bold, "#{@game.ipo_reserved_name} shares:"),
              h('td.right', @corporation.reserved_shares.map { |s| "#{s.percent}%" }.join(', ')),
            ]),
          ]),
        ])
      end

      def render_revenue_history
        last_run = @corporation.operating_history[@corporation.operating_history.keys.max]
        revenue = @game.format_revenue_currency(last_run.revenue)
        text, type =
          case (last_run.routes.empty? ? 'no_run' : last_run.dividend_kind)
          when 'no_run'
            ["[#{revenue}]", 'did not run']
          when 'withhold'
            ["[#{revenue}]", 'withheld']
          when 'half'
            ["¦#{revenue}¦", 'half-paid']
          else
            [revenue, 'paid out']
          end

        h(:div, { style: { display: 'inline', marginLeft: '2rem' } }, [
          'Last Run: ',
          h('span.bold', { attrs: { title: type } }, text),
        ])
      end

      def render_operating_order
        round = @game.round
        order =
          if round.operating?
            round.entities.index(@corporation)
          else
            @game.operating_order.index(@corporation)
          end

        if order
          m = round.entities.index(round.current_entity) if round.operating?
          span_class = '.bold' if order && m && order >= m
          [h(:div, { style: { display: 'inline' } }, [
            'Order: ',
            h("span#{span_class}", order + 1),
          ])]
        else
          []
        end
      end

      def render_loans
        loan_props = { style: {} }
        if @corporation.loans.size > @game.maximum_loans(@corporation)
          color = StockMarket::COLOR_MAP[:red]
          loan_props[:style][:backgroundColor] = color
          loan_props[:style][:color] = contrast_on(color)
        end

        [
          h('tr.ipo', loan_props, [
            h('td.right', @game.corp_loans_text),
            h('td.padded_number', "#{@corporation.loans.size}/"\
                                  "#{@game.maximum_loans(@corporation)}"),
          ]),
        ]
      end

      def render_interest
        interest_props = { style: {} }
        unless @game.can_pay_interest?(@corporation)
          color = StockMarket::COLOR_MAP[:yellow]
          interest_props[:style][:backgroundColor] = color
          interest_props[:style][:color] = contrast_on(color)
        end

        [
          h('tr.ipo', interest_props, [
            h('td.right', 'Interest Due'),
            h('td.padded_number', @game.format_currency(@game.interest_owed(@corporation)).to_s),
          ]),
        ]
      end

      def render_capitalization_type
        h('tr.ipo', [
          h('td.right', 'Cap. Type'),
          h('td.padded_number', @corporation.capitalization_type_desc.to_s),
        ])
      end

      def render_escrow_account
        h('tr.ipo', [
          h('td.right', 'Escrow'),
          h('td.padded_number', @game.format_currency(@corporation.escrow)),
        ])
      end

      def render_buying_power
        h('tr.ipo', [
          h('td.right', 'Buying Power'),
          h('td.padded_number', @game.format_currency(@game.buying_power(@corporation, full: true)).to_s),
        ])
      end

      def toggle_desc_detail(event, i)
        event.JS.stopPropagation
        elm = Native(@hidden_divs["#{@corporation.name}_#{i}"]).elm
        elm.style.display = elm.style.display == 'none' ? 'grid' : 'none'
      end

      def render_abilities(abilities)
        hidden_props = {
          style: {
            display: 'none',
            marginBottom: '0.5rem',
            padding: '0.1rem 0.2rem',
            fontSize: '80%',
          },
        }
        ability_props = {}

        ability_lines = abilities.flat_map.with_index do |ability, i|
          if ability.desc_detail
            ability_props = {
              style: { cursor: 'pointer' },
              on: { click: ->(event) { toggle_desc_detail(event, i) } },
            }
          end

          children = [h('div.nowrap', ability_props, ability.description)]
          if ability.desc_detail
            children << @hidden_divs["#{@corporation.name}_#{i}"] = h(:div, hidden_props, ability.desc_detail)
          end
          children
        end

        h('div.ability_table', { style: { padding: '0 0.5rem 0.2rem' } }, [
          h('div.bold', "Abilit#{abilities.count(&:description) > 1 ? 'ies' : 'y'}"),
          *ability_lines,
        ])
      end

      def render_minors(minors)
        minor_logos = minors.map do |minor|
          logo_props = {
            attrs: {
              src: minor.logo,
            },
            style: {
              paddingRight: '1px',
              paddingLeft: '1px',
              height: '20px',
            },
          }
          h(:img, logo_props)
        end
        inner_props = {
          style: {
            display: 'inline-block',
          },
        }
        outer_props = {
          style: {
            textAlign: 'center',
          },
        }
        h('div', outer_props, [h('div', inner_props, minor_logos)])
      end

      def selected?
        @corporation == @selected_corporation
      end

      def logo_for_user(entity)
        setting_for(:simple_logos, @game) ? entity.simple_logo : entity.logo
      end

      def can_assign_corporation?
        @selected_corporation && @game.abilities(@selected_company, :assign_corporation)
      end
    end
  end
end
