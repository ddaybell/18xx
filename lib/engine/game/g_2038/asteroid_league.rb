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

        # §9e: AL is guaranteed to already exist by this point, since
        # Phase 4's asteroid_league_must_form event above always runs first.
        def event_independents_must_join_league!
          remaining_independents.dup.each { |minor| merge_independent_into_al!(minor) }
        end

        # §7.39/Phase 9f.
        def independent_must_merge?(minor)
          return false unless @asteroid_league_formed
          return false unless minor.minor?
          return false if minor.closed?
          return false unless minor.trains.empty?

          cheapest = depot.depot_trains.map(&:price).min
          cheapest.nil? || minor.cash < cheapest
        end

        # `floated` is set directly, not via `float_corporation` -- the
        # rules grant a fixed $250 on formation, not par x total_shares.
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

        # AL forms mid-OR, after this round's @entities snapshot was
        # taken -- slots it into the current OR at its $125 position only
        # if no corporation priced $124 or lower has operated yet.
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

        def remaining_independents
          @minors.reject(&:closed?)
        end

        def record_al_independent_offered!(entity)
          @al_independents_ever_offered << entity.id unless @al_independents_ever_offered.include?(entity.id)
        end

        def merge_independent_into_al!(minor, first_opportunity: !@al_independents_ever_offered.include?(minor.id))
          owner = minor.owner
          half_cash = pay_independent_merge_cash!(minor, owner, first_opportunity, @al_corporation)

          reserved_share = @al_reserved_shares[minor.id]
          reserved_share.buyable = true
          share_pool.buy_shares(owner, reserved_share, exchange: :free)

          # `transfer`, not a manual owner-reassign loop -- a manual loop
          # skips invalidating @crowded_corps, so a merge pushing AL over
          # its train_limit (§9g) went undetected by Step::DiscardShip.
          transfer(:trains, minor, @al_corporation)

          transfer_independent_base!(minor, @al_corporation, counted: true)
          transfer_independent_mine_claims!(minor, @al_corporation)
          carry_over_independent_special_status!(minor, @al_corporation)

          private_company = company_by_id(minor.id)
          minor.close!
          private_company&.close!

          log_independent_al_merge!(minor, owner, half_cash)
        end

        # §13a Short Game exception: the "still owns a ship" exception for
        # a later merge doesn't exist under this optional rule -- only the
        # first-opportunity case ever pays out.
        def pay_independent_merge_cash!(minor, owner, first_opportunity, recipient)
          owner_gets_half = first_opportunity || (!optional_short_game? && !minor.trains.empty?)
          # The owner's share rounds up, the recipient's rounds down.
          # (total_cash + 1) / 2 is plain Integer#/ -- Opal/browser float
          # division, not Ruby's, so a bare `/` here silently returns
          # 72.5 instead of 72 for total_cash == 144. .to_f/.floor
          # replicates Ruby's own result in both environments.
          total_cash = minor.cash.round
          half_cash = owner_gets_half ? ((total_cash + 1).to_f / 2).floor : 0
          remaining_cash = total_cash - half_cash
          minor.spend(half_cash, owner, check_positive: false) if half_cash.positive?
          minor.spend(remaining_cash, recipient, check_positive: false) if remaining_cash.positive?
          half_cash
        end

        # A base AL receives via merger counts against its own
        # base_limit; a Growth Corp's inherited base stays an uncounted
        # extra. base_limit(AL) reserves capacity for not-yet-merged
        # independents (§8.12/Phase 9h) -- an uncounted merged-in base
        # would let AL exceed its real combined total.
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

        # Claims count against entity's own claim_limit too (§9g/Phase 8).
        # A plain ownership reassignment is enough -- claim_limit is
        # always computed fresh from @mine_state.
        def transfer_independent_mine_claims!(minor, entity)
          @mine_state.each_value do |state|
            state[:mines].each { |m| m[:owner] = entity.id if m[:owner] == minor.id }
          end
        end

        # Only push a pilot source for independents PILOT_NAMES actually
        # recognizes, or pilot_description would render a blank
        # "<nil>: <nil>" entry for it. The treasury-income source's
        # per-OR income must follow it here too, or Minor#close! (called
        # right after this) sets @floated false and silently ends it.
        def carry_over_independent_special_status!(minor, entity)
          (@growth_corp_pilot[entity.id] ||= []) << minor.id if Game::PILOT_NAMES.key?(minor.id)
          @fast_buck_income_recipient = entity if minor.id == treasury_income_source_sym
        end

        def log_independent_al_merge!(minor, owner, half_cash)
          @log << if half_cash.positive?
                    "#{minor.name} merges into #{@al_corporation.name}; #{owner.name} receives "\
                      "#{format_currency(half_cash)} and a 10% #{@al_corporation.name} share "\
                      "(#{@al_corporation.name} keeps the other half of #{minor.name}'s treasury)"
                  else
                    "#{minor.name} merges into #{@al_corporation.name}; #{owner.name} receives "\
                      "a 10% #{@al_corporation.name} share (#{@al_corporation.name} keeps all of "\
                      "#{minor.name}'s treasury)"
                  end
        end
      end
    end
  end
end
