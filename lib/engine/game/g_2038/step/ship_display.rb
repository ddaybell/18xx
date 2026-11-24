# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module Step
        module ShipDisplay
          def live_route_hexes(entity)
            return [] unless entity == current_entity

            @trace
          end

          # @ran_ships isn't cleared until `setup` runs again for the next
          # entity's turn, so these stay visible after control moves on.
          def current_turn_routes(entity)
            return [] unless entity == current_entity

            @round.routes.select { |r| @ran_ships.include?(r.train) }
          end

          def ship_choices(entity)
            return {} unless @trace.empty?

            ships = available_ships(entity)
            return {} if ships.size <= 1

            ships.to_h { |t| ["#{Route::SHIP}#{t.id}", ship_label(t)] }
          end

          def current_ship_choice(entity)
            ship = current_ship(entity)
            ship && "#{Route::SHIP}#{ship.id}"
          end

          # `blocked` is "not clickable because mid-flight" (click still
          # responds, with a flash message) vs. "not clickable, already
          # finished this OR" (a dead end, no message). `select_ship` is
          # set only for the "Clear Ship" control, distinct from `choice`
          # (which would re-launch a ship).
          def ship_rows(entity)
            ships = slowest_first(entity, @game.route_trains(entity))
            return [] if ships.empty?

            selected = @selected_completed_ship_id ? nil : current_ship_choice(entity)
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

          def settled_ship_row(entity, ship, cancellable, pending_ship)
            stats = @route_stats_by_ship[ship]
            route = @round.routes.find { |r| r.train == ship }
            can_cancel = cancellable.include?(ship)
            is_pending = ship == pending_ship
            is_selected = is_pending || (can_cancel && ship.id == @selected_completed_ship_id)
            # cancellable_ships excludes a route once a later one this
            # turn has explored a hex -- reopening it risks a replay
            # drawing a different tile/rotation than it actually did live.
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
                                          max_hexes(entity, ship, stats[:refuel_mp]), stats[:refuels]),
              revenue: route && @game.format_currency(route.revenue),
              color_index: route_color_index(entity, ship),
              locked_by_label: locking_ship && ship_label(locking_ship),
              locked_by_color_index: locking_ship && route_color_index(entity, locking_ship),
              found_at: @auto_all_found_at&.dig(ship.id),
            }
          end

          def unrun_ship_row(entity, ship, selected, mid_flight)
            ship_choice = "#{Route::SHIP}#{ship.id}"
            is_selected = ship_choice == selected
            live_stats = nil
            live_revenue = nil
            is_preview = false
            if mid_flight && is_selected
              live_stats = route_stats(@hexes_explored_this_trip, @cargo, @trace.size - 1,
                                       max_hexes(entity, ship, @refuel_mp_gained), @refueled_hexes.size)
              live_revenue = @game.format_currency(@game.trace_revenue(entity, ship, @trace, @cargo))
            elsif !@auto_fill_declined.include?(ship) && (preview = preview_last_route(entity, ship))
              # Not gated on !mid_flight -- a different ship's blocked
              # row still has a preview to show, just not act on.
              is_preview = true
              explored = preview[:hexes].count { |h| needs_exploration?(h) }
              refuels = preview[:refueled_hex_ids].size
              live_stats = route_stats(explored, preview[:cargo], preview[:hexes].size - 1,
                                       max_hexes(entity, ship, preview[:refuel_mp]), refuels)
              live_revenue = @game.format_currency(preview[:revenue])
            end
            real_choice = ship_choice if !mid_flight && ship_choices(entity).key?(ship_choice)
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

          # A Hash, not just the hexes, so Map#render_route_lines can look
          # each ship's route_color_index up directly rather than
          # assuming draw order lines up with row color.
          def previewed_ship_routes(entity)
            return {} unless entity == current_entity
            return {} unless @trace.empty?

            slowest_first(entity, available_ships(entity)).each_with_object({}) do |ship, h|
              next if @auto_fill_declined.include?(ship)

              route = preview_last_route(entity, ship)
              h[ship] = route[:hexes] if route
            end
          end

          # Separate from previewed_ship_routes: that shows a settled
          # last-OR route; this shows the still-changing best-so-far of a
          # live search, drawn dashed (map.rb) so it reads as unsettled.
          def auto_route_all_preview_hexes(entity)
            return [nil, nil] unless auto_route_all_active?(entity)
            return [nil, nil] unless @auto_all_final_ship

            hexes = @game.autorouter.best_hexes
            return [nil, nil] unless hexes

            [@auto_all_final_ship, hexes]
          end

          # Color is tied to a ship's position in the fleet, not to what
          # state it's currently in -- nil when nothing's drawn at all.
          def route_color_index(entity, ship)
            has_route = current_turn_routes(entity).any? { |r| r.train == ship } ||
              (ship == current_ship(entity) && !live_route_hexes(entity).empty?) ||
              previewed_ship_routes(entity).key?(ship)
            return nil unless has_route

            slowest_first(entity, @game.route_trains(entity)).index(ship)
          end

          # The Probe is excluded outright, not left to find nothing
          # worth suggesting -- it always earns $0 by design, so "best
          # revenue" is meaningless for it, and which hex to explore next
          # is a player call, not the autorouter's.
          def suggestable?(entity)
            return false if @rollback&.dig(:finished)
            return false if current_ship(entity)&.name == 'Probe'

            @trace.empty? && !current_ship(entity).nil?
          end

          # Must agree with ship_rows' own is_preview check -- both go
          # through preview_last_route and the same @auto_fill_declined gate.
          def previous_route_available?(entity)
            return false unless suggestable?(entity)
            return false if @auto_fill_declined.include?(current_ship(entity))

            !preview_last_route(entity, current_ship(entity)).nil?
          end

          def apply_previous_route!(entity, ship)
            return false if @auto_fill_declined.include?(ship)

            suggestion = preview_last_route(entity, ship)
            return false unless suggestion

            local_choose!(entity, "#{Route::SHIP}#{ship.id}") if available_ships(entity).size > 1
            apply_pending_suggestion!(entity, suggestion)
            true
          end

          def apply_pending_suggestion!(entity, suggestion)
            return unless suggestion

            @round.laid_hexes = []

            hexes = suggestion[:hexes]
            # Removed as applied, not a static lookup -- otherwise a
            # route revisiting the same hex would re-trigger the pickup,
            # which doubles as an undo of that same cargo (Route#pick_up).
            pending_cargo = suggestion[:cargo].dup

            local_choose!(entity, hexes.first.id)

            hexes.each_cons(2) do |from, to|
              break if @trace.empty? # maybe_auto_finish! already closed it out

              choice = from.neighbors.value?(to) && needs_exploration?(to) ? "#{Route::FLYOVER}#{to.id}" : to.id
              local_choose!(entity, choice)
              next if @trace.empty?

              matches, pending_cargo = pending_cargo.partition { |c| c[:hex_id] == to.id }
              matches.each do |c|
                pickup_choice = c[:mine_idx] ? "#{Route::PICKUP}#{c[:mine_idx]}" : Route::TRANSSHIP
                # Re-validate -- a mine claimed by another ship since this
                # suggestion was computed would otherwise raise "Invalid
                # route choice" instead of just skipping it.
                local_choose!(entity, pickup_choice) if choices.key?(pickup_choice)
              end

              # §7.12: move_to itself never auto-refuels any more.
              local_choose!(entity, Route::REFUEL) if suggestion[:refueled_hex_ids].include?(to.id) && choices.key?(Route::REFUEL)
            end
          end

          # Opt-in hook for View::Game::Map#render_ship_marker.
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

          def slowest_first(entity, ships)
            ships.sort_by { |t| [t.name == 'Probe' ? 0 : 1, @game.ship_distance(entity, t)] }
          end

          def any_suggestable?(entity)
            return false if @rollback&.dig(:finished)
            return false unless @trace.empty?

            available_ships(entity).any? { |t| t.name != 'Probe' }
          end

          # public/icons/g_2038/ship_marker_0.svg .. _10.svg
          SHIP_MARKER_MAX_MP = 10

          # public/icons/g_2038/ship_marker_<key>_<mp>.svg -- any ship name
          # not listed here falls back to the generic marker set above.
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
