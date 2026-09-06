# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module Step
        module AutoRouteAll
          # Public: searches for and locally builds (finish_route, not
          # yet submitted) `ship`'s best route -- callable for any
          # specific ship, not just current_ship. Selects the ship
          # first if more than one remains unrun (must go through
          # local_choose! rather than a bare @selected_ship_id
          # assignment, so the rest of this entity's state stays
          # consistent with whichever ship is actually being built).
          # Returns the Autorouter::Result if a route was found and
          # applied, nil (having already logged "No profitable route
          # found") if not -- shared by both best_ship_order's own
          # discarded trial orderings and the real, final application of
          # whichever ordering wins (see ship_selector.rb's
          # auto_route_all_button).
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

          # Shared by build_ship_route! above (the synchronous path, still
          # used by try_ordering!'s ranking trials) and the chunked final-
          # build loop in auto_route_all_tick! below, so there's only one
          # place a found Result actually gets turned into a local route.
          def apply_ship_result!(entity, ship, result)
            suggestion = suggestion_from_result(ship, result)
            return nil unless suggestion

            local_choose!(entity, "#{Route::SHIP}#{ship.id}") if available_ships(entity).size > 1
            apply_pending_suggestion!(entity, suggestion)
            result
          end

          # The joint "autoroute everything still unfilled" search (the
          # global "Auto" button -- see ship_selector.rb's auto_route_
          # all_button). Two ships autorouted individually
          # one after another can total less revenue than routing them
          # together in a different order (whichever goes first gets
          # first pick of every mine), so the single-ship search alone
          # can't be trusted once more than one ship is involved. With at
          # most 4 ships this game ever hands any one entity, exhaustively
          # trying every ordering (<=4! = 24) and keeping the best-
          # scoring one is cheap enough to just do outright rather than
          # reach for a heuristic. Driven from start_auto_route_all!/
          # auto_route_all_tick! below, one ordering (via try_ordering!,
          # just below) or one real ship build per call.
          #
          # Default (and floor) for the per-ship, per-ordering trial
          # budget -- now user-configurable as "Ranking timeout" on the
          # Tools tab (see ship_selector.rb's auto_route_all_button and
          # #start_auto_route_all!'s own ranking_timeout param), since a
          # real board can hide a slow ship's true value well past 4s.
          #
          # This value, not the caller's own `timeout:` (the "Search
          # timeout" setting -- long vestigial for G2038: the final
          # per-ship pass always runs Autorouter to full proof and
          # ignores it entirely), bounds each ordering trial -- the "<=24
          # orderings, cheap enough to just do outright" reasoning above
          # only counts *orderings*, not searches: each ordering runs
          # build_ship_route! once per ship in it, so the real total is up
          # to N x N! individual searches (96 for 4 ships), not 24. Every
          # trial is rolled back regardless of outcome (see try_ordering!)
          # and exists only to *rank* orderings against each other --
          # unlike the final per-ship pass (which keeps its results and
          # always runs to full proof), it was never the source of an
          # applied result.
          TRIAL_TIMEOUT = 4.0

          # One ordering's worth of the search above -- shared by both
          # start_auto_route_all!/auto_route_all_tick! below so there's one
          # place this build-then-roll-back logic can drift. Every ship in
          # `order` is actually built (so later ships in the ordering see
          # the earlier ones' mines/stations already claimed, the whole
          # reason ordering matters at all) then fully unwound in reverse
          # before returning.
          #
          # `current_best_total` (the best confirmed total from orderings
          # already tried) lets this bail out of `order` early once it's
          # provably unable to win: before building each remaining ship,
          # `ceiling_remaining` is the sum of Game#solo_ceiling for
          # every not-yet-built ship in this order -- an admissible (never
          # too low) upper bound on what they could contribute even with
          # the whole board to themselves, ignoring MP cost and ignoring
          # that an earlier ship here may have already claimed the best of
          # it. If what's already been earned plus that generous ceiling
          # still can't beat current_best_total, no real search of the
          # remaining ships can possibly change the outcome -- so this
          # order is abandoned (whatever wasn't built simply doesn't add
          # to `total`, correctly scoring this order as a loss) without
          # spending real search time proving it more precisely.
          def try_ordering!(entity, order, timeout, current_best_total)
            # Computed once per ship (not once for the initial sum and
            # again per iteration below) -- solo_ceiling scans every
            # explored mine on the map and isn't cached, so recomputing
            # it a second time for the same ship against identical,
            # unmutated state doubled real cost across up to 24 orderings
            # x 4 ships every single Auto click for no benefit.
            ceilings = order.to_h { |t| [t, @game.solo_ceiling(entity, t)] }
            ceiling_remaining = ceilings.values.sum
            rollbacks = []
            total = 0
            # A ship's trial result is only safe to reuse verbatim in the
            # final-build phase (see auto_route_all_tick!) if its own
            # precondition -- everything earlier ships in THIS ordering
            # left behind -- is guaranteed to be identical there too.
            # That only holds for a PREFIX of ships whose own trial
            # results were each proven_optimal (not merely the best found
            # within `timeout`): a capped, unproven result could differ
            # from what an uncapped final search finds for that same
            # ship, which would change what's left for every ship after
            # it. The first non-proven (or unbuilt, pruned-away) ship
            # ends the reusable prefix; cached stops growing from there,
            # even if trailing ships happened to also prove optimal.
            cached = {}
            chain_valid = true
            # Different orderings sharing the same leading ships (any
            # ordering starting with the same first ship, say, or the
            # same first two, etc.) face an IDENTICAL board at that
            # point, so build_ship_route! -- deterministic given the same
            # starting state and the same TRIAL_TIMEOUT cap -- would
            # search and find the exact same thing again.  @auto_all_prefix_cache
            # (reset per Auto click, see start_auto_route_all!) is keyed
            # by the ship-id sequence seen so far THIS trial, shared across
            # every trial in the whole ranking phase -- a repeat prefix
            # skips straight to re-applying the previously found result
            # (still needed, to consume the same mines for whatever ship
            # comes next in THIS trial) instead of re-searching. Safe
            # regardless of proven_optimal: every trial in the ranking phase
            # runs under the identical TRIAL_TIMEOUT cap, so reusing a
            # capped result is exactly as valid as reusing a proven one
            # here (unlike the final-build cache below, which mixes a capped
            # trial against an uncapped real build and so requires proof).
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
              # A suggested/optimal route doesn't always spend every last
              # MP -- stopping early with MP to spare is often correct,
              # not just possible -- so apply_ship_result! can leave
              # @trace non-empty (mid-flight) rather than relying on
              # maybe_auto_finish!'s own MP-exhaustion trigger. The real
              # final-build phase already covers this via
              # finish_and_submit_choice (see ship_selector.rb's
              # submit_built_ship_route!) before ever touching the next
              # ship; this trial loop builds several ships back-to-back
              # and needs the same explicit finish, or the NEXT ship's own
              # SHIP-selection choice sees a still-live @trace and
              # (correctly, per ship_choices' own rule, but confusingly)
              # gets rejected as invalid. The returned submit choice is
              # discarded -- nothing here is ever actually submitted,
              # this trial gets fully rolled back regardless of outcome.
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

          # Every ship built during this trial (see try_ordering! above)
          # gets torn back down, in reverse build order, once the trial's
          # total is known -- a ranking trial only ever exists to compare
          # orderings against each other, never to keep its own result.
          def rollback_trial_ordering!(entity, rollbacks)
            rollbacks.reverse_each do |r|
              @rollback = r
              rollback_local_flight!(entity)
            end
          end

          # Chunked equivalent of "compute best_ship_order, then actually
          # build+submit each ship in that order" so the caller can yield
          # (a real setTimeout, same as Autorouter's own) between ticks
          # instead of blocking the browser for the whole operation. State
          # lives entirely on this step instance (long-lived on
          # @game.round.steps for the whole round, unlike a view component
          # that a store(:game, ...) call mid-flow could tear down and rebuild)
          # so the view-layer caller can safely resume across ticks purely
          # by calling auto_route_all_tick! again -- it never needs to hold any
          # state of its own besides "keep calling until :done".
          #
          # Deliberately does NOT submit the built route itself
          # (Action::Choose/process_action are Actionable/view-layer
          # concerns, not this step's) -- returns :built so the caller
          # knows a route was just built and it's their turn to submit it
          # before the next tick, :ranking for a trial tick with nothing
          # to submit, or :done once there's nothing left to do at all.
          # Orderings are deduplicated by ship *name*, not object identity --
          # two same-named ships (a twin pair, say two 6/5s) are fully
          # interchangeable as far as the search is concerned (only
          # distance/cargo_holds ever matter, never which physical ship
          # object), so swapping their positions in an ordering can never
          # change the outcome. ships.permutation.to_a treats them as
          # distinct anyway, so without this a twin pair doubles the real
          # work for no possible gain (a triplet multiplies it by 6).
          #
          # The surviving orderings are then resorted so whichever one
          # matches "longest range first" (ships sorted by ship_distance,
          # descending) is tried first, not wherever permutation happened
          # to place it -- the ship with the most to lose from going last
          # is a reasonable guess at the best order, and trying it first
          # means try_ordering!'s own cross-ordering pruning (see its own
          # comment) has a real, high bar to prune every later ordering
          # against from the very start, instead of ratcheting up slowly.
          # This never risks correctness -- every ordering the dedup above
          # kept is still fully tried, just not necessarily in permutation
          # order.
          def start_auto_route_all!(entity, timeout:, ranking_timeout: TRIAL_TIMEOUT)
            # Set first, before any of the setup work below (permutation
            # generation/dedup, the longest-range-first sort) -- all real
            # wall-clock time the click already spent by the time a player
            # sees anything on screen.
            @auto_all_started_at = Time.now
            @auto_all_entity = entity
            # A hard floor, not a clamp against reasonable user values --
            # 0 or negative would spin start_chunk!/run_one_chunk! without
            # ever advancing past the ranking phase's very first combo.
            @auto_all_trial_timeout = [ranking_timeout.to_f, 0.1].max
            @auto_all_final_timeout = timeout
            ships = available_ships(entity).reject { |t| t.name == 'Probe' }
            orderings = ships.size <= 1 ? [] : ships.permutation.to_a.uniq { |order| order.map(&:name) }
            # A SINGLE surviving ordering has nothing to be ranked
            # against, so trialing it is pure waste.
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
            # Per-ship snapshot of found_at_ratio, captured the instant
            # each ship's own final search completes (see the final-build
            # loop below) -- unlike @game.autorouter's own live
            # value, this survives past that ship's own turn so its row
            # can keep showing "how early was this found" after the fact,
            # not just while it's the currently active ship. Never
            # populated for a ship served from the ranking-trial cache
            # (@auto_all_cached_results) -- that reuses a result from a
            # trial's own, already-discarded router instance, with no
            # found_at history of its own to carry over.
            @auto_all_found_at = {}
            @auto_all_trial_index = 0
            @auto_all_final_index = 0
            @auto_all_final_ship = nil
            @auto_all_finished_at = nil
            # Hard backstop, independent of every lower-level timeout
            # Rather than only trusting Autorouter's own internal per-search
            # deadline to always fire correctly, this caps the *entire*
            # multi-ship operation at a generous but genuinely finite multiple
            # of its own worst-case legitimate cost, so a bug anywhere in the
            # chain still can't run forever -- see the check at the top of
            # auto_route_all_tick!.
            # The final phase now runs Autorouter (uncapped -- it
            # runs to proof, no route_timeout involved), so its slice of
            # the backstop can't be derived from a configured timeout any
            # more; a generous flat per-ship allowance replaces it (an
            # hour per ship -- far past anything observed even on the
            # worst real board tested, ~168s in-browser, while still
            # genuinely finite).
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

          # Hard backstop, independent of every lower-level timeout -- see
          # start_auto_route_all!'s own comment on @auto_all_deadline for
          # why this exists at all. Returns true (and tears the run down)
          # only in the "should never happen" case; false otherwise.
          def auto_route_all_deadline_exceeded!(entity)
            return false unless @auto_all_deadline && Time.now > @auto_all_deadline

            @game.log << "#{entity.name}'s Auto route search was stopped after exceeding its own worst-case " \
                         'time budget -- this should never happen; please report it.'
            @auto_all_active = false
            @auto_all_final_ship = nil
            @auto_all_finished_at = Time.now
            true
          end

          # One ordering trial per call (see try_ordering!'s own comment).
          # Returns :ranking while trials remain, nil once every ordering
          # has been tried and it's time to move on to the final build
          # phase below.
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

          # Chunked (start_chunk!/run_one_chunk!/finish_chunk!), not a
          # single blocking call, so the live clock keeps updating and the
          # tab stays responsive throughout each ship's search.
          #
          # The final builds run Autorouter (see autorouter.rb) to full
          # proof. The RANKING TRIALS above (build_ship_ route!, called
          # from try_ordering!) also run it, via its own chunked interface
          # bounded externally by TRIAL_TIMEOUT rather than run to proof
          #
          # @auto_all_cached_results (set alongside @auto_all_best_order in
          # run_auto_route_ranking_trial_tick! above -- see try_ordering!'s
          # own comment on the prefix-validity reasoning) lets a ship
          # whose ranking trial already reached proven_optimal within
          # TRIAL_TIMEOUT skip a second, identical search here entirely:
          # on a simple board the ranking phase can fully solve a ship in
          # well under 4s, and re-running that same deterministic search a
          # second time (once per ordering trial already, trials can
          # number up to N!, and then again here) would waste real time
          # proving the same already-proven answer again for nothing. Both
          # the ranking trial and this final build always run to full
          # proof. Since both stages run the identical deterministic search
          # under identical conditions, a cached ship's route is guaranteed
          # to be exactly what a real (re-)search would produce anyway. A
          # user manually cutting a ship's OWN final build short
          # via "Accept & next ship" doesn't affect this: that only ever
          # touches the ship being built live, never a ranking trial, so
          # it can't poison what gets cached for a later ship.
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
              # ship's own start_chunk! (which would reset the router's
              # internal found_at bookkeeping).
              @auto_all_found_at[ship.id] = router.found_at_ratio
              next unless apply_ship_result!(entity, ship, result)

              return :built
            end

            @auto_all_active = false
            @auto_all_final_ship = nil
            @auto_all_finished_at = Time.now
            :done
          end

          # Live progress, read directly off this (long-lived, one-per-
          # round -- NOT one-per-entity) step instance rather than through
          # Snabberb's own store mechanism.
          #
          # `entity` here guards against a second bug this same sharing
          # caused: since this ONE step instance's @auto_all_* ivars are
          # shared across every corp's turn all round, they kept showing
          # whichever corp's run happened most recently even while looking
          # at a totally different corp that never had Auto clicked at
          # all. Only report anything when the caller's current entity
          # matches whichever entity start_auto_route_all! was actually invoked for.
          def auto_route_all_active?(entity)
            @auto_all_active && entity == @auto_all_entity
          end

          # Public: user-initiated "accept this ship's current best and
          # move on" (see ship_selector.rb's skip button). Only
          # meaningful during the final phase while the engine actually
          # holds a best (the engine's stop_early! no-ops otherwise);
          # the tick chain then completes the ship on its next tick,
          # submits it, and proceeds to the next ship exactly as if the
          # proof had finished naturally.
          def skip_current_ship_search!(entity)
            return unless auto_route_all_active?(entity)
            return unless @auto_all_final_ship

            @game.autorouter.stop_early!
          end

          # Public: the ship id of whichever ship the final phase's
          # chunked search is CURRENTLY building for this entity, or nil
          # (during trials, or once the run's finished) -- lets
          # ShipSelector attach the live counter to that ship's own row
          # instead of showing it detached below the whole list. Only
          # meaningful during the final phase; the ranking trials run
          # each ordering's own throwaway searches without ever settling
          # on "the ship currently being routed" in a way worth
          # displaying against a row.
          # Read-only peek, never mutates search state (unlike
          # @auto_all_final_ship itself, whose nil/non-nil is load-
          # bearing for start_chunk!'s own "have I already begun this
          # ship's search" check in the tick loop -- setting it eagerly
          # here would skip that call entirely for the next ship).
          #
          # Needed because @auto_all_final_ship is deliberately nil for
          # exactly one tick boundary: the tick that finishes a ship
          # clears it to nil (see the final-phase loop) BEFORE returning
          # :built, and it's only reassigned to the NEXT ship on some
          # later tick -- but :built is also the one moment that
          # actually triggers a real re-render (ship_selector.rb's
          # run_auto_route_all_tick!).
          def auto_route_all_current_ship_id(entity)
            return nil unless auto_route_all_active?(entity)
            return @auto_all_final_ship.id if @auto_all_final_ship
            return nil if @auto_all_trial_index < @auto_all_orderings.size

            next_ship = @auto_all_best_order[@auto_all_final_index..]&.find { |t| available_ships(entity).include?(t) }
            next_ship&.id
          end

          # Frozen at whatever it read at completion (@auto_all_finished_at),
          # not live Time.now, once the run is done -- otherwise this kept
          # recomputing against the current time on every *later* re-render
          # this same step/game triggers for completely unrelated reasons
          # (another player's action, anything else that calls
          # store(:game, ...)), so a "Finished: 12s" label would silently
          # keep climbing indefinitely long after the search itself had
          # actually stopped.
          def auto_route_all_elapsed(entity)
            return nil unless @auto_all_started_at && entity == @auto_all_entity

            ((@auto_all_finished_at || Time.now) - @auto_all_started_at).round
          end

          # Entity-agnostic, unlike auto_route_all_active? above -- this
          # is only ever used to decide whether the view's own live-clock
          # setInterval (ship_selector.rb's start_auto_route_clock!) should
          # keep ticking at all. That has to stay true for as long as the
          # search itself is running, even if the player has since
          # switched to looking at a different corp's own (unrelated,
          # correctly nil) panel -- if this were entity-scoped too, the
          # clock would clear itself the instant the player looked away,
          # and the counter would freeze instead of catching back up once
          # they looked back.
          def auto_route_all_running?
            @auto_all_active
          end

          # Public: ship/hexes/cargo/revenue computed from an
          # Autorouter::Result, ready for apply_pending_suggestion! --
          # or nil (having already logged "No profitable route found")
          # if the search came up empty. Pure computation; nothing here
          # touches real game state.
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
