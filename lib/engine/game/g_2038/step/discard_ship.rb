# frozen_string_literal: true

require_relative '../../../step/discard_train'

module Engine
  module Game
    module G2038
      module Step
        class DiscardShip < Engine::Step::DiscardTrain
          # Sorts cheapest ship first, so the discard choice
          # reads left-to-right by price rather than whatever order the
          # corporation happened to buy its ships in.
          def trains(corporation)
            super.sort_by(&:price)
          end

          # §8: a player who just bought the very ship that both crowds
          # their own corp AND hands them the Form-AL/merge decision
          # should resolve their OWN discard first (DiscardShip is
          # ordered ahead of FormAsteroidLeague/MergeIntoLeague in the
          # step list) -- but that global ordering must not ALSO block a
          # completely unrelated player's own pending Form-AL/merge
          # decision just because someone else's corp happens to be
          # crowded at the same moment. Round::Base#process_action picks
          # the first active+blocking step in list order and raises
          # immediately if it can't handle the incoming action, so
          # without this, any crowded corp globally blocks every other
          # player's unrelated actions.
          def blocking?
            return false if unrelated_blocking_step_pending?

            super
          end

          private

          # Every player who owns a corp this step would actually make
          # discard right now.
          def crowded_owners
            crowded_corps.map(&:owner)
          end

          # True if some OTHER step is genuinely blocking (active, with a
          # real decision pending right now) for the one entity it would
          # actually hand the turn to -- current_entity, not the full
          # active_entities list, since a step offering several entities
          # a decision in sequence (MergeIntoLeague, FormAsteroidLeague)
          # only ever actually lets the *first* of them act; checking the
          # whole list here would wrongly defer to a step whose real next
          # actor is one of this step's own crowded-corp owners just
          # because some *later*, not-yet-reached candidate in that same
          # step belongs to someone else.
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
