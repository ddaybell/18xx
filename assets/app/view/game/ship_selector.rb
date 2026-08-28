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
    # `{ choice:, label:, selected:, stats:, revenue:, select_train: }`
    # hashes -- `choice` is nil for a ship that's already finished this OR
    # (or mid-flight and not the selected one); `stats`
    # (`{explored:, mines:, codes:}`, or nil) and `revenue` (a formatted
    # currency string, or nil) render as the row's Explore/Mines/Revenue
    # columns; `select_train` is set only for an already-submitted route
    # still eligible for the single "Clear Ship" control below the list.
    class ShipSelector < Snabberb::Component
      include Actionable
      include Lib::Settings

      needs :game, store: true

      # One shared column template for the header and every row -- see
      # render_row/render_row_header, both of which render `display:
      # contents` wrappers so their cells become direct children of a
      # single outer grid (render's own row-list div) instead of each
      # row laying out its own independent (and differently-sized) grid.
      # Nesting a grid per row was the original approach and left columns
      # misaligned row to row, since each row's own "auto" name column
      # sized itself only to that row's own label width -- found live in
      # browser once ship names started varying in length.
      # The last three (Auto-run progress/Best/Max) carry a real MINIMUM,
      # not minmax(0, ...) -- a 0 minimum lets the track collapse under
      # space pressure, and even nowrap text then overflows the shrunk
      # cell horizontally into its neighbor rather than wrapping (nowrap
      # only stops WRAPPING, not overflow) -- found live in browser as
      # garbled overlapping header text that changing to nowrap alone
      # didn't fix, only changed the shape of.
      ROW_GRID_COLUMNS = 'minmax(3rem, auto) 3.5rem 4.5rem minmax(4.5rem, auto) ' \
                         'minmax(5rem, auto) minmax(3.5rem, auto) minmax(3.5rem, auto) minmax(3.5rem, auto)'

      # Native browser tooltip (title attr) on the "Theoretical Max"
      # header -- per the user, the number there is a certified UPPER
      # BOUND on what's still reachable, not a promise: it starts
      # optimistic (every ceiling assumed simultaneously realizable) and
      # only decreases as the search rules out combinations, ending
      # equal to Current Best exactly when the search has proven nothing
      # better exists (see OptimalAutorouter#certified_bound) -- at which
      # point this ship's own search stops on its own.
      THEORETICAL_MAX_TOOLTIP = 'This value may never be obtainable. It is a theoretical maximum value assuming ' \
                                 'full connectivity. This value decreases to the actual max, whereupon the ' \
                                 'autorun ceases for this ship.'

      # Native browser tooltip on "Found At" -- see OptimalAutorouter#
      # found_at_ratio for the exact mechanics. This is a LIVE, honest
      # signal, not a prediction: it can only ever shrink for as long as
      # the search runs without improving, since it's "when the current
      # best was found" divided by "how many combos have been tried in
      # total so far."
      FOUND_AT_TOOLTIP = 'What fraction of the combos tried so far were needed to find the current Best. ' \
                          'Shrinks the longer the search runs without improving -- a low, still-shrinking number ' \
                          'means most of the recent work has only been confirming that nothing better exists, ' \
                          'not searching for it.'

      def render
        step = @game.round.active_step
        return '' unless step.respond_to?(:ship_rows)

        entity = @game.round.current_entity
        rows = step.ship_rows(entity)

        # True while an Auto-all click (see auto_route_all_button) is
        # actively running for this entity -- suppresses every other way
        # to touch a route below (row clicks, Modify/Submit-preview,
        # the hand-fly action bar, even a second click of Auto itself)
        # for the duration. Without this, a route the run just built (and
        # is about to submit on a later tick) could flash into view as an
        # ordinary clickable/previewable row in between -- found live in
        # browser: per-route buttons appearing then disappearing mid-run.
        # Confirmed with the user: don't let anyone touch a route
        # mid-sequence, accidentally or otherwise.
        auto_running = step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)

        # Per the user: the live Auto counter reads better attached to
        # whichever ship's row is actually being routed right now, not
        # detached below the whole ship list -- only meaningful during
        # the final (chunked) phase, nil during ranking trials (no single
        # ship is "current" yet) or once the run's done.
        current_train_id = step.respond_to?(:auto_route_all_current_train_id) ? step.auto_route_all_current_train_id(entity) : nil
        row_progress = current_train_id && auto_route_progress_parts

        children = []
        if rows.any?
          row_children = rows.map do |row|
            parts = row[:train_id] == current_train_id ? row_progress : nil
            render_row(step, entity, row, auto_running: auto_running, progress: parts)
          end
          # width: 'fit-content' -- without it the grid stretches to fill
          # the panel's full width, and with no `fr` tracks in
          # ROW_GRID_COLUMNS, the track-sizing algorithm hands all of
          # that leftover space to the one `auto`-sized column (the ship
          # name), opening a big gap before Explore instead of leaving it
          # after Revenue -- found live in browser as a wide blank stripe
          # between every ship's badge and its Explore count.
          grid_style = { display: 'grid', gridTemplateColumns: ROW_GRID_COLUMNS, columnGap: '0.5rem',
                         rowGap: '0.1rem', alignItems: 'center', width: 'fit-content' }
          # Wrapped in its own horizontally-scrollable container -- found
          # live in browser (via Inspect Element): the Best/Max cells
          # were correctly in the DOM with correct widths all along, not
          # a CSS track-sizing bug at all. The real cause was the PAGE's
          # own fixed-width left panel (div#left), an ancestor we don't
          # control, which has overflow:hidden and was silently clipping
          # anything wider than its own width -- no scrollbar, no visual
          # cue, just invisible data loss once the grid grew past 4
          # columns. This div becomes ITS OWN scroll container instead,
          # constrained to the parent's available width (maxWidth: 100%)
          # -- if the grid's real content (7 columns' worth) is wider
          # than that, a scrollbar appears here rather than the outer
          # panel silently cropping it away.
          scroll_style = { maxWidth: '100%', overflowX: 'auto' }
          children << h(:div, { style: scroll_style }, [h(:div, { style: grid_style }, [render_row_header] + row_children)])
        end

        # The one contextual bar for whichever state currently applies
        # (a hand-flown route in progress/finished awaiting Submit/Clear)
        # -- entity-level state, not tied to any particular row, so it
        # renders once below the whole list rather than nested under
        # whichever row happens to be selected. nil (and so absent) once
        # neither state applies -- see render_action_bar. Suppressed
        # outright while auto_running (see above).
        bar = render_action_bar(step, entity) unless auto_running
        children << bar if bar

        # Modify/Submit/Auto: quick ways to fill in a route without hand-
        # flying it, grouped in one row below the ship list rather than
        # appearing/disappearing under whichever row is selected.
        idle_controls = render_idle_controls(step, entity, auto_running: auto_running, current_train_id: current_train_id)
        children << idle_controls if idle_controls

        # Submit All Routes (see submit_all_button -- and G2038::Step::
        # Route#suppress_standalone_pass?, which keeps the standalone
        # PassButton from also showing elsewhere on the page) plus
        # Clear Ship for whichever already-submitted route the row
        # list above has targeted for cancellation, if any -- the last
        # row of controls, below everything else. Suppressed outright
        # while auto_running (see above) -- Submit All Routes in
        # particular is exactly the accidental-mid-sequence-submit risk
        # this whole change exists to close off.
        submit_controls = render_submit_controls(step, entity) unless auto_running
        children << submit_controls if submit_controls

        return '' if children.empty?

        h(:div, { style: { marginBottom: '0.5rem' } }, children)
      end

      # Modify/Submit act directly on the selected ship's own passive
      # preview (see ship_rows/preview_last_route) -- no separate
      # "Activate" step first. That used to be a three-button sequence
      # (Activate, then Deactivate/Modify/Submit), but Activate never
      # revealed anything the preview wasn't already showing (same
      # stats, same route line on the map) -- it only flipped the row
      # from italic to normal and put three buttons under it. Confirmed
      # with the user: both of these already do "load, then act" in one
      # step via apply_previous_route! (the same helper Submit All Routes
      # uses per-ship), so there was nothing left for a standalone
      # Activate/Deactivate pair to do. Modify lands on the hand-fly
      # Submit/Clear bar (render_flight_bar); this Submit finishes the
      # job in one click for "I like this as-is."
      def render_idle_controls(step, entity, auto_running: false, current_train_id: nil)
        buttons = []
        # Modify/individual-Submit and a second Auto click are both
        # suppressed while auto_running -- see render's own comment. Only
        # the counter (below) stays visible during a run.
        unless auto_running
          if step.respond_to?(:previous_route_available?) && step.previous_route_available?(entity)
            buttons << local_button('Modify') { step.apply_previous_route!(entity, step.current_train(entity)) }
            buttons << previous_route_submit_button(step, entity)
          end
          if autorouting_allowed? && step.respond_to?(:any_suggestable?) && step.any_suggestable?(entity)
            buttons << auto_route_all_button(step, entity)
            warning = four_ship_warning(step, entity)
            buttons << warning if warning
          end
        end
        # While a run is active but still in the ranking-trials phase (no
        # single ship "current" yet -- see render's own current_train_id
        # comment), the row-level counter has nothing to attach to, so
        # this bottom counter fills in with "Working" instead. Once a
        # ship becomes current, its row takes over and this suppresses
        # itself (see auto_route_counter_cell); once the whole run's
        # done, it reappears showing the resting "Finished" time.
        if auto_running && !current_train_id
          elapsed = step.respond_to?(:auto_route_all_elapsed) ? step.auto_route_all_elapsed(entity) : nil
          # Same live-clock DOM id as the row-level and finished-state
          # counters (see start_auto_route_clock!) -- only one of the
          # three is ever actually in the document at once (trials-phase
          # bottom, row-attached during the final phase, or finished-
          # state bottom), so there's no id collision, and the clock
          # keeps updating whichever one is currently present.
          buttons << h(:div, { attrs: { id: 'auto_route_counter' } }, "Auto-run Working: #{elapsed}s") if elapsed
        end
        counter = auto_route_counter_cell(step, entity)
        buttons << counter if counter

        # The one control that DOES show during a run: accept the
        # current ship's best-so-far and move on to the next ship (per
        # the user: total control over how close to optimal each ship's
        # run gets). Meaningful only once the search has actually FOUND a
        # candidate route, not just because a ship is current --
        # skip_current_ship_search! itself is always safe either way
        # (OptimalAutorouter#stop_early! no-ops without a best), but
        # showing/hiding it needs to track the search's LIVE state, not
        # whatever it was at the last full render.
        #
        # Rendered here (gated only on current_train_id) but VISUALLY
        # hidden by default -- its actual show/hide is driven every
        # second by the same poll that already updates the Progress/Best/
        # Bound text (see start_auto_route_clock!), not by Snabberb
        # re-rendering it. A real re-render only happens at specific
        # trigger points (ship boundaries, first-searching-tick, first-
        # best-found), and for a ship whose search runs long past that
        # first-best moment, NOTHING forces another one -- so a button
        # shown at that one instant stayed shown in the DOM forever
        # after, even though best_so_far can only ever have been true
        # right then (found live: visible the whole time a ship's search
        # sat at nil, long after whatever earlier moment actually
        # rendered it). Tying visibility to the same live per-second poll
        # that already correctly tracks best_so_far (proven correct by
        # the console log) sidesteps needing every possible internal
        # state transition to also remember to trigger a real re-render.
        if current_train_id && step.respond_to?(:skip_current_ship_search!)
          button_props = {
            # Keyed per-ship, not just 'accept_next_ship' -- Snabbdom
            # patches a matched key's existing DOM node rather than
            # replacing it, and the JS poll above mutates that node's
            # style.display directly (bypassing Snabbdom's own tracking
            # of what it thinks the style is). A stable key across a ship
            # boundary risks Snabbdom leaving that externally-mutated
            # style alone if it doesn't consider the (unchanged, still
            # 'none') style prop worth re-applying, letting a stale
            # "visible" state leak into the next ship's freshly-started
            # search. Varying the key forces a genuinely fresh (hidden)
            # DOM node at every ship transition instead.
            key: "accept_next_ship_#{current_train_id}",
            attrs: { id: 'auto_route_accept_button' },
            style: { marginRight: '0.3rem', display: 'none' },
            on: {
              click: lambda {
                step.skip_current_ship_search!(entity)
                store(:game, @game)
              },
            },
          }
          buttons << h('button.no_margin', button_props, 'Accept & next ship')
        end

        return nil if buttons.empty?

        h(:div, { style: { marginTop: '0.3rem', display: 'flex', flexWrap: 'wrap', alignItems: 'center' } }, buttons)
      end

      # Whether this game instance allows the computational route
      # assistant at all -- the exact same site-wide setting every
      # other game's own AutoRouter-backed "Auto" button already
      # checks (see assets/app/view/game/route_selector.rb), not a
      # G2038-specific opt-out. "Last"/"Reset" (replaying a route
      # already on record) aren't gated by this -- they're a memory
      # convenience, not the search-based assistant this setting
      # exists to let a game disable.
      def autorouting_allowed?
        @game_data.dig('settings', 'auto_routing') || @game_data['mode'] == :hotseat
      end

      # The real end-of-turn Pass (see submit_all_button -- see also
      # G2038::Step::Route#suppress_standalone_pass?, which keeps the
      # standalone PassButton from also showing elsewhere on the page)
      # plus Clear Ship for whichever already-submitted route is
      # currently targeted (see clear_completed_button/
      # select_completed_train!).
      def render_submit_controls(step, entity)
        buttons = []
        buttons << clear_completed_button(step, entity) if step.respond_to?(:selected_completed_train) &&
          step.selected_completed_train(entity)
        buttons << submit_all_button(step, entity) if step.respond_to?(:local_pass?) && !step.local_pass?(entity)
        return nil if buttons.empty?

        h(:div, { style: { marginTop: '0.3rem', display: 'flex', flexWrap: 'wrap' } }, buttons)
      end

      # The real end-of-turn Pass -- same action the shared PassButton
      # dispatches (process_action(Action::Pass.new(...))), but built
      # locally with the same button.no_margin styling every other
      # control here uses instead of reusing that component directly:
      # PassButton renders its own `button#pass` element with its own
      # CSS-driven height/padding, which doesn't match `.no_margin` and
      # left it visibly taller than Clear Ship sitting right next to it.
      def submit_all_button(step, entity)
        props = {
          key: 'submit_all',
          style: { marginRight: '0.3rem' },
          on: {
            click: -> { submit_all_routes!(step, entity) },
          },
        }
        h('button.no_margin', props, step.pass_description)
      end

      # Submits everything pass_description's own total just promised:
      # whatever's actively on screen for the currently selected ship
      # (an already hand-flown/finished-but-unsubmitted flight -- same
      # apply-then-submit their own dedicated Submit buttons already do,
      # see previous_route_submit_button/submit_button above) first, then
      # every other still-unrun ship that has a viable prior route on
      # file (see Step::Route#preview_last_route -- ship_rows shows these
      # passively too), rebuilt from that route and submitted the same
      # way. Only once nothing's left to submit does the real Pass
      # actually end the turn. Found live in browser: previewing every
      # ship's prior route at once (ship_rows) but Submit All Routes
      # only ever folding in the one ship on screen -- clicking it
      # silently dropped the other ships' already-displayed routes
      # instead of submitting them.
      def submit_all_routes!(step, entity)
        choice = step.finish_and_submit_choice(entity)
        process_action(Engine::Action::Choose.new(entity, choice: choice)) if choice

        step.available_trains(entity).dup.each do |train|
          next unless step.apply_previous_route!(entity, train)

          submit_choice = step.finish_and_submit_choice(entity)
          process_action(Engine::Action::Choose.new(entity, choice: submit_choice)) if submit_choice
        end

        process_action(Engine::Action::Pass.new(@game.pass_entity(@user)))
      end

      # Cancels whichever already-submitted route the row list above is
      # currently targeting (row click -> step.select_completed_train!) --
      # a real, recorded action, since it undoes state other clients can
      # already see. `key:` is load-bearing here, not decorative -- this
      # button only exists in the `buttons` array once a ship's been
      # selected, so it gets *inserted in front of* the already-present
      # PassButton rather than appended; without a stable key, Snabberb's
      # positional (keyless) diffing patches the existing PassButton DOM
      # node into becoming this one instead of inserting a new node,
      # which can leave a stale closure (captured `train` from before
      # anything was selected) bound to the button that's now on screen.
      # Found live in browser: the first several clicks after selecting
      # a ship silently did nothing, until enough re-renders elsewhere
      # happened to shake the correct handler loose.
      def clear_completed_button(step, entity)
        train = step.selected_completed_train(entity)
        props = {
          key: 'clear_completed',
          style: { marginRight: '0.3rem' },
          on: {
            click: lambda {
              process_action(Engine::Action::Choose.new(entity, choice: step.cancel_completed_choice(train)))
            },
          },
        }
        h('button.no_margin', props, 'Clear Selected Route')
      end

      # The one contextual bar for the entity's current flight state --
      # a hand-flown route in progress or finished but not yet submitted
      # (Submit/Clear). nil once nothing's in that state -- e.g. nothing
      # started yet (see render_idle_controls for Modify/Submit/Auto
      # instead), or a ship's suggestion already got applied-and-
      # submitted in the same click Modify/Submit themselves make.
      # store(:game, @game) (inside local_button) forces the re-render a
      # process_action call would otherwise have given us for free,
      # since @game itself (and the round/step objects hanging off it)
      # were mutated in place.
      def render_action_bar(step, entity)
        return render_flight_bar(step, entity) if step.respond_to?(:local_pass?) && step.local_pass?(entity)

        nil
      end

      # One-click "load this ship's last-OR route and submit it as-is" --
      # apply_previous_route! (the same helper Submit All Routes uses
      # per-ship) does the load-then-apply-then-hand-fly-equivalent work
      # locally; finish_and_submit_choice's own Choose is the one real,
      # recorded action. Label reads the preview's own revenue (see
      # Step::Route#previous_route_submit_label) so it matches what the
      # row already shows before this is ever clicked.
      def previous_route_submit_button(step, entity)
        props = {
          key: 'previous_route_submit',
          style: { marginRight: '0.3rem' },
          on: {
            click: lambda {
              train = step.current_train(entity)
              next unless step.apply_previous_route!(entity, train)

              choice = step.finish_and_submit_choice(entity)
              process_action(Engine::Action::Choose.new(entity, choice: choice)) if choice
            },
          },
        }
        h('button.no_margin', props, step.previous_route_submit_label(entity))
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
          key: "local_#{label}",
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
      # "Path timeout" off of), so route_timeout alone is the closest fit
      # for the final, real pass over the winning ordering. best_ship_
      # order's own discarded ranking trials do NOT get this full budget
      # any more (see that method's own comment: up to N x N! of them run,
      # so handing each the full route_timeout could turn one click into
      # an effectively unbounded wall-clock hang -- found live in
      # browser) -- they run on a much smaller fixed budget instead, and
      # surface their own any_trial_timed_out back to this button so a
      # ranking-phase timeout still shows up in the warning below.
      #
      # Autoroutes every still-unfilled ship in one click, in whichever
      # order actually maximizes their combined revenue (see
      # G2038::Step::Route#start_auto_route_all!'s own comment for why a
      # single-ship search alone can't be trusted once more than one
      # ship is involved) -- matching the same "autoroute whatever
      # doesn't already have a route" paradigm the standard AutoRouter's
      # own Auto button uses elsewhere on the site, per the user. A ship
      # the player already dealt with (Submitted, or still showing a
      # pre-populated history preview they haven't cleared) is left
      # alone; only available_trains -- genuinely untouched this turn --
      # ever gets swept in.
      #
      # Chunked via G2038::Step::Route#start_auto_route_all!/
      # auto_route_all_tick! -- even with the trial phase separately
      # capped (see above), a handful of ships can still take a couple
      # of minutes total, and running that as one giant synchronous call
      # left the tab "semi-responsive" (scroll worked, tab-switch didn't)
      # for the whole duration -- found live in browser. Each tick here
      # is exactly one already-bounded unit of work (one ranking trial,
      # or one real ship build), scheduled via a real setTimeout so the
      # browser gets to repaint/handle events in between, mirroring the
      # same pattern Autorouter#resume_async! already uses for a single
      # ship's own search. All progress state lives on the step instance
      # itself (see start_auto_route_all!'s own comment on why), not
      # here -- this method only needs to keep calling auto_route_all_
      # tick! until it returns :done, submitting whenever it returns
      # :built.
      #
      # Runs its own independent setInterval (start_auto_route_clock!,
      # not tied to the tick-chain's own cadence) so the on-screen
      # counter (auto_route_counter_cell) ticks smoothly in real time --
      # the tick-chain alone can go up to route_timeout (30s by default)
      # between updates during the final per-ship pass, which wouldn't
      # read as "live" at all. Both the clock and the tick-chain trigger
      # re-renders purely via store(:game, @game) -- the one store key
      # already proven to survive repeated re-renders during this flow
      # (see G2038::Step::Route#auto_route_all_active?'s own comment for
      # why a second, view-local store key didn't).
      def auto_route_all_button(step, entity)
        timeout = setting_for(:route_timeout).to_i

        click = lambda do
          # Guards against a fast double-click starting a second,
          # overlapping tick-chain before the first click's re-render has
          # had a chance to hide this very button (Snabberb's repaint is
          # async, queued via requestAnimationFrame -- there's a real gap
          # between this handler running and the DOM actually reflecting
          # auto_running). Two tick-chains driving the same shared step/
          # Autorouter state concurrently is the leading suspect for a
          # run seen live in browser climbing past 2000s with no
          # configured timeout anywhere near that -- see start_auto_
          # route_all!'s own @auto_all_deadline backstop for the other
          # half of that fix.
          next if step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)

          step.start_auto_route_all!(entity, timeout: timeout)
          @auto_tick_count = 0
          @auto_tick_started = nil
          @auto_tick_seen_final_phase = false
          @auto_tick_last_rendered_best = nil
          start_auto_route_clock!
          # store(:game, ...) alone wouldn't actually paint "Working: 0s"
          # before the tick-chain starts -- Snabberb's own update queues
          # the repaint via requestAnimationFrame, which can't fire until
          # the current synchronous JS finishes, and the very first tick
          # (a real ranking trial, up to TRIAL_TIMEOUT seconds) runs
          # synchronously too. Deferring that first tick via setTimeout,
          # same as every later tick already does, gives the browser a
          # real chance to paint in between -- otherwise clicking Auto
          # gave no feedback at all until whatever the first trial
          # happened to take had already elapsed. Per the user: it's fine
          # to show a bare "0s" for that first instant.
          #
          # Double-deferred via requestAnimationFrame THEN setTimeout,
          # not setTimeout alone -- timer tasks run BEFORE the browser's
          # next paint, so a bare setTimeout(0) started the first tick
          # ahead of the initial "Working: 0s" render. Harmless for a
          # single ship (first tick = one 0.2s chunk, paint follows
          # almost immediately) but a multi-ship run's first tick is a
          # whole ranking trial (up to TRIAL_TIMEOUT x ships seconds of
          # synchronous work, ~8s for two ships), and with a second
          # trial right behind it the counter showed NOTHING for ~17s --
          # found live in browser. rAF fires only after the paint
          # actually happens, so sequencing the tick chain behind it
          # guarantees the counter is on screen before any heavy work
          # starts.
          store(:game, @game)
          %x{
            requestAnimationFrame(function() {
              setTimeout(function() {#{run_auto_route_all_tick!(step, entity)}}, 0);
            });
          }
        end

        props = {
          key: 'auto',
          style: { marginRight: '0.3rem' },
          on: { click: click },
        }
        h('button.no_margin', props, 'Auto')
      end

      # Only the AL, in Phases IV-V, ever holds 4 ships at once -- the one
      # case where the ranking phase's ordering count (4! = 24, even after
      # start_auto_route_all!'s own duplicate-ship dedup and cross-
      # ordering pruning) can still make a single Auto click slow. Rather
      # than build further machinery around a rare worst case, per the
      # user: just suggest flying one ship by hand first -- Auto only ever
      # touches still-unfilled ships, so doing that already drops this
      # back to the cheap 3-ship case with no engine changes at all.
      def four_ship_warning(step, entity)
        return nil unless step.respond_to?(:unfilled_ship_count) && step.unfilled_ship_count(entity) >= 4

        h(:div, { style: { fontSize: '80%', opacity: 0.7, flexBasis: '100%' } },
          'Auto may be slow with 4 ships -- consider flying one manually first.')
      end

      def run_auto_route_all_tick!(_stale_step, entity)
        # Re-resolve step fresh from the live store every tick -- do NOT
        # trust the `_stale_step` parameter, and do NOT trust this
        # component's own @game ivar either, past the very first call.
        #
        # @game is only ever written by init_needs (construction time) or
        # by this component's own store(:game, ...) calls -- Snabberb's
        # store(key, value) (see gem source, component.rb) sets the ivar
        # on the calling instance (and the root, if it also declares the
        # need), but never on any OTHER already-built instance holding
        # that same need. Every full re-render (@root.render, triggered
        # by literally any component anywhere calling store) rebuilds the
        # ENTIRE tree from scratch via h(Component, ...) -> Component.new
        # -- a fresh ShipSelector instance every time. The MessageChannel
        # continuation below is a plain recursive method call on `self`,
        # so it keeps running on the ORIGINAL instance for as long as no
        # external render happens -- but the instant some OTHER action
        # (another player's move, an Undo, Restart Turn, anything) forces
        # one, a brand new ShipSelector instance takes that slot in the
        # tree while this old one, kept alive only by the JS closure
        # still holding a reference to it, ticks on forever against its
        # own now-frozen @game snapshot from before that render -- @game
        # itself never mutates in place, so re-deriving `step` from it
        # every tick (the fix this comment used to describe) still only
        # ever sees that same stale snapshot. Found live in browser
        # (twice): fluctuating/duplicate combo counters, and separately a
        # Restart Turn that visibly reset the turn while the original run
        # kept ticking and logging in the background afterward.
        #
        # @store, by contrast, is the single Hash object @root.store
        # itself (see initialize) -- shared, not copied, by every
        # instance ever built from that root, and mutated in place by
        # every store(key, value) call anywhere in the app, root or not.
        # Reading store[:game] (the bare getter, no side effects) instead
        # of trusting @game gives even an orphaned instance the true,
        # live-current game on every tick, closing the gap the @game-only
        # fix left open.
        @game = store[:game]
        step = @game.round.active_step

        # If the CURRENT (freshly-resolved) step no longer agrees an
        # Auto run is active for this entity -- because it genuinely
        # finished through some other path, or because an intervening
        # action (Undo, Restart Turn, anything) moved the game on
        # without it -- stop dead instead of silently continuing to
        # compute a route nobody asked for any more. Per the user: an
        # in-progress Auto run must not survive an action that
        # invalidates it.
        unless step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)
          `console.log("g2038 auto: chain stopped -- run no longer active for this entity (game state moved on)")`
          return
        end

        # Dev-only throughput telemetry (browser console, F12): with 0.2s
        # work chunks the healthy rate is ~4-5 ticks/sec -- a much lower
        # rate means the chain is being starved (throttling, render tax);
        # a healthy tick rate with low combos/sec means the engine itself
        # is slow inside the browser. This is the instrumentation that
        # separates the two failure modes without another blind run.
        @auto_tick_count = (@auto_tick_count || 0) + 1
        @auto_tick_started ||= Time.now
        if (@auto_tick_count % 100).zero?
          elapsed = (Time.now - @auto_tick_started).round(1)
          combos = @game.optimal_autorouter.combos_so_far
          rate = elapsed.positive? ? (@auto_tick_count / elapsed).round(1) : 0
          %x{
            console.log("g2038 auto: ticks=" + #{@auto_tick_count} + " elapsed=" + #{elapsed} +
                        "s (" + #{rate} + " ticks/s), engine combos=" + #{combos})
          }
        end

        status = step.auto_route_all_tick!(entity)

        if status == :built
          @auto_tick_last_rendered_best = nil
          submit_choice = step.finish_and_submit_choice(entity)
          process_action(Engine::Action::Choose.new(entity, choice: submit_choice)) if submit_choice
          store(:game, @game)
        end

        # One extra render at the FIRST final-phase tick (trials -> real
        # search transition), not just at ship-boundary :built/:done --
        # without it, the first ship's progress display was stuck at the
        # bottom "Working" fallback for that ship's ENTIRE search, only
        # ever moving onto a ship's own row starting with ship 2 (the
        # peek-ahead that attaches it happens at the PRIOR ship's :built
        # render, which ship 1 has none of). Found live in browser via
        # the console log: no "Rendering game view" entry appeared
        # between the click and ship 1's own completion. @auto_tick_
        # seen_final_phase ensures this fires exactly once per Auto
        # click, not once per tick.
        if status == :searching && !@auto_tick_seen_final_phase
          @auto_tick_seen_final_phase = true
          store(:game, @game)
        end

        # A render on every GENUINE improvement (first find, or any later
        # better answer) -- same idea as @auto_tick_seen_final_phase
        # above but for a transition that can happen (repeatedly) at any
        # point deep into a long search, not just at its very start.
        # Covers two needs at once:
        #  - "Accept & next ship" (gated on best_so_far being truthy --
        #    see render_idle_controls) never appearing at all: nothing
        #    else forces a real Snabberb re-render between ship-boundary
        #    events, so the button's visibility stays frozen at whatever
        #    it was computed as during the last real render. Found live:
        #    a ship stuck at best=$0 for 1000+ seconds, then finding
        #    $250, still showed no Accept button afterward.
        #  - the live map's dashed "current best" preview (map.rb's
        #    render_route_lines) needs a real render every time the
        #    answer actually changes, not just once, to stay in sync.
        # @auto_tick_last_rendered_best (reset to nil at each :built
        # ship-boundary above) tracks whatever value this last forced a
        # render for, so this only fires on a genuine change -- never
        # once per tick, and never twice for the same value. The live
        # clock's own setInterval only patches existing DOM nodes'
        # textContent -- it can't add a button or redraw the map itself.
        current_best = @game.optimal_autorouter.best_so_far
        if status == :searching && current_best && current_best != @auto_tick_last_rendered_best
          @auto_tick_last_rendered_best = current_best
          store(:game, @game)
        end

        if status == :done
          store(:game, @game)
        else
          # Yield via a MessageChannel post, NOT setTimeout(fn, 0) --
          # background tabs clamp timers to >= 1s (Chrome's intensive
          # throttling), which starved the whole tick chain to ~1 work
          # chunk per second the moment the player switched tabs: found
          # live in browser, a search Compare finished in 168s foreground
          # was still going at 1280s via Auto. Message-channel tasks are
          # ordinary posted tasks, not timers, so they're exempt from
          # timer clamping and the chain keeps its normal pace while the
          # player reads another tab. (The browser can still outright
          # freeze a long-backgrounded page under memory/battery savers
          # -- nothing short of a Web Worker escapes that -- but plain
          # tab-switching no longer slows the search.) The 1s display
          # clock IS still a throttled timer in background, which is
          # fine: it's display-only and catches up on focus.
          %x{
            var ch = new MessageChannel();
            ch.port1.onmessage = function() {
              ch.port1.onmessage = null;
              #{run_auto_route_all_tick!(step, entity)}
            };
            ch.port2.postMessage(null);
          }
        end
      end

      # Self-contained JS interval (same %x{}/setInterval idiom
      # view/form.rb's Turnstile polling already uses) rather than
      # threading a JS interval handle back and forth across Ruby calls
      # -- it checks auto_route_clock_active? itself each tick and clears
      # itself the moment that flips false, so run_auto_route_all_tick!
      # never needs to know this clock exists at all beyond starting it.
      #
      # Writes the counter text STRAIGHT into the existing DOM node (by
      # id) instead of store(:game, ...) -- found live in browser: the
      # old 200ms store() approach re-rendered the ENTIRE game view (a
      # late-game map re-diff isn't cheap) between every 0.2s work chunk,
      # and that render overhead ate most of the wall clock: a search the
      # blocking Compare button finished in 168s ran 800s+ through the
      # chunked Auto flow on the same board. A seconds-granularity label
      # doesn't need vdom at all -- one real store() fires when the run
      # ends, to swap the panel back to its finished/interactive state.
      def start_auto_route_clock!
        %x{
          var self = this;
          var iv = setInterval(function() {
            if (!self.$auto_route_clock_active_q()) {
              clearInterval(iv);
              self.$store("game", self.game);
              return;
            }
            var parts = self.$auto_route_progress_parts().$to_n();
            ['progress', 'best', 'max', 'found_at'].forEach(function(key) {
              var el = document.getElementById('auto_route_' + key);
              if (el) { el.textContent = parts[key]; }
            });
            var acceptBtn = document.getElementById('auto_route_accept_button');
            if (acceptBtn) { acceptBtn.style.display = parts.best ? '' : 'none'; }
          }, 1000);
        }
      end

      # The three progress cells' current text (Auto-run progress / Best
      # revenue / Theoretical Max -- per the user, split into their own
      # labeled columns rather than one combined sentence), resolved
      # fresh from the live step -- called from the clock's JS interval,
      # which has no step/entity closure of its own to reuse, and from
      # render's own row-building for the initial paint each tick starts
      # with.
      def auto_route_progress_parts
        step = @game.round.active_step
        entity = @game.round.current_entity
        empty = { progress: '', best: '', max: '', found_at: '' }
        return empty unless entity && step.respond_to?(:auto_route_all_elapsed)

        elapsed = step.auto_route_all_elapsed(entity)
        return empty unless elapsed

        # Per the user: Progress is just the bare timer, nothing else --
        # "Working"/"Finished" is conveyed by the Best/Max columns having
        # content or not (Max clears once the search stops needing to
        # prove anything further), not by prose here.
        running = step.auto_route_all_active?(entity)
        parts = { progress: "#{elapsed}s", best: '', max: '', found_at: '' }
        return parts unless running

        # While the final search is live, show the certified state of
        # play: the best route in hand and the PROVEN maximum anything
        # still untried could pay -- the gap between them shrinking in
        # real time is what tells the user whether "Accept & next ship"
        # is worth clicking yet.
        router = @game.optimal_autorouter
        best = router.best_so_far
        bound = router.certified_bound
        parts[:best] = "$#{best}" if best
        parts[:max] = "$#{bound}" if bound && !(best && bound <= best)

        # Found At: what fraction of combos-tried-so-far were needed to
        # find the current best (see OptimalAutorouter#found_at_ratio) --
        # an honest, live "found early vs. found late" signal, not a
        # fabricated confidence score. Shrinks the longer a run goes on
        # without improving, since the denominator (combos so far) keeps
        # climbing while the numerator (when it was found) stays fixed --
        # per the user, this is what actually answers "was the real work
        # done early, with everything since just confirming a negative."
        ratio = router.found_at_ratio
        parts[:found_at] = "#{(ratio * 100).round(1)}%" if ratio
        parts
      end

      # Re-fetches the active step fresh each tick rather than closing
      # over the one passed into auto_route_all_button -- this runs from
      # a JS interval with no Ruby call stack of its own to carry that
      # reference, and the step is cheap (and safe) to look up fresh from
      # @game every time regardless.
      def auto_route_clock_active_q
        step = @game.round.active_step
        step.respond_to?(:auto_route_all_running?) && step.auto_route_all_running?
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
          key: 'submit',
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
        label = step.respond_to?(:pass_description) ? step.pass_description.sub(/\ACancel/, 'Clear') : 'Clear'
        props = {
          key: 'cancel_flight',
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

      # Shared padding/box-sizing every cell (header or row) uses, so
      # header text and row values -- both plain, unstyled text, same
      # font/size as each other -- still line up in the same columns.
      def cell_style(extra = {})
        { padding: '2px 6px', boxSizing: 'border-box' }.merge(extra)
      end

      # Column headers over the ship list -- `display: contents` so these
      # cells become direct children of render's own outer grid (see
      # ROW_GRID_COLUMNS) instead of laying out a second, independent
      # grid.
      def render_row_header
        label_style = cell_style(opacity: 0.7)
        # nowrap only -- NOT overflow:hidden. Found live in browser: an
        # item with overflow other than visible (hidden/auto/scroll) is
        # excluded from a grid track's automatic max-content sizing (its
        # min/max-content contribution is treated as 0, per how CSS grid
        # track sizing handles overflow), so adding overflow:hidden as a
        # safety net backfired -- it told the track it was free to
        # collapse toward nothing instead of protecting its content.
        # Plain nowrap plus ROW_GRID_COLUMNS' own real minimum widths
        # worked while these three headers stayed one word each ("Max").
        # "Current Best" is a genuinely longer two-word label -- under a
        # wide "Mines" column (a long cargo list) squeezing the row's
        # remaining space, nowrap had nothing left to do but let it
        # overflow straight across into "Bound"'s own cell, since nothing
        # clips text that doesn't fit. Found live: "Current Best" and
        # "Bound" rendering on top of each other. Letting these headers
        # wrap onto a second line instead (same as every data row's own
        # multi-line "Mines" cell already does) fixes the overlap without
        # reintroducing the overflow:hidden collapse.
        progress_label_style = label_style
        h(:div, { style: { display: 'contents' } }, [
            h(:div, { style: label_style }, 'Ships'),
            h(:div, { style: label_style }, 'Explore'),
            h(:div, { style: label_style }, 'Mines'),
            h(:div, { style: label_style.merge(textAlign: 'right') }, 'Revenue'),
            h(:div, { style: progress_label_style }, 'Progress'),
            h(:div, { style: progress_label_style }, 'Current Best'),
            h(:div, { style: progress_label_style, attrs: { title: THEORETICAL_MAX_TOOLTIP } }, 'Bound'),
            h(:div, { style: progress_label_style, attrs: { title: FOUND_AT_TOOLTIP } }, 'Found At'),
          ])
      end

      def render_row(step, entity, row, auto_running: false, progress: nil)
        clickable = !row[:choice].nil?
        # An already-submitted, still-cancellable route can't be
        # re-launched (choice is nil), but clicking it still means
        # something: targeting it for the single "Clear Ship" control
        # below the list (see G2038::Step::Route#select_completed_train!).
        selectable = !row[:select_train].nil?
        blocked = row[:blocked]
        # A settled, already-submitted route from before a later route
        # this turn explored a hex (see Step::Route#cancellable_trains) --
        # can never be reopened, for real: undoing it and resubmitting
        # something different risks the game drawing a different tile (or
        # a different Lucky/IF/DH redraw candidate) on replay than it
        # actually did live. Greyed out and given its own explanatory
        # click, same treatment as `blocked` below, rather than looking
        # identical to a still-cancellable row and silently doing nothing.
        locked = row[:locked]

        # `display: contents` -- the row itself renders no box of its own
        # (so cursor/opacity live on each cell below, not here); its four
        # cells become direct children of render's own outer grid, the
        # same one render_row_header's cells join, so every row's Ship/
        # Explore/Mines/Revenue columns line up with every other row's
        # (and the header's) regardless of how wide any one row's own
        # label happens to be.
        # No click handler at all while auto_running (see render's own
        # comment) -- a route mid-sequence must be purely informational,
        # not clickable/selectable/whatever-blocked-means-right-now.
        wrapper_props = { style: { display: 'contents' } }
        if auto_running
          clickable = selectable = blocked = locked = false
        elsif clickable
          wrapper_props[:on] = { click: -> { process_action(Engine::Action::Choose.new(entity, choice: row[:choice])) } }
        elsif selectable
          wrapper_props[:on] = {
            click: -> {
              step.select_completed_train!(row[:select_train])
              store(:game, @game)
            },
          }
        elsif blocked
          wrapper_props[:on] = {
            click: -> {
              store(:flash_opts, "Cannot switch ships mid-flight; please submit or cancel the active ship's route first.")
            },
          }
        elsif locked
          wrapper_props[:on] = {
            click: -> {
              # Flash#render forwards `message` straight through as
              # snabbdom children, so an array of strings/vnodes renders
              # as rich content, same as a plain string would -- reuses
              # render_ship_name itself (the same bordered/filled badge
              # every row's own ship name already gets) rather than a
              # separate, only-similar-looking style, so the locking
              # ship's name reads as the exact same badge seen elsewhere
              # on this panel. Kept short deliberately: the full RNG-
              # replay reasoning lives in cancellable_trains' own comment
              # for whoever wants it; this just needs to name the cause
              # and point at the one real way around it (Undo).
              ship_badge = render_ship_name(
                { selected: false, color_index: row[:locked_by_color_index], label: row[:locked_by_label] || 'a later ship' }
              )
              store(:flash_opts, { message: ['Route locked by ', ship_badge, "'s explore. Use Undo to go back further."] },
                    skip: false)
            },
          }
        end

        cursor = (clickable || blocked || selectable || locked) && !row[:selected] ? 'pointer' : 'default'
        opacity = (clickable || selectable) ? 1.0 : ((blocked || locked) ? 0.7 : 1.0)
        # A passive preview (see Step::Route#ship_rows' `preview` flag) is
        # only ever informational -- what Reset *would* build, not a real
        # loaded/actionable route the way an active suggestion, an
        # in-progress hand-fly, or an already-submitted route are.
        # Italicized so it reads as "not yet loaded" at a glance, rather
        # than looking identical to a live route the player might think
        # they need to Clear before flying something else. Confirmed with
        # the user after exactly that confusion showed up live in browser.
        font_style = row[:preview] ? 'italic' : 'normal'
        value_style = cell_style(cursor: cursor, opacity: opacity, fontStyle: font_style)

        stats = row[:stats]
        children = [
          h(:div, { style: value_style }, [render_ship_name(row)]),
          h(:div, { style: value_style }, stats ? stats[:explored].to_s : ''),
          h(:div, { style: value_style }, stats ? mines_cell(stats) : ''),
          h(:div, { style: value_style.merge(textAlign: 'right') }, revenue_cell(row)),
        ]
        # The three live Auto-run cells, attached to whichever ship's row
        # the final search is currently building (see render's own
        # comment on why) -- blank for every other row. Each gets the DOM
        # id the clock's direct-text-write targets (see start_auto_route_
        # clock!) only when it's actually this row's cells that are live,
        # so the per-second update lands on the right ship if the player
        # has since scrolled/re-rendered past a ship boundary.
        cell_style_progress = cell_style(opacity: 0.8, fontSize: '85%', whiteSpace: 'nowrap')
        # Found At is the one column that keeps showing something after
        # its ship stops being "current" -- per the user, a historical
        # record of how early that ship's own answer was found is worth
        # keeping around, unlike Progress/Best/Bound (which only ever
        # meant anything about a search that's still live). Falls back to
        # row[:found_at] -- a plain ratio snapshotted at the moment this
        # ship's search completed (see Step::Route#ship_rows) -- once
        # `progress` itself goes nil for a finished ship's row.
        %i[progress best max found_at].each do |part|
          attrs = progress ? { id: "auto_route_#{part}" } : {}
          text =
            if progress
              progress[part].to_s
            elsif part == :found_at && row[:found_at]
              "#{(row[:found_at] * 100).round(1)}%"
            else
              ''
            end
          children << h(:div, { style: cell_style_progress, attrs: attrs }, text)
        end

        h(:div, wrapper_props, children)
      end

      # The row's revenue -- finished/pending value, or blank -- always
      # plain text.
      def revenue_cell(row)
        row[:revenue] || ''
      end

      # Sits in the same control row as the Auto button (render_idle_
      # controls) -- live elapsed time while an Auto-all click (see
      # auto_route_all_button) is running, then stays showing the final
      # time until the next click resets it. Replaces the old one-shot
      # "Autoroute finished in Xs" flash popup entirely, per the user --
      # persistent and in-context instead of a toast that comes and goes
      # on its own timer. Deliberately doesn't mention timeouts/optimality
      # at all (an earlier version appended "(may not be optimal)") --
      # per the user, players already know an autorouter isn't guaranteed
      # optimal, and calling it out here specifically would misleadingly
      # read as "this run in particular is more likely to be bad," which
      # isn't what a trial hitting its ranking-only timeout actually means.
      #
      # Reads straight off the step (auto_route_all_elapsed/_active?) --
      # NOT a view-local store -- see G2038::Step::Route#auto_route_all_
      # active?'s own comment for why a Snabberb store key didn't survive
      # here. Returns nil (not a blank vnode) when there's nothing to
      # show, so render_idle_controls can cleanly decide whether to
      # include it at all.
      # Only shown once a run has FINISHED -- while active, the live
      # counter is attached to the currently-routing ship's own row (see
      # render's row_counter_text/render_row's counter_text param) so it
      # reads as information about that specific ship, not a detached
      # panel-wide status line. Kept here for the resting "Finished"
      # state so the final elapsed time stays visible even after the
      # last ship's row has stopped showing a counter of its own and the
      # Auto button has reappeared.
      def auto_route_counter_cell(step, entity)
        return nil unless step.respond_to?(:auto_route_all_elapsed)
        return nil if step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)

        elapsed = step.auto_route_all_elapsed(entity)
        return nil unless elapsed

        # The id is the live clock's direct-DOM update target (see
        # start_auto_route_clock!) while a row owns it; once finished,
        # nothing but this cell exists to hold the id, so it's safe (and
        # harmless -- the clock's own interval has already cleared
        # itself by this point) to carry it here too.
        h(:div, { attrs: { id: 'auto_route_counter' }, style: { opacity: 0.7 } }, "Auto-run Finished: #{elapsed}s")
      end

      def mines_cell(stats)
        return stats[:mines].to_s if stats[:codes].to_s.empty?

        "#{stats[:mines]} (#{stats[:codes]})"
      end

      # A small box around just the ship's name -- the same look every
      # other game's train-selector uses for its own per-train color (see
      # route_selector.rb's train_name rendering), not a border around the
      # whole row/summary. Bordered to show which ship is selected (same
      # font/bg convention the row itself used to use), and additionally
      # filled with this ship's own fixed color slot (see
      # G2038::Step::Route#route_color_index) whenever it has a route
      # currently drawn on the map, so the name and its line on the map
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
