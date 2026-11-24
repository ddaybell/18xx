# frozen_string_literal: true

require_relative '../../../step/buy_sell_par_shares'

module Engine
  module Game
    module G2038
      module Step
        # §8: a second way to start a corporation -- trading in an owned
        # independent for its president's certificate instead of cash.
        class BuySellParShares < Engine::Step::BuySellParShares
          GROW = 'grow_'

          # $10 (Growth Corp conversion) and $125 (Asteroid League) are
          # each set directly by their own formation code, never chosen
          # from this list.
          SPECIAL_PAR_PRICES = [10, 125].freeze

          def get_par_prices(entity, corp)
            super.reject { |p| SPECIAL_PAR_PRICES.include?(p.price) }
          end

          # Base's version reads corporation.shares, correct only when
          # ipo_owner == self -- not true here once a full-cap corp's
          # ipo_owner moves to the bank (optional_stock_repurchases).
          # ipo_shares tracks the right holder regardless (same fix 1862
          # uses for its own chartered companies).
          def can_buy_any_from_ipo?(entity)
            @game.corporations.each do |corporation|
              next unless corporation.ipoed
              return true if can_buy_shares?(entity, corporation.ipo_shares)
            end

            false
          end

          # Base's version only asks "can afford SOME corp's cash par" --
          # wrong here, since a Growth Corp conversion is free. Without
          # this, a player who can't afford any cash par loses 'par' from
          # `actions`, and since the exchange buttons only render inside
          # the Par component, that silently hides the exchange option too.
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

          # Without the bought? guard, a second growth-convertible minor
          # would keep offering another exchange after this turn's one
          # purchase-type action is already used up.
          def choice_available?(entity)
            return false unless entity&.player?
            return false if bought?

            !@game.growth_convertible_minors(entity).empty? && !@game.growth_convertible_corporations.empty?
          end

          # Base's `bought?` only recognizes PURCHASE_ACTIONS
          # (BuyCompany/BuyShares/Par) -- a growth exchange dispatches via
          # Action::Choose instead, so it's otherwise invisible here.
          def bought?
            super || @round.current_actions.any? { |x| x.is_a?(Action::Choose) && x.choice.to_s.start_with?(GROW) }
          end

          # The exchange buttons render directly in par.rb, not via the
          # generic Choose component or a hex click.
          def entity_choices(_entity)
            {}
          end

          def choice_name
            nil
          end

          def choices(_entity = current_entity)
            {}
          end

          # Called from par.rb.
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

            # process_choose has no track_action call by default, unlike
            # the base class's buy/par actions.
            track_action(action, corp)
          end

          # Base's action_is_shenanigan? only recognizes Par/BuyShares/
          # SellShares/TakeLoan, so a growth conversion otherwise falls
          # through to its vague generic catch-all.
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
