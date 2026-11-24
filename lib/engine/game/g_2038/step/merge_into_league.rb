# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G2038
      module Step
        # §8, Phase 9c/9d. `@round.declined` resets every new round
        # instance, so a Stock round also excludes anyone already in the
        # permanent `al_independents_ever_offered` -- otherwise a later
        # Stock round would see a fresh, empty `declined` and wrongly
        # treat a long-ago decliner as a brand-new candidate.
        class MergeIntoLeague < Engine::Step::Base
          ACTIONS = %w[choose].freeze
          MERGE = 'merge'
          DECLINE = 'decline'

          def round_state
            { declined: [] }
          end

          def actions(entity)
            return [] unless entity == current_entity

            ACTIONS
          end

          # Overrides the Passer-based default (`!@passed`) -- AL can form
          # mid-OR, after `skip_steps` may have already marked this step
          # passed while nothing was yet eligible.
          def active?
            !active_entities.empty?
          end

          # Round::Base#current_entity/can_act? are keyed off
          # active_entities[0] alone -- returning the full candidate list
          # here made every remaining independent's owner show as
          # "acting" simultaneously, even though only the first can act.
          def active_entities
            pending_entities.take(1)
          end

          # Opt-in hook (assets/app/view/game/entity_order.rb): the full
          # upcoming queue, shown for context even though only the first
          # entry is actually "active" above.
          def override_entities
            pending_entities
          end

          def description
            'Merge into Asteroid League'
          end

          def choice_name
            "Merge #{current_entity.name} into #{@game.al_corporation.name}"
          end

          def choices
            {
              MERGE => "Merge #{current_entity.name} into #{@game.al_corporation.name}",
              DECLINE => 'Decline',
            }
          end

          def process_choose(action)
            entity = action.entity
            choice = action.choice
            raise GameError, "Invalid choice: #{choice}" unless choices.key?(choice)

            first_opportunity = !@game.al_independents_ever_offered.include?(entity.id)
            @game.record_al_independent_offered!(entity)

            if choice == MERGE
              @game.merge_independent_into_al!(entity, first_opportunity: first_opportunity)
            else
              @round.declined << entity
              @log << "#{entity.owner.name} declines to merge #{entity.name} into #{@game.al_corporation.name}"
            end
          end

          private

          def pending_entities
            return [] unless @game.asteroid_league_formed?

            candidates = @game.remaining_independents - @round.declined
            candidates = candidates.reject { |m| @game.al_independents_ever_offered.include?(m.id) } if @round.stock?
            sort_by_owner_rotation(candidates)
          end

          def sort_by_owner_rotation(candidates)
            return candidates if candidates.empty?

            players = @game.players.dup
            start_index = players.index(@game.al_corporation.owner) || 0
            owner_positions = players.rotate(start_index).each_with_index.to_h

            candidates.sort_by { |m| owner_positions[m.owner] || Float::INFINITY }
          end
        end
      end
    end
  end
end
