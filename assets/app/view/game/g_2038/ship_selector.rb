# frozen_string_literal: true

require 'view/game/actionable'

module View
  module Game
    module G2038
      # Row data comes from Step::Route#ship_rows(entity): `choice` is nil
      # for a ship that's already finished this OR (or mid-flight and not
      # the selected one); `select_ship` is set only for an
      # already-submitted route still eligible for "Clear Ship" below.
      class ShipSelector < Snabberb::Component
        include Actionable
        include Lib::Settings

        needs :game, store: true

        # The progress columns carry a real MINIMUM, not minmax(0, ...) --
        # a 0 minimum lets the track collapse under space pressure, and
        # nowrap text then overflows into its neighbor instead of wrapping.
        ROW_GRID_COLUMNS_BASE = 'minmax(3rem, auto) 3rem 4.5rem 3rem 3.5rem 3.5rem'
        ROW_GRID_COLUMNS_PROGRESS = 'minmax(5rem, auto) minmax(3.5rem, auto) minmax(3.5rem, auto)'

        def row_grid_columns(show_progress_cols)
          return ROW_GRID_COLUMNS_BASE unless show_progress_cols

          "#{ROW_GRID_COLUMNS_BASE} #{ROW_GRID_COLUMNS_PROGRESS}"
        end

        THEORETICAL_MAX_TOOLTIP = 'This value may never be obtainable. It is a theoretical maximum value assuming ' \
                                  'full connectivity. This value decreases to the actual max, whereupon the ' \
                                  'autorun ceases for this ship.'

        def render
          step = @game.round.active_step
          return '' unless step.respond_to?(:ship_rows)

          entity = @game.round.current_entity
          rows = step.ship_rows(entity)

          # Suppresses every other way to touch a route for the duration --
          # without this, a route the run just built could flash into view
          # as an ordinary clickable row before its own submit tick.
          auto_running = step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)

          current_ship_id = step.respond_to?(:auto_route_all_current_ship_id) ? step.auto_route_all_current_ship_id(entity) : nil
          row_progress = current_ship_id && auto_route_progress_parts

          children = []
          grid = render_ship_rows_grid(step, entity, rows, auto_running, current_ship_id, row_progress)
          children << grid if grid

          bar = render_action_bar(step, entity) unless auto_running
          children << bar if bar

          idle_controls = render_idle_controls(step, entity, auto_running: auto_running, current_ship_id: current_ship_id)
          children << idle_controls if idle_controls

          submit_controls = render_submit_controls(step, entity) unless auto_running
          children << submit_controls if submit_controls

          return '' if children.empty?

          h(:div, { style: { marginBottom: '0.5rem' } }, children)
        end

        def render_ship_rows_grid(step, entity, rows, auto_running, current_ship_id, row_progress)
          return nil if rows.empty?

          # row[:found_at] isn't displayed, but Step::Route#ship_rows still
          # populates it only for a ship that WAS auto-routed -- a
          # convenient signal some row has real history to show.
          show_progress_cols = auto_running || rows.any? { |r| r[:found_at] }

          row_children = rows.map do |row|
            parts = row[:ship_id] == current_ship_id ? row_progress : nil
            render_row(step, entity, row, auto_running: auto_running, progress: parts,
                                          show_progress_cols: show_progress_cols)
          end
          # Without width: 'fit-content', the grid stretches to fill the
          # panel, and with no `fr` tracks, the leftover space all goes to
          # the one `auto` column (ship name), opening a gap before Explore.
          grid_style = {
            display: 'grid',
            gridTemplateColumns: row_grid_columns(show_progress_cols),
            columnGap: '0.5rem',
            rowGap: '0.1rem',
            alignItems: 'center',
            width: 'fit-content',
          }
          # The page's own left panel (div#left) has overflow:hidden and
          # silently clips anything wider, with no scrollbar -- this div
          # becomes its own scroll container instead.
          scroll_style = { maxWidth: '100%', overflowX: 'auto' }
          h(:div, { style: scroll_style },
            [h(:div, { style: grid_style }, [render_row_header(show_progress_cols)] + row_children)])
        end

        # Modify is intentionally hidden (not offered as a button below),
        # but apply_previous_route! and everything else it needs are
        # deliberately left in place rather than removed, in case it
        # comes back.
        def render_idle_controls(step, entity, auto_running: false, current_ship_id: nil)
          buttons = []
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
          # Before any ship becomes "current" (ranking-trials phase), the
          # row-level counter has nothing to attach to -- this fills in.
          if auto_running && !current_ship_id
            elapsed = step.respond_to?(:auto_route_all_elapsed) ? step.auto_route_all_elapsed(entity) : nil
            # Shares its DOM id with the row-level/finished-state counters
            # -- only one of the three is ever in the document at once.
            buttons << h(:div, { attrs: { id: 'auto_route_counter' } }, "Auto-run Working: #{elapsed}s") if elapsed
          end
          counter = auto_route_counter_cell(step, entity)
          buttons << counter if counter

          # Visually hidden by default -- shown/hidden by the same JS
          # poll that updates the Progress/Best/Bound text directly (see
          # start_auto_route_clock!), not by a Snabberb re-render.
          if current_ship_id && step.respond_to?(:skip_current_ship_search!)
            button_props = {
              # Keyed per-ship: the JS poll mutates this node's
              # style.display directly, so a stable key across a ship
              # boundary would let that externally-mutated style leak
              # into the next ship's freshly-started search.
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

        # Same site-wide setting every other game's AutoRouter-backed
        # "Auto" button checks (route_selector.rb) -- not G2038-specific.
        def autorouting_allowed?
          @game_data.dig('settings', 'auto_routing') || @game_data['mode'] == :hotseat
        end

        # See Step::Route#suppress_standalone_pass? for why the standalone
        # PassButton never also shows elsewhere on the page.
        def render_submit_controls(step, entity)
          buttons = []
          buttons << clear_completed_button(step, entity) if step.respond_to?(:selected_completed_ship) &&
            step.selected_completed_ship(entity)
          buttons << submit_all_button(step, entity) if step.respond_to?(:local_pass?) && !step.local_pass?(entity)
          return nil if buttons.empty?

          h(:div, { style: { marginTop: '0.3rem', display: 'flex', flexWrap: 'wrap' } }, buttons)
        end

        # Built locally rather than reusing PassButton: its `button#pass`
        # doesn't match `.no_margin` and renders visibly taller than
        # Clear Ship sitting next to it.
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

        # Fires exactly one real action: step.submit_all_choice(entity)
        # already packed everything to submit into one self-contained
        # choice, so the whole click undoes atomically with a single Undo.
        def submit_all_routes!(step, entity)
          choice = step.submit_all_choice(entity)
          action = choice ? Engine::Action::Choose.new(entity, choice: choice) : Engine::Action::Pass.new(entity)
          process_action(action)
        end

        # `key:` is load-bearing: this button gets inserted in front of
        # the already-present PassButton, not appended -- without a
        # stable key, Snabbdom's positional diffing patches the existing
        # PassButton node into becoming this one, leaving a stale
        # closure (captured `ship`) bound to the button now on screen.
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

        def render_action_bar(step, entity)
          return render_flight_bar(step, entity) if step.respond_to?(:local_pass?) && step.local_pass?(entity)

          nil
        end

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

        # No button for undoing the last hex -- clicking the route's own
        # endpoint on the map does that directly (see
        # Step::Route#undo_click_hex/undo_last_hex!).
        def render_flight_bar(step, entity)
          buttons = []
          buttons << submit_button(step, entity) if step.respond_to?(:submit_ready?) && step.submit_ready?(entity)
          buttons << cancel_flight_button(step, entity)

          action_bar(buttons)
        end

        def action_bar(buttons)
          # Not `[label, *buttons]` -- Opal's array-splat crashes on a
          # snabbdom vnode the moment it isn't a plain array already.
          children = [h(:span, { style: { marginRight: '0.4rem' } }, 'Route:')] + buttons

          h(:div, { style: { marginTop: '0.3rem', display: 'flex', flexWrap: 'wrap', alignItems: 'center' } },
            children)
        end

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

        # `timeout` is passed through for signature compatibility only --
        # Autorouter's final per-ship pass always runs to full proof
        # regardless. `ranking_timeout` is the one budget that still
        # matters: the per-ship cap on the ordering trials that pick
        # which ship goes first.
        #
        # Chunked via start_auto_route_all!/auto_route_all_tick! rather
        # than one synchronous call, which left the tab unresponsive for
        # the whole run. Runs its own independent setInterval
        # (start_auto_route_clock!) so the counter ticks smoothly, since
        # the tick-chain itself can go minutes between updates.
        def auto_route_all_button(step, entity)
          timeout = setting_for(:route_timeout).to_i
          ranking_timeout = (setting_for(:ranking_timeout) || 4).to_f

          click = lambda do
            # Guards against a fast double-click starting a second,
            # overlapping tick-chain before Snabberb's async repaint hides
            # this button -- two tick-chains driving the same shared
            # Autorouter state concurrently can run unbounded.
            next if step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)

            step.start_auto_route_all!(entity, timeout: timeout, ranking_timeout: ranking_timeout)
            @auto_tick_count = 0
            @auto_tick_started = nil
            @auto_tick_seen_final_phase = false
            @auto_tick_last_rendered_best = nil
            start_auto_route_clock!
            # Double-deferred via requestAnimationFrame then setTimeout,
            # not setTimeout alone -- a bare setTimeout(0) runs before the
            # next paint, starting the first (synchronous, potentially
            # long) tick ahead of the initial "Working: 0s" render.
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

        # Only the AL ever holds 4 ships at once -- the one case where the
        # ranking phase's ordering count (4! = 24) can make a single Auto
        # click slow. Rather than build machinery for that rare case, just
        # suggest flying one ship by hand first, dropping back to the
        # cheap 3-ship case.
        def four_ship_warning(step, entity)
          return nil unless step.respond_to?(:unfilled_ship_count)
          return nil unless step.unfilled_ship_count(entity) >= 4
          return nil unless @game.respond_to?(:warn_on_four_ships?)
          return nil unless @game.warn_on_four_ships?(entity)

          h(:div, { style: { fontSize: '80%', opacity: 0.7, flexBasis: '100%' } },
            'Auto may be slow with 4 ships -- consider flying one manually first.')
        end

        def run_auto_route_all_tick!(_stale_step, entity)
          # Re-resolve from the live store, not `_stale_step` or this
          # component's own @game ivar: a full re-render builds a fresh
          # ShipSelector instance, but the recursive tick-chain below is
          # a plain method call that keeps running on the ORIGINAL
          # instance -- whose @game would otherwise be a frozen snapshot
          # from before any later external render (Undo, Restart Turn).
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

        def auto_route_tick_still_active?(step, entity)
          return false unless step.respond_to?(:auto_route_all_active?)
          return true if step.auto_route_all_active?(entity)

          `console.log("g2038 auto: chain stopped -- run no longer active for this entity (game state moved on)")`
          false
        end

        # Dev-only console telemetry: a low ticks/sec rate means the chain
        # is starved (throttling); a healthy rate with low combos/sec
        # means the engine itself is slow.
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

        # Two independent forced-render cases (both only while :searching,
        # not mutually exclusive): (1) one extra render at the first
        # final-phase tick -- without it, ship 1's progress display is
        # stuck on the bottom "Working" fallback for its entire search,
        # since the row-level counter only ever gets attached via the
        # PRIOR ship's :built render. (2) a render on every genuine
        # improvement in best_so_far -- otherwise "Accept & next ship"
        # and the map's dashed preview both stay frozen at whatever they
        # were at the last real render, since the live clock's
        # setInterval only patches existing DOM text, it can't add a
        # button or redraw the map.
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

        # MessageChannel, not setTimeout(fn, 0): background tabs clamp
        # timers to >= 1s (Chrome's intensive throttling), starving the
        # tick chain the moment the player switches tabs. MessageChannel
        # tasks are ordinary posted tasks, exempt from timer clamping.
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

        # Writes the counter text straight into the existing DOM node
        # rather than store(:game, ...) -- re-rendering the entire game
        # view every tick made the render overhead eat most of the wall
        # clock. One real store() fires when the run ends.
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

        # Called from the clock's JS interval, which has no step/entity
        # closure of its own to reuse.
        def auto_route_progress_parts
          step = @game.round.active_step
          entity = @game.round.current_entity
          empty = { progress: '', best: '', max: '', has_best: false }
          return empty unless entity
          return empty unless step.respond_to?(:auto_route_all_elapsed)

          elapsed = step.auto_route_all_elapsed(entity)
          return empty unless elapsed

          running = step.auto_route_all_active?(entity)
          parts = { progress: "#{elapsed}s", best: '', max: '', has_best: false }
          return parts unless running

          router = @game.autorouter
          best = router.best_so_far
          bound = router.certified_bound
          # has_best is a real boolean, not inferred from "$0" text (which
          # is truthy in JS regardless) -- the clock's interval reads this
          # to gate "Accept & next ship".
          parts[:has_best] = !best.nil?
          parts[:best] = "$#{best || 0}"
          parts[:max] = "$#{bound}" if bound && !(best && bound <= best)
          parts
        end

        # This runs from a JS interval, so it can't close over the step
        # passed into auto_route_all_button.
        def auto_route_clock_active_q
          step = @game.round.active_step
          step.respond_to?(:auto_route_all_running?) && step.auto_route_all_running?
        end

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

        # Leaves alone: an explored partial route, and any route an
        # intervening Explore has already locked in (see cancellable_ships).
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

        def cell_style(extra = {})
          { padding: '2px 6px', boxSizing: 'border-box' }.merge(extra)
        end

        def render_row_header(show_progress_cols)
          label_style = cell_style(opacity: 0.7)
          # Not overflow:hidden: an item with overflow other than visible
          # is excluded from a grid track's max-content sizing entirely,
          # so it backfires by letting the track collapse toward nothing.
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

        def row_click_props(step, entity, row, auto_running)
          clickable = !row[:choice].nil?
          # selectable covers two distinct clicks: targeting an
          # already-submitted route for "Clear Ship", or dropping that
          # targeting via deselect_completed_ship!.
          selectable = !row[:select_ship].nil? || row[:deselect_completed]
          blocked = row[:blocked]
          # A settled route from before a later route this turn explored
          # a hex (cancellable_ships) can never be reopened: resubmitting
          # something different risks the game drawing a different tile
          # on replay than it actually did live.
          locked = row[:locked]

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
                # renders as rich content.
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
          # Only this row gets the DOM id the clock writes into directly,
          # so the per-second update lands on the right ship.
          cell_style_progress = cell_style(opacity: 0.8, fontSize: '85%', whiteSpace: 'nowrap')
          return h(:div, wrapper_props, children) unless show_progress_cols

          %i[progress best max].each do |part|
            attrs = progress ? { id: "auto_route_#{part}" } : {}
            text = progress ? progress[part].to_s : ''
            children << h(:div, { style: cell_style_progress, attrs: attrs }, text)
          end

          h(:div, wrapper_props, children)
        end

        def revenue_cell(row)
          row[:revenue] || ''
        end

        # Only shown once a run has finished -- while active, the live
        # counter is attached to the currently-routing ship's own row.
        def auto_route_counter_cell(step, entity)
          return nil unless step.respond_to?(:auto_route_all_elapsed)
          return nil if step.respond_to?(:auto_route_all_active?) && step.auto_route_all_active?(entity)

          elapsed = step.auto_route_all_elapsed(entity)
          return nil unless elapsed

          h(:div, { attrs: { id: 'auto_route_counter' }, style: { opacity: 0.7 } }, "Auto-run Finished: #{elapsed}s")
        end

        def mines_cell(stats)
          return stats[:mines].to_s if stats[:codes].to_s.empty?

          "#{stats[:mines]} (#{stats[:codes]})"
        end

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
