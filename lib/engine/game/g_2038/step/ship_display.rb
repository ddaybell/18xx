# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module Step
        module ShipDisplay
          # Optional hook for the map view: the in-progress trace, so it can
          # be drawn as a live route line while the ship is still flying
          # (before `finish` turns it into a real Engine::Route).
          def live_route_hexes(entity)
            return [] unless entity == current_entity

            @trace
          end

          # Optional hook for the map view: this entity's already-finished
          # routes for this OR turn, so each stays visible in its own color
          # even after control moves on to Dividend/BuyShip/etc (this step
          # stops blocking once every ship has flown, but @ran_ships isn't
          # cleared until `setup` runs again for the next entity's turn).
          def current_turn_routes(entity)
            return [] unless entity == current_entity

            @round.routes.select { |r| @ran_ships.include?(r.train) }
          end

          # Public interface for the dedicated ship-selector tab UI (mirrors
          # the standard route-selector look from other games). Empty when
          # there's nothing to pick (0 or 1 available, unrun ship) -- the
          # single-ship case skips straight to base selection with no click
          # needed -- or once a flight is under way (@trace non-empty),
          # since switching ships mid-flight would abandon the current ship's
          # in-progress trace/cargo/MP spend.  Switching back is only possible
          # via Cancel/End Route.
          def ship_choices(entity)
            return {} unless @trace.empty?

            ships = available_ships(entity)
            return {} if ships.size <= 1

            ships.to_h { |t| ["#{Route::SHIP}#{t.id}", ship_label(t)] }
          end

          # The currently-resolved ship's choice key, for highlighting the
          # selected tab (nil if nothing's resolved yet -- 2+ ships, none
          # picked).
          def current_ship_choice(entity)
            ship = current_ship(entity)
            ship && "#{Route::SHIP}#{ship.id}"
          end

          # Public: one row per owned ship, for the ship-selector UI --
          # covers both still-pickable ships and ones that already finished
          # this OR (with their Explore/Mines column stats), so a
          # multi-ship entity doesn't lose sight of what each ship did once
          # it moves on to the next. Empty when there was never a real ship
          # choice to make (this entity has 1 or 0 ships total).
          #
          # `blocked` distinguishes "not clickable because mid-flight" (the
          # view should still respond to a click, with an explanatory flash
          # message) from "not clickable because this ship already finished
          # this OR" (a genuine dead end -- no message needed). `select_ship`
          # is set only for an already-submitted route still eligible for
          # the single "Clear Ship" control (see select_completed_ship!) --
          # distinct from `choice`, which would actually re-launch a ship,
          # not just target it for cancellation.
          def ship_rows(entity)
            # The Probe always leads, then slowest-ship-first for
            # everything else -- matches the same order the "start of
            # turn" auto-search uses for non-Probe ships. A display-only
            # sort, local to this method -- it never touches entity.
            # trains' own stored (acquisition) order, which other
            # shared display code (e.g. the Spreadsheet tab) still
            # expects to reflect when each ship was actually bought.
            ships = slowest_first(entity, @game.route_trains(entity))
            return [] if ships.empty?

            # current_ship still auto-resolves to the sole remaining
            # unrun ship regardless, but its row's highlight must defer
            # to an explicitly-targeted completed route instead of both
            # showing "selected" at once.
            selected = @selected_completed_ship_id ? nil : current_ship_choice(entity)
            # Blocks switching ships both while actively flying and while
            # a just-finished flight is still awaiting Submit/Discard --
            # see compute_choices' matching guard.
            mid_flight = !@trace.empty? || @rollback&.dig(:finished)
            pending_ship = @rollback&.dig(:finished_ship)
            cancellable = cancellable_ships
            ships.map do |ship|
              if @ran_ships.include?(ship)
                settled_ship_row(entity, ship, cancellable, pending_ship)
              else
                unrun_ship_row(entity, ship, selected, mid_flight)
              end
            end
          end

          # A ship that's already run this OR -- either genuinely
          # submitted (a settled fact) or the currently-pending,
          # not-yet-submitted flight (still the one the action bar
          # belongs to).
          def settled_ship_row(entity, ship, cancellable, pending_ship)
            stats = @route_stats_by_ship[ship]
            route = @round.routes.find { |r| r.train == ship }
            can_cancel = cancellable.include?(ship)
            # Not unconditionally false -- a locally-finished,
            # not-yet-submitted flight (ship == pending_ship) is still
            # the one the player's action bar belongs to; only a
            # genuinely already-*submitted* route is a settled fact,
            # selected only if it's the one the "Clear Ship" control
            # currently targets.
            is_pending = ship == pending_ship
            is_selected = is_pending || (can_cancel && ship.id == @selected_completed_ship_id)
            # Locked: a later route this turn already explored a hex, so
            # this one's own submission can never be safely reopened
            # (cancellable_ships -- a replayed reopen risks the game
            # drawing a different tile/rotation than it actually did
            # live). Flagged separately from `blocked` (an unrun ship
            # mid-flight) so ShipSelector can grey this row out and
            # explain *why* on click.
            locked = !can_cancel && !is_pending
            locking_ship = locking_ship_for(ship) if locked
            {
              choice: nil,
              blocked: false,
              locked: locked,
              select_ship: (can_cancel ? ship : nil),
              label: ship_label(ship),
              selected: is_selected,
              ship_id: ship.id,
              stats: stats && route_stats(stats[:explored], stats[:cargo], stats[:hexes],
                                          max_hexes(entity, ship, stats[:refuels]), stats[:refuels]),
              revenue: route && @game.format_currency(route.revenue),
              color_index: route_color_index(entity, ship),
              locked_by_label: locking_ship && ship_label(locking_ship),
              locked_by_color_index: locking_ship && route_color_index(entity, locking_ship),
              found_at: @auto_all_found_at&.dig(ship.id),
            }
          end

          # A ship that hasn't run this OR yet -- either the live,
          # currently-selected hand-flown flight in progress, a passive
          # preview of its last-OR route (see preview_last_route), or
          # nothing at all yet.
          def unrun_ship_row(entity, ship, selected, mid_flight)
            ship_choice = "#{Route::SHIP}#{ship.id}"
            is_selected = ship_choice == selected
            live_stats = nil
            live_revenue = nil
            is_preview = false
            if mid_flight && is_selected
              live_stats = route_stats(@hexes_explored_this_trip, @cargo, @trace.size - 1,
                                       max_hexes(entity, ship, @refueled_hexes.size), @refueled_hexes.size)
              live_revenue = @game.format_currency(@game.trace_revenue(entity, ship, @trace, @cargo))
            elsif !@auto_fill_declined.include?(ship) && (preview = preview_last_route(entity, ship))
              # Not gated on !mid_flight -- a *different* ship's own
              # blocked row still has a perfectly good preview to show;
              # the player's just not allowed to act on it right now.
              # IS gated on @auto_fill_declined -- "Clear All"
              # (Route#clear_all!) declines every still-unrun ship
              # specifically so this preview stops showing.
              is_preview = true
              explored = preview[:hexes].count { |h| needs_exploration?(h) }
              refuels = preview[:refueled_hex_ids].size
              live_stats = route_stats(explored, preview[:cargo], preview[:hexes].size - 1,
                                       max_hexes(entity, ship, refuels), refuels)
              live_revenue = @game.format_currency(preview[:revenue])
            end
            # Real per-turn "pick this ship" action only exists once
            # there's an actual choice to make -- ship_choices only has
            # this key with 2+ still-unrun ships and nothing flying yet
            # (a lone remaining ship auto-resolves as current -- see
            # current_ship).
            real_choice = ship_choice if !mid_flight && ship_choices(entity).key?(ship_choice)
            # No real choice to make, but a completed route is still
            # targeted for "Clear Selected Route" -- let the row still
            # drop that targeting on click (deselect_completed_ship!),
            # the same symmetric way targeting a completed route
            # already drops this ship's own selection.
            offer_local_deselect = !mid_flight && !real_choice && @selected_completed_ship_id
            {
              choice: real_choice,
              deselect_completed: offer_local_deselect,
              blocked: mid_flight && !is_selected,
              select_ship: nil,
              label: ship_label(ship),
              selected: is_selected,
              ship_id: ship.id,
              stats: live_stats,
              revenue: live_revenue,
              color_index: route_color_index(entity, ship),
              preview: is_preview,
            }
          end

          # Public: {ship => hexes} for every still-unrun ship's own
          # passively-previewed prior route -- lets the map draw all of
          # them simultaneously. A Hash (not just the hexes) so
          # View::Game::Map#render_route_lines can look each ship's own
          # route_color_index up directly, rather than assuming draw
          # order lines up with row color -- it doesn't, the moment a
          # submitted route or the live ship join the same pass.
          def previewed_ship_routes(entity)
            return {} unless entity == current_entity
            return {} unless @trace.empty?

            slowest_first(entity, available_ships(entity)).each_with_object({}) do |ship, h|
              next if @auto_fill_declined.include?(ship)

              route = preview_last_route(entity, ship)
              h[ship] = route[:hexes] if route
            end
          end

          # Public: the ship currently being searched by a live Auto-all
          # run, plus its current best hexes so far -- nil (either) unless
          # there's something real to show. Deliberately separate from
          # previewed_ship_routes above: that one shows a NOT-yet-run
          # ship's own last-recorded (settled) route; this shows the
          # CURRENTLY-searching ship's still-changing, unsettled best,
          # drawn with a dashed line on the map (see map.rb's
          # render_route_lines) so it reads as "still under test," never
          # confusable with a real, finished route.
          def auto_route_all_preview_hexes(entity)
            return [nil, nil] unless auto_route_all_active?(entity)
            return [nil, nil] unless @auto_all_final_ship

            hexes = @game.autorouter.best_hexes
            return [nil, nil] unless hexes

            [@auto_all_final_ship, hexes]
          end

          # Public: this ship's own fixed color slot, same convention
          # the standard RouteSelector already uses (route_selector.rb:
          # `route_prop(@routes.index(route), :color)` -- @routes built
          # once per turn, in a stable order, never reshuffled by what's
          # submitted/active/previewed) -- a ship's color is tied to its
          # position in the fleet, not to what state it's currently in.
          # Shows nil for a ship with no route currently drawn at all (not yet
          # run, not selected, no pending suggestion, no viable prior
          # route to preview) -- same as the standard selector only
          # coloring a row once it actually has a route object to draw.
          def route_color_index(entity, ship)
            has_route = current_turn_routes(entity).any? { |r| r.train == ship } ||
              (ship == current_ship(entity) && !live_route_hexes(entity).empty?) ||
              previewed_ship_routes(entity).key?(ship)
            return nil unless has_route

            slowest_first(entity, @game.route_trains(entity)).index(ship)
          end

          # Public: whether "Suggest Route" is meaningful right now -- a
          # ship must be selected (single-ship case auto-resolves this; a
          # multi-ship entity needs its tab clicked first, same as
          # launching by hand) and not already mid-flight, since the
          # autorouter always plans a fresh flight from a base, never a
          # continuation of one already underway. Whether the autorouter
          # is available *at all* for this game instance (the site's own
          # per-instance auto_routing setting) is a view-level concern --
          # see ship_selector.rb#autorouting_allowed? -- not something
          # the engine checks; every other game's own AutoRouter-backed
          # Auto button is gated the same way, entirely outside the step.
          # The Probe (TSI's pre-float ship) is excluded outright, not
          # just left to find nothing worth suggesting -- its whole "route"
          # is exploration, and which hex to explore next is a player call
          # the autorouter has no business optimizing (it always earns $0
          # by design, so "best revenue" is meaningless for it anyway).
          def suggestable?(entity)
            return false if @rollback&.dig(:finished)
            return false if current_ship(entity)&.name == 'Probe'

            @trace.empty? && !current_ship(entity).nil?
          end

          # Public: whether this ship finished a run in some earlier OR
          # that "Modify"/"Submit" (see render_idle_controls) could
          # actually replay right now. Must agree with ship_rows' own
          # is_preview check (both go through preview_last_route and the
          # same @auto_fill_declined gate -- see Route#clear_all!).
          def previous_route_available?(entity)
            return false unless suggestable?(entity)
            return false if @auto_fill_declined.include?(current_ship(entity))

            !preview_last_route(entity, current_ship(entity)).nil?
          end

          # Public: builds `ship`'s last-recorded route as a local,
          # finished-but-not-yet-submitted flight -- preview_last_route's
          # own replay logic, applied for real rather than just
          # displayed. Used by "Submit All Routes" to rebuild every
          # still-unrun, non-declined ship from its last-OR route in one
          # click. Returns false if there's nothing on record, it's no
          # longer viable, or the ship was explicitly declined (Clear
          # Ship) this turn.
          def apply_previous_route!(entity, ship)
            return false if @auto_fill_declined.include?(ship)

            suggestion = preview_last_route(entity, ship)
            return false unless suggestion

            local_choose!(entity, "#{Route::SHIP}#{ship.id}") if available_ships(entity).size > 1
            apply_pending_suggestion!(entity, suggestion)
            true
          end

          # Public: hands a computed suggestion off to hand-flying --
          # every caller lands in the exact same place: a fully local,
          # not-yet-submitted flight the player can either Submit as-is
          # or back out of the tail end and fly on from wherever they
          # backed up to.
          #
          # Replays the suggestion through local_choose! itself, hop by
          # hop -- exactly as if the player had clicked each of those
          # hexes by hand. A suggestion never explores unexplored
          # territory: the autorouter's own travel-cost graph (Game#
          # hex_bfs) is happy to fly it straight through unexplored
          # hexes to reach an already-known one, and every unexplored
          # hop along the way replays below as a plain FLYOVER, never
          # an Explore.
          def apply_pending_suggestion!(entity, suggestion)
            return unless suggestion

            @round.laid_hexes = []

            hexes = suggestion[:hexes]
            # A once-only queue, not a static hex_id => [entries] lookup
            # -- each entry is removed the moment it's actually applied,
            # so a route that revisits the same hex a second time purely
            # for pathing finds nothing left pending there. This
            # matters because pick_up doubles as an undo whenever the
            # SAME mine is still this ship's own cargo from earlier in
            # this visit (Route#pick_up/#undo_pickup!), so re-attempting
            # it on a later revisit would silently UNDO the earlier
            # pickup instead of no-op'ing.
            pending_cargo = suggestion[:cargo].dup

            local_choose!(entity, hexes.first.id)

            hexes.each_cons(2) do |from, to|
              break if @trace.empty? # maybe_auto_finish! already closed it out

              # A suggestion never *explores* a hex it doesn't need to,
              # but it does fly straight through unexplored ones it has
              # no reason to stop at. An unexplored direct neighbor is
              # only ever reachable as FLYOVER (Skip) or the 2-MP
              # Explore, and since the latter never applies here, the
              # former is always the right one.
              choice = from.neighbors.value?(to) && needs_exploration?(to) ? "#{Route::FLYOVER}#{to.id}" : to.id
              local_choose!(entity, choice)
              next if @trace.empty?

              matches, pending_cargo = pending_cargo.partition { |c| c[:hex_id] == to.id }
              matches.each do |c|
                pickup_choice = c[:mine_idx] ? "#{Route::PICKUP}#{c[:mine_idx]}" : Route::TRANSSHIP
                # Re-validate right before applying -- a suggestion
                # computed against a mine another ship has since
                # claimed would otherwise dispatch a choice
                # compute_choices no longer offers, raising "Invalid
                # route choice" instead of just quietly not picking it up.
                local_choose!(entity, pickup_choice) if choices.key?(pickup_choice)
              end

              # §7.12: apply the plan's own refuel decisions as real
              # actions -- move_to itself never auto-refuels any more,
              # so without this a suggestion's chosen refuel timing
              # would just silently vanish on replay.
              local_choose!(entity, Route::REFUEL) if suggestion[:refueled_hex_ids].include?(to.id) && choices.key?(Route::REFUEL)
            end
          end

          # Public opt-in hook for View::Game::Map#render_ship_marker:
          # the hex the currently-flying ship sits on, which marker icon
          # to show, and where to center it. Rendered as a top-level
          # map overlay (same technique as route lines) rather than a
          # per-hex Part::Icon, since that ties the marker's size to the
          # small-icon slot system, which shrinks/repositions icons to
          # avoid overlapping others. Positioning: dead center for a
          # double-mine hex (both mine circles already sit symmetric
          # around center); a bit below center for everything else
          # (leaves the hex's top-standardized label/single mine
          # circle/city token clear).
          def ship_marker(entity)
            return nil unless entity == current_entity
            return nil if @trace.empty?

            ship = current_ship(entity)
            return nil unless ship

            mp = [[mp_left(entity, ship), 0].max, SHIP_MARKER_MAX_MP].min
            hex = @trace.last
            position = double_mine_hex?(hex) ? :center : :below_center
            [hex, ship_marker_icon_name(ship, mp), position]
          end

          # Shared Probe-then-slowest-first ordering -- see ship_rows'
          # own comment for the full reasoning. Pulled out so other
          # per-ship walks (previewed_ship_routes, best_ship_order) offer
          # ships in the same order they're displayed in, rather than
          # entity.trains' raw acquisition order.
          def slowest_first(entity, ships)
            ships.sort_by { |t| [t.name == 'Probe' ? 0 : 1, @game.ship_distance(entity, t)] }
          end

          # Public: whether the joint "Auto" (autoroute every still-
          # unfilled ship -- see best_ship_order/build_ship_route!) has
          # anything to work with right now.
          def any_suggestable?(entity)
            return false if @rollback&.dig(:finished)
            return false unless @trace.empty?

            available_ships(entity).any? { |t| t.name != 'Probe' }
          end

          # public/icons/g_2038/ship_marker_0.svg .. _10.svg -- covers every
          # ship's distance (max printed is 9, +1 for Torch).
          SHIP_MARKER_MAX_MP = 10

          # public/icons/g_2038/ship_marker_<key>_<mp>.svg -- real per-ship
          # illustrations, added incrementally as each ship type's art is
          # extracted/generated (see ROADMAP.md Phase 12). Any ship name
          # not listed here still falls back to the plain generic marker
          # set above. `max_mp` caps the badge value at this specific
          # ship's own real ceiling (base distance + Torch's +1), narrower
          # than the generic set's 0..10 range, since a real per-ship-type
          # marker can never need a value its own ship could never reach.
          SHIP_MARKER_ART = {
            'Probe' => { key: 'probe', max_mp: 4 },
            '3/2' => { key: '3_2', max_mp: 4 },
            '5/1' => { key: '5_1', max_mp: 6 },
            '4/3' => { key: '4_3', max_mp: 5 },
            '6/2' => { key: '6_2', max_mp: 7 },
            '5/4' => { key: '5_4', max_mp: 6 },
            '7/3' => { key: '7_3', max_mp: 8 },
            '6/5' => { key: '6_5', max_mp: 7 },
            '8/4' => { key: '8_4', max_mp: 9 },
            '7/6' => { key: '7_6', max_mp: 8 },
            '9/5' => { key: '9_5', max_mp: 10 },
            '9/7' => { key: '9_7', max_mp: 10 },
          }.freeze

          def ship_marker_icon_name(ship, mp)
            art = ship && SHIP_MARKER_ART[ship.name]
            return "g_2038/ship_marker_#{mp}" unless art

            "g_2038/ship_marker_#{art[:key]}_#{[mp, art[:max_mp]].min}"
          end

          def double_mine_hex?(hex)
            @game.mine_state[hex.id]&.dig(:mines)&.size == 2
          end
        end
      end
    end
  end
end
