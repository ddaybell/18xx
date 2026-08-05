# frozen_string_literal: true

require 'view/game/actionable'

module View
  module Game
    # Generic tab-style selector for choosing which of several available
    # "vehicles" (trains, ships, etc.) to act with next, for games whose
    # route-building step can't use the standard RouteSelector (e.g. it
    # doesn't build multiple routes in parallel for a single batched submit).
    # Visually mirrors RouteSelector's train tabs; any step opts in by
    # implementing `ship_rows(entity)`, an array of
    # `{ choice:, label:, selected:, summary: }` hashes -- `choice` is nil
    # for a ship that's already finished this OR, in which case `summary`
    # (e.g. mines visited/revenue) renders next to its label instead.
    class ShipSelector < Snabberb::Component
      include Actionable
      include Lib::Settings

      needs :game, store: true

      def render
        step = @game.round.active_step
        return '' unless step.respond_to?(:ship_rows)

        entity = @game.round.current_entity
        rows = step.ship_rows(entity)
        suggest = render_suggest_button(step, entity)
        return suggest || '' if rows.empty?

        tabs = rows.map { |row| render_row(entity, row) }

        children = [
          h(:div, 'Select Ship:'),
          h(:div, { style: { display: 'flex', flexDirection: 'column', alignItems: 'flex-start' } }, tabs),
        ]
        # Not `*suggest` -- Opal's array-splat tries a respond_to?(:to_a)
        # duck-type check on the spread value, which crashes outright on a
        # snabbdom vnode (not a real Opal object, so it has no $respond_to?
        # at all): "value.$respond_to? is not a function", found live in
        # browser the moment a multi-ship entity (e.g. TSI with several
        # ships) rendered this panel. A plain conditional append sidesteps
        # the coercion entirely.
        children << suggest if suggest

        h(:div, { style: { marginBottom: '0.5rem' } }, children)
      end

      # "Suggest" only ever makes sense for a ship that's selected (or, in
      # the common single-ship case, implicitly the only one there is)
      # and hasn't launched yet -- once mid-flight, the step's own
      # choices already show the live options, and switching to a
      # suggested plan mid-trace isn't offered.
      #
      # Suggest/Previous/Trim are plain method calls on the step object,
      # never process_action -- computing (or discarding) a preview isn't
      # itself a game move, so it shouldn't become a permanent entry in
      # the action history. Earlier builds routed all four through
      # process_action, which meant every Suggest Route click -- accepted
      # or not -- got baked into the replayable action log forever; found
      # live in browser as a multi-minute page-load hang once the search's
      # own time budget was temporarily raised for testing, since replay
      # re-ran the full search for every one of those recorded clicks.
      # This mirrors how the standard Engine::AutoRouter already works
      # (RouteSelector#actions' `auto` lambda calls router.compute
      # directly and stores the result as local UI state) -- only the
      # final submit/Accept is a real action. store(:game, @game) forces
      # the re-render a process_action call would otherwise have given us
      # for free, since @game itself (and the round/step objects hanging
      # off it) were mutated in place.
      # Two-state button bar, kept compact ("Route:" + at most three
      # buttons) rather than showing every option at once: nothing
      # pending yet offers "Last"/"Suggest" (pick a starting point);
      # once something's pending, those two are replaced by "Trim
      # Stop"/"Accept"/"Clear" (work with what's on offer). "Clear" drops
      # the pending suggestion outright and returns to the first state,
      # same as repeatedly trimming but in one click.
      def render_suggest_button(step, entity)
        return nil unless step.respond_to?(:suggestable?) && step.suggestable?(entity)

        pending = step.respond_to?(:suggestion_pending?) && step.suggestion_pending?(entity)
        buttons = pending ? pending_buttons(step, entity) : idle_buttons(step, entity)
        # Not `[label, *buttons]` -- Opal's array-splat crashes on a
        # snabbdom vnode the moment it isn't a plain array already (see
        # ShipSelector's earlier `*suggest` incident); plain concatenation
        # sidesteps the coercion entirely.
        children = [h(:span, { style: { marginRight: '0.4rem' } }, 'Route:')] + buttons

        if pending
          children << h(:div, { style: { marginTop: '0.2rem' } }, step.pending_suggestion_summary(entity))
        end

        h(:div, { style: { marginTop: '0.3rem', display: 'flex', flexWrap: 'wrap', alignItems: 'center' } },
          children)
      end

      def idle_buttons(step, entity)
        buttons = []
        if step.respond_to?(:previous_route_available?) && step.previous_route_available?(entity)
          buttons << local_button('Last') { step.replay_previous_route!(entity) }
        end
        buttons << suggest_button(step, entity)
        buttons
      end

      def pending_buttons(step, entity)
        buttons = []
        buttons << local_button('Trim Stop') { step.trim_pending_suggestion!(entity) } if step.trimmable?(entity)
        buttons << accept_button(step, entity)
        buttons << local_button('Clear') { step.clear_pending_suggestion!(entity) }
        buttons
      end

      # A button whose click runs purely locally against the already-
      # in-memory game/step objects (no process_action), then forces a
      # re-render. Used for every preview-only interaction (Suggest,
      # Previous Route, Trim) -- see render_suggest_button's comment.
      def local_button(label)
        props = {
          style: { marginRight: '0.3rem' },
          on: {
            click: lambda {
              yield
              store(:game, @game)
            },
          },
        }
        h('button.no_margin', props, label)
      end

      # Suggest Route's own click handler additionally checks, right after
      # the search runs, whether it hit its time budget -- if so it flashes
      # a transient warning (not logged: it's a heads-up about search
      # quality, not game state) so the player knows the preview may not be
      # the true optimum before they decide whether to accept it.
      def suggest_button(step, entity)
        props = {
          style: { marginRight: '0.3rem' },
          on: {
            click: lambda {
              step.suggest_route!(entity)
              store(:game, @game)
              next unless step.respond_to?(:pending_suggestion_timed_out?)
              next unless step.pending_suggestion_timed_out?(entity)

              store(
                :flash_opts,
                'The route suggester ran out of time before finishing its search -- '\
                'this may not be the best possible route.',
              )
            },
          },
        }
        h('button.no_margin', props, 'Suggest')
      end

      # The one and only action this whole flow ever submits -- see
      # render_suggest_button's comment. Carries the pending suggestion's
      # hex path and cargo picks directly in the choice string (see
      # Step::Route#accept_choice_for_pending), so it's fully
      # self-contained and needs no prior action to have populated
      # anything for replay to work.
      def accept_button(step, entity)
        props = {
          style: { marginRight: '0.3rem' },
          on: {
            click: lambda {
              choice = step.accept_choice_for_pending(entity)
              process_action(Engine::Action::Choose.new(entity, choice: choice)) if choice
            },
          },
        }
        h('button.no_margin', props, 'Accept')
      end

      def render_row(entity, row)
        clickable = !row[:choice].nil?
        blocked = row[:blocked]
        label = row[:summary] ? "#{row[:label]} — #{row[:summary]}" : row[:label]

        # Plain ship-choice tabs (no summary yet) stay short/centered and
        # shrink to fit, same look as before. Once a summary is attached
        # (a finished ship's revenue/mines-visited recap, or the actively
        # flying ship's live cargo status), the label can run long -- these
        # stretch to the panel's full width and wrap instead of running off
        # the edge with `nowrap` and getting clipped by the sidebar.
        style = {
          border: "solid 3px #{row[:selected] ? color_for(:font) : color_for(:bg)}",
          display: 'block',
          cursor: clickable || blocked ? (row[:selected] ? 'default' : 'pointer') : 'default',
          margin: '0.1rem 0rem',
          padding: '3px 6px',
          minWidth: '1.5rem',
          maxWidth: '100%',
          width: row[:summary] ? '100%' : 'fit-content',
          boxSizing: 'border-box',
          textAlign: row[:summary] ? 'left' : 'center',
          whiteSpace: 'normal',
          wordBreak: 'break-word',
          opacity: clickable ? 1.0 : 0.7,
        }

        props = { style: style }
        if clickable
          props[:on] = { click: -> { process_action(Engine::Action::Choose.new(entity, choice: row[:choice])) } }
        elsif blocked
          props[:on] = {
            click: -> {
              store(:flash_opts, "Cannot switch ships in mid-flight; please finish active ship's route first.")
            },
          }
        end

        h(:div, props, label)
      end
    end
  end
end
