# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module Step
        module AutoRouteAll
          # Must select the ship via local_choose!, not a bare
          # @selected_ship_id assignment, so the rest of this entity's
          # state stays consistent with whichever ship is being built.
          def build_ship_route!(entity, ship, timeout: Autorouter::DEFAULT_TIMEOUT)
            router = @game.autorouter
            router.start_chunk!(entity, ship)
            deadline = Time.now + timeout
            done = false
            loop do
              done = router.run_one_chunk!
              break if done || Time.now > deadline
            end
            result = router.finish_chunk!
            result.proven_optimal = done if result
            apply_ship_result!(entity, ship, result)
          end

          def apply_ship_result!(entity, ship, result)
            suggestion = suggestion_from_result(ship, result)
            return nil unless suggestion

            local_choose!(entity, "#{Route::SHIP}#{ship.id}") if available_ships(entity).size > 1
            apply_pending_suggestion!(entity, suggestion)
            result
          end

          # Two ships autorouted individually can total less revenue than
          # routing them together in a different order (whichever goes
          # first gets first pick of every mine) -- with at most 4
          # ships, exhaustively trying every ordering (<=4! = 24) is
          # cheap enough to just do outright.
          #
          # Bounds each ordering trial, not the final per-ship pass
          # (which always runs Autorouter to full proof) -- real total
          # search count is up to N x N! (96 for 4 ships), not just 24.
          TRIAL_TIMEOUT = 4.0

          # Builds every ship in `order` (so later ships see earlier
          # ones' mines/stations already claimed), then fully unwinds in
          # reverse. `ceiling_remaining` (sum of Game#solo_ceiling for
          # not-yet-built ships, an admissible upper bound) lets this
          # bail out early: if what's already earned plus that generous
          # ceiling still can't beat current_best_total, the order is
          # abandoned without spending real search time proving it.
          def try_ordering!(entity, order, timeout, current_best_total)
            ceilings = order.to_h { |t| [t, @game.solo_ceiling(entity, t)] }
            ceiling_remaining = ceilings.values.sum
            rollbacks = []
            total = 0
            # Only a PREFIX of ships whose trial results were each
            # proven_optimal (not merely best-found-within-timeout) is
            # safe to reuse verbatim in the final-build phase -- the
            # first non-proven ship ends the reusable prefix.
            cached = {}
            chain_valid = true
            # Different orderings sharing the same leading ships face an
            # identical, deterministic board at that point -- a repeat
            # prefix (keyed by ship-id sequence) skips straight to
            # re-applying the previously found result.
            @auto_all_prefix_cache ||= {}
            prefix_ids = []

            order.each do |ship|
              break if total + ceiling_remaining <= current_best_total

              ceiling_remaining -= ceilings[ship]
              prefix_ids << ship.id
              prefix_key = prefix_ids.join(',')

              @rollback = capture_rollback!
              memo = @auto_all_prefix_cache[prefix_key]
              result = memo ? apply_ship_result!(entity, ship, memo) : build_ship_route!(entity, ship, timeout: timeout)
              # apply_ship_result! can leave @trace non-empty
              # (mid-flight) -- the next ship's SHIP-selection choice
              # would see that and get rejected as invalid. The
              # returned submit choice is discarded; this trial is
              # rolled back regardless of outcome.
              finish_and_submit_choice(entity) if result
              @auto_all_prefix_cache[prefix_key] ||= result if result
              total += result.revenue if result
              rollbacks << @rollback

              if chain_valid && result&.proven_optimal
                cached[ship.id] = result
              else
                chain_valid = false
              end
            end

            rollback_trial_ordering!(entity, rollbacks)

            { total: total, cached: cached }
          end

          def rollback_trial_ordering!(entity, rollbacks)
            rollbacks.reverse_each do |r|
              @rollback = r
              rollback_local_flight!(entity)
            end
          end

          # State lives on this step instance (long-lived on
          # @game.round.steps), not a view component, so the caller can
          # safely resume across ticks just by calling
          # auto_route_all_tick! again. Deliberately does NOT submit the
          # built route itself -- returns :built (caller's turn to
          # submit before the next tick), :ranking, or :done.
          #
          # Orderings are deduplicated by ship *name*: two same-named
          # ships are fully interchangeable for the search (only
          # distance/cargo_holds matter), but ships.permutation.to_a
          # treats them as distinct, doubling real work for a twin pair
          # with no possible gain.
          #
          # Surviving orderings are resorted so "longest range first" is
          # tried first -- the ship with the most to lose from going
          # last is a reasonable guess at the best order, giving
          # try_ordering!'s pruning a high bar from the start.
          def start_auto_route_all!(entity, timeout:, ranking_timeout: TRIAL_TIMEOUT)
            @auto_all_started_at = Time.now
            @auto_all_entity = entity
            # A hard floor: 0 or negative would spin start_chunk!/
            # run_one_chunk! without ever advancing past the ranking
            # phase's first combo.
            @auto_all_trial_timeout = [ranking_timeout.to_f, 0.1].max
            @auto_all_final_timeout = timeout
            ships = available_ships(entity).reject { |t| t.name == 'Probe' }
            orderings = ships.size <= 1 ? [] : ships.permutation.to_a.uniq { |order| order.map(&:name) }
            # A single surviving ordering has nothing to rank against.
            orderings = [] if orderings.size == 1
            unless orderings.empty?
              heuristic_first = ships.sort_by { |t| -@game.ship_distance(entity, t) }
              orderings = [heuristic_first, *(orderings - [heuristic_first])] if orderings.include?(heuristic_first)
            end
            @auto_all_orderings = orderings
            @auto_all_best_order = ships
            @auto_all_best_total = -1
            @auto_all_cached_results = nil
            @auto_all_prefix_cache = {}
            # Survives past a ship's own turn, unlike @game.autorouter's
            # live found_at_ratio, so its row keeps showing "how early
            # was this found" after the fact. Never populated for a
            # ship served from the ranking-trial cache -- that reuses a
            # result from an already-discarded router instance.
            @auto_all_found_at = {}
            @auto_all_trial_index = 0
            @auto_all_final_index = 0
            @auto_all_final_ship = nil
            @auto_all_finished_at = nil
            # Caps the *entire* multi-ship operation at a generous but
            # finite multiple of its worst-case legitimate cost, so a
            # bug anywhere in the chain still can't run forever. The
            # final phase runs Autorouter uncapped (to proof), so an
            # hour-per-ship flat allowance stands in for it -- far past
            # anything observed (~168s in-browser on the worst board
            # tested) while still genuinely finite.
            worst_case_trials = orderings.size * @auto_all_trial_timeout * [ships.size, 1].max
            worst_case_final = 3600 * [ships.size, 1].max
            @auto_all_deadline = @auto_all_started_at + worst_case_trials + worst_case_final + 30
            @auto_all_active = true
          end

          def auto_route_all_tick!(entity)
            return :done if auto_route_all_deadline_exceeded!(entity)

            ranking_status = run_auto_route_ranking_trial_tick!(entity)
            return ranking_status if ranking_status

            run_auto_route_final_build_tick!(entity)
          end

          # Returns true (and tears the run down) only in the "should
          # never happen" case; false otherwise.
          def auto_route_all_deadline_exceeded!(entity)
            return false unless @auto_all_deadline && Time.now > @auto_all_deadline

            @game.log << "#{entity.name}'s Auto route search was stopped after exceeding its own worst-case " \
                         'time budget -- this should never happen; please report it.'
            @auto_all_active = false
            @auto_all_final_ship = nil
            @auto_all_finished_at = Time.now
            true
          end

          def run_auto_route_ranking_trial_tick!(entity)
            return nil unless @auto_all_trial_index < @auto_all_orderings.size

            order = @auto_all_orderings[@auto_all_trial_index]
            result = try_ordering!(entity, order, @auto_all_trial_timeout, @auto_all_best_total)
            if result[:total] > @auto_all_best_total
              @auto_all_best_total = result[:total]
              @auto_all_best_order = order
              @auto_all_cached_results = result[:cached]
            end
            @auto_all_trial_index += 1
            :ranking
          end

          # @auto_all_cached_results lets a ship whose ranking trial
          # already reached proven_optimal within TRIAL_TIMEOUT skip a
          # second, identical search entirely -- both stages run the
          # identical deterministic search, so the cached route is
          # guaranteed to match a real (re-)search.
          def run_auto_route_final_build_tick!(entity)
            while @auto_all_final_index < @auto_all_best_order.size
              ship = @auto_all_best_order[@auto_all_final_index]
              unless available_ships(entity).include?(ship)
                @auto_all_final_index += 1
                next
              end

              if @auto_all_final_ship.nil? && (cached = @auto_all_cached_results&.dig(ship.id))
                @auto_all_final_index += 1
                next unless apply_ship_result!(entity, ship, cached)

                return :built
              end

              router = @game.autorouter
              router.start_chunk!(entity, ship) if @auto_all_final_ship != ship
              @auto_all_final_ship = ship

              return :searching unless router.run_one_chunk!

              @auto_all_final_ship = nil
              @auto_all_final_index += 1
              result = router.finish_chunk!
              # Captured before apply_ship_result! moves on to the next
              # ship's start_chunk!, which resets this bookkeeping.
              @auto_all_found_at[ship.id] = router.found_at_ratio
              next unless apply_ship_result!(entity, ship, result)

              return :built
            end

            @auto_all_active = false
            @auto_all_final_ship = nil
            @auto_all_finished_at = Time.now
            :done
          end

          # `entity` guards against a real bug: this step instance is
          # one-per-round, not one-per-entity, so its @auto_all_* ivars
          # are shared across every corp's turn -- without this check
          # they kept showing whichever corp's run happened most
          # recently, even for a corp that never had Auto clicked.
          def auto_route_all_active?(entity)
            @auto_all_active && entity == @auto_all_entity
          end

          def skip_current_ship_search!(entity)
            return unless auto_route_all_active?(entity)
            return unless @auto_all_final_ship

            @game.autorouter.stop_early!
          end

          # @auto_all_final_ship is deliberately nil for exactly one
          # tick boundary (cleared before :built returns, reassigned to
          # the next ship only on a later tick) -- this falls back to
          # the next available ship in that window rather than reporting
          # nothing.
          def auto_route_all_current_ship_id(entity)
            return nil unless auto_route_all_active?(entity)
            return @auto_all_final_ship.id if @auto_all_final_ship
            return nil if @auto_all_trial_index < @auto_all_orderings.size

            next_ship = @auto_all_best_order[@auto_all_final_index..]&.find { |t| available_ships(entity).include?(t) }
            next_ship&.id
          end

          # Frozen at @auto_all_finished_at, not live Time.now, once the
          # run is done -- otherwise a "Finished: 12s" label would
          # silently keep climbing on every later re-render.
          def auto_route_all_elapsed(entity)
            return nil unless @auto_all_started_at && entity == @auto_all_entity

            ((@auto_all_finished_at || Time.now) - @auto_all_started_at).round
          end

          # Entity-agnostic, unlike auto_route_all_active? -- if this
          # were entity-scoped too, the view's live clock would clear
          # itself the instant the player looked away to another corp.
          def auto_route_all_running?
            @auto_all_active
          end

          def suggestion_from_result(ship, result)
            unless result
              @log << "No profitable route found for #{ship_label(ship)}"
              return nil
            end

            { ship: ship, hexes: result.hexes, cargo: result.cargo, revenue: result.revenue,
              refueled_hex_ids: result.refueled_hex_ids }
          end
        end
      end
    end
  end
end
