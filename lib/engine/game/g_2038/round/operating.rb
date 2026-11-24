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

          # Catches the Probe rusting mid-round, after TSI's pre-float
          # turn was already queued -- Game#operating_order stops
          # inserting TSI once the Probe is gone, but only takes effect
          # on the next round built from scratch.
          def skip_entity?(entity)
            return true if @game.tsi_pre_float?(entity) && !@game.probe_available?

            super
          end

          # §7.39/Phase 9f. Checked here rather than skip_entity? so
          # BuyTrain still runs first -- the owner could buy a
          # replacement ship during this same turn.
          def after_end_of_turn(operator)
            super

            return unless operator.minor?
            return unless @game.independent_must_merge?(operator)

            @game.merge_independent_into_al!(operator)
          end

          # TSI's pre-float turn is Route only -- the rest of a normal
          # corp turn doesn't apply yet (e.g. Dividend's default
          # "withhold" would still move the share price at $0 revenue).
          def skip_steps
            entity = @entities[@entity_index]
            return super unless @game.tsi_pre_float?(entity)

            route_step = @steps.find { |s| s.is_a?(G2038::Step::Route) }
            return super if route_step&.active? && route_step&.blocking?

            @steps.each { |s| s.pass! unless s == route_step }
          end

          private

          def pay_fast_buck_treasury
            # Read via Game#fast_buck_income_recipient, not the source
            # company directly -- Minor#close! sets its @floated to
            # false on absorption, which would silently stop the income.
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
