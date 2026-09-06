# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G2038
      module Step
        # Forces AE's owner to explicitly form-or-decline the Asteroid
        # League once eligible (Phase 3-4).  This
        # must interrupt play and force a real yes/no, not sit as a
        # take-it-or-leave-it side option. The generic engine's
        # `choose_ability` mechanism (Step::SpecialChoose) can only ever be
        # non-blocking -- its `blocks?` is hardcoded false, and even if that
        # weren't true, the round's own blocking check keys off
        # `current_entity` (a player/operating corp), which a bare private
        # company like AE never is -- so a dedicated step was the only way
        # to make this a real, forced decision. AE's `choose_ability`
        # ability was removed from entities.rb; this replaces it entirely.
        #
        # Modeled directly on MergeIntoLeague's same shape: overrides
        # active_entities/active? (bypassing the Passer/@passed default,
        # same reason MergeIntoLeague does -- eligibility can begin
        # partway through a round, since buying the Phase III ship is
        # itself an OR action) and a round_state flag that resets for free
        # on every new round instance, giving "ask again next round" (per
        # EVENTS_TEXT: "...or at the beginning of each Stock or Operating
        # round thereafter" -- confirmed with the user this means BOTH
        # round types, not just OR; wired into both stock_round and
        # operating_round in game.rb for exactly this reason).
        #
        # Named `al_formation_declined`, not `declined` -- both this step
        # and MergeIntoLeague are wired into the same operating_round, and
        # round_state is applied step by step in array order with no
        # namespacing; a same-named key here (which needs a boolean) would
        # silently clobber MergeIntoLeague's own `declined` (which needs an
        # array), corrupting it to `false` and crashing the next `Array#-`
        # call on it. Hit exactly this bug once already -- confirmed the
        # crash, fixed by renaming rather than trying to share one key.
        class FormAsteroidLeague < Engine::Step::Base
          ACTIONS = %w[choose].freeze
          FORM = 'form'
          DECLINE = 'decline'

          def round_state
            { al_formation_declined: false }
          end

          def actions(entity)
            return [] unless entity == current_entity

            ACTIONS
          end

          def active?
            !active_entities.empty?
          end

          def active_entities
            return [] unless eligible?

            [ae.owner]
          end

          def blocks?
            true
          end

          def description
            'Form Asteroid League?'
          end

          def choice_name
            "Form the Asteroid League as #{ae.name}'s owner?"
          end

          def choices
            {
              FORM => 'Form the Asteroid League',
              DECLINE => 'Decline (asked again next round)',
            }
          end

          def process_choose(action)
            if action.choice == FORM
              @game.form_asteroid_league!(ae.owner)
            else
              @round.al_formation_declined = true
              @log << "#{ae.owner.name} declines to form the Asteroid League this round"
            end
          end

          private

          def eligible?
            return false if @game.asteroid_league_formed?
            return false if @round.al_formation_declined
            return false unless %w[3 4].include?(@game.phase.name)

            ae&.owner&.player?
          end

          def ae
            @game.company_by_id('AE')
          end
        end
      end
    end
  end
end
