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

        # Single-ship entity: there's no separate row to click (see
        # ship_rows -- "no extra click when there's no real choice"), the
        # one ship is implicitly always selected, so its action bar
        # (Last/Suggest, or Accept/Modify/Cancel, or Submit/Cancel,
        # whichever state applies -- see render_action_bar) just shows
        # directly.
        if rows.empty?
          bar = render_action_bar(step, entity)
          return bar || ''
        end

        # Multi-ship entity: each row gets its own action bar, appearing
        # right under it once that row is selected -- clicking a row
        # both picks that ship (the existing SHIP_ choice) and reveals
        # its buttons, rather than a single button bar shared below the
        # whole list for whichever ship happens to be selected.
        row_children = rows.flat_map do |row|
          [render_row(entity, row), row[:selected] ? render_action_bar(step, entity) : nil]
        end.compact

        h(:div, { style: { marginBottom: '0.5rem' } },
          h(:div, { style: { display: 'flex', flexDirection: 'column', alignItems: 'flex-start' } }, row_children))
      end

      # The one action bar for whichever ship is currently selected --
      # exactly one of three mutually exclusive states (a pending
      # suggestion and an in-progress/pending-submit flight can never
      # coexist: one requires @trace empty, the other requires it not to
      # be): nothing started yet (Last/Suggest), a suggestion awaiting a
      # decision (Accept/Modify/Cancel), or a hand-flown route in progress
      # or finished but not yet submitted (Submit/Cancel).
      # nil when none of the three has anything to show (e.g. a
      # multi-ship entity whose selected ship already ran, or the
      # autorouter is disabled and nothing's in progress).
      #
      # Suggest/Previous/Accept/Modify/Clear are plain method calls on the
      # step object, never process_action -- computing (or discarding) a
      # preview isn't itself a game move, so it shouldn't become a
      # permanent entry in the action history. Earlier builds routed all
      # of these through process_action, which meant every Suggest Route
      # click -- accepted or not -- got baked into the replayable action
      # log forever; found live in browser as a multi-minute page-load
      # hang once the search's own time budget was temporarily raised for
      # testing, since replay re-ran the full search for every one of
      # those recorded clicks. Accept used to be the one exception,
      # submitting itself as a single self-contained real action -- but
      # that turned out to crash on replay whenever 2+ ships were still
      # unrun (the choice string had no way to say which ship it was for)
      # and denied the player a last chance to change their mind before
      # the route locked in; it's local now too, same as everything else
      # here, only the final Submit is a real action. This mirrors how the
      # standard Engine::AutoRouter already works (RouteSelector#actions'
      # `auto` lambda calls router.compute directly and stores the result
      # as local UI state).
      # store(:game, @game) forces the re-render a process_action call
      # would otherwise have given us for free, since @game itself (and
      # the round/step objects hanging off it) were mutated in place.
      def render_action_bar(step, entity)
        if step.respond_to?(:suggestion_pending?) && step.suggestion_pending?(entity)
          return render_pending_suggestion_bar(step, entity)
        end

        return render_flight_bar(step, entity) if step.respond_to?(:local_pass?) && step.local_pass?(entity)

        render_idle_bar(step, entity)
      end

      def render_idle_bar(step, entity)
        buttons = []
        if step.respond_to?(:previous_route_available?) && step.previous_route_available?(entity)
          buttons << local_button('Last') { step.replay_previous_route!(entity) }
        end
        buttons << suggest_button(step, entity) if step.respond_to?(:suggestable?) && step.suggestable?(entity)
        return nil if buttons.empty?

        action_bar(buttons)
      end

      # Accept and Modify both hand the whole suggestion off to
      # hand-flying via the same local replay (see
      # G2038::Step::Route#apply_pending_suggestion!) -- Accept just does
      # it and leaves the player looking at Submit/Cancel, ready to go if
      # they like the route as-is; Modify does the exact same thing, the
      # only difference being the player's intent to then click on the
      # route's own endpoint and undo it hex by hex (see
      # G2038::Step::Route#undo_click_hex/undo_last_hex!) before
      # submitting. No Trim Stop button needed here -- that endpoint-click
      # undo covers the same "back off from the end" need either way.
      def render_pending_suggestion_bar(step, entity)
        buttons = []
        buttons << local_button('Accept') { step.apply_pending_suggestion!(entity) }
        buttons << local_button('Modify') { step.apply_pending_suggestion!(entity) }
        buttons << local_button('Clear Ship') { step.clear_pending_suggestion!(entity) }

        action_bar(buttons)
      end

      # Submit only shows once it's actually legal (see
      # G2038::Step::Route#submit_ready?'s comment) -- e.g. right after
      # launch, before a second hex has been entered, only Cancel has
      # anything to do yet.
      # No button for undoing the last hex here -- clicking the route's
      # own endpoint on the map does it directly now (with a confirm
      # popup first if it would un-reveal a tile), whether the flight is
      # still in progress or already finished but not yet submitted --
      # see G2038::Step::Route#undo_click_hex/undo_last_hex!.
      def render_flight_bar(step, entity)
        buttons = []
        buttons << submit_button(step, entity) if step.respond_to?(:submit_ready?) && step.submit_ready?(entity)
        buttons << cancel_flight_button(step, entity)

        action_bar(buttons)
      end

      def action_bar(buttons)
        # Not `[label, *buttons]` -- Opal's array-splat crashes on a
        # snabbdom vnode the moment it isn't a plain array already (see
        # ShipSelector's earlier `*suggest` incident); plain concatenation
        # sidesteps the coercion entirely.
        children = [h(:span, { style: { marginRight: '0.4rem' } }, 'Route:')] + buttons

        h(:div, { style: { marginTop: '0.3rem', display: 'flex', flexWrap: 'wrap', alignItems: 'center' } },
          children)
      end

      # A button whose click runs purely locally against the already-
      # in-memory game/step objects (no process_action), then forces a
      # re-render. Used for every preview-only interaction (Suggest,
      # Previous Route, Trim, Modify, Clear) -- see render_action_bar's
      # comment.
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

      # Reuses the standard AutoRouter's own "Route timeout" Tools-tab
      # setting as this search's time budget -- G2038's autorouter is a
      # single-phase search (no separate path-building phase to hang
      # "Path timeout" off of), so route_timeout alone is the closest fit.
      # Additionally checks, right after the search runs, whether it hit
      # that budget -- if so it flashes a transient warning (not logged:
      # it's a heads-up about search quality, not game state) so the
      # player knows the preview may not be the true optimum before they
      # decide whether to accept it.
      def suggest_button(step, entity)
        props = {
          style: { marginRight: '0.3rem' },
          on: {
            click: lambda {
              step.suggest_route!(entity, timeout: setting_for(:route_timeout).to_i)
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
        h('button.no_margin', props, 'Auto')
      end

      # A hand-flown (or accepted/modified) route's real submit: the whole
      # flight was already built up locally, hop by hop (see
      # G2038::Step::Route#local_choose!). Shows (and is clickable) as
      # soon as finishing is a legal move, not just once the flight has
      # actually finished -- ending a route with MP still left looks and
      # behaves identically to running out of MP, one click either way
      # (see submit_ready?/finish_and_submit_choice's comments): no
      # separate "Finish" click before Submit appears.
      def submit_button(step, entity)
        props = {
          style: { marginRight: '0.3rem' },
          on: {
            click: lambda {
              choice = step.finish_and_submit_choice(entity)
              process_action(Engine::Action::Choose.new(entity, choice: choice)) if choice
            },
          },
        }
        h('button.no_margin', props, step.submit_button_label(entity))
      end

      # Clears an in-progress or finished-but-not-yet-submitted flight --
      # runs purely locally (step.local_pass!, the exact same discard the
      # standalone Pass button triggers when it intercepts a real Pass
      # action -- see assets/app/view/game/actionable.rb), so this is a
      # same-effect shortcut living right on the ship's row rather than a
      # second, different code path. The explored-tile warning comes
      # straight from pass_description (shared with the standalone
      # button's own wording), just with "Cancel" swapped for "Clear
      # Ship" -- the two buttons never show at once (suppress_standalone_
      # pass? hides the standalone one whenever this one would apply), so
      # there's no risk of them reading inconsistently side by side.
      def cancel_flight_button(step, entity)
        label = step.respond_to?(:pass_description) ? step.pass_description.sub(/\ACancel/, 'Clear Ship') : 'Clear Ship'
        props = {
          style: { marginRight: '0.3rem' },
          on: {
            click: lambda {
              step.local_pass!(entity)
              store(:game, @game)
            },
          },
        }
        h('button.no_margin', props, label)
      end

      def render_row(entity, row)
        clickable = !row[:choice].nil?
        blocked = row[:blocked]

        # No border/box on the row itself -- that lives on just the ship's
        # name now (see render_ship_name), matching every other game's
        # look (a colored box around the train's name, not the whole row/
        # summary). Once a summary is attached (a finished ship's revenue/
        # mines-visited recap, or the actively flying ship's live cargo
        # status), the label can run long -- these stretch to the panel's
        # full width and wrap instead of running off the edge with
        # `nowrap` and getting clipped by the sidebar.
        style = {
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
              store(:flash_opts, "Cannot switch ships mid-flight; please submit or cancel the active ship's route first.")
            },
          }
        end

        children = [render_ship_name(row)]
        children << " — #{row[:summary]}" if row[:summary]

        h(:div, props, children)
      end

      # A small box around just the ship's name -- the same look every
      # other game's train-selector uses for its own per-train color (see
      # route_selector.rb's train_name rendering), not a border around the
      # whole row/summary. Bordered to show which ship is selected (same
      # font/bg convention the row itself used to use), and additionally
      # filled with this ship's own route color (see
      # G2038::Step::Route#route_color_index) whenever it has one
      # currently drawn on the map (submitted this turn, mid-flight, or a
      # pending suggestion preview), so the name and its line on the map
      # read as the same thing at a glance.
      def render_ship_name(row)
        style = {
          display: 'inline-block',
          padding: '2px 6px',
          border: "solid 3px #{row[:selected] ? color_for(:font) : color_for(:bg)}",
        }
        if row[:color_index]
          bg_color = route_prop(row[:color_index], :color)
          style[:backgroundColor] = bg_color
          style[:color] = contrast_on(bg_color)
        end
        h(:span, { style: style }, row[:label])
      end
    end
  end
end
