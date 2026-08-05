# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G2038
      module Step
        # Voluntary independent-to-AL mergers (§8, Phase 9c/9d), modeled
        # directly on 1835's Prussian formation/merger step
        # (g_1835/step/minor_exchange.rb): reuses the generic `choose`
        # action (no dedicated Action class), and a `round_state`-backed
        # `declined` array that naturally resets every new round instance --
        # giving "one pass per round" for free with no extra bookkeeping.
        #
        # Timing (confirmed with the user): the instant the AL forms, every
        # remaining independent gets one offer, clockwise from the AL
        # president -- this can land in whichever round type AL happened to
        # form in. After that, only independents who've *never* been offered
        # a choice may be offered one during a Stock round (the one true
        # initial pass); anyone who already declined only gets re-offered at
        # the start of an Operating round, every OR, for as long as they
        # remain unmerged. `@game.al_independents_ever_offered` (permanent,
        # not round-scoped) is what distinguishes "never offered yet" from
        # "declined previously" for this Stock-round restriction.
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

          # Overrides the Passer-based default (`!@passed`) entirely, same
          # as 1835's MinorExchange -- this step's relevance can flip from
          # false to true *partway through* a round (AL can form mid-OR via
          # SpecialChoose), well after `skip_steps` may have already marked
          # it passed while nothing was yet eligible. A purely dynamic
          # `active?` means it can pick back up later in that same round
          # instead of staying permanently skipped once passed.
          def active?
            !active_entities.empty?
          end

          def active_entities
            return [] unless @game.asteroid_league_formed?

            candidates = @game.remaining_independents - @round.declined
            candidates = candidates.reject { |m| @game.al_independents_ever_offered.include?(m.id) } if @round.stock?
            sort_by_owner_rotation(candidates)
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
            @game.al_independents_ever_offered << entity.id unless @game.al_independents_ever_offered.include?(entity.id)

            if choice == MERGE
              @game.merge_independent_into_al!(entity, first_opportunity: first_opportunity)
            else
              @round.declined << entity
              @log << "#{entity.owner.name} declines to merge #{entity.name} into #{@game.al_corporation.name}"
            end
          end

          private

          # Clockwise from the AL president, always -- confirmed with the
          # user this doesn't depend on who formed the AL or whose turn it
          # currently is. Stable sort keeps same-owner independents
          # adjacent, so a player who owns 2+ gets asked about all of them
          # back to back before rotating to the next player.
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
