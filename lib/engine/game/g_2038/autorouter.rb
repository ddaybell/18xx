# frozen_string_literal: true

module Engine
  module Game
    module G2038
      # Single-ship route optimizer ("Suggest Route"): finds the
      # highest-revenue flight for one specific ship, launching from one of
      # its owner's bases and ending at a valid delivery hex. Intended for
      # speeding up the later stages of a game -- most of the map explored,
      # ships flying longer distances, refueling stations and claims
      # everywhere -- not for shortcutting exploration itself: this NEVER
      # explores a new hex, that stays a player decision. Confirmed with
      # the user: an unexplored hex is still a normal 1 MP flyover (zero
      # value, since there's nothing to pick up somewhere with no
      # mine_state entry) -- it's only ever *entering the 2 MP explore
      # cost* that's off the table, never passing through or over.
      #
      # This is a fundamentally different problem from the standard 18xx
      # `Engine::AutoRouter` (lib/engine/auto_router.rb), which is built
      # entirely around track/path-walking (`node.walk`) and shared-track
      # conflict detection (hexside bitfields, so multiple trains sharing
      # one corporation's track don't double-count a segment) -- neither
      # concept exists in G2038 (no paths, no shared-track blocking between
      # ships), so this is a parallel implementation, not a reuse of that
      # one. Modeled instead as a budget-constrained orienteering search:
      # DFS over the hex-adjacency graph, branch-and-bound pruned, tracking
      # MP spent, cargo aboard, which specific mines this candidate route
      # has already picked up (so a double-mine hex's two loads are never
      # double-counted, and a used mine is never picked twice by a route
      # that loops back), and which refueling stations have already topped
      # this flight off (mirrors Step::Route's @refueled_hexes -- once per
      # station per flight).
      #
      # Reuses Game#trace_revenue/#pickup_value/#transshipment_value/
      # #deliverable_destination? for the actual revenue math rather than
      # reimplementing it, so this can never drift from what a manually
      # flown route would actually earn.
      class Autorouter
        Result = Struct.new(:hexes, :cargo, :revenue, :timed_out, :elapsed, keyword_init: true)

        # Wall-clock safety net, not a target: on a heavily-explored,
        # richly-connected map with a long-range ship, the raw search space
        # (revisits allowed, since backtracking through a freshly-refueled
        # hex can genuinely be optimal) can still blow up well past what's
        # reasonable for a single synchronous request. Mirrors the existing
        # Engine::AutoRouter's own accepted philosophy (route_timeout/
        # path_timeout, returning the best found so far rather than
        # guaranteeing a proven-global optimum) rather than inventing a new
        # standard for this game specifically.
        #
        # Safe to be generous now that a click of "Suggest Route" is a
        # local, unrecorded computation (see Step::Route#suggest_route!'s
        # caller in ShipSelector) rather than a real action baked into
        # replay forever -- this cost is paid once, by the player who
        # asked for it, not on every future page load.
        DEFAULT_TIMEOUT = 30.0
        NODES_PER_TIME_CHECK = 500

        def initialize(game)
          @game = game
        end

        # Best full flight for this one ship -- which base to launch from,
        # every hop, every pickup, and where it ends -- or nil if nothing
        # reachable earns any revenue at all. `result.timed_out` is true if
        # the deadline cut the search short (the result is still the best
        # candidate found, just not provably optimal).
        def suggest_route(entity, train, timeout: DEFAULT_TIMEOUT)
          @entity = entity
          @train = train
          @full_mp = @game.ship_distance(entity, train)
          @holds = @game.cargo_holds_for_train(train)
          @max_mine_value = max_reachable_mine_value(entity)
          @max_per_slot_value = [@max_mine_value, max_transshipment_value(train)].max
          @best = nil
          @deadline = Time.now + timeout
          @nodes_since_check = 0
          @timed_out = false
          @started_at = Time.now
          @visited_states = {}

          # Seed a cheap, guaranteed-reachable baseline via plain BFS
          # before the expensive exhaustive search below -- a
          # transshipment credit needs no exploration, no claim, nothing
          # but flying there, so it should never be lost to the deadline.
          # With every unexplored hex now a valid (zero-value) flyover,
          # the raw search space in an early-game, mostly-unexplored
          # scenario is enormous relative to how little there is to prune
          # on (bound() barely helps until *something* profitable is
          # already found) -- found live in browser: the exhaustive
          # search alone could time out before ever stumbling onto even
          # this trivial, always-available baseline.
          seed_transshipment_baseline!

          launch_hexes(entity).each { |hex| search(hex, @full_mp, [], [], [], [hex]) }
          @best&.timed_out = @timed_out
          @best&.elapsed = (Time.now - @started_at).round(2)
          @best
        end

        private

        def deadline_exceeded?
          @nodes_since_check += 1
          return false if @nodes_since_check < NODES_PER_TIME_CHECK

          @nodes_since_check = 0
          @timed_out ||= Time.now > @deadline
        end

        def launch_hexes(entity)
          entity.tokens.filter_map { |t| t.city&.hex }.uniq
        end

        # Plain BFS (ignoring pickups/refueling entirely, same idea as
        # Step::Route's plain_shortest_paths) from each launch hex to
        # every currently-paying transshipment hex within reach -- cheap
        # (O(hexes) per launch hex) since it never branches on cargo
        # combinations, just hop count.
        def seed_transshipment_baseline!
          launch_hexes(@entity).each do |start|
            dist, predecessor = plain_bfs(start)

            @game.class::TRANSSHIPMENT_HEXES.each do |hex_id|
              next unless @game.transshipment_hex?(hex_id)
              next unless dist[hex_id] && dist[hex_id] <= @full_mp

              path = reconstruct_path(start, hex_id, predecessor)
              value = @game.transshipment_value(@game.hex_by_id(hex_id), @train)
              record_if_better(path, [{ hex_id: hex_id, mine_idx: nil, ore: nil, value: value }])
            end
          end
        end

        def plain_bfs(start)
          dist = { start.id => 0 }
          predecessor = {}
          queue = [start]

          until queue.empty?
            hex = queue.shift
            hex.neighbors.each_value do |neighbor|
              next if neighbor.empty || dist.key?(neighbor.id)

              dist[neighbor.id] = dist[hex.id] + 1
              predecessor[neighbor.id] = hex
              queue << neighbor
            end
          end

          [dist, predecessor]
        end

        def reconstruct_path(start, target_id, predecessor)
          path = []
          hex = @game.hex_by_id(target_id)
          while hex && hex.id != start.id
            path.unshift(hex)
            hex = predecessor[hex.id]
          end
          [start] + path
        end

        # An admissible (never-too-low) upper bound on how much MORE
        # revenue is even theoretically obtainable from here: every
        # remaining hold filled with the single best mine value reachable
        # anywhere on the map for this entity. Loose on purpose -- a tight
        # bound would need its own per-node reachability search -- but
        # cheap, and enough to prune hopeless branches once cargo is
        # nearly full. Computed once per suggest_route call, not per node.
        def max_reachable_mine_value(entity)
          best = 0
          @game.mine_state.each do |hex_id, state|
            state[:mines].each_index do |idx|
              mine = state[:mines][idx]
              next if mine[:used]
              next if mine[:owner] && mine[:owner] != entity.id

              value = @game.pickup_value(entity, hex_id, idx)
              best = value if value > best
            end
          end
          best
        end

        # The bound above only ever looks at mines -- but a transshipment
        # credit needs no exploration or claim ownership at all, so it can
        # be the entire reason a route is worth taking even when nothing
        # is explored yet (e.g. right at the start of the game). Without
        # this, max_reachable_mine_value would be 0 with nothing explored,
        # making the bound below prune every branch immediately and miss
        # transshipment-only routes entirely -- found live in browser.
        def max_transshipment_value(train)
          best = 0
          @game.class::TRANSSHIPMENT_HEXES.each do |hex_id|
            next unless @game.transshipment_hex?(hex_id)

            value = @game.transshipment_value(@game.hex_by_id(hex_id), train)
            best = value if value > best
          end
          best
        end

        # cargo: array of {hex_id:, mine_idx:, ore:, value:}, exactly like
        # Step::Route's @cargo. used: array of [hex_id, mine_idx] pairs this
        # candidate route has already picked up (mine[:used] itself is
        # real/global state, checked fresh each call; this is additionally
        # needed so a route that loops back to the same hex can't pick the
        # same mine twice within its own candidate flight). refueled: array
        # of hex_ids already topped off this candidate flight.
        def search(hex, mp_left, cargo, used, refueled, path)
          # Checked FIRST and unconditionally (a cheap boolean once
          # @timed_out latches true) rather than only pruning this call's
          # own further expansion -- `search` is invoked from loops in
          # every ancestor frame (this method's own neighbor loop, and
          # suggest_route's launch_hexes loop), which keep calling search
          # again for remaining siblings regardless of how deep a prior
          # branch got before timing out. Only a check this early makes
          # the whole call tree unwind promptly once the deadline passes,
          # instead of merely stopping one branch at a time.
          return if @timed_out
          return if deadline_exceeded?

          # Many different hop sequences can converge on the exact same
          # (position, fuel, mines-collected, stations-already-refueled)
          # state -- e.g. two different detours that each end up back at
          # the same hex with the same fuel and the same cargo aboard.
          # Once seen, every future outcome reachable from that state is
          # identical no matter which path arrived there (revenue only
          # ever depends on the *final* hex + cargo -- see
          # Game#trace_revenue -- never on how it got there), so a repeat
          # visit can't find anything the first visit won't already have
          # found. Found live in browser: a real, richly-explored board
          # with several refueling stations let the DFS re-explore
          # equivalent states over and over via different detours, eating
          # the entire time budget before ever reaching a genuinely new
          # (and better) combination. This is a correctness-preserving
          # dedup, not a heuristic like worth_revisiting?/bound() below --
          # it never discards a distinct reachable outcome, only repeat
          # visits to one already fully explored.
          state_key = "#{hex.id}|#{mp_left}|#{used.sort.join(',')}|#{refueled.sort.join(',')}"
          return if @visited_states[state_key]

          @visited_states[state_key] = true

          consider_finish(hex, cargo, path)

          return if mp_left <= 0
          return if bound(cargo) <= (@best&.revenue || 0)

          prev_hex = path[-2]

          ordered_neighbors(hex).each do |neighbor|
            next if neighbor.empty
            # Immediately backtracking to the hex we just came from is only
            # ever worth exploring if it now offers something it didn't
            # last time (a pickup we skipped, or a refuel we haven't used
            # yet) -- otherwise it's a pure waste of 2 MP that every other
            # branch already had the chance to reach directly. This is a
            # heuristic, not a proof: it trades a vanishingly rare missed
            # optimum (see refuel_shortcut_paths' own commentary on this
            # exact tradeoff in Step::Route) for pruning the single biggest
            # source of pointless branching in this search.
            next if neighbor == prev_hex && !worth_revisiting?(neighbor, cargo.size, used, refueled)

            next_mp = mp_left - 1
            next if next_mp.negative?

            next_refueled = refueled
            if @game.refueling_station_owner(neighbor.id) == @entity && !refueled.include?(neighbor.id)
              next_mp = [next_mp + 3, @full_mp].min
              next_refueled = refueled + [neighbor.id]
            end

            branch_pickups(neighbor, next_mp, cargo, used, next_refueled, path + [neighbor])
          end
        end

        # Cheap ordering hint, not a correctness mechanism: still visits
        # every neighbor eventually, just tries the ones likely to matter
        # (an unused pickup this entity can take, or an unused refuel this
        # entity owns) before the ones that are pure pass-through. On a
        # richly-explored late-game board the raw branching factor is huge
        # relative to the 4s deadline (found live: whole-map-explored, one
        # ship, DEFAULT_TIMEOUT expired well before DFS's arbitrary
        # neighbor-hash-order stumbled onto a better, refuel-dependent
        # route) -- finding a strong candidate early lets bound() start
        # pruning the unproductive majority of the tree much sooner, so
        # more of the time budget goes toward branches that could actually
        # beat it. Doesn't change what's reachable or how it's scored.
        def ordered_neighbors(hex)
          hex.neighbors.values.reject(&:empty).sort_by { |n| promising?(n) ? 0 : 1 }
        end

        def promising?(hex)
          return true if @game.refueling_station_owner(hex.id) == @entity

          state = @game.mine_state[hex.id]
          return false unless state

          state[:mines].any? { |m| !m[:used] && (!m[:owner] || m[:owner] == @entity.id) }
        end

        def worth_revisiting?(hex, cargo_size, used, refueled)
          return true if @game.refueling_station_owner(hex.id) == @entity && !refueled.include?(hex.id)
          return false if cargo_size >= @holds

          state = @game.mine_state[hex.id]
          return false unless state

          state[:mines].each_index.any? do |idx|
            mine = state[:mines][idx]
            !mine[:used] && !used.include?([hex.id, idx]) && (!mine[:owner] || mine[:owner] == @entity.id)
          end
        end

        # Every combination of loads available at `hex` (at most 2 mines
        # ever exist on one hex, so this is never more than 4 combinations:
        # take neither, either, or both) -- collecting is always optional,
        # never mandatory, since holding a slot open for a better find
        # later can be the right call, the same tradeoff a human player
        # faces (loads can't be jettisoned once aboard).
        def branch_pickups(hex, mp_left, cargo, used, refueled, path)
          pickup_options(hex, cargo.size, used).each do |extra_cargo, extra_used|
            search(hex, mp_left, cargo + extra_cargo, used + extra_used, refueled, path)
          end
        end

        def pickup_options(hex, cargo_size, used)
          state = @game.mine_state[hex.id]
          return [[[], []]] unless state

          available = state[:mines].each_index.reject do |idx|
            mine = state[:mines][idx]
            mine[:used] || used.include?([hex.id, idx]) ||
              (mine[:owner] && mine[:owner] != @entity.id)
          end
          return [[[], []]] if available.empty?

          combos = [[]]
          available.each { |idx| combos += combos.map { |c| c + [idx] } }

          combos.filter_map do |idxs|
            next if cargo_size + idxs.size > @holds

            extra_cargo = idxs.map do |idx|
              mine = state[:mines][idx]
              { hex_id: hex.id, mine_idx: idx, ore: mine[:ore], value: @game.pickup_value(@entity, hex.id, idx) }
            end
            [extra_cargo, idxs.map { |idx| [hex.id, idx] }]
          end
        end

        # Transshipment credit is its own terminal branch, not folded into
        # pickup_options above -- collecting it always ends the flight
        # immediately (Step::Route#pick_up_transshipment!/process_choose),
        # unlike ore which lets the ship keep flying. So "collect and
        # finish here" and "don't collect (maybe finish anyway with
        # whatever ore is aboard, or keep flying)" are genuinely different
        # branches, not a combination to explore further from.
        def consider_finish(hex, cargo, path)
          return unless path.size > 1
          return unless @game.deliverable_destination?(hex)

          record_if_better(path, cargo)

          return unless @game.transshipment_hex?(hex.id) && cargo.size < @holds

          value = @game.transshipment_value(hex, @train)
          record_if_better(path, cargo + [{ hex_id: hex.id, mine_idx: nil, ore: nil, value: value }])
        end

        def record_if_better(path, cargo)
          revenue = @game.trace_revenue(@entity, @train, path, cargo)
          return unless revenue.positive?
          return if @best && revenue <= @best.revenue

          @best = Result.new(hexes: path.dup, cargo: cargo.dup, revenue: revenue)
        end

        # Was previously just cargo.sum(:value) -- an admissible bound on
        # raw pickup value, but NOT on total achievable revenue, since it
        # ignored that the same cargo could be worth more depending on
        # *where* the route ends (Game#home_delivery_bonus) or *who's*
        # flying it (Game#independent_ore_bonus, direct or pilot-inherited).
        # Once holds are full, remaining_holds hits 0 and this collapsed to
        # a flat ceiling equal to whatever the first valid finish happened
        # to score -- so the very first deliverable hex found (even a
        # zero-bonus one, like the entity's own base) could immediately
        # prune away a genuinely better finish further out (e.g. flying on
        # to a corp's home base for its ore-matching delivery bonus).
        # Found live in browser: a 6/2 with claimed Rare+Nickel aboard
        # suggested ending at TSI's own base instead of continuing to LE's
        # for its +$20 Nickel bonus. Confirmed with the user this needs to
        # account for every bonus type, not just this one.
        def bound(cargo)
          remaining_holds = [@holds - cargo.size, 0].max
          raw = cargo.sum { |c| c[:value] } + (remaining_holds * @max_per_slot_value)
          raw + max_possible_home_bonus(cargo, remaining_holds) + max_possible_ore_bonus(cargo, remaining_holds)
        end

        # Best achievable Game#home_delivery_bonus for this cargo -- only
        # one destination can ever be chosen, so this is the best single
        # corp's bonus, not a sum across all of them. Must also credit
        # *remaining* holds, not just cargo already aboard: assuming every
        # empty hold could still be filled with this same bonus-matching
        # ore (an admissible best case, even if a differently-valued ore
        # ends up there instead) -- otherwise this collapses back to the
        # same under-pruning bug the whole bound() rewrite (see the class
        # comment above) was fixing in the first place, just one level
        # deeper: with 2 of 3 holds already nickel and 1 empty, the bound
        # credited only the 2 *already aboard* instead of the 3 achievable
        # by filling the last hold with nickel too, undershooting a
        # genuinely better route's true ceiling by the delivery bonus on
        # that one extra unit -- enough to prune it as "no better than
        # what's already found." Found live in browser (2026-08-04): a 4/3
        # with 2 claimed Nickel aboard and 1 hold free pruned away the
        # branch that would've picked up a 3rd Nickel and delivered all
        # three to LE, in favor of a worse route already on record.
        def max_possible_home_bonus(cargo, remaining_holds)
          @game.home_delivery_bonuses.values.map do |ore, amount|
            (cargo.count { |c| c[:ore] == ore } + remaining_holds) * amount
          end.max || 0
        end

        # Best achievable Game#independent_ore_bonus for this cargo --
        # covers both a bare independent flying its own ship (entity.id
        # directly) and a Growth Corp with an inherited pilot ore bonus.
        # Deliberately does NOT call Game#independent_ore_bonus/
        # #pilot_ore_bonus directly: those resolve the specific ship's
        # pilot via Step::Route#pilot_source_for_train, which can
        # *auto-assign* an unambiguous pilot-ship pairing as a side effect
        # (logging it) the moment it's asked -- unacceptable from inside a
        # bound() check run many times per search, during what's supposed
        # to be a side-effect-free preview. Instead reads
        # Game#growth_corp_pilots(entity) directly (a plain, read-only
        # lookup of which pilot sources this entity has at all, not which
        # ship each is currently assigned to) and takes the best matching
        # ore across all of them -- an admissible over-approximation if the
        # pilot that actually ends up on this specific ship differs, which
        # only risks under-pruning (safe), never over-pruning. Same
        # remaining-holds credit as max_possible_home_bonus above, and for
        # the same reason.
        def max_possible_ore_bonus(cargo, remaining_holds)
          sources = [@entity.id] + @game.growth_corp_pilots(@entity)
          ores = sources.filter_map { |s| @game.class::INDEPENDENT_ORE_BONUS[s] }.uniq
          return 0 if ores.empty?

          best_count = ores.map { |ore| cargo.count { |c| c[:ore] == ore } }.max
          (best_count + remaining_holds) * @game.class::INDEPENDENT_ORE_BONUS_AMOUNT
        end
      end
    end
  end
end
