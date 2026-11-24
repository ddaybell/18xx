# frozen_string_literal: true

require_relative 'combo_generator'

module Engine
  module Game
    module G2038
      # Pulls candidate cargo combinations from ComboGenerator in
      # strictly decreasing ceiling order. The search can stop the
      # moment the next combo's ceiling can no longer beat the best
      # REAL revenue already found -- a provable stopping point, not a
      # timeout or a guess, since every ceiling is admissible (never
      # too low) and ComboGenerator guarantees later combos never rank
      # higher.
      #
      # Not simply "first feasible combo wins": a combo's ceiling
      # assumes every slot could independently reach its own best-case
      # bonus, which a single real route (one actual delivery
      # destination) often can't simultaneously realize -- so a fully
      # feasible combo can still fall short of its own ceiling.
      class Autorouter
        # timed_out is always false -- this engine has no time cap, it
        # runs to proof. certified_bound is the proven maximum any route
        # could still pay when a run stops early via #stop_early!.
        # proven_optimal is true only for a full run to proof.
        Result = Struct.new(:hexes, :cargo, :revenue, :timed_out, :elapsed, :combos_tried,
                            :destination_hex_id, :certified_bound, :proven_optimal, :refueled_hex_ids,
                            keyword_init: true)

        # A CHUNK is the amount of time the autorouter blocks the browser
        # from processing other events.  At the end of each CHUNK,
        # control is given back to the browser to process other events
        # (e.g. user inputs, screen renders, etc.)
        CHUNK_DURATION = 0.2

        def initialize(game)
          @game = game
        end

        # One full search per possible destination-ore focus (see
        # #scoped_slots_for), not just an optimization: ComboGenerator
        # needs per-slot values to be additive, but Game#candidate_slots'
        # combined ceiling (every slot crediting its OWN best-case home
        # bonus) isn't separable -- it assumes multiple different
        # bonus-paying hexes could all be the same real ending at once.
        # Without the split, proof of optimality on a real 39-candidate,
        # 7-hold board took 40,000+ combos and never finished in 10
        # minutes. Within one sweep, every slot credits a bonus for only
        # that sweep's ore, so values genuinely can be summed and
        # trusted as a real joint ceiling.
        def suggest_route(entity, ship)
          start_chunk!(entity, ship)
          loop { break if run_one_chunk! }
          finish_chunk!
        end

        # Chunked interface (Step::Route#auto_route_all_tick! drives it).
        # The only way a run ends before full proof is an external
        # #stop_early! call (the "Accept & next ship" skip button).
        def start_chunk!(entity, ship)
          @entity = entity
          @ship = ship
          @started_at = Time.now
          @stopped_early = false
          @stopped_bound = nil
          @best = nil
          @total_combos = 0
          @cur_ceiling = nil
          @generators = []
          @peeked = []
          @done = false

          @prof = Hash.new(0.0)
          @prof_n = Hash.new(0)

          @best_found_at_combo = nil
          @holds = @game.cargo_holds_for_ship(ship)
          slots = @holds.zero? ? [] : reachable_slots(entity, ship)
          @ctx = slots.empty? ? nil : build_search_context(entity, ship, slots)
          return unless @ctx

          # Memoized across the WHOLE run, all sweeps included --
          # #search_goals depends only on which hexes must be visited,
          # never on sweep/cargo values. Per profiling, the per-combo
          # search was ~99% of a 313s real-board run, much of it
          # byte-identical repeat searches.
          @goal_memo = {}

          focus_ores = @game.home_delivery_bonuses.values.map(&:first).uniq
          focus_ores = [nil] if focus_ores.empty?
          sweep_slot_lists = focus_ores.map { |ore| scoped_slots_for(entity, ship, slots, ore) }

          # One merged frontier across every (sweep, combo size)
          # generator -- the moment the single best peeked ceiling
          # across all of them drops to or below the floor, nothing
          # anywhere can beat it.
          @generators = sweep_slot_lists.flat_map do |sweep_slots|
            max_size = [@holds, sweep_slots.size].min
            next [] if max_size.zero?

            (1..max_size).map { |r| ComboGenerator.new(sweep_slots, r) }
          end
          @peeked = @generators.map(&:next_combo)

          # Ranks launch bases so geometrically_feasible?'s `.any?` checks
          # the most promising one first -- only changes search order,
          # never whether a combo is accepted.
          top_combo_idxs = sweep_slot_lists.map do |sweep_slots|
            top = sweep_slots.sort_by(&:value).last([@holds, sweep_slots.size].min)
            top.map { |s| @ctx[:index][s.hex_id] }
          end
          @ctx[:launch_idxs] = @ctx[:launch_idxs].sort_by do |launch_idx|
            top_combo_idxs.sum { |idxs| mst_lower_bound([launch_idx, *idxs]) }
          end
        end

        def run_one_chunk!
          deadline = Time.now + CHUNK_DURATION

          until search_done?
            step_combo!

            return false if !search_done? && Time.now > deadline
          end

          true
        end

        def finish_chunk!
          return nil unless @best

          Result.new(hexes: @best[:hexes], cargo: @best[:cargo], revenue: @best[:revenue],
                     timed_out: false, elapsed: (Time.now - @started_at).round(2),
                     combos_tried: @total_combos, destination_hex_id: @best[:hexes].last.id,
                     certified_bound: @stopped_early ? @stopped_bound : @best[:revenue],
                     proven_optimal: !@stopped_early, refueled_hex_ids: @best[:refueled_hex_ids])
        end

        # The highest ceiling among every generator's currently-peeked
        # candidate -- since ceilings are admissible, this is a proven
        # statement about the whole remaining search space at any
        # moment.
        def certified_bound
          @cur_ceiling
        end

        def best_so_far
          @best && @best[:revenue]
        end

        def best_hexes
          @best && @best[:hexes]
        end

        # No-op until a first best exists.
        def stop_early!
          return unless @best

          @stopped_early = true
          @stopped_bound = certified_bound
          @done = true
          @cur_ceiling = nil
        end

        def combos_so_far
          @total_combos || 0
        end

        attr_reader :best_found_at_combo

        # An honest, live "found early vs found late" signal, not a
        # fabricated confidence percentage -- shrinks the longer a run
        # goes without improving.
        def found_at_ratio
          return nil unless @best_found_at_combo && @total_combos&.positive?

          @best_found_at_combo.to_f / @total_combos
        end

        def profile_summary
          return 'no run recorded' unless @prof

          phases = @prof.keys.sort_by { |k| -@prof[k] }.map { |k| "#{k}: #{@prof[k].round(1)}s" }
          counts = @prof_n.map { |k, v| "#{k}=#{v}" }.join(', ')
          (phases + [counts]).join("\n")
        end

        # Console messages render even while a synchronous Opal run has
        # the tab itself frozen, so this heartbeat shows real-time
        # progress without waiting for the final alert.
        PROGRESS_LOG_EVERY = 1000

        def log_progress!
          elapsed = (Time.now - @started_at).round(1)
          bound = certified_bound
          active = @peeked.count { |p| p }
          msg = "Autorouter: combos=#{@total_combos} elapsed=#{elapsed}s " \
                "best=$#{@best ? @best[:revenue] : 0} bound<=$#{bound || '?'} " \
                "active=#{active}/#{@generators.size} | " \
                "search=#{@prof[:search].round(1)}s " \
                "(searches=#{@prof_n[:searches]} memo=#{@prof_n[:memo_hits]})"
          if RUBY_ENGINE == 'opal'
            %x{console.log(#{msg})}
          else
            warn msg
          end
        end

        private

        def search_done?
          @done
        end

        # Ends the instant the global best ceiling can no longer beat
        # the best VERIFIED revenue found so far. The floor only rises
        # after #build_flight succeeds, turning the abstract feasibility
        # answer into a concrete, MP-verified path -- never a paper claim.
        def step_combo!
          t0 = Time.now
          idx, ceiling = best_peeked_index(@peeked)
          @prof[:peek] += Time.now - t0
          floor = @best ? @best[:revenue] : -1
          @cur_ceiling = idx ? ceiling : nil

          if !idx || @cur_ceiling <= floor
            @done = true
            @cur_ceiling = nil
            return
          end

          combo = @peeked[idx]
          @total_combos += 1
          log_progress! if (@total_combos % PROGRESS_LOG_EVERY).zero?

          t0 = Time.now
          found = route_for_combo(@entity, @ship, combo)
          @prof[:route] += Time.now - t0

          if found && found[:revenue] > floor
            t0 = Time.now
            built = build_flight(combo, found[:destination_hex_id])
            @prof[:build] += Time.now - t0
            @prof_n[:builds] += 1
            if built && built[:revenue] > floor
              @best = built
              @best_found_at_combo = @total_combos
            end
          end

          t0 = Time.now
          @peeked[idx] = @generators[idx].next_combo
          @prof[:next_combo] += Time.now - t0
        end

        # Returns [best_idx, best_ceiling] -- the caller used to
        # recompute the ceiling a second time right after this method
        # already found it; returning it here avoids that redundant sum
        # over tens of thousands of combos.
        def best_peeked_index(peeked)
          best_idx = nil
          best_ceiling = -1

          peeked.each_with_index do |combo, i|
            next unless combo

            ceiling = combo.sum(&:value)
            next unless ceiling > best_ceiling

            best_ceiling = ceiling
            best_idx = i
          end

          [best_idx, best_idx && best_ceiling]
        end

        # A slot here only gets home-bonus credit if its ore matches
        # THIS sweep's focus, making every sweep's values genuinely
        # additive. Only one sweep per value in home_delivery_bonuses is
        # needed, and no separate "no bonus" sweep: for any real combo,
        # whichever ore its destination actually pays, that ore's sweep
        # credits it exactly -- so the true best combo can never rank
        # low enough, in at least one sweep, to be pruned away.
        def scoped_slots_for(entity, ship, slots, focus_ore)
          amount = focus_ore && @game.best_home_delivery_amount(focus_ore)

          slots.map do |slot|
            claimed = slot.mine_idx && @game.mine_state.dig(slot.hex_id, :mines, slot.mine_idx, :owner) == entity.id
            fixed = @game.entity_fixed_ore_bonus(entity, ship, slot.ore, claimed: claimed)
            home = focus_ore && slot.ore == focus_ore ? amount : 0

            scoped = slot.dup
            scoped.value = slot.raw_value + fixed + home
            scoped
          end
        end

        # Game#candidate_slots has no notion of distance -- fine for
        # ranking, combinatorially disastrous for the actual search.
        # Filters out any slot farther than the ship's theoretical max
        # reach (MP plus +3 per station, an admissible over-estimate)
        # from every launch hex -- provably unreachable, so dropping it
        # can never lose the true optimum.
        def reachable_slots(entity, ship)
          max_mp = @game.ship_distance(entity, ship)
          launch_hexes = entity.tokens.filter_map { |t| t.city&.hex }.uniq
          return [] if launch_hexes.empty?

          station_count = @game.hexes.count { |h| @game.refueling_station_owner(h.id) == entity }
          reach_cap = max_mp + (3 * station_count)
          launch_dists = launch_hexes.map { |hex| @game.hex_bfs(hex).first }

          @game.candidate_slots(entity, ship).select do |slot|
            launch_dists.any? { |dist| (d = dist[slot.hex_id]) && d <= reach_cap }
          end
        end

        # Returns nil if no real route can collect every slot in the
        # combo. Modeled as a state-space search over only the
        # "important" hexes (launch candidates, waypoints, stations,
        # home-bonus hexes) -- pairwise distances between these are
        # already free via Game#hex_bfs, so a detour through a station
        # is automatically free too, no special-casing needed.
        def route_for_combo(entity, ship, combo)
          t0 = Time.now
          wp_ids = combo.map(&:hex_id).uniq.sort
          key = wp_ids.join(',')
          @prof[:key_build] += Time.now - t0

          goals =
            if @goal_memo.key?(key)
              @prof_n[:memo_hits] += 1
              @goal_memo[key]
            else
              t0 = Time.now
              geom_ok = geometrically_feasible?(wp_ids)
              @prof[:geom_check] += Time.now - t0
              if geom_ok
                t0 = Time.now
                result = search_goals(wp_ids)
                @prof[:search] += Time.now - t0
                @prof_n[:searches] += 1
                @goal_memo[key] = result
              else
                @prof_n[:geom_rejected] += 1
                @goal_memo[key] = nil
              end
            end
          return nil unless goals

          t0 = Time.now
          revenue = best_revenue_for_goals(entity, ship, combo, goals)
          @prof[:goal_revenue] += Time.now - t0
          revenue
        end

        # Any real flight visiting every hex in a combo must cover at
        # least the cost of the MINIMUM SPANNING TREE connecting those
        # hexes plus the launch point -- a provable lower bound, so a
        # `false` here is always safe (rejects only truly impossible
        # combos). Exists because a combo's ceiling ranking has no idea
        # about map geometry, and could otherwise only be discovered
        # infeasible by paying for the full BFS in search_goals.
        def geometrically_feasible?(wp_ids)
          idx = @ctx[:index]
          wp_idxs = wp_ids.map { |id| idx[id] }
          budget = @ctx[:max_mp] + (3 * @ctx[:station_count])

          # The MST only connects the combo's own hexes -- it says
          # nothing about also needing to END somewhere deliverable.
          # The cheapest nearest_deliverable case across every member
          # is a safe, still-admissible lower bound on that extra cost.
          ending_extra = wp_idxs.filter_map { |i| @ctx[:nearest_deliverable][i]&.first }.min || 0

          @ctx[:launch_idxs].any? { |launch_idx| mst_lower_bound([launch_idx, *wp_idxs]) + ending_extra <= budget }
        end

        # Prim's algorithm -- `idxs` is small (under ~10 nodes), so
        # naive O(n^2) is cheap. Returns Float::INFINITY if any node is
        # unreachable within this set, failing the budget comparison
        # above without needing its own special case.
        def mst_lower_bound(idxs)
          return 0 if idxs.size <= 1

          dist = @ctx[:dist]
          in_tree = [idxs.first]
          remaining = idxs.drop(1)
          total = 0

          until remaining.empty?
            best_cost = nil
            best_node = nil
            in_tree.each do |a|
              remaining.each do |b|
                d = dist[a][b]
                next unless d
                next if best_cost && d >= best_cost

                best_cost = d
                best_node = b
              end
            end
            return Float::INFINITY unless best_node

            total += best_cost
            in_tree << best_node
            remaining.delete(best_node)
          end

          total
        end

        # Everything about the state search that does NOT depend on the
        # specific combo, computed once per suggest_route call instead
        # of once per combo. Assigns every hex a small integer index and
        # builds pairwise distances as a plain 2D array -- integer
        # indexing instead of nested string-hash lookups in the hottest
        # loop. nearest_deliverable[i]: the closest legal-ending hex
        # from node i, with its distance.
        def build_search_context(entity, ship, slots)
          launch_hexes = entity.tokens.filter_map { |t| t.city&.hex }.uniq
          return nil if launch_hexes.empty?

          launch_ids = launch_hexes.map(&:id)
          station_ids = @game.hexes.select { |h| @game.refueling_station_owner(h.id) == entity }.map(&:id)
          bonus_ids = @game.home_delivery_bonuses.keys
          slot_ids = slots.map(&:hex_id).uniq

          ids = (launch_ids + station_ids + bonus_ids + slot_ids).uniq
          index = {}
          ids.each_with_index { |id, i| index[id] = i }

          deliverable_ids = @game.hexes.select { |h| @game.deliverable_destination?(h) }.map(&:id)

          dist = []
          nearest_deliverable = []
          ids.each do |id|
            d = @game.hex_bfs(@game.hex_by_id(id)).first
            dist << ids.map { |other| d[other] }

            best = nil
            best_id = nil
            deliverable_ids.each do |dh|
              dd = d[dh]
              next unless dd
              next if best && best <= dd

              best = dd
              best_id = dh
            end
            nearest_deliverable << [best, best_id]
          end

          station_bit = Array.new(ids.size)
          station_ids.each_with_index { |id, i| station_bit[index[id]] = i }

          {
            ids: ids,
            index: index,
            dist: dist,
            nearest_deliverable: nearest_deliverable,
            station_bit: station_bit,
            station_count: station_ids.size,
            station_hex_ids: station_ids,
            launch_idxs: launch_ids.map { |id| index[id] },
            core_idxs: (station_ids + bonus_ids).uniq.map { |id| index[id] },
            max_mp: @game.ship_distance(entity, ship),
          }
        end

        # §7.12: refueling at entity's own stations is a MAY, never
        # automatic. Returns nil if infeasible, else { generic: <hex id
        # of a plain no-bonus ending, or nil>, specific: [in-graph
        # ending hex ids whose choice changes revenue] }.
        #
        # State = (node, MP remaining, waypoints-collected bitmask,
        # stations-refueled bitmask), packed into one integer key for
        # dominance pruning. Visiting a not-yet-refueled station
        # branches into two states (refuel now / decline) whenever
        # declining could plausibly pay off later, distinguished by the
        # `refueled` bit so the two are never conflated.
        def search_goals(wp_ids)
          ctx = @ctx
          idx = ctx[:index]
          wp_idxs = wp_ids.map { |id| idx[id] }
          v_bits = wp_idxs.size
          r_bits = ctx[:station_count]
          full_mask = (1 << v_bits) - 1
          max_mp = ctx[:max_mp]
          dist = ctx[:dist]
          station_bit = ctx[:station_bit]
          nearest = ctx[:nearest_deliverable]

          wp_bit = Array.new(ctx[:ids].size)
          wp_idxs.each_with_index { |ni, b| wp_bit[ni] = b }
          # Collecting transshipment always ends the flight immediately
          # (unlike an ordinary mine pickup). `transship_bit[b]` is true
          # when waypoint bit `b`'s hex is a transshipment pickup.
          transship_bit = wp_ids.map { |id| @game.transshipment_hex?(id) }

          nodes = (ctx[:core_idxs] + wp_idxs).uniq

          # .to_s is load-bearing: Opal's Hash only has a native fast
          # path for string keys, integer keys fall through to its slow
          # generic bucket path.
          best_mp = {}
          queue = []
          head = 0

          ctx[:launch_idxs].each do |ni|
            v = wp_bit[ni] ? (1 << wp_bit[ni]) : 0
            k = (((ni << v_bits) | v) << r_bits).to_s
            next if best_mp[k] && best_mp[k] >= max_mp

            best_mp[k] = max_mp
            queue << [ni, max_mp, v, 0]
          end

          generic = nil
          specific = {}

          while head < queue.length
            ni, mp, v, r = queue[head]
            head += 1

            next if best_mp[((((ni << v_bits) | v) << r_bits) | r).to_s] != mp

            if v == full_mask
              nd, nd_id = nearest[ni]
              generic ||= nd_id if nd && nd <= mp
              specific[ctx[:ids][ni]] = true if nd&.zero?
            end

            # A state at a transshipment waypoint is a dead end for
            # further travel, regardless of whether v == full_mask yet.
            wb_here = wp_bit[ni]
            next if wb_here && transship_bit[wb_here]

            row = dist[ni]
            nodes.each do |mi|
              next if mi == ni

              cost = row[mi]
              next unless cost && cost <= mp

              nmp = mp - cost
              nv = v
              wb = wp_bit[mi]
              nv |= (1 << wb) if wb

              sb = station_bit[mi]
              # Once mp_spent reaches 3, refueling already gets the max
              # possible +3, so refuel-now weakly dominates declining --
              # no need to branch past that point. Below 3, declining is
              # a genuine choice worth its own state.
              can_refuel = sb && (r & (1 << sb)).zero?
              defer_worth_exploring = can_refuel && (max_mp - nmp) < 3

              if !can_refuel || defer_worth_exploring
                enqueue_goal_state(nmp, nv, r, mi, best_mp, queue, v_bits, r_bits, full_mask, nearest)
              end

              next unless can_refuel

              bumped_mp = [nmp + 3, max_mp].min
              bumped_nr = r | (1 << sb)
              enqueue_goal_state(bumped_mp, nv, bumped_nr, mi, best_mp, queue, v_bits, r_bits, full_mask, nearest)
            end
          end

          return nil if !generic && specific.empty?

          { generic: generic, specific: specific.keys }
        end

        # Once every waypoint is collected, prunes a state unless SOME
        # delivery point is still reachable -- crediting every
        # still-unrefueled station's full +3 keeps this admissible.
        def enqueue_goal_state(nmp, nv, nr, mi, best_mp, queue, v_bits, r_bits, full_mask, nearest)
          if nv == full_mask
            nd = nearest[mi] && nearest[mi][0]
            if nd
              refueled = nr.to_s(2).count('1')
              return if nmp + (3 * (r_bits - refueled)) < nd
            end
          end

          nk = ((((mi << v_bits) | nv) << r_bits) | nr).to_s
          cur = best_mp[nk]
          return if cur && cur >= nmp

          best_mp[nk] = nmp
          queue << [mi, nmp, nv, nr]
        end

        def best_revenue_for_goals(entity, ship, combo, goals)
          cargo = combo.map { |slot| { hex_id: slot.hex_id, mine_idx: slot.mine_idx, ore: slot.ore, value: slot.raw_value } }

          candidates = goals[:specific].dup
          candidates << goals[:generic] if goals[:generic] && !candidates.include?(goals[:generic])

          best_hex_id = nil
          best_revenue = -1

          candidates.each do |hex_id|
            revenue = @game.trace_revenue(entity, ship, [nil, @game.hex_by_id(hex_id)], cargo)
            next unless revenue > best_revenue

            best_revenue = revenue
            best_hex_id = hex_id
          end

          return nil unless best_hex_id

          { destination_hex_id: best_hex_id, revenue: best_revenue }
        end

        # Returns nil if no legal concrete path could be built, so the
        # caller simply doesn't accept the combo. The revenue returned
        # is always recomputed from the REAL built path and cargo, so
        # anything surprising in the concrete path can never inflate
        # the reported number past what submitting would pay.
        def build_flight(combo, target_hex_id)
          node_path, refueled_hex_ids = plan_node_path(combo.map(&:hex_id).uniq, target_hex_id)
          return nil unless node_path

          # First expansion's arbitrary BFS shortest path can
          # accidentally pass through one of entity's own stations
          # mid-leg. If the MP walk fails because of that, retry with
          # station-avoiding legs (planned refuel stations are leg
          # endpoints, so they're unaffected).
          hexes = expand_node_path(node_path, avoid_stations: false)
          hexes = expand_node_path(node_path, avoid_stations: true) unless hexes && flight_within_mp?(hexes, refueled_hex_ids)
          return nil unless hexes && hexes.size > 1 && flight_within_mp?(hexes, refueled_hex_ids)

          cargo = combo.map { |s| { hex_id: s.hex_id, mine_idx: s.mine_idx, ore: s.ore, value: s.raw_value } }
          { hexes: hexes, cargo: cargo, revenue: @game.trace_revenue(@entity, @ship, hexes, cargo),
            refueled_hex_ids: refueled_hex_ids }
        end

        # Re-runs the same state search as #search_goals, but tracking
        # parents and stopping at the FIRST state matching the chosen
        # ending -- returns [path, refueled_hex_ids]. Runs once per
        # ACCEPTED combo, not per tried combo, so the double-search
        # cost is negligible.
        def plan_node_path(wp_ids, target_hex_id)
          ctx = @ctx
          idx = ctx[:index]
          wp_idxs = wp_ids.map { |id| idx[id] }
          v_bits = wp_idxs.size
          r_bits = ctx[:station_count]
          full_mask = (1 << v_bits) - 1
          max_mp = ctx[:max_mp]
          dist = ctx[:dist]
          station_bit = ctx[:station_bit]
          nearest = ctx[:nearest_deliverable]
          target_idx = idx[target_hex_id]

          wp_bit = Array.new(ctx[:ids].size)
          wp_idxs.each_with_index { |ni, b| wp_bit[ni] = b }
          nodes = (ctx[:core_idxs] + wp_idxs).uniq
          transship_bit = wp_ids.map { |id| @game.transshipment_hex?(id) }

          best_mp = {}
          parent = {}
          queue = []
          head = 0

          ctx[:launch_idxs].each do |ni|
            v = wp_bit[ni] ? (1 << wp_bit[ni]) : 0
            k = (((ni << v_bits) | v) << r_bits).to_s
            next if best_mp[k] && best_mp[k] >= max_mp

            best_mp[k] = max_mp
            parent[k] = nil
            queue << [ni, max_mp, v, 0]
          end

          goal_key = nil

          while head < queue.length
            ni, mp, v, r = queue[head]
            head += 1
            k = ((((ni << v_bits) | v) << r_bits) | r).to_s
            next if best_mp[k] != mp

            if v == full_mask
              # `nodes` deliberately excludes launch hexes (no mid-flight
              # travel through them), but a generic ending can legally
              # resolve to one (fly out and back to base). Without the
              # `nodes.include?` guard this expected a literal revisit
              # this graph never offers, and silently lost real,
              # better-paying combos to a nil here. Falling back to the
              # nearest_deliverable check handles it like any other
              # generic ending.
              if target_idx && nodes.include?(target_idx)
                if ni == target_idx
                  goal_key = k
                  break
                end
              else
                nd, nd_id = nearest[ni]
                if nd_id == target_hex_id && nd && nd <= mp
                  goal_key = k
                  break
                end
              end
            end

            wb_here = wp_bit[ni]
            next if wb_here && transship_bit[wb_here]

            row = dist[ni]
            nodes.each do |mi|
              next if mi == ni

              cost = row[mi]
              next unless cost && cost <= mp

              nmp = mp - cost
              nv = v
              wb = wp_bit[mi]
              nv |= (1 << wb) if wb

              # Same refuel-or-decline branching as search_goals.
              sb = station_bit[mi]
              can_refuel = sb && (r & (1 << sb)).zero?
              defer_worth_exploring = can_refuel && (max_mp - nmp) < 3

              if !can_refuel || defer_worth_exploring
                try_enqueue_path_state(mi, nmp, nv, r, k, best_mp, parent, queue, v_bits, r_bits)
              end

              next unless can_refuel

              bumped_mp = [nmp + 3, max_mp].min
              bumped_nr = r | (1 << sb)
              try_enqueue_path_state(mi, bumped_mp, nv, bumped_nr, k, best_mp, parent, queue, v_bits, r_bits)
            end
          end

          return nil unless goal_key

          # A state's `r` bits only differ from its parent's by the one
          # station bit set on the transition that reached it, so a
          # changed bit means a refuel happened arriving at that node.
          mask = (1 << r_bits) - 1
          shift = v_bits + r_bits
          path = []
          refueled_hex_ids = []
          k = goal_key
          while k
            node_id = ctx[:ids][k.to_i >> shift]
            path.unshift(node_id)
            parent_key = parent[k]
            parent_r = parent_key ? parent_key.to_i & mask : 0
            refueled_hex_ids << node_id if (k.to_i & mask) != parent_r
            k = parent_key
          end
          path << target_hex_id unless path.last == target_hex_id
          [path, refueled_hex_ids]
        end

        def try_enqueue_path_state(mi, nmp, nv, nr, k, best_mp, parent, queue, v_bits, r_bits)
          nk = ((((mi << v_bits) | nv) << r_bits) | nr).to_s
          cur = best_mp[nk]
          return if cur && cur >= nmp

          best_mp[nk] = nmp
          parent[nk] = k
          queue << [mi, nmp, nv, nr]
        end

        def expand_node_path(node_hex_ids, avoid_stations:)
          hexes = [@game.hex_by_id(node_hex_ids.first)]

          node_hex_ids.each_cons(2) do |a, b|
            leg =
              if avoid_stations
                bfs_leg(@game.hex_by_id(a), b, @ctx[:station_hex_ids] - [a, b])
              else
                predecessor_leg(a, b)
              end
            return nil unless leg

            hexes.concat(leg)
          end

          hexes
        end

        def predecessor_leg(a_id, b_id)
          _dist, pred = @game.hex_bfs(@game.hex_by_id(a_id))
          leg = []
          hex = @game.hex_by_id(b_id)
          while hex && hex.id != a_id
            leg.unshift(hex)
            hex = pred[hex.id]
          end
          return nil unless hex

          leg
        end

        # Delegates to Game#hex_bfs's own blocked:-aware walk rather than
        # a second, hand-rolled implementation that could silently drift
        # if a future rule changed what counts as a passable neighbor.
        def bfs_leg(start_hex, target_id, blocked_ids)
          dist, pred = @game.hex_bfs(start_hex, blocked: blocked_ids)
          return nil unless dist.key?(target_id)

          leg = []
          hex = @game.hex_by_id(target_id)
          while hex && hex.id != start_hex.id
            leg.unshift(hex)
            hex = pred[hex.id]
          end
          leg
        end

        # Only applies the +3 bump at hexes in refueled_hex_ids (the
        # plan's own decisions) -- not at every eligible station
        # encountered, so an unplanned mid-leg pass-through never
        # silently refuels either.
        def flight_within_mp?(hexes, refueled_hex_ids)
          full = @ctx[:max_mp]
          mp = full
          applied = {}

          hexes.each_cons(2) do |_a, b|
            mp -= 1
            return false if mp.negative?

            if refueled_hex_ids.include?(b.id) && !applied[b.id]
              mp = [mp + 3, full].min
              applied[b.id] = true
            end
          end

          true
        end
      end
    end
  end
end
