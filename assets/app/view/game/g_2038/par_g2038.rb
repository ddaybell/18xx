# frozen_string_literal: true

module View
  module Game
    # G2038-only Par-screen addition: buttons to start a corporation by
    # trading in an owned independent (Growth Corp conversion, Phase 8)
    # instead of paying cash. Mixed into the shared Par component the
    # same way HexG2038 is mixed into Hex -- only ever reached via a
    # `@step.respond_to?(:growth_exchange_choices)` guard at its call
    # site in par.rb itself, so no other game's Par screen is affected.
    module ParG2038
      def render_growth_exchange
        return [] unless @step.respond_to?(:growth_exchange_choices)

        choices = @step.growth_exchange_choices(@current_entity, @corporation)
        return [] if choices.empty?

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

        [h(:div, [
          h('div.inline', { style: { marginTop: '0.5rem' } }, 'Exchange Independent: '),
          *buttons,
        ])]
      end
    end
  end
end
