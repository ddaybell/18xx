# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module GrowthCorporations
        # Growth Corp conversion is only available in Phases 2-3, and
        # never once the Asteroid League has formed (§8). §13d's "still
        # may not be launched during Phase I" is already true
        # unconditionally here, so no separate check is needed under
        # optional_variant_start_pack?.
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

        # Trades in `minor` (one of the player's own still-active
        # independents) for `corp`'s president's certificate (Phase 8).
        # `corp` always pars at $67 (fixed treasury share price -- see
        # Share#price_per_share, which reads par_price for as long as a
        # share's owner is still the corp itself) while its market token
        # starts at the separately-labeled $10/par_2 cell -- mirrors
        # form_asteroid_league!'s pattern of bypassing float_corporation
        # entirely for full control over exactly what cash moves.
        def form_growth_corporation!(player, minor, corp)
          par_67 = stock_market.par_prices.find { |pp| pp.price == 67 }
          price_10 = stock_market.par_prices.find { |pp| pp.price == 10 }

          corp.capitalization = :incremental

          # §13c's ipo_owner migration (Game#setup) runs at game start,
          # before any corp's eventual capitalization is knowable --
          # every corp still shows :full at that point, so under
          # optional_stock_repurchases? it was already swept into the
          # bank along with every genuinely full-cap corp. Reclaim it
          # now: nothing but the bank could possibly hold any of its
          # shares at this exact moment. Without this, SharePool#
          # buy_shares' own incremental-cap payment routing never
          # matches, and every share a player buys from this corp's IPO
          # box silently pays the bank instead of the corp.
          if corp.ipo_owner != corp
            corp.ipo_owner = corp
            bank.shares_by_corporation[corp].dup.each { |share| transfer_treasury_share!(share, corp) }
          end

          stock_market.set_par(corp, par_67)
          # set_par (above) also pushes corp onto par_67.corporations, which
          # is what actually draws a token on the stock market chart --
          # that must not stay, or the corp shows up at BOTH $67 and $10.
          # par_price staying at par_67 (for treasury pricing) doesn't
          # require the token to render there too.
          par_67.corporations.delete(corp)
          corp.share_price = price_10
          price_10.corporations << corp

          share_pool.buy_shares(player, corp.presidents_share, exchange: :free)

          minor.spend(minor.cash, corp) if minor.cash.positive?

          # transfer (not a manual owner-reassign loop) -- see
          # merge_independent_into_al!'s identical fix/comment for why: a
          # manual loop never invalidates Game::Base's own @crowded_corps
          # memoization, so a conversion that pushes the new Growth Corp
          # over its own train_limit would go completely undetected.
          transfer(:trains, minor, corp)

          # Mine-claim/pilot-and-Fast-Buck transfer are identical
          # mechanics to merge_independent_into_al!'s own asset
          # transfer, just landing on `corp` instead of the AL -- the
          # base transfer differs in one respect: counted: false here,
          # since a Growth Corp's own inherited base stays an uncounted
          # extra, unlike AL's counted: true (see transfer_independent_
          # base!'s own comment for why).
          transfer_independent_base!(minor, corp, counted: false)
          transfer_independent_mine_claims!(minor, corp)
          carry_over_independent_special_status!(minor, corp)

          corp.floated = true

          # This independent will never merge into the AL now (it's closing
          # permanently as an independent) -- its reserved AL share (Phase 9a2)
          # is released as ordinary buyable AL stock rather than granted to
          # anyone, since no merge is happening here.
          @al_reserved_shares[minor.id].buyable = true

          private_company = company_by_id(minor.id)
          minor.close!
          private_company&.close!

          @log << "#{player.name} trades in #{minor.name} for #{corp.name}'s president's certificate "\
                  "(par #{format_currency(67)}, market price #{format_currency(10)})"

          # Bypasses the normal par step (set_par/buy_shares called
          # directly, above), same as after_buy_company's TSI formation
          # -- after_par is what actually fires event_group_b/
          # c_corps_available! once every corp in the current group has
          # launched (launched means the President's cert is acquired,
          # not sold out). Without this call, a Growth-Corp-only
          # completion of a group could never unlock the next one.
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
                  # §13d: "TSI's par price is player-chosen" -- and must
                  # be chosen immediately, interrupting the auction right
                  # when ST is bought (waiting for the ordinary ipo/par
                  # UI, only reachable once WaterfallAuction stops
                  # blocking for everyone, was too late). `@round.
                  # companies_pending_par` is the base engine's own
                  # mechanism for this shape, wired into stock_round via
                  # G2038::Step::CompanyPendingPar (this game's own
                  # subclass, fixing the base version's `corporation.
                  # shares.first` to `ipo_shares.first`, needed since
                  # optional_variant_start_pack? always implies
                  # optional_stock_repurchases?), positioned *before*
                  # WaterfallAuction so it wins the first-blocking-step
                  # lookup.
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

        # TSI is never parrable through the *ordinary* cash-par UI, baseline
        # or variant -- its president's cert only ever comes from ST's own
        # `shares` ability (see after_buy_company above), either an
        # immediate fixed-price grant (baseline) or a forced player choice
        # via G2038::Step::CompanyPendingPar (optional_variant_start_pack?).
        # Without this, nothing stops any player from cash-parring TSI
        # directly through the ordinary par UI before ST is even bought --
        # a real gap in both modes.
        #
        # The exception below is required, not just belt-and-suspenders:
        # assets/app/view/game/{par,form_corporation}.rb both gate their
        # own price-selection buttons behind this exact method ("Cannot
        # Par" otherwise) -- CompanyPendingPar#process_par itself never
        # calls can_par? at all, but the UI the player clicks through to
        # submit that Par action does, for every corp. Without this
        # exception the interrupt correctly blocked every other player,
        # but the intended buyer saw "Cannot Par" too. `round.
        # respond_to?` guards against Operating-round contexts, where
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
