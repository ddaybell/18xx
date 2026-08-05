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
          # one left in the Depot must merge into the AL instead of taking
          # its turn (§7.39/Phase 9f) -- mirrors how a closed entity is
          # already skipped here, just with a forced merge as the reason.
          # Safe to call more than once per entity: once merged, `minor.
          # closed?` is true, so the `super` check above short-circuits
          # before ever reaching `independent_must_merge?` again.
          def skip_entity?(entity)
            return true if super

            return false unless @game.independent_must_merge?(entity)

            @game.merge_independent_into_al!(entity)
            true
          end

          # TSI's pre-float turn (flying the Probe under ST's owner's
          # control -- see Game#tsi_pre_float?) is Route only. Once Route
          # is done deciding, the rest of a normal corp turn --
          # Dividend/BuyTrain/BuyCompany/BuyInfrastructure -- doesn't
          # really apply yet (no real president, no real revenue/price
          # mechanics) and going through them one by one either misbehaves
          # (Dividend's default "withhold" still moves the share price
          # even off $0 revenue) or just adds noise (a string of "TSI
          # skips ..." lines). Confirmed with the user: once Route
          # finishes, silently end the turn instead. While Route is still
          # the live decision (blocking), this falls through to the
          # ordinary behavior unchanged -- only takes over once nothing
          # is left to decide there.
          def skip_steps
            entity = @entities[@entity_index]
            return super unless @game.tsi_pre_float?(entity)

            route_step = @steps.find { |s| s.is_a?(G2038::Step::Route) }
            return super if route_step&.active? && route_step.blocking?

            @steps.each { |s| s.pass! unless s == route_step }
          end

          private

          def pay_fast_buck_treasury
            # Fast Buck earns $15 per OR into its own treasury, not to its
            # owner -- and once it's been absorbed (Growth Corp conversion
            # or an AL merger), the same $15 follows it into whichever corp
            # now holds that treasury (Game#fast_buck_income_recipient,
            # reassigned at absorption time). Reading the recipient via
            # that indirection rather than @game.minor_by_id('FB') directly
            # matters because Minor#close! unconditionally sets FB's own
            # @floated to false -- paying FB itself post-absorption would
            # silently stop the income forever instead of continuing it.
            recipient = @game.fast_buck_income_recipient
            return unless recipient&.floated?

            @game.bank.spend(15, recipient)
            if recipient.id == 'FB'
              @game.log << "Fast Buck receives #{@game.format_currency(15)} into its treasury"
            else
              @game.log << "#{recipient.name} receives #{@game.format_currency(15)} from Fast Buck's income"
            end
          end
        end
      end
    end
  end
end
