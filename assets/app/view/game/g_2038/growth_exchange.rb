# frozen_string_literal: true

require 'view/game/actionable'

module View
  module Game
    module G2038
      # G2038-only Par-screen addition: buttons to start a corporation by
      # trading in an owned independent (Growth Corp conversion, Phase 8)
      # instead of paying cash. Dedicated child component, mounted from
      # Par#render only when @step.respond_to?(:growth_exchange_choices),
      # so no other game's Par screen is affected.
      class GrowthExchange < Snabberb::Component
        include Actionable

        needs :step
        needs :current_entity
        needs :corporation

        def render
          choices = @step.growth_exchange_choices(@current_entity, @corporation)
          return '' if choices.empty?

          buttons = choices.map do |choice, label|
            props = {
              style: {
                width: 'calc(17.5rem/6)',
                padding: '0.2rem',
              },
              on: { click: -> { process_action(Engine::Action::Choose.new(@current_entity, choice: choice)) } },
            }
            h('button.small.par_price', props, label)
          end

          h(:div, [
            h('div.inline', { style: { marginTop: '0.5rem' } }, 'Exchange Independent: '),
            *buttons,
          ])
        end
      end
    end
  end
end
