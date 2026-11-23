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
        # Timing: the instant the AL forms, the game stops and every
        # remaining independent is immediately asked in turn, clockwise
        # from the AL president -- an atomic, uninterruptible sequence
        # (this step's own `active?`/`blocking?` force it) that completes
        # entirely within whichever round type AL happened to form in.
        # Every one of them ends this initial sweep recorded in
        # `@game.al_independents_ever_offered` (permanent, not
        # round-scoped), whether they merged or declined.
        #
        # After that, independents can only merge one further way: any
        # remaining decliner gets asked again at the start of every
        # Operating round, for as long as they stay unmerged -- never
        # during a Stock round. The `@round.stock?` filter below enforces
        # that: `@round.declined` resets on every new round instance, so
        # without also excluding anyone already in
        # `al_independents_ever_offered`, a later Stock round would see
        # a fresh, empty local `declined` and wrongly treat a long-ago
        # decliner as a brand-new candidate.
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

          # Only the one entity actually being asked right now -- mirrors
          # G1870::Step::Connection's own fix for the identical shape
          # (several entities, owned by different players, all eligible
          # at once, but only ever answered one at a time, in order).
          # Round::Base#current_entity/can_act? are keyed off
          # active_entities[0] alone -- returning the *whole* candidate
          # list here made every remaining independent's owner show as
          # "acting" simultaneously the instant AL formed, even though
          # only the first can actually submit a choice.
          def active_entities
            pending_entities.take(1)
          end

          # Opt-in hook (see assets/app/view/game/entity_order.rb): the
          # full upcoming queue, still shown in order for context even
          # though only pending_entities.first is actually "active" above
          # -- same split 1870's Connection module uses (active_entities
          # vs override_entities) for its own destination-run queue.
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

          # Clockwise from the AL president, always. Stable sort keeps same-owner
          # independents adjacent, so a player who owns 2+ gets asked about all of them
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
