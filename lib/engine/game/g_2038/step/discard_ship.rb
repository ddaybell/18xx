# frozen_string_literal: true

require_relative '../../../step/discard_train'

module Engine
  module Game
    module G2038
      module Step
        class DiscardShip < Engine::Step::DiscardTrain
          def trains(corporation)
            super.sort_by(&:price)
          end

          # This step is ordered ahead of FormAsteroidLeague/MergeIntoLeague
          # so a player's own crowded corp resolves first -- but
          # Round::Base#process_action picks the first active+blocking step
          # in list order globally, so without this check a crowded corp
          # would also block every other player's unrelated pending action.
          def blocking?
            return false if unrelated_blocking_step_pending?

            super
          end

          private

          def crowded_owners
            crowded_corps.map(&:owner)
          end

          # Checks current_entity, not the full active_entities list -- a
          # step offering several entities a decision in sequence only
          # ever actually lets the first of them act, so checking the
          # whole list could wrongly defer over a later, not-yet-reached
          # entity that happens to belong to someone else.
          def unrelated_blocking_step_pending?
            mine = crowded_owners

            @round.steps.any? do |step|
              next false if step.equal?(self)
              next false if !step.active? || !step.blocking?

              entity = step.current_entity
              owner = entity.respond_to?(:owner) ? entity.owner : entity
              owner && !mine.include?(owner)
            end
          end
        end
      end
    end
  end
end
