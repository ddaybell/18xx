# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module AsteroidLeague
        def event_asteroid_league_can_form!
          @log << 'Asteroid League may now be formed'
          @corporations << @al_corporation
        end

        # Backstop for §8: if AE's owner hasn't already declared formation
        # via G2038::Step::FormAsteroidLeague, it's forced the moment
        # Phase 4 begins.
        def event_asteroid_league_must_form!
          return if @asteroid_league_formed

          form_asteroid_league!(company_by_id('AE')&.owner)
        end

        # Phase 5 mandatory merger (§9e): every independent still active
        # merges into the AL immediately, no player choice involved -- AL is
        # guaranteed to already exist by this point (Phase 4's
        # asteroid_league_must_form event above always runs first). Mirrors
        # 1835's event_forced_pr_exchange! (force-loop + direct merge calls,
        # bypassing the voluntary MergeIntoLeague step entirely).
        def event_independents_must_join_league!
          remaining_independents.dup.each { |minor| merge_independent_into_al!(minor) }
        end

        # §7.39/Phase 9f: an independent that owns no ship and can't afford
        # the cheapest one left in the Depot must merge into the AL rather
        # than go bankrupt -- checked at the END of its own OR turn (see
        # G2038::Round::Operating#after_end_of_turn's own comment on why
        # not pre-emptively before that turn even starts). Moot before the
        # AL exists, since there's nowhere for it to merge into yet.
        def independent_must_merge?(minor)
          return false unless @asteroid_league_formed
          return false unless minor.minor?
          return false if minor.closed?
          return false unless minor.trains.empty?

          cheapest = depot.depot_trains.map(&:price).min
          cheapest.nil? || minor.cash < cheapest
        end

        # AL is neither a Public Corp (needs 50% floated) nor a Growth Corp
        # (the engine has no such distinction) -- per the rules it's active
        # immediately on formation with a fixed $250 grant, so `floated` is
        # set directly rather than via `float_corporation` (which would pay
        # out par x total_shares, the wrong amount here).
        def form_asteroid_league!(owner)
          return if @asteroid_league_formed
          return unless owner

          @asteroid_league_formed = true

          share_price = stock_market.par_prices.find { |pp| pp.price == 125 }
          stock_market.set_par(@al_corporation, share_price)
          share_pool.buy_shares(owner, @al_corporation.presidents_share, exchange: :free)
          bank.spend(250, @al_corporation)
          @al_corporation.floated = true

          ae = company_by_id('AE')
          ae.all_abilities.select { |a| a.type == :choose_ability }.each { |a| ae.remove_ability(a) }

          @log << "#{owner.name} forms the Asteroid League, receiving its President's certificate "\
                  "and #{format_currency(250)} initial capital"

          insert_al_into_current_or_if_eligible!
        end

        # AL always pars at $125 -- see form_asteroid_league! just above.
        AL_INSERTION_MAX_PRICE = 124

        # AL forms mid-OR (buying a Phase III ship, which triggers
        # eligibility, is itself an OR action) but wasn't in this round's
        # @entities snapshot -- confirmed with the user: it may still slot
        # into *this* OR, at its rightful $125 position ahead of any
        # corporation priced $124 or lower, but only if no such corporation
        # has operated yet this round. Once one has, it's too late to
        # insert AL fairly ahead of it, so AL simply waits for the next OR
        # (where it's included from the start in the normal way).
        def insert_al_into_current_or_if_eligible!
          return unless round.is_a?(Engine::Round::Operating)

          already_acted = round.entities.first(round.entity_index + 1)
          return if already_acted.any? { |e| e.corporation? && e.share_price && e.share_price.price <= AL_INSERTION_MAX_PRICE }

          pending_ids = round.entities.last(round.entities.size - round.entity_index - 1).map(&:id)
          pending_ids << @al_corporation.id
          round.entities = already_acted + operating_order.select { |e| pending_ids.include?(e.id) }
        end

        def asteroid_league_formed?
          @asteroid_league_formed
        end

        # Independents (minors) that haven't yet merged into the AL or
        # converted into a Growth Corp -- the pool Step::MergeIntoLeague
        # offers each round, and the Phase 5/bankruptcy mandatory triggers
        # sweep in directly (Phase 9).
        def remaining_independents
          @minors.reject(&:closed?)
        end

        # Records that `entity` has been offered (accepted or declined) an
        # AL merge -- called by Step::MergeIntoLeague#process_choose, the
        # one interactive path where a player actually sees this offer.
        # `al_independents_ever_offered` stays an attr_reader-only ivar
        # otherwise, matching the rest of the codebase's convention of
        # exposing a named mutator (rand_state=, merge_independent_into_al!)
        # rather than letting a step reach into game-class state directly.
        def record_al_independent_offered!(entity)
          @al_independents_ever_offered << entity.id unless @al_independents_ever_offered.include?(entity.id)
        end

        # Merges `minor` into the Asteroid League (Phase 9c, and the forced
        # paths: event_independents_must_join_league! at Phase 5, and
        # independent bankruptcy). Mirrors form_growth_corporation!'s asset
        # transfer shape (Phase 8) minus the par/president's-cert dance --
        # AL already exists, already floated, at this point.
        def merge_independent_into_al!(minor, first_opportunity: !@al_independents_ever_offered.include?(minor.id))
          owner = minor.owner
          half_cash = pay_independent_merge_cash!(minor, owner, first_opportunity, @al_corporation)

          reserved_share = @al_reserved_shares[minor.id]
          reserved_share.buyable = true
          share_pool.buy_shares(owner, reserved_share, exchange: :free)

          # transfer (not a manual owner-reassign loop) -- it also
          # invalidates Game::Base's own @crowded_corps memoization
          # (checked by Step::DiscardShip#active?/crowded_corps to force
          # an over-limit discard). A manual loop bypasses that
          # invalidation entirely, so a merge that pushes AL over its own
          # train_limit (§9g -- AL's own train_limit is real, just like
          # any corp's) went completely undetected until something else
          # happened to touch @crowded_corps later -- found live in
          # browser: AL sitting at 5 ships with its own limit at 4, no
          # discard ever prompted.
          transfer(:trains, minor, @al_corporation)

          transfer_independent_base!(minor, @al_corporation, counted: true)
          transfer_independent_mine_claims!(minor, @al_corporation)
          carry_over_independent_special_status!(minor, @al_corporation)

          private_company = company_by_id(minor.id)
          minor.close!
          private_company&.close!

          log_independent_al_merge!(minor, owner, half_cash)
        end

        # The owner only receives half the treasury on the independent's
        # first opportunity to merge (when the AL forms). Any later merge
        # -- a decline followed by accepting a subsequent offer, the
        # Phase 5 forced merge, or a bankruptcy-forced merge -- gives the
        # owner nothing unless the independent still owns a ship at the
        # moment of merger. Short Game exception (§13a):
        # "Independent owners receive 1/2 of their cash-on-hand only if
        # they join the Asteroid League when it first forms (regardless
        # of whether they still possess a spaceship if they join later)"
        # -- the "still owns a ship" exception for a later merge simply
        # doesn't exist under this optional rule; only the
        # first-opportunity case ever pays out.
        #
        # Returns half_cash so the caller's own log line can distinguish
        # a split payout from a keep-everything one.
        def pay_independent_merge_cash!(minor, owner, first_opportunity, recipient)
          owner_gets_half = first_opportunity || (!optional_short_game && !minor.trains.empty?)
          # .round guards against a non-integer minor.cash -- money here
          # should always be whole dollars, but this is defensive in case
          # some earlier turn's arithmetic left a fractional residue (found
          # live in browser: a stale $72.5 in a log line, from an odd
          # total run through plain float division somewhere upstream).
          # Confirmed with the user: the owner's share rounds UP, the
          # recipient's share rounds DOWN -- the opposite of what this
          # used to do (owner got floor(total/2), recipient got the ceil
          # remainder). Both amounts are computed up front from the same
          # rounded total, rather than spending the owner's half and then
          # relying on whatever's left in minor.cash for the recipient's
          # share, so a leftover fractional cent can never carry over via
          # the second spend.
          total_cash = minor.cash.round
          half_cash = owner_gets_half ? (total_cash + 1) / 2 : 0
          remaining_cash = total_cash - half_cash
          # check_positive: false on top of the .positive? guards themselves
          # (not just belt-and-suspenders) -- matches Step::Dividend#
          # payout_entity's own zero-guard + check_positive: false pairing
          # for the same "split revenue between multiple parties, some
          # shares legitimately zero" shape.
          minor.spend(half_cash, owner, check_positive: false) if half_cash.positive?
          minor.spend(remaining_cash, recipient, check_positive: false) if remaining_cash.positive?
          half_cash
        end

        # Shared by merge_independent_into_al! (entity: AL, counted: true)
        # and form_growth_corporation! (entity: the new Growth Corp,
        # counted: false) -- the two are NOT identical: confirmed with the
        # user that a base the AL receives via merger DOES count against
        # its own base_limit (a Growth Corp's own inherited base, from the
        # one independent it converted from, stays an uncounted extra, as
        # before). This matters beyond bookkeeping -- base_limit(AL)
        # already reserves capacity for not-yet-merged independents by
        # shrinking as remaining_independents.size grows and giving it
        # back as they merge in (§8.12/Phase 9h); if a merged-in base
        # never actually consumed any of that returning capacity, AL could
        # end up placing its own full allotment of bases AND keep every
        # inherited one too, exceeding its real combined total. Counting
        # it here (via @base_hexes, the same array base_hexes(entity).size
        # is checked against in Step::BuyInfrastructure#base_choices)
        # keeps the two exactly offsetting, so the true combined cap holds.
        def transfer_independent_base!(minor, entity, counted:)
          return unless (token = minor.tokens.find(&:used))

          new_token = Token.new(entity)
          entity.tokens << new_token
          token.swap!(new_token, check_tokenable: false)
          if counted
            @base_hexes[entity] << minor.coordinates
          else
            @extra_base_hexes[entity] << minor.coordinates
          end
        end

        # Claims transfer too, and DO count against entity's own
        # claim_limit (§9g/Phase 8 alike) -- a plain ownership
        # reassignment, since claims_placed_lifetime/claim_limit are
        # always computed fresh from @mine_state, nothing else to keep in
        # sync. Shared by merge_independent_into_al! and
        # form_growth_corporation!.
        def transfer_independent_mine_claims!(minor, entity)
          @mine_state.each_value do |state|
            state[:mines].each { |m| m[:owner] = entity.id if m[:owner] == minor.id }
          end
        end

        # Fast Buck has no in-flight pilot ability (its $15/OR income is
        # passive, unrelated to any ship) -- only push a pilot source for
        # independents PILOT_NAMES actually recognizes, or pilot_
        # description would render a blank "<nil>: <nil>" entry for it.
        # A treasury_income source's (Fast Buck today) own per-OR income
        # follows it wherever it's absorbed -- otherwise Minor#close!
        # (called by the caller right after this) sets its own @floated
        # to false forever, and pay_fast_buck_treasury would just
        # silently stop paying anyone. Shared by merge_independent_into_al!
        # and form_growth_corporation!.
        #
        # Game::PILOT_NAMES -- qualified since PILOT_NAMES is defined
        # directly on Game, not in this module; a bare reference here
        # would only see this module's own (empty) ancestry, never Game's.
        def carry_over_independent_special_status!(minor, entity)
          (@growth_corp_pilot[entity.id] ||= []) << minor.id if Game::PILOT_NAMES.key?(minor.id)
          @fast_buck_income_recipient = entity if minor.id == treasury_income_source_sym
        end

        def log_independent_al_merge!(minor, owner, half_cash)
          if half_cash.positive?
            @log << "#{minor.name} merges into #{@al_corporation.name}; #{owner.name} receives "\
                    "#{format_currency(half_cash)} and a 10% #{@al_corporation.name} share "\
                    "(#{@al_corporation.name} keeps the other half of #{minor.name}'s treasury)"
          else
            @log << "#{minor.name} merges into #{@al_corporation.name}; #{owner.name} receives "\
                    "a 10% #{@al_corporation.name} share (#{@al_corporation.name} keeps all of "\
                    "#{minor.name}'s treasury)"
          end
        end
      end
    end
  end
end
