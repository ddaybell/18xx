# frozen_string_literal: true

require_relative '../../../round/operating'

module Engine
  module Game
    module G2038
      module Round
        class Operating < Engine::Round::Operating
          def setup
            super
            pay_fast_buck_treasury
          end

          # An independent that owns no ship and can't afford the cheapest
          # one left in the Depot must merge into the AL (§7.39/Phase 9f)
          # -- but only once it's had its own turn and is *still* shipless
          # at the end of it, not pre-emptively before that turn even
          # starts. The rule text ties this to the independent's own
          # turn ending shipless, not to a shipless check firing whenever
          # any *other* company's turn happens to end with this
          # independent up next in rotation. Checked in after_end_of_turn 
          # instead of skip_entity?, so the independent's own turn (Route 
          # auto-skips with no ships, but BuyTrain still runs -- the owner 
          # could choose to buy it a replacement ship there) happens first.
          def after_end_of_turn(operator)
            super

            return unless operator.minor? && @game.independent_must_merge?(operator)

            @game.merge_independent_into_al!(operator)
          end

          # TSI's pre-float turn (flying the Probe under ST's owner's
          # control -- see Game#tsi_pre_float?) is Route only. Once Route
          # is done deciding, the rest of a normal corp turn --
          # Dividend/BuyTrain/BuyCompany/BuyInfrastructure -- doesn't
          # really apply yet (no real president, no real revenue/price
          # mechanics) and going through them one by one either misbehaves
          # (Dividend's default "withhold" still moves the share price
          # even off $0 revenue) or just adds noise (a string of "TSI
          # skips ..." lines). Once Route finishes, silently end the turn 
          # instead. While Route is still the live decision (blocking), 
          # this falls through to the ordinary behavior unchanged -- only 
          # takes over once nothing is left to decide there.
          def skip_steps
            entity = @entities[@entity_index]
            return super unless @game.tsi_pre_float?(entity)

            route_step = @steps.find { |s| s.is_a?(G2038::Step::Route) }
            return super if route_step&.active? && route_step.blocking?

            @steps.each { |s| s.pass! unless s == route_step }
          end

          private

          def pay_fast_buck_treasury
            # Whichever company entities.rb marks as a treasury_income
            # source (Fast Buck today; Game#treasury_income_source_sym)
            # earns its flat amount per OR into its own treasury, not to
            # its owner -- and once it's been absorbed (Growth Corp
            # conversion or an AL merger), the same amount follows it into
            # whichever corp now holds that treasury (Game#
            # fast_buck_income_recipient, reassigned at absorption time).
            # Reading the recipient via that indirection rather than
            # @game.minor_by_id(source_sym) directly matters because
            # Minor#close! unconditionally sets the source's own @floated
            # to false -- paying it directly post-absorption would
            # silently stop the income forever instead of continuing it.
            recipient = @game.fast_buck_income_recipient
            return unless recipient&.floated?

            amount = @game.fast_buck_income_amount
            @game.bank.spend(amount, recipient)
            if recipient.id == @game.treasury_income_source_sym
              @game.log << "#{recipient.name} receives #{@game.format_currency(amount)} into its treasury"
            else
              source_name = @game.company_by_id(@game.treasury_income_source_sym)&.name
              @game.log << "#{recipient.name} receives #{@game.format_currency(amount)} from #{source_name}'s income"
            end
          end
        end
      end
    end
  end
end
