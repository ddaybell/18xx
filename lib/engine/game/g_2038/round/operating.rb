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

          # TSI's pre-float turn only exists to let ST's owner fly the
          # Probe (Game#tsi_pre_float?/#probe_available?) -- if the Probe
          # has since rusted, there's nothing left for that turn to do
          # and no normal corporate turn to fall back to either, since
          # TSI still hasn't floated. Game#operating_order also stops
          # inserting TSI once the Probe is gone, but only takes effect
          # on the *next* round built from scratch -- this catches the
          # Probe rusting *during* a round where TSI's turn was already
          # queued before that happened.
          def skip_entity?(entity)
            return true if @game.tsi_pre_float?(entity) && !@game.probe_available?

            super
          end

          # An independent that owns no ship and can't afford the
          # cheapest one left in the Depot must merge into the AL
          # (§7.39/Phase 9f) -- but only once it's had its own turn and
          # is *still* shipless at the end of it, not pre-emptively
          # before that turn even starts. Checked in after_end_of_turn
          # instead of skip_entity?, so the independent's own turn
          # (BuyTrain still runs -- the owner could buy a replacement
          # ship there) happens first.
          def after_end_of_turn(operator)
            super

            return unless operator.minor?
            return unless @game.independent_must_merge?(operator)

            @game.merge_independent_into_al!(operator)
          end

          # TSI's pre-float turn (flying the Probe under ST's owner's
          # control -- Game#tsi_pre_float?) is Route only. The rest of a
          # normal corp turn doesn't really apply yet (no real president,
          # no real revenue/price mechanics) -- going through them one
          # by one either misbehaves (Dividend's default "withhold"
          # still moves the share price even off $0 revenue) or adds
          # noise. Once Route finishes, silently end the turn instead.
          def skip_steps
            entity = @entities[@entity_index]
            return super unless @game.tsi_pre_float?(entity)

            route_step = @steps.find { |s| s.is_a?(G2038::Step::Route) }
            return super if route_step&.active? && route_step&.blocking?

            @steps.each { |s| s.pass! unless s == route_step }
          end

          private

          def pay_fast_buck_treasury
            # Whichever company entities.rb marks as a treasury_income
            # source (Fast Buck today) earns its flat amount per OR into
            # its own treasury -- and once absorbed (Growth Corp
            # conversion or an AL merger), the amount follows it into
            # whichever corp now holds that treasury (Game#
            # fast_buck_income_recipient). Reading the recipient via that
            # indirection matters because Minor#close! unconditionally
            # sets the source's own @floated to false -- paying it
            # directly post-absorption would silently stop the income.
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
