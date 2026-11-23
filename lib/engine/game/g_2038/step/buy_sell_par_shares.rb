# frozen_string_literal: true

require_relative '../../../step/buy_sell_par_shares'

module Engine
  module Game
    module G2038
      module Step
        # Adds a second way to start any unfloated, non-AL corporation (§8):
        # trading in an owned independent for that corp's president's
        # certificate instead of paying cash. Surfaced as extra buttons
        # directly in the par UI (assets/app/view/game/par.rb) alongside the
        # normal par-price buttons, rather than a separate step/action -- see
        # Game#form_growth_corporation! for the actual asset transfer.
        class BuySellParShares < Engine::Step::BuySellParShares
          GROW = 'grow_'

          # Two market cells exist solely for special-cased formation paths,
          # never a player-chosen cash par: $10/par_2 is Growth Corp
          # conversion's fixed market-token start (Game#
          # form_growth_corporation!, set directly via `share_price=`), and
          # $125/par_1 is the Asteroid League's own fixed par
          # (Game#form_asteroid_league!, via stock_market.set_par). Neither
          # should appear among the regular 67/77/88/100 par choices.
          SPECIAL_PAR_PRICES = [10, 125].freeze

          def get_par_prices(entity, corp)
            super.reject { |p| SPECIAL_PAR_PRICES.include?(p.price) }
          end

          # The Base can_buy_any_from_ipo?/can_ipo_any? methods look at
          # corporation.shares to find what's still buyable pre-sellout
          # -- correct only when ipo_owner == self, true for every game
          # except this one. Once optional_stock_repurchases points a
          # full-cap corp's ipo_owner at the bank, those still-unsold
          # shares move to the bank and corporation.shares goes
          # permanently empty, even for a corp nobody has parred yet.
          # corporation.ipo_shares tracks the *right* holder regardless
          # of where ipo_owner points -- the same fix 1862 already uses
          # for its own chartered companies. Deliberately doesn't also
          # check genuine treasury shares here -- the standard
          # render_treasury_shares/can_buy? path already handles those
          # on its own once buy_shares is available for any reason.
          def can_buy_any_from_ipo?(entity)
            @game.corporations.each do |corporation|
              next unless corporation.ipoed
              return true if can_buy_shares?(entity, corporation.ipo_shares)
            end

            false
          end

          # Base's own version only asks "can this player afford SOME
          # corp's cheapest cash par price" -- wrong here, since a
          # Growth Corp conversion starts a corp for FREE (an owned
          # independent traded in, exchange: :free). Without this
          # override, a player holding a convertible independent but
          # unable to afford ANY corp's cheapest cash par lost 'par'
          # from `actions` entirely -- and since the growth-exchange
          # buttons only render *inside* the Par component, which only
          # mounts when 'par' is in @current_actions, losing 'par'
          # silently hid the exchange option too, even though it needs
          # no cash at all.
          def can_ipo_any?(entity)
            return true if choice_available?(entity)

            !bought? && @game.corporations.any? do |c|
              @game.can_par?(c, entity) && can_buy?(entity, c.ipo_shares.first&.to_bundle)
            end
          end

          def actions(entity)
            result = super
            return result unless choice_available?(entity)

            result = result.dup
            result << 'choose' unless result.include?('choose')
            result << 'pass' unless result.include?('pass')
            result
          end

          # Without the bought? guard, a player who still holds a second
          # growth-convertible minor would keep 'choose'/'pass' in
          # `actions` forever, even after already exchanging once this
          # turn, and the round would never auto-advance, forcing an
          # unnecessary manual Done click. A growth exchange is a
          # purchase-type action (`bought?` above), so it must be
          # blocked exactly like a second buy_shares/par would be.
          def choice_available?(entity)
            return false unless entity&.player?
            return false if bought?

            !@game.growth_convertible_minors(entity).empty? && !@game.growth_convertible_corporations.empty?
          end

          # The base class's `bought?` only recognizes PURCHASE_ACTIONS
          # (BuyCompany/BuyShares/Par). A growth-exchange choice
          # dispatches via Action::Choose, which isn't in that list, so
          # without this override the engine never registered the
          # exchange as "having acted" -- the round wouldn't advance
          # once the queried player had nothing else to do. Scoped to
          # the "grow_" prefix so it doesn't affect unrelated Choose
          # actions from other steps.
          def bought?
            super || @round.current_actions.any? { |x| x.is_a?(Action::Choose) && x.choice.to_s.start_with?(GROW) }
          end

          # The exchange buttons render directly in par.rb rather than
          # via the generic bottom-panel Choose component or a map hex
          # click -- explicitly no-op'd here so choose.rb's
          # `step.choice_name` and hex.rb's dispatch never crash or
          # misfire for this step.
          def entity_choices(_entity)
            {}
          end

          def choice_name
            nil
          end

          def choices(_entity = current_entity)
            {}
          end

          # Called from par.rb: this player's exchange options specifically
          # for `corporation` (one button per owned independent).
          def growth_exchange_choices(entity, corporation)
            return {} unless choice_available?(entity)
            return {} unless @game.growth_convertible_corporations.include?(corporation)

            @game.growth_convertible_minors(entity).each_with_object({}) do |minor, result|
              result["#{GROW}#{corporation.id}_#{minor.id}"] = "Exchange #{minor.name}"
            end
          end

          def process_choose(action)
            entity = action.entity
            _prefix, corp_id, minor_id = action.choice.split('_')
            corp = @game.corporation_by_id(corp_id)
            minor = @game.minor_by_id(minor_id)
            if !corp || !minor || !@game.growth_convertible_corporations.include?(corp) ||
               !@game.growth_convertible_minors(entity).include?(minor)
              raise GameError, "Invalid growth conversion choice: #{action.choice}"
            end

            @game.form_growth_corporation!(entity, minor, corp)

            # Base-class buy/par actions self-record via track_action --
            # process_choose has no such call by default, so without
            # this the exchange would never land in @round.
            # current_actions for `bought?` (above) to find.
            track_action(action, corp)
          end

          # The base engine's own action_is_shenanigan? only recognizes
          # Par/BuyShares/SellShares/TakeLoan. A growth-corp conversion
          # dispatches via Action::Choose instead, so it fell through to
          # the generic "Unknown action choose disabling for safety"
          # catch-all: accurate, but unhelpfully vague about why.
          # `corporation` here is already the newly-formed corp --
          # should_stop_applying_program looks it up from @round.
          # players_history, which process_choose's track_action(action,
          # corp) call above deliberately files this action under.
          def action_is_shenanigan?(entity, other_entity, action, corporation, share_to_buy)
            if action.is_a?(Action::Choose) && action.choice.to_s.start_with?(GROW)
              return "#{corporation.name} formed as Growth Corporation"
            end

            super
          end
        end
      end
    end
  end
end
