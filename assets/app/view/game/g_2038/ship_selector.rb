# frozen_string_literal: true

require 'view/game/actionable'

module View
  module Game
    module G2038
      # G2038's tab-style selector for choosing which ship to act with next.
      # G2038::Step::Route can't use the standard RouteSelector because a
      # single OR flies multiple ships and batches their routes for
      # submission, rather than building one route per train like every
      # other game. Visually mirrors RouteSelector's train tabs;
      # G2038::Step::Route implements `ship_rows(entity)`, an array of
      # `{ choice:, label:, selected:, stats:, revenue:, select_ship: }`
      # hashes -- `choice` is nil for a ship that's already finished this OR
      # (or mid-flight and not the selected one); `stats`
      # (`{explored:, mines:, codes:}`, or nil) and `revenue` (a formatted
      # currency string, or nil) render as the row's Explore/Mines/Revenue
      # columns; `select_ship` is set only for an already-submitted route
      # still eligible for the single "Clear Ship" control below the list.
      class ShipSelector < Snabberb::Component
        include Actionable
        include Lib::Settings

        needs :game, store: true

        # One shared column template for the header and every row -- see
        # render_row/render_row_header, both of which render `display:
        # contents` wrappers so their cells become direct children of a
        # single outer grid instead of each row laying out its own
        # independent (and differently-sized) grid.
        # The last three (Auto-run progress/Best/Max) carry a real
        # MINIMUM, not minmax(0, ...) -- a 0 minimum lets the track
        # collapse under space pressure, and even nowrap text then
        # overflows the shrunk cell horizontally into its neighbor
        # instead of wrapping (nowrap only stops WRAPPING, not overflow).
        ROW_GRID_COLUMNS_BASE = 'minmax(3rem, auto) 3rem 4.5rem 3rem 3.5rem 3.5rem'
        ROW_GRID_COLUMNS_PROGRESS = 'minmax(5rem, auto) minmax(3.5rem, auto) minmax(3.5rem, auto)'

        # Ships/Explore/Mines/Revenue always show; Progress/Current Best/
        # Bound only join the grid once there's an actual auto-route search
        # (live or historically recorded) to say anything about -- see
        # render's own show_progress_cols comment. The header and every row
        # must agree on this every render, since they all share one CSS
        # grid (see render_row_header/render_row).
        def row_grid_columns(show_progress_cols)
          return ROW_GRID_COLUMNS_BASE unless show_progress_cols

          "#{ROW_GRID_COLUMNS_BASE} #{ROW_GRID_COLUMNS_PROGRESS}"
        end

        # Native browser tooltip (title attr) on the "Theoretical Max"
        # header -- the number there is a certified UPPER BOUND on what's
        # still reachable, not a promise: it starts optimistic (every
        # ceiling assumed simultaneously realizable) and only decreases
        # as the search rules out combinations, ending equal to Current
        # Best exactly when the search has proven nothing better exists
        # (Autorouter#certified_bound).
        THEORETICAL_MAX_TOOLTIP = 'This value may never be obtainable. It is a theoretical maximum value assuming ' \
                                  'full connectivity. This value decreases to the actual max, whereupon the ' \
                                  'autorun ceases for this ship.'

        def render
          step = @game.round.active_step
          return '' unless step.respond_to?(:ship_rows)

          entity = @game.round.current_entity
          rows = step.ship_rows(entity)

          # True while an Auto-all click (see auto_route_all_button) is
          # actively running for this entity -- suppresses every other
          # way to touch a route below for the duration. Without this, a
          # route the run just built (and is about to submit on a later
          # tick) could flash into view as an ordinary clickable/
          # previewable row in between.
          auto_running = step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)

          # The live Auto counter attaches to whichever ship's row is
          # actually being routed right now -- only meaningful during the
          # final (chunked) phase, nil during ranking trials or once the
          # run's done.
          current_ship_id = step.respond_to?(:auto_route_all_current_ship_id) ? step.auto_route_all_current_ship_id(entity) : nil
          row_progress = current_ship_id && auto_route_progress_parts

          children = []
          grid = render_ship_rows_grid(step, entity, rows, auto_running, current_ship_id, row_progress)
          children << grid if grid

          # The one contextual bar for whichever state currently applies
          # (a hand-flown route in progress/finished awaiting Submit/
          # Clear) -- entity-level state, so it renders once below the
          # whole list rather than nested under whichever row is
          # selected. Suppressed while auto_running.
          bar = render_action_bar(step, entity) unless auto_running
          children << bar if bar

          # Modify/Submit/Auto: quick ways to fill in a route without
          # hand-flying it.
          idle_controls = render_idle_controls(step, entity, auto_running: auto_running, current_ship_id: current_ship_id)
          children << idle_controls if idle_controls

          # Submit All Routes plus Clear Ship for whichever already-
          # submitted route is targeted for cancellation. Suppressed
          # while auto_running -- Submit All Routes in particular is
          # exactly the accidental-mid-sequence-submit risk auto_running
          # exists to close off.
          submit_controls = render_submit_controls(step, entity) unless auto_running
          children << submit_controls if submit_controls

          return '' if children.empty?

          h(:div, { style: { marginBottom: '0.5rem' } }, children)
        end

        # The ship-list grid itself (header + one row per ship) -- nil if
        # there's nothing to show. Split out of render so that method's
        # remaining job (assembling the ship-list grid plus the contextual
        # bars/controls below it) reads as one flat sequence of "add this
        # piece if present" steps.
        def render_ship_rows_grid(step, entity, rows, auto_running, current_ship_id, row_progress)
          return nil if rows.empty?

          # Current Best/Bound are only meaningful once SOME auto-route
          # search has actually run -- either live right now
          # (auto_running) or already finished this turn. row[:found_at]
          # isn't displayed any more, but it's still populated by Step::
          # Route#ship_rows only for a ship that WAS auto-routed, so its
          # presence is a convenient signal some row has real history to
          # show.
          show_progress_cols = auto_running || rows.any? { |r| r[:found_at] }

          row_children = rows.map do |row|
            parts = row[:ship_id] == current_ship_id ? row_progress : nil
            render_row(step, entity, row, auto_running: auto_running, progress: parts,
                                          show_progress_cols: show_progress_cols)
          end
          # width: 'fit-content' -- without it the grid stretches to fill
          # the panel's full width, and with no `fr` tracks in
          # row_grid_columns, the track-sizing algorithm hands all of
          # that leftover space to the one `auto`-sized column (the ship
          # name), opening a big gap before Explore instead of after
          # Revenue.
          grid_style = {
            display: 'grid',
            gridTemplateColumns: row_grid_columns(show_progress_cols),
            columnGap: '0.5rem',
            rowGap: '0.1rem',
            alignItems: 'center',
            width: 'fit-content',
          }
          # Wrapped in its own horizontally-scrollable container -- the
          # page's own fixed-width left panel (div#left), an ancestor we
          # don't control, has overflow:hidden and silently clips
          # anything wider than its own width with no scrollbar or
          # visual cue. This div becomes ITS OWN scroll container
          # instead, constrained to the parent's available width.
          scroll_style = { maxWidth: '100%', overflowX: 'auto' }
          h(:div, { style: scroll_style },
            [h(:div, { style: grid_style }, [render_row_header(show_progress_cols)] + row_children)])
        end

        # Modify/Submit act directly on the selected ship's own passive
        # preview -- no separate "Activate" step first; both already do
        # "load, then act" in one step via apply_previous_route! (the same
        # helper Submit All Routes uses per-ship). Modify lands on the
        # hand-fly Submit/Clear bar (render_flight_bar); this Submit (now
        # labeled "Accept prior run" -- previous_route_submit_label)
        # finishes the job in one click for "I like this as-is."
        #
        # Modify itself is currently hidden -- not offered as a button
        # below -- but apply_previous_route! and everything else it needs
        # are deliberately left in place, not removed, in case it
        # comes back.
        def render_idle_controls(step, entity, auto_running: false, current_ship_id: nil)
          buttons = []
          # Modify/individual-Submit and a second Auto click are both
          # suppressed while auto_running. Only the counter (below) stays
          # visible during a run.
          unless auto_running
            if step.respond_to?(:previous_route_available?) && step.previous_route_available?(entity)
              buttons << previous_route_submit_button(step, entity)
            end
            if step.respond_to?(:clear_all_available?) && step.clear_all_available?(entity)
              buttons << clear_all_button(step, entity)
            end
            if autorouting_allowed? && step.respond_to?(:any_suggestable?) && step.any_suggestable?(entity)
              buttons << auto_route_all_button(step, entity)
              warning = four_ship_warning(step, entity)
              buttons << warning if warning
            end
          end
          # While a run is active but still in the ranking-trials phase
          # (no single ship "current" yet), the row-level counter has
          # nothing to attach to, so this bottom counter fills in with
          # "Working" instead. Once a ship becomes current, its row
          # takes over and this suppresses itself (auto_route_counter_
          # cell); once the run's done, it reappears as "Finished".
          if auto_running && !current_ship_id
            elapsed = step.respond_to?(:auto_route_all_elapsed) ? step.auto_route_all_elapsed(entity) : nil
            # Same live-clock DOM id as the row-level and finished-state
            # counters -- only one of the three is ever actually in the
            # document at once, so there's no id collision.
            buttons << h(:div, { attrs: { id: 'auto_route_counter' } }, "Auto-run Working: #{elapsed}s") if elapsed
          end
          counter = auto_route_counter_cell(step, entity)
          buttons << counter if counter

          # The one control that DOES show during a run: accept the
          # current ship's best-so-far and move on to the next ship.
          # Rendered here (gated only on current_ship_id) but VISUALLY
          # hidden by default -- its actual show/hide is driven every
          # second by the same poll that already updates the Progress/
          # Best/Bound text, not by Snabberb re-rendering it. A real
          # re-render only happens at specific trigger points, and for a
          # ship whose search runs long past the first-best moment,
          # nothing forces another one, so a button shown at that one
          # instant stayed shown in the DOM forever after.
          if current_ship_id && step.respond_to?(:skip_current_ship_search!)
            button_props = {
              # Keyed per-ship, not just 'accept_next_ship' -- Snabbdom
              # patches a matched key's existing DOM node rather than
              # replacing it, and the JS poll above mutates that node's
              # style.display directly. A stable key across a ship
              # boundary risks Snabbdom leaving that externally-mutated
              # style alone, letting a stale "visible" state leak into
              # the next ship's freshly-started search.
              key: "accept_next_ship_#{current_ship_id}",
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
        # assistant at all -- the same site-wide setting every other
        # game's AutoRouter-backed "Auto" button checks (route_
        # selector.rb), not a G2038-specific opt-out.
        def autorouting_allowed?
          @game_data.dig('settings', 'auto_routing') || @game_data['mode'] == :hotseat
        end

        # The real end-of-turn Pass (submit_all_button -- see also
        # G2038::Step::Route#suppress_standalone_pass?, which keeps the
        # standalone PassButton from also showing elsewhere on the page)
        # plus Clear Ship for whichever already-submitted route is
        # currently targeted.
        def render_submit_controls(step, entity)
          buttons = []
          buttons << clear_completed_button(step, entity) if step.respond_to?(:selected_completed_ship) &&
            step.selected_completed_ship(entity)
          buttons << submit_all_button(step, entity) if step.respond_to?(:local_pass?) && !step.local_pass?(entity)
          return nil if buttons.empty?

          h(:div, { style: { marginTop: '0.3rem', display: 'flex', flexWrap: 'wrap' } }, buttons)
        end

        # Same action the shared PassButton dispatches, but built locally
        # with the same button.no_margin styling every other control here
        # uses -- PassButton's own `button#pass` doesn't match
        # `.no_margin` and would render visibly taller than Clear Ship
        # sitting right next to it.
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
        # the currently selected ship's own finished-but-unsubmitted
        # flight first, then every other still-unrun ship with a viable
        # prior route on file (Step::Route#preview_last_route), rebuilt
        # and submitted the same way. Only once nothing's left to submit
        # does the real Pass actually end the turn.
        # Fires exactly ONE real action: step.submit_all_choice(entity)
        # already decided (client-side) everything this click is about
        # to submit and packed it into one self-contained SUBMIT_ALL
        # choice. The terminal Pass is NOT part of that choice -- it's
        # bundled on afterward via Step::Route#auto_actions -- so either
        # way the whole click undoes atomically with a single Undo.
        def submit_all_routes!(step, entity)
          choice = step.submit_all_choice(entity)
          action = choice ? Engine::Action::Choose.new(entity, choice: choice) : Engine::Action::Pass.new(entity)
          process_action(action)
        end

        # Cancels whichever already-submitted route the row list above is
        # currently targeting -- a real, recorded action, since it undoes
        # state other clients can already see. `key:` is load-bearing
        # here, not decorative -- this button only exists in the
        # `buttons` array once a ship's been selected, so it gets
        # *inserted in front of* the already-present PassButton rather
        # than appended; without a stable key, Snabberb's positional
        # diffing patches the existing PassButton DOM node into becoming
        # this one instead of inserting a new node, leaving a stale
        # closure (captured `ship` from before anything was selected)
        # bound to the button that's now on screen.
        def clear_completed_button(step, entity)
          ship = step.selected_completed_ship(entity)
          props = {
            key: 'clear_completed',
            style: { marginRight: '0.3rem' },
            on: {
              click: lambda {
                process_action(Engine::Action::Choose.new(entity, choice: step.cancel_completed_choice(ship)))
              },
            },
          }
          h('button.no_margin', props, 'Clear Selected Route')
        end

        # The one contextual bar for the entity's current flight state --
        # a hand-flown route in progress or finished but not yet
        # submitted (Submit/Clear). nil once nothing's in that state.
        # store(:game, @game) (inside local_button) forces the re-render
        # a process_action call would otherwise give us for free, since
        # @game itself was mutated in place.
        def render_action_bar(step, entity)
          return render_flight_bar(step, entity) if step.respond_to?(:local_pass?) && step.local_pass?(entity)

          nil
        end

        # One-click "load this ship's last-OR route and submit it as-is"
        # -- apply_previous_route! does the load-then-apply work locally;
        # finish_and_submit_choice's own Choose is the one real, recorded
        # action.
        def previous_route_submit_button(step, entity)
          props = {
            key: 'previous_route_submit',
            style: { marginRight: '0.3rem' },
            on: {
              click: lambda {
                ship = step.current_ship(entity)
                next unless step.apply_previous_route!(entity, ship)

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

        # `timeout` ("Search timeout") is passed through for signature
        # compatibility only -- Autorouter's final per-ship pass always
        # runs to full mathematical proof regardless (autorouter.rb's own
        # Result comment). `ranking_timeout` is the one budget that still
        # matters: the per-ship cap on each of the up-to-N! ordering
        # trials that pick which ship goes first.
        #
        # Autoroutes every still-unfilled ship in one click, in whichever
        # order actually maximizes combined revenue (see G2038::Step::
        # Route#start_auto_route_all! for why a single-ship search alone
        # can't be trusted once more than one ship is involved). A ship
        # already dealt with (Submitted, or showing an uncleared history
        # preview) is left alone.
        #
        # Chunked via start_auto_route_all!/auto_route_all_tick! -- a
        # handful of ships can take a couple of minutes total, and running
        # that as one giant synchronous call left the tab unresponsive for
        # the whole duration. Each tick is one already-bounded unit of
        # work, scheduled via setTimeout so the browser can repaint/handle
        # events in between (mirroring Autorouter#resume_async!'s own
        # pattern). This method only needs to keep calling
        # auto_route_all_tick! until it returns :done, submitting
        # whenever it returns :built.
        #
        # Runs its own independent setInterval (start_auto_route_clock!)
        # so the on-screen counter ticks smoothly in real time -- the
        # tick-chain alone can go up to route_timeout (30s by default)
        # between updates during the final per-ship pass.
        def auto_route_all_button(step, entity)
          timeout = setting_for(:route_timeout).to_i
          ranking_timeout = (setting_for(:ranking_timeout) || 4).to_f

          click = lambda do
            # Guards against a fast double-click starting a second,
            # overlapping tick-chain before the first click's re-render
            # has had a chance to hide this button (Snabberb's repaint is
            # async, queued via requestAnimationFrame). Two tick-chains
            # driving the same shared Autorouter state concurrently is the
            # leading suspect for a run seen climbing past 2000s with no
            # configured timeout anywhere near that (see start_auto_
            # route_all!'s own @auto_all_deadline backstop for the other
            # half of that fix).
            next if step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)

            step.start_auto_route_all!(entity, timeout: timeout, ranking_timeout: ranking_timeout)
            @auto_tick_count = 0
            @auto_tick_started = nil
            @auto_tick_seen_final_phase = false
            @auto_tick_last_rendered_best = nil
            start_auto_route_clock!
            # Double-deferred via requestAnimationFrame THEN setTimeout,
            # not setTimeout alone -- timer tasks run BEFORE the browser's
            # next paint, so a bare setTimeout(0) started the first tick
            # (a real ranking trial, up to TRIAL_TIMEOUT x ships seconds
            # of synchronous work) ahead of the initial "Working: 0s"
            # render, leaving the counter showing nothing for that whole
            # span. rAF fires only after the paint happens, guaranteeing
            # the counter is on screen first.
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

        # Only the AL, in Phases IV-V, ever holds 4 ships at once -- the
        # one case where the ranking phase's ordering count (4! = 24,
        # even after start_auto_route_all!'s own dedup/pruning) can still
        # make a single Auto click slow (Game#warn_on_four_ships?,
        # entities.rb, AL only). Rather than build machinery around a
        # rare worst case, just suggest flying one ship by hand first --
        # Auto only touches still-unfilled ships, so that drops this back
        # to the cheap 3-ship case with no engine changes.
        def four_ship_warning(step, entity)
          return nil unless step.respond_to?(:unfilled_ship_count)
          return nil unless step.unfilled_ship_count(entity) >= 4
          return nil unless @game.respond_to?(:warn_on_four_ships?)
          return nil unless @game.warn_on_four_ships?(entity)

          h(:div, { style: { fontSize: '80%', opacity: 0.7, flexBasis: '100%' } },
            'Auto may be slow with 4 ships -- consider flying one manually first.')
        end

        def run_auto_route_all_tick!(_stale_step, entity)
          # Re-resolve step fresh from the live store every tick -- do
          # NOT trust the `_stale_step` parameter, and do NOT trust this
          # component's own @game ivar either, past the very first call.
          # Every full re-render rebuilds the ENTIRE tree from scratch
          # (a fresh ShipSelector instance every time); the recursive
          # tick-chain below is a plain method call on `self`, so it
          # keeps running on the ORIGINAL instance even after some other
          # action (Undo, Restart Turn) causes an external render -- and
          # @game on that orphaned instance is now a frozen snapshot from
          # before that render. @store, by contrast, is the single Hash
          # object @root.store itself, shared and mutated in place by
          # every store(key, value) call anywhere in the app, so reading
          # store[:game] gives even an orphaned instance the true,
          # live-current game on every tick.
          @game = store[:game]
          step = @game.round.active_step
          return unless auto_route_tick_still_active?(step, entity)

          log_auto_route_tick_telemetry!

          status = step.auto_route_all_tick!(entity)
          submit_built_ship_route!(step, entity) if status == :built
          force_render_on_auto_route_progress!(status)

          if status == :done
            store(:game, @game)
          else
            schedule_next_auto_route_tick!(step, entity)
          end
        end

        # If the CURRENT (freshly-resolved) step no longer agrees an Auto
        # run is active for this entity -- because it genuinely finished,
        # or an intervening action (Undo, Restart Turn) moved the game on
        # without it -- the tick chain must stop dead instead of silently
        # continuing to compute a route nobody asked for any more.
        def auto_route_tick_still_active?(step, entity)
          return false unless step.respond_to?(:auto_route_all_active?)
          return true if step.auto_route_all_active?(entity)

          `console.log("g2038 auto: chain stopped -- run no longer active for this entity (game state moved on)")`
          false
        end

        # Dev-only throughput telemetry (browser console, F12): with 0.2s
        # work chunks the healthy rate is ~4-5 ticks/sec -- a much lower
        # rate means the chain is being starved (throttling, render tax); a
        # healthy tick rate with low combos/sec means the engine itself is
        # slow inside the browser. This is the instrumentation that
        # separates the two failure modes without another blind run.
        def log_auto_route_tick_telemetry!
          return unless @game.respond_to?(:autorouter)

          @auto_tick_count = (@auto_tick_count || 0) + 1
          @auto_tick_started ||= Time.now
          return unless (@auto_tick_count % 100).zero?

          elapsed = (Time.now - @auto_tick_started).round(1)
          combos = @game.autorouter.combos_so_far
          rate = elapsed.positive? ? (@auto_tick_count / elapsed).round(1) : 0
          %x{
            console.log("g2038 auto: ticks=" + #{@auto_tick_count} + " elapsed=" + #{elapsed} +
                        "s (" + #{rate} + " ticks/s), engine combos=" + #{combos})
          }
        end

        def submit_built_ship_route!(step, entity)
          @auto_tick_last_rendered_best = nil
          submit_choice = step.finish_and_submit_choice(entity)
          process_action(Engine::Action::Choose.new(entity, choice: submit_choice)) if submit_choice
          store(:game, @game)
        end

        # Two independent forced-render cases, both only meaningful while
        # `status` is :searching (checked separately, not mutually
        # exclusive -- both can legitimately fire on the same tick):
        #
        # 1. One extra render at the FIRST final-phase tick (trials -> real
        # search transition), not just at ship-boundary :built/:done --
        # without it, the first ship's progress display was stuck at the
        # bottom "Working" fallback for that ship's ENTIRE search, only
        # ever moving onto a ship's own row starting with ship 2 (the
        # peek-ahead that attaches it happens at the PRIOR ship's :built
        # render, which ship 1 has none of). Found live in browser via the
        # console log: no "Rendering game view" entry appeared between the
        # click and ship 1's own completion. @auto_tick_seen_final_phase
        # ensures this fires exactly once per Auto click, not once per
        # tick.
        #
        # 2. A render on every GENUINE improvement (first find, or any
        # later better answer) -- a transition that can happen (repeatedly)
        # at any point deep into a long search, not just at its very start.
        # Covers two needs at once:
        #  - "Accept & next ship" (gated on best_so_far being truthy -- see
        #    render_idle_controls) never appearing at all: nothing else
        #    forces a real Snabberb re-render between ship-boundary events,
        #    so the button's visibility stays frozen at whatever it was
        #    computed as during the last real render. Found live: a ship
        #    stuck at best=$0 for 1000+ seconds, then finding $250, still
        #    showed no Accept button afterward.
        #  - the live map's dashed "current best" preview (map.rb's
        #    render_route_lines) needs a real render every time the answer
        #    actually changes, not just once, to stay in sync.
        # @auto_tick_last_rendered_best (reset to nil at each :built
        # ship-boundary in submit_built_ship_route!) tracks whatever value
        # this last forced a render for, so this only fires on a genuine
        # change -- never once per tick, and never twice for the same
        # value. The live clock's own setInterval only patches existing DOM
        # nodes' textContent -- it can't add a button or redraw the map
        # itself.
        def force_render_on_auto_route_progress!(status)
          return unless status == :searching

          unless @auto_tick_seen_final_phase
            @auto_tick_seen_final_phase = true
            store(:game, @game)
          end

          current_best = @game.autorouter.best_so_far
          return unless current_best
          return if current_best == @auto_tick_last_rendered_best

          @auto_tick_last_rendered_best = current_best
          store(:game, @game)
        end

        # Yield via a MessageChannel post, NOT setTimeout(fn, 0) --
        # background tabs clamp timers to >= 1s (Chrome's intensive
        # throttling), which starved the whole tick chain to ~1 work
        # chunk per second the moment the player switched tabs.
        # Message-channel tasks are ordinary posted tasks, not timers,
        # so they're exempt from timer clamping. The 1s display clock IS
        # still a throttled timer in background, which is fine: it's
        # display-only and catches up on focus.
        def schedule_next_auto_route_tick!(step, entity)
          %x{
            var ch = new MessageChannel();
            ch.port1.onmessage = function() {
              ch.port1.onmessage = null;
              #{run_auto_route_all_tick!(step, entity)}
            };
            ch.port2.postMessage(null);
          }
        end

        # Self-contained JS interval rather than threading a JS interval
        # handle back and forth across Ruby calls -- it checks
        # auto_route_clock_active? itself each tick and clears itself the
        # moment that flips false.
        #
        # Writes the counter text STRAIGHT into the existing DOM node (by
        # id) instead of store(:game, ...) -- the old 200ms store()
        # approach re-rendered the ENTIRE game view between every 0.2s
        # work chunk, and that render overhead ate most of the wall
        # clock. A seconds-granularity label doesn't need vdom at all --
        # one real store() fires when the run ends.
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
              ['progress', 'best', 'max'].forEach(function(key) {
                var el = document.getElementById('auto_route_' + key);
                if (el) { el.textContent = parts[key]; }
              });
              var acceptBtn = document.getElementById('auto_route_accept_button');
              if (acceptBtn) { acceptBtn.style.display = parts.has_best ? '' : 'none'; }
            }, 1000);
          }
        end

        # The three progress cells' current text (Auto-run progress /
        # Best revenue / Theoretical Max, split into their own labeled
        # columns rather than one combined sentence), resolved fresh
        # from the live step -- called from the clock's JS interval,
        # which has no step/entity closure of its own to reuse.
        def auto_route_progress_parts
          step = @game.round.active_step
          entity = @game.round.current_entity
          empty = { progress: '', best: '', max: '', has_best: false }
          return empty unless entity
          return empty unless step.respond_to?(:auto_route_all_elapsed)

          elapsed = step.auto_route_all_elapsed(entity)
          return empty unless elapsed

          # Progress is just the bare timer -- "Working"/"Finished" is
          # conveyed by the Best/Max columns having content or not (Max
          # clears once the search stops needing to prove anything
          # further), not by prose here.
          running = step.auto_route_all_active?(entity)
          parts = { progress: "#{elapsed}s", best: '', max: '', has_best: false }
          return parts unless running

          # While the final search is live, show the certified state of
          # play: the best route in hand and the PROVEN maximum anything
          # still untried could pay -- the gap between them shrinking in
          # real time is what tells the user whether "Accept & next ship"
          # is worth clicking yet.
          router = @game.autorouter
          best = router.best_so_far
          bound = router.certified_bound
          # Show $0 rather than a blank cell until the first real route
          # is found. has_best stays a real boolean (not inferred from
          # the "$0" text, which is truthy in JS regardless) -- the
          # clock's own interval reads this to gate "Accept & next
          # ship", which must stay hidden until best_so_far is genuinely
          # non-nil, not just display-non-blank.
          parts[:has_best] = !best.nil?
          parts[:best] = "$#{best || 0}"
          parts[:max] = "$#{bound}" if bound && !(best && bound <= best)
          parts
        end

        # Re-fetches the active step fresh each tick rather than closing
        # over the one passed into auto_route_all_button -- this runs
        # from a JS interval with no Ruby call stack of its own to carry
        # that reference.
        def auto_route_clock_active_q
          step = @game.round.active_step
          step.respond_to?(:auto_route_all_running?) && step.auto_route_all_running?
        end

        # A hand-flown (or accepted/modified) route's real submit: the
        # whole flight was already built up locally, hop by hop
        # (G2038::Step::Route#local_choose!). Shows as soon as finishing
        # is a legal move, not just once the flight has actually
        # finished -- ending a route with MP still left behaves
        # identically to running out of MP, one click either way.
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

        # Discards an in-progress or finished-but-not-yet-submitted flight
        # -- runs purely locally (step.local_pass!, the exact same
        # discard the standalone Pass button triggers when it intercepts
        # a real Pass action). Labeled "Reset," not "Clear": discarding
        # the local flight also leaves @trace empty again, which brings
        # back the ship's own italicized suggested route rather than
        # leaving the row genuinely blank.
        def cancel_flight_button(step, entity)
          label = step.respond_to?(:pass_description) ? step.pass_description.sub(/\ACancel/, 'Reset') : 'Reset'
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

        # Resets the whole idle-controls panel back to "nothing decided
        # yet" in one click -- Route#clear_all_action/clear_all! discard
        # every still-cancellable route submitted this OR, a safe/
        # unexplored local flight, and every still-unrun ship's own
        # passive suggested-route preview. What it deliberately leaves
        # alone: an explored partial route, and any route an intervening
        # Explore has already locked in (see cancellable_ships).
        def clear_all_button(step, entity)
          props = {
            key: 'clear_all',
            style: { marginRight: '0.3rem' },
            on: {
              click: lambda {
                action = step.clear_all_action(entity)
                process_action(action) if action
                step.clear_all!(entity)
                store(:game, @game)
              },
            },
          }
          h('button.no_margin', props, 'Clear All')
        end

        # Shared padding/box-sizing every cell (header or row) uses, so
        # header text and row values -- both plain, unstyled text, same
        # font/size as each other -- still line up in the same columns.
        def cell_style(extra = {})
          { padding: '2px 6px', boxSizing: 'border-box' }.merge(extra)
        end

        # Column headers over the ship list -- `display: contents` so these
        # cells become direct children of render's own outer grid (see
        # row_grid_columns) instead of laying out a second, independent
        # grid.
        def render_row_header(show_progress_cols)
          label_style = cell_style(opacity: 0.7)
          # nowrap only -- NOT overflow:hidden. An item with overflow
          # other than visible is excluded from a grid track's automatic
          # max-content sizing (its contribution is treated as 0), so
          # overflow:hidden as a safety net backfires: it tells the track
          # it's free to collapse toward nothing instead of protecting
          # its content. Letting a header wrap onto a second line
          # instead (same as every data row's multi-line "Mines" cell)
          # avoids the overlap that caused.
          progress_label_style = label_style
          headers = [
            h(:div, { style: label_style }, 'Ships'),
            h(:div, { style: label_style }, 'Rev.'),
            h(:div, { style: label_style }, 'Mines'),
            h(:div, { style: label_style }, 'Hexes'),
            h(:div, { style: label_style }, 'Refuel'),
            h(:div, { style: label_style }, 'Exp.'),
          ]
          if show_progress_cols
            headers << h(:div, { style: progress_label_style }, 'Progress')
            headers << h(:div, { style: progress_label_style }, 'Current Best')
            headers << h(:div, { style: progress_label_style, attrs: { title: THEORETICAL_MAX_TOOLTIP } }, 'Bound')
          end
          h(:div, { style: { display: 'contents' } }, headers)
        end

        # This row's click behavior (a handler, or none) plus the four
        # underlying state flags -- returned together because
        # auto_running forces all four false at once, and render_row
        # still needs the (possibly-suppressed) flags afterward for
        # cursor/opacity.
        def row_click_props(step, entity, row, auto_running)
          clickable = !row[:choice].nil?
          # An already-submitted, still-cancellable route can't be
          # re-launched (choice is nil), but clicking it still means
          # something: targeting it for the single "Clear Ship" control
          # below the list. An unrun ship with no real choice of its own
          # can mean something too, once a completed route is currently
          # targeted -- clicking it drops that targeting instead
          # (deselect_completed_ship!).
          selectable = !row[:select_ship].nil? || row[:deselect_completed]
          blocked = row[:blocked]
          # A settled, already-submitted route from before a later route
          # this turn explored a hex (Step::Route#cancellable_ships) --
          # can never be reopened: undoing it and resubmitting something
          # different risks the game drawing a different tile (or a
          # different Lucky/IF/DH redraw candidate) on replay than it
          # actually did live. Greyed out with its own explanatory
          # click, rather than looking identical to a still-cancellable
          # row and silently doing nothing.
          locked = row[:locked]

          # `display: contents` -- the row itself renders no box of its
          # own; its cells become direct children of render's own outer
          # grid, the same one render_row_header's cells join, so every
          # row's columns line up with every other row's regardless of
          # how wide any one row's own label happens to be.
          wrapper_props = { style: { display: 'contents' } }
          if auto_running
            clickable = selectable = blocked = locked = false
          elsif clickable
            wrapper_props[:on] = { click: -> { process_action(Engine::Action::Choose.new(entity, choice: row[:choice])) } }
          elsif selectable
            wrapper_props[:on] = {
              click: lambda {
                if row[:select_ship]
                  step.select_completed_ship!(row[:select_ship])
                else
                  step.deselect_completed_ship!
                end
                store(:game, @game)
              },
            }
          elsif blocked
            wrapper_props[:on] = {
              click: lambda {
                store(:flash_opts, "Cannot switch ships mid-flight; please submit or cancel the active ship's route first.")
              },
            }
          elsif locked
            wrapper_props[:on] = {
              click: lambda {
                # Flash#render forwards `message` straight through as
                # snabbdom children, so an array of strings/vnodes
                # renders as rich content -- reuses render_ship_name
                # itself so the locking ship's name reads as the exact
                # same badge seen elsewhere on this panel.
                ship_badge = render_ship_name(
                  { selected: false, color_index: row[:locked_by_color_index], label: row[:locked_by_label] || 'a later ship' }
                )
                store(:flash_opts, { message: ['Route locked by ', ship_badge, "'s explore. Use Undo to go back further."] },
                      skip: false)
              },
            }
          end

          [wrapper_props, clickable, selectable, blocked, locked]
        end

        def render_row(step, entity, row, auto_running: false, progress: nil, show_progress_cols: false)
          wrapper_props, clickable, selectable, blocked, locked = row_click_props(step, entity, row, auto_running)

          cursor = (clickable || blocked || selectable || locked) && !row[:selected] ? 'pointer' : 'default'
          opacity = if clickable || selectable
                      1.0
                    else
                      (blocked || locked ? 0.7 : 1.0)
                    end
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
            h(:div, { style: value_style.merge(textAlign: 'right') }, revenue_cell(row)),
            h(:div, { style: value_style }, stats ? mines_cell(stats) : ''),
            h(:div, { style: value_style }, stats ? "#{stats[:hexes]}/#{stats[:max_hexes]}" : ''),
            h(:div, { style: value_style }, stats ? stats[:refuels].to_s : ''),
            h(:div, { style: value_style }, stats ? stats[:explored].to_s : ''),
          ]
          # The three live Auto-run cells, attached to whichever ship's
          # row the final search is currently building -- blank for
          # every other row. Each gets the DOM id the clock's direct-
          # text-write targets only when it's actually this row's cells
          # that are live, so the per-second update lands on the right
          # ship if the player has since scrolled past a ship boundary.
          cell_style_progress = cell_style(opacity: 0.8, fontSize: '85%', whiteSpace: 'nowrap')
          return h(:div, wrapper_props, children) unless show_progress_cols

          %i[progress best max].each do |part|
            attrs = progress ? { id: "auto_route_#{part}" } : {}
            text = progress ? progress[part].to_s : ''
            children << h(:div, { style: cell_style_progress, attrs: attrs }, text)
          end

          h(:div, wrapper_props, children)
        end

        # The row's revenue -- finished/pending value, or blank -- always
        # plain text.
        def revenue_cell(row)
          row[:revenue] || ''
        end

        # Sits in the same control row as the Auto button -- live
        # elapsed time while an Auto-all click is running, then stays
        # showing the final time until the next click resets it.
        # Deliberately doesn't mention timeouts/optimality -- players
        # already know an autorouter isn't guaranteed optimal, and
        # calling it out here would misleadingly imply this run in
        # particular is more likely to be bad.
        #
        # Reads straight off the step (auto_route_all_elapsed/_active?)
        # -- NOT a view-local store (see G2038::Step::Route#
        # auto_route_all_active? for why a Snabberb store key didn't
        # survive here). Returns nil (not a blank vnode) when there's
        # nothing to show.
        # Only shown once a run has FINISHED -- while active, the live
        # counter is attached to the currently-routing ship's own row so
        # it reads as information about that specific ship.
        def auto_route_counter_cell(step, entity)
          return nil unless step.respond_to?(:auto_route_all_elapsed)
          return nil if step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)

          elapsed = step.auto_route_all_elapsed(entity)
          return nil unless elapsed

          # The id is the live clock's direct-DOM update target while a
          # row owns it; once finished, nothing but this cell exists to
          # hold the id, so it's safe to carry it here too.
          h(:div, { attrs: { id: 'auto_route_counter' }, style: { opacity: 0.7 } }, "Auto-run Finished: #{elapsed}s")
        end

        def mines_cell(stats)
          return stats[:mines].to_s if stats[:codes].to_s.empty?

          "#{stats[:mines]} (#{stats[:codes]})"
        end

        # A small box around just the ship's name -- the same look every
        # other game's train-selector uses for its own per-train color.
        # Bordered to show which ship is selected, and additionally
        # filled with this ship's own fixed color slot (G2038::Step::
        # Route#route_color_index) whenever it has a route currently
        # drawn on the map, so the name and its line on the map read as
        # the same thing at a glance.
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
end
