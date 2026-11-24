# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module GrowthCorporations
        # §8.
        def growth_conversion_allowed?
          %w[2 3].include?(phase.name) && !@asteroid_league_formed
        end

        def growth_convertible_corporations
          return [] unless growth_conversion_allowed?

          @corporations.select { |c| c.corporation? && !c.ipoed && c.id != 'AL' }
        end

        def growth_convertible_minors(player)
          @minors.select { |m| m.owner == player && !m.closed? }
        end

        # Phase 8. Pars at $67 (treasury share price) while the market
        # token starts at the separately-labeled $10/par_2 cell.
        def form_growth_corporation!(player, minor, corp)
          par_67 = stock_market.par_prices.find { |pp| pp.price == 67 }
          price_10 = stock_market.par_prices.find { |pp| pp.price == 10 }

          corp.capitalization = :incremental

          # Reclaim ipo_owner from the bank -- Game#setup's §13c migration
          # ran before capitalization was knowable, so this corp was
          # swept in as if full-cap. Without this, SharePool#buy_shares'
          # incremental-cap routing never matches and every IPO purchase
          # silently pays the bank instead of the corp.
          if corp.ipo_owner != corp
            corp.ipo_owner = corp
            bank.shares_by_corporation[corp].dup.each { |share| transfer_treasury_share!(share, corp) }
          end

          stock_market.set_par(corp, par_67)
          # set_par also pushed corp's token onto par_67's cell -- must
          # be removed, or the corp renders at both $67 and $10.
          par_67.corporations.delete(corp)
          corp.share_price = price_10
          price_10.corporations << corp

          share_pool.buy_shares(player, corp.presidents_share, exchange: :free)

          minor.spend(minor.cash, corp) if minor.cash.positive?

          # `transfer`, not a manual loop -- see
          # merge_independent_into_al!'s identical fix for why.
          transfer(:trains, minor, corp)

          # counted: false -- a Growth Corp's inherited base stays an
          # uncounted extra (unlike AL's counted: true merger).
          transfer_independent_base!(minor, corp, counted: false)
          transfer_independent_mine_claims!(minor, corp)
          carry_over_independent_special_status!(minor, corp)

          corp.floated = true

          # This independent is closing permanently, not merging into the
          # AL -- its reserved AL share (Phase 9a2) is simply released.
          @al_reserved_shares[minor.id].buyable = true

          private_company = company_by_id(minor.id)
          minor.close!
          private_company&.close!

          @log << "#{player.name} trades in #{minor.name} for #{corp.name}'s president's certificate "\
                  "(par #{format_currency(67)}, market price #{format_currency(10)})"

          # par/buy_shares were called directly above, bypassing the
          # normal par step -- after_par must still run, since it's what
          # fires event_group_b/c_corps_available! once a group completes.
          after_par(corp)
        end

        def company_header(company)
          is_minor = @minors.find { |m| m.id == company.id }
          is_minor ? 'INDEPENDENT COMPANY' : 'PRIVATE COMPANY'
        end

        def after_par(corporation)
          super

          return unless @corporations.all?(&:ipoed)

          case @available_corp_group
          when :group_a
            event_group_b_corps_available!
          when :group_b
            event_group_c_corps_available!
          end
        end

        def after_buy_company(player, company, _price)
          target_price = optional_short_game? ? 67 : (weaker_tsi_price || 100)
          share_price = stock_market.par_prices.find { |pp| pp.price == target_price }

          # NOTE: This should only ever be TSI
          abilities(company, :shares) do |ability|
            ability.shares.each do |share|
              if share.president
                if optional_variant_start_pack?
                  # §13d: TSI's par price is player-chosen, immediately
                  # when ST is bought -- waiting for the ordinary par UI
                  # (only reachable once WaterfallAuction stops blocking)
                  # would be too late.
                  @round.companies_pending_par << company
                else
                  stock_market.set_par(share.corporation, share_price)
                  share_pool.buy_shares(player, share, exchange: :free)
                  after_par(share.corporation)
                end
              else
                # Suppress president-share swap: TSI_0 must only move when ST is bought.
                # Without this, buying TSI_2+TSI_3 triggers a swap that pulls TSI_0 out of
                # the IPO early, causing "Cannot buy share from player" when ST is resolved.
                share_pool.buy_shares(player, share, exchange: :free, allow_president_change: false)
              end
            end
          end
        end

        # TSI is never parrable through the ordinary cash-par UI -- its
        # president's cert only ever comes from ST's `shares` ability
        # (see after_buy_company above). The exception for the pending
        # parrer is required: assets/app/view/game/{par,form_corporation}.rb
        # gate their price-selection buttons behind this method for every
        # corp, so without it the intended buyer would see "Cannot Par"
        # too. `round.respond_to?` guards Operating-round contexts, where
        # companies_pending_par was never declared.
        def can_par?(corporation, parrer)
          if corporation.id == 'TSI'
            pending = round.respond_to?(:companies_pending_par) &&
              round.companies_pending_par.find { |c| c.id == 'ST' }
            return false if !pending || pending.owner != parrer
          end

          super
        end
      end
    end
  end
end
