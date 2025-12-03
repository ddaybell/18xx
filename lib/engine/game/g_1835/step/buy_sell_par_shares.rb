# frozen_string_literal: true

require_relative '../../../step/buy_sell_par_shares'

module Engine
  module Game
    module G1835
      module Step
        class BuySellParShares < Engine::Step::BuySellParShares
          # Nationalization: Check if player can buy shares from another player
          # Requires owning at least 55% of the corporation
          def can_buy?(entity, bundle)
            if bundle&.owner&.player?
              return false unless can_nationalize?(entity, bundle.corporation)

              return entity.cash >= nationalization_price(bundle.price) &&
                !@round.players_sold[entity][bundle.corporation] &&
                can_gain?(entity, bundle)
            end

            super
          end

          # Check if entity can buy any shares from other players
          def can_buy_any_from_player?(entity)
            return false if bought?

            @game.corporations.select(&:floated?).any? do |corporation|
              can_nationalize?(entity, corporation) &&
                entity.cash >= nationalization_price(corporation.share_price.price)
            end
          end

          # Check if player owns >= 55% of the corporation (required for nationalization)
          def can_nationalize?(player, corporation)
            player.percent_of(corporation) >= @game.class::NATIONALIZATION_THRESHOLD
          end

          # Calculate nationalization price (150% of market value)
          def nationalization_price(price)
            (price * 1.5).ceil
          end

          def process_buy_shares(action)
            return super unless action.bundle.owner.player?

            # Nationalization: buying shares from another player
            player = action.entity
            bundle = action.bundle
            price = nationalization_price(bundle.price)
            owner = bundle.owner
            corporation = bundle.corporation

            raise GameError, 'Cannot nationalize this corporation' unless can_nationalize?(player, corporation)
            raise GameError, 'Not enough cash for nationalization' unless player.cash >= price

            @log << "-- Nationalization: #{player.name} buys a #{bundle.percent}% share " \
                    "of #{corporation.name} from #{owner.name} for #{@game.format_currency(price)} --"

            @game.share_pool.transfer_shares(bundle,
                                             player,
                                             spender: player,
                                             receiver: owner,
                                             price: price)

            track_action(action, corporation)
          end
        end
      end
    end
  end
end
