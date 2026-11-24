# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G2038
      module Step
        # Step::SpecialChoose's `blocks?` is hardcoded false, so it can't
        # force a real yes/no decision -- a dedicated step was the only
        # way to do that, replacing AE's `choose_ability` ability entirely.
        #
        # `al_formation_declined`, not `declined`: this step and
        # MergeIntoLeague share the same operating_round's unnamespaced
        # round_state, and `declined` is already MergeIntoLeague's own
        # (an array) -- reusing that key would silently corrupt it to
        # `false`.
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
