# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module GrowthCorporations
        # Unfloated, non-AL corps currently unlocked into @corporations --
        # the same pool the normal cash-par path already offers, since
        # trading in an independent is just a second way to start any of
        # them (Phase 8).
        # Growth Corp conversion is only available in Phases 2-3, and never
        # once the Asteroid League has formed (§8).
        # §13d: "Growth Corporations still may not be launched during Phase
        # I even so" -- already true unconditionally, variant or not: a
        # corp only ever becomes a Growth Corp via the trade-in-an-
        # independent conversion path (form_growth_corporation!, which sets
        # capitalization = :incremental as ITS OWN result -- see below), and
        # that path is already gated to Phases 2-3 here regardless of any
        # group-partition timeline. No separate check needed under
        # optional_variant_start_pack.
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
          # before any corp's eventual capitalization is knowable -- every
          # corp still shows :full at that point (this one only becomes
          # :incremental right here, via conversion), so under
          # optional_stock_repurchases it was already swept into the bank
          # along with every genuinely full-cap corp. Reclaim it now: this
          # corp hasn't parred/floated yet, so nothing but the bank could
          # possibly hold any of its shares at this exact moment -- safe
          # to move all of them back unconditionally. Without this,
          # SharePool#buy_shares' own incremental-cap payment routing
          # (keyed on `bundle.owner.corporation?`) never matches, since
          # the shares stay bank-owned forever, and every share a player
          # buys from this corp's own IPO box silently pays the bank
          # instead of the corp -- found live: a Growth Corp showing only
          # its inherited independent's treasury cash, none of what
          # players had actually paid for its shares.
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

          # Mine-claim/pilot-and-Fast-Buck transfer are identical mechanics
          # to merge_independent_into_al!'s own asset transfer, just
          # landing on `corp` instead of the AL (see those shared methods'
          # own comments) -- the base transfer differs in one respect:
          # counted: false here, since a Growth Corp's own inherited base
          # (from the one independent it converted from) stays an
          # uncounted extra, unlike AL's counted: true (see
          # transfer_independent_base!'s own comment for why the two
          # aren't the same).
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
          # directly, above) same as after_buy_company's TSI formation --
          # after_par is what actually fires event_group_b/c_corps_available!
          # once every corp in the current group has launched (§ "Once all
          # of a group is launched, the next group is immediately
          # available" -- launched means the President's cert is
          # acquired, not sold out; a Growth Corp is launched/active the
          # instant this happens). Without this call, a Growth-Corp-only
          # completion of a group could never unlock the next one, no
          # matter how much of its stock later sold. Found live in
          # browser: RU formed as a Growth Corp, sold out, and the next
          # group still never became available.
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
          target_price = optional_short_game ? 67 : 100
          share_price = stock_market.par_prices.find { |pp| pp.price == target_price }

          # NOTE: This should only ever be TSI
          abilities(company, :shares) do |ability|
            ability.shares.each do |share|
              if share.president
                if optional_variant_start_pack
                  # §13d: "TSI's par price is player-chosen" -- and must be
                  # chosen immediately, interrupting the auction right when
                  # ST is bought (confirmed with the user -- waiting for
                  # the ordinary ipo/par UI, which only ever becomes
                  # reachable once WaterfallAuction stops blocking for
                  # *everyone*, was too late whenever other companies were
                  # still unsold). `@round.companies_pending_par` is the
                  # base engine's own mechanism for exactly this shape (a
                  # private grants a president's cert, its buyer must
                  # immediately pick a par price before anyone else can
                  # act) -- already wired into stock_round via
                  # G2038::Step::CompanyPendingPar (this game's own
                  # subclass, fixing the base version's `corporation.
                  # shares.first` to `ipo_shares.first` -- needed since
                  # optional_variant_start_pack always implies
                  # optional_stock_repurchases, which relocates an unparred
                  # full-cap corp's shares to the bank at setup), which is
                  # positioned *before* WaterfallAuction in that array so
                  # it wins Round::Base#process_action's first-blocking-
                  # step lookup and genuinely blocks everyone else's turn
                  # until this resolves.
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
        # via G2038::Step::CompanyPendingPar (optional_variant_start_pack).
        # Without this, nothing stops any player from cash-parring TSI
        # directly through the ordinary par UI before ST is even bought --
        # a real gap in both modes.
        #
        # The exception below is required, not just belt-and-suspenders:
        # assets/app/view/game/{par,form_corporation}.rb both gate their
        # own price-selection buttons behind this exact method ("Cannot
        # Par" otherwise) -- CompanyPendingPar#process_par itself never
        # calls can_par? at all, but the UI the player actually clicks
        # through to submit that Par action does, for every corp. Found
        # live: the interrupt correctly blocked every other player, but
        # the intended buyer saw "Cannot Par" too, with no way to ever
        # submit a price. `round.respond_to?` guards against Operating-
        # round contexts, where companies_pending_par was never declared
        # (round_state only merges keys the current round's own steps
        # opted into) and would otherwise raise via method_missing.
        def can_par?(corporation, parrer)
          if corporation.id == 'TSI'
            pending = round.respond_to?(:companies_pending_par) &&
              round.companies_pending_par.find { |c| c.id == 'ST' }
            return false unless pending && pending.owner == parrer
          end

          super
        end
      end
    end
  end
end
