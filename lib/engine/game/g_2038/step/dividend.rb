# frozen_string_literal: true

require_relative '../../../step/dividend'

module Engine
  module Game
    module G2038
      module Step
        class Dividend < Engine::Step::Dividend
          # Corporations choose: full payout (stock +2), half payout (stock +1),
          # or withhold (stock -1).
          CORP_DIVIDEND_TYPES = %i[payout half withhold].freeze

          # Independents (minors) choose: split half with owner, or retain all
          # in treasury. No stock price — minors have no share price.
          MINOR_DIVIDEND_TYPES = %i[split retain].freeze

          def dividend_types
            current_entity.minor? ? self.class::MINOR_DIVIDEND_TYPES : self.class::CORP_DIVIDEND_TYPES
          end

          def skip!
            default_kind = current_entity.minor? ? 'retain' : 'withhold'
            action = Engine::Action::Dividend.new(current_entity, kind: default_kind)
            action.id = @game.actions.last.id if @game.actions.last
            process_dividend(action)
          end

          # Half payout needs shareholders paid before the corporation, not
          # after -- the base engine's process_dividend always pays the
          # corporation first off a pre-computed split, but half's split is
          # only a naive floor(revenue/2) target; the real per-holder ceil
          # in payout_shares can push shareholders' actual total above
          # that. Computing the corporation's share as whatever's left of
          # revenue *after* the real shareholder payout (using the same
          # revenue split, so both agree on the same per_share) makes the
          # corporation absorb the ceil rounding instead of over-paying
          # total revenue. Full duplication of process_dividend is needed
          # since the base method hardcodes corporation-then-shares with no
          # smaller override point; every other kind (payout, withhold,
          # split, retain) behaves identically to the base version.
          def process_dividend(action)
            entity = action.entity
            revenue = total_revenue
            subsidy = total_subsidy
            kind = action.kind.to_sym
            payout = dividend_options(entity)[kind]

            entity.operating_history[[@game.turn, @round.round_num]] =
              OperatingInfo.new(routes, action, revenue, @round.laid_hexes)

            @game.close_companies_on_event!(entity, 'ran_train') unless @round.routes.empty?
            entity.trains.each { |train| train.operated = true }
            rust_obsolete_trains!(entity)
            @round.routes = []
            @round.extra_revenue = 0

            shareholder_revenue = revenue - payout[:corporation]
            if kind == :half && payout[:per_share].positive?
              paid = shareholder_payout_total(entity, shareholder_revenue)
              payout = payout.merge(corporation: revenue - paid)
            end

            log_run_payout(entity, kind, revenue, subsidy, action, payout)

            payout_corporation(payout[:corporation] + subsidy, entity)
            # shareholder_revenue (not revenue - payout[:corporation]) --
            # for :half, payout[:corporation] has already been adjusted
            # above, so re-deriving it from that would silently swap in a
            # different, already-rounded revenue figure and recompute a
            # different per_share than shareholder_payout_total just used.
            payout_shares(entity, shareholder_revenue) if payout[:per_share].positive?

            change_share_price(entity, payout)
            pass!
          end

          # Mirrors what payout_shares is about to actually disburse (same
          # per_share math, via the same dividends_for_entity ceil-per-
          # holder logic) without paying anyone yet -- used only to figure
          # out how much the corporation should be left holding.
          def shareholder_payout_total(entity, revenue)
            per_share = payout_per_share(entity, revenue)
            (@game.players + @game.corporations).sum { |payee| dividends_for_entity(entity, payee, per_share) }
          end

          def round_state
            super.merge(laid_hexes: [])
          end

          # ---------------------------------------------------------------------------
          # Corporation dividend methods
          # ---------------------------------------------------------------------------

          # Full payout: all revenue to shareholders. Stock moves right 2.
          # (share_price_change handles the +2; this just sets per_share.)
          def payout(entity, revenue)
            { corporation: 0, per_share: payout_per_share(entity, revenue) }
          end

          # Half payout: half to shareholders, half retained. Stock moves right 1.
          #
          # dividends_for_entity ceils *per holder*, so fragmented ownership
          # can push shareholders' actual total above a naive floor(revenue/2)
          # (confirmed with the user: a $150 half-pay gives $8/share -- ceil
          # of $7.50 -- to shareholders, and the remaining $70, not a flat
          # $75, to the corporation). process_dividend below pays
          # shareholders first off this same revenue split, then gives the
          # corporation whatever's actually left over.
          def half(entity, revenue)
            corp = revenue / 2
            { corporation: corp, per_share: payout_per_share(entity, revenue - corp) }
          end

          # Withhold: all retained. Stock moves left 1.
          def withhold(_entity, revenue)
            { corporation: revenue, per_share: 0 }
          end

          # ---------------------------------------------------------------------------
          # Minor dividend methods
          # ---------------------------------------------------------------------------

          # Split: owner gets half, treasury retains half. No price movement.
          def split(entity, revenue)
            player_share = revenue / 2
            { corporation: revenue - player_share, per_share: payout_per_share(entity, player_share) }
          end

          # Retain: all stays in treasury. No price movement.
          def retain(_entity, revenue)
            { corporation: revenue, per_share: 0 }
          end

          # ---------------------------------------------------------------------------
          # Stock price movement
          # ---------------------------------------------------------------------------

          # shareholders_revenue is the portion going to shareholders (revenue - corporation).
          #   Full payout  → shareholders_revenue == total_revenue → right 2
          #   Half payout  → 0 < shareholders_revenue < total_revenue → right 1
          #   Withhold     → shareholders_revenue == 0 → left 1
          #   Minor        → no stock price → no movement
          def share_price_change(entity, shareholders_revenue)
            return {} if entity.minor?
            return { share_direction: :left,  share_times: 1 } if shareholders_revenue.zero?
            return { share_direction: :right, share_times: 2 } if shareholders_revenue == total_revenue

            { share_direction: :right, share_times: 1 }
          end

          # ---------------------------------------------------------------------------
          # Logging
          # ---------------------------------------------------------------------------

          def log_run_payout(entity, kind, revenue, subsidy, _action, payout)
            if entity.minor?
              case kind
              when :split
                player_amount = payout[:per_share]  # minor has 1 share; per_share == owner's cut
                corp_amount   = payout[:corporation]
                @log << "#{entity.name} splits #{@game.format_currency(revenue)}: "\
                        "#{@game.format_currency(player_amount)} to owner, "\
                        "#{@game.format_currency(corp_amount)} to treasury"
              when :retain
                @log << "#{entity.name} retains #{@game.format_currency(revenue)} in treasury"
              end
            else
              case kind
              when :payout
                @log << "#{entity.name} pays full dividend of #{@game.format_currency(revenue)}"
              when :half
                corp = payout[:corporation]
                paid = revenue - corp
                @log << "#{entity.name} pays half dividend — "\
                        "#{@game.format_currency(paid)} to shareholders, "\
                        "#{@game.format_currency(corp)} retained"
              when :withhold
                @log << "#{entity.name} withholds #{@game.format_currency(revenue)}"
              end
            end

            return unless subsidy.positive?

            @log << "#{entity.name} earns #{@game.subsidy_name} of #{@game.format_currency(subsidy)}"
          end
        end
      end
    end
  end
end
