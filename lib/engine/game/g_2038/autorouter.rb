# frozen_string_literal: true

require_relative 'combo_generator'

module Engine
  module Game
    module G2038
      # The ship-route search engine ("Auto"/"Suggest Route", and the
      # multi-ship ordering search in Step::Route#try_ordering!). Reuses
      # Game#hex_bfs, Game#candidate_slots, and ComboGenerator (this
      # file is the feasibility solver plus the orchestrating
      # #suggest_route entry point). 
      #
      # Strategy: pull candidate cargo combinations from ComboGenerator in
      # strictly decreasing ceiling order. For each, ask "can a real route
      # actually collect all of it, and if so, what's the best real
      # revenue reachable" (#route_for_combo below). Because ComboGenerator
      # guarantees every later combo has a ceiling <= this one, and every
      # combo's ceiling is an admissible (never too low) bound on its own
      # true achievable revenue, the search can stop the moment the next
      # combo's ceiling can no longer beat the best REAL revenue already
      # found -- at that point no untried combo could possibly do better.
      # This is a provable stopping point, not a timeout or a guess.
      #
      # Note this is *not* simply "first feasible combo wins": a combo's
      # ceiling assumes every slot in it could independently reach its own
      # best-case destination bonus, which a single real route often can't
      # simultaneously realize (only one hex is ever the actual delivery
      # destination) -- so a combo can be fully feasible (every slot
      # reachable) yet still fall short of its own ceiling. The ceiling-
      # vs-best-real-found comparison handles that correctly; a naive
      # "stop at first feasible" would not.
      class Autorouter
        # timed_out is always false here: this engine has no time cap at
        # all, it runs to proof. certified_bound/proven_optimal: when a
        # run stops early via #stop_early! instead of reaching full
        # proof, certified_bound is the proven maximum any route could
        # still pay ("$430, and nothing can beat $470") -- a bounded
        # statement, never a guess. proven_optimal is true only for a
        # full run to proof (bound == revenue).
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

        # Runs one full search per possible "destination ore focus" (see
        # #scoped_slots_for) plus the max real revenue found across all of
        # them wins. Necessary, not just an optimization on top of a
        # single search: ComboGenerator's own correctness depends on
        # per-slot values being additive/separable (a combo's rank is
        # exactly the sum of its slots' own values) -- Game#candidate_
        # slots' combined ceiling (every slot crediting its OWN best-case
        # home bonus, regardless of whether other slots in the same combo
        # could share that same destination) is NOT separable in that
        # sense, since it silently assumes multiple different bonus-
        # paying hexes could all be the same real ending at once. On a
        # real 39-candidate, 7-hold board this meant the search's proof
        # of optimality (not the answer itself, which it found almost
        # immediately) took 40,000+ combos and never finished within 10
        # minutes.
        #
        # Splitting into one sweep per assumed destination ore fixes this:
        # within a single sweep, every slot's value only ever credits a
        # bonus for THAT one ore, so two slots' values genuinely can be
        # summed and trusted as a real joint ceiling. #scoped_slots_for's
        # own comment covers why running one sweep per bonus-paying ore
        # (plus none needed for "no bonus" -- see there) still can't miss
        # the true global optimum.
        # Synchronous entry point (the dev Compare button; scripts). Runs
        # to proof (or until #stop_early! is called externally -- see
        # start_chunk!) -- there's no timeout knob, by design.
        def suggest_route(entity, ship)
          start_chunk!(entity, ship)
          loop { break if run_one_chunk! }
          finish_chunk!
        end

        # Chunked interface (Step::Route#auto_route_all_tick! drives it):
        # start_chunk! sets up the whole run, run_one_chunk! does at most
        # CHUNK_DURATION of work and returns true once genuinely finished,
        # finish_chunk! returns the final
        # Result (or nil). The only way a run ends before full proof is an
        # external #stop_early! call (the per-ship "Accept & next ship"
        # skip button).
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

          # Always-on phase profiling (a few Time.now calls per combo,
          # negligible)
          @prof = Hash.new(0.0)
          @prof_n = Hash.new(0)

          @best_found_at_combo = nil
          @holds = @game.cargo_holds_for_ship(ship)
          slots = @holds.zero? ? [] : reachable_slots(entity, ship)
          @ctx = slots.empty? ? nil : build_search_context(entity, ship, slots)
          return unless @ctx

          # Feasibility results memoized across the WHOLE run, all sweeps
          # included -- the expensive state search (#search_goals) depends
          # only on which HEXES must be visited, never on which specific
          # mine on a double-mine hex, which sweep's ore focus is asking,
          # or the cargo's values. A 3-sweep run re-tries mostly the same
          # combos per sweep, and combos differing only in mine_idx share
          # a hex set outright -- found via profiling: the per-combo
          # search was ~99% of a 313s real-board run, much of it
          # byte-identical repeat searches.
          @goal_memo = {}

          focus_ores = @game.home_delivery_bonuses.values.map(&:first).uniq
          focus_ores = [nil] if focus_ores.empty?
          sweep_slot_lists = focus_ores.map { |ore| scoped_slots_for(entity, ship, slots, ore) }

          # One merged frontier across EVERY (ore-focus sweep, combo size)
          # generator. #best_peeked_index already picks
          # the globally-highest-ceiling entry across however many
          # generators it's given, regardless of which sweep or size they
          # came from, so merging every generator into one frontier here
          # gets this for free -- no separate per-sweep bookkeeping
          # needed, and the stopping proof is if anything simpler: the
          # moment the single best peeked ceiling across ALL generators
          # drops to or below the floor, nothing anywhere can beat it.
          @generators = sweep_slot_lists.flat_map do |sweep_slots|
            max_size = [@holds, sweep_slots.size].min
            next [] if max_size.zero?

            (1..max_size).map { |r| ComboGenerator.new(sweep_slots, r) }
          end
          @peeked = @generators.map(&:next_combo)

          # Same "rank by promise, cheaply, once" idea applied to the
          # entity's own launch bases (per the user): geometrically_
          # feasible?'s `@ctx[:launch_idxs].any? { ... }` otherwise walks
          # them in whatever arbitrary order entity.tokens happened to
          # return, with no relationship to which one is actually likely
          # to let a real combo through. Ranking cost: for each base, the
          # SAME mst_lower_bound already built for the per-combo check,
          # summed across every sweep's own top-`holds`-value combo --
          # the same reference point that used to rank sweep order,
          # reused here for "how well does this base connect to the kind
          # of high-value combo we're hoping to find". Cheap -- a
          # handful of bases times a handful of sweeps, computed ONCE
          # here, not per combo -- and completely safe: this only
          # changes which base geometrically_feasible?'s `.any?` happens
          # to check first, never whether a combo is accepted, since
          # every base still gets tried if an earlier one fails.
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

        # The certified maximum ANY untried combination could still pay
        # right now: simply the single highest ceiling among every
        # generator's currently-peeked candidate, across every sweep and
        # combo size at once. Every generator's own emission is ceiling-descending, and ceilings
        # are admissible (never too low), so "best_found vs this bound"
        # is a proven statement about the whole remaining search space at
        # any moment -- the basis for both #stop_early!'s certified bound
        # and the live "no remaining route can beat $X" display.
        def certified_bound
          @cur_ceiling
        end

        # Best revenue found so far (nil before the first accepted
        # build) -- with #certified_bound, powers the live gap display.
        def best_so_far
          @best && @best[:revenue]
        end

        # The current best's own concrete hex path -- for drawing it on
        # the map live while the search continues (see
        # Step::Route#auto_route_all_preview_hexes/map.rb's
        # render_route_lines), same underlying data #best_so_far's
        # revenue comes from, just the path instead of the number.
        def best_hexes
          @best && @best[:hexes]
        end

        # Bailout feature: stops a search and accepts the current best.
        # The Result comes back with the honest certified_bound at the moment of stopping and
        # proven_optimal: false. No-op until a first best exists; there'd
        # be nothing to accept.
        def stop_early!
          return unless @best

          @stopped_early = true
          @stopped_bound = certified_bound
          @done = true
          @cur_ceiling = nil
        end

        # Live progress reader for the view's dev-only console throughput
        # logging (see ship_selector.rb's run_auto_route_all_tick!) --
        # how many combos the in-flight chunked run has tried so far.
        def combos_so_far
          @total_combos || 0
        end

        # The combo index the final best answer surfaced at (nil if no
        # run/answer) -- see the comment where it's set.
        attr_reader :best_found_at_combo

        # What fraction of the combos tried SO FAR were needed to find the
        # current best -- an honest, live "found early vs found late"
        # signal, not a fabricated confidence percentage. best_found_at_
        # combo is fixed the instant @best last improved; combos_so_far
        # keeps climbing for as long as the proof continues without a
        # better answer turning up. So this ratio only ever shrinks the
        # longer a run goes without improving: 50% right after the find,
        # trending toward single digits (or lower) the more proof-work
        # piles up on top of it with nothing to show for it. Per the
        # user: this is what actually answers "was the real work done
        # early, with everything since just confirming a negative" --
        # exactly the situation "Accept & next ship" exists for, now with
        # a real number behind the decision instead of a guess. nil
        # before any combo has ever been accepted.
        def found_at_ratio
          return nil unless @best_found_at_combo && @total_combos&.positive?

          @best_found_at_combo.to_f / @total_combos
        end

        # Per-phase wall-clock breakdown of the most recent run -- see
        # start_chunk!'s own comment on why this is always-on. The dev
        # "Time Optimal" button appends this to its alert, so a browser
        # slowness report arrives with the actual in-browser hotspot
        # named.
        def profile_summary
          return 'no run recorded' unless @prof

          phases = @prof.keys.sort_by { |k| -@prof[k] }.map { |k| "#{k}: #{@prof[k].round(1)}s" }
          counts = @prof_n.map { |k, v| "#{k}=#{v}" }.join(', ')
          (phases + [counts]).join("\n")
        end

        # Live heartbeat every PROGRESS_LOG_EVERY combos -- browser
        # console under Opal (console messages render even while a
        # synchronous run has the tab itself frozen), stderr under MRI --
        # so a long run shows real-time progress AND leaves its last
        # snapshot behind even if the user gives up and reloads before it
        # finishes. Answers "is it stuck or just slow, and where is the
        # time going" without waiting for the final alert.
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

        # One bounded unit of work: try exactly one combo. Every (sweep,
        # combo size) generator peeks its own next candidate, merged into
        # one frontier (see #start_chunk!); each step tries whichever
        # peeked combo has the single highest ceiling across ALL of them,
        # ending the instant that global best can no longer beat the best
        # VERIFIED revenue found so far. An improving combo only actually
        # raises that floor after #build_flight succeeds -- turning the
        # abstract feasibility answer into a concrete, MP-verified hex
        # path -- so the floor is always something the player could
        # genuinely submit, never just a paper claim.
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
              # Which combo the winning answer actually surfaced at --
              # observed (one real board) to be a tiny fraction of the
              # total, with everything after being pure proof-of-
              # optimality; tracked so that hypothesis can be tested
              # across a sample of boards rather than one anecdote.
              @best_found_at_combo = @total_combos
            end
          end

          t0 = Time.now
          @peeked[idx] = @generators[idx].next_combo
          @prof[:next_combo] += Time.now - t0
        end

        # Returns [best_idx, best_ceiling] -- the caller (step_combo!)
        # needs both, and used to recompute the winning combo's own
        # ceiling a second time via a fresh .sum(&:value) right after
        # this method already computed the identical value while finding
        # it. That doubled the cost of the single hottest per-combo
        # operation across the whole search (tens of thousands of combos
        # on a real board, per this file's own profiling) for zero
        # benefit -- returning the value already in hand here instead.
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

        # Rebuilds `slots` with each one's ranking `.value` scoped to a
        # single assumed destination ore (or none, if `focus_ore` is nil)
        # -- unlike Game#candidate_slots' own `.value` (every slot gets
        # its own independently-best home bonus, not separable across a
        # combo -- see #suggest_route's own comment), a slot here only
        # ever gets home-bonus credit if its ore matches THIS sweep's
        # focus, making every sweep's own values genuinely additive.
        #
        # Only one sweep per *value* in home_delivery_bonuses.values (not
        # one per bonus-paying hex) is needed, and no separate "no bonus"
        # sweep either: for any real combo, whichever few of its slots
        # (if any) end up sharing one real destination's ore either don't
        # exist (every sweep then scores it identically, by raw value +
        # entity-fixed bonus alone -- correct either way) or do exist for
        # some ore O, in which case the O-focused sweep credits those
        # slots their real bonus exactly and is therefore guaranteed >=
        # that combo's true revenue -- so the true best combo can never
        # rank low enough, in at least one sweep, to be pruned away
        # before being tried.
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

        # Game#candidate_slots (component 2) returns every currently
        # pickable slot game-wide, with no notion of distance at all --
        # fine for ranking, but combinatorially disastrous for the actual
        # search.
        #
        # This filters out any slot that's farther than the ship's own
        # theoretical maximum reach -- MP budget plus +3 for every one of
        # entity's own stations on the whole map (an admissible, safe
        # over-estimate per the user: a real flight could never benefit
        # from more refuels than stations that exist at all, regardless of
        # whether they're actually reachable in a way that helps) -- from
        # EVERY one of entity's launch hexes. A slot beyond that cap from
        # every launch hex is provably unreachable by any real route
        # regardless of which other slots are combined with it, so
        # dropping it up front can never lose the true optimum, only
        # shrink the search space actually explored.
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

        # Checks whether this specific combo (a fixed set of pickup slots) can
        # actually be collected by a single flight -- some launch hex,
        # some visiting order, some insertion of refuels at entity's own
        # stations, all within the ship's MP budget -- and if so, the
        # best real revenue reachable (accounting for which valid ending
        # hex, if any, is both reachable and actually pays a home_
        # delivery_bonus for this cargo's ore mix). Returns nil if no
        # real route can collect every slot in the combo at all.
        #
        # Modeled as a small state-space search over just the "important"
        # hexes -- launch candidates, this combo's own waypoints, entity's
        # own refueling stations, and every home_delivery_bonus hex.
        #
        # Pairwise distances between these (at most a few dozen) hexes are
        # already free (Game#hex_bfs, component 1), so a detour through a
        # station that happens to sit exactly on the shortest path between
        # two other important hexes is automatically free too (dist(A,S)
        # + dist(S,B) == dist(A,B)), with no special-casing needed --
        # station nodes are just ordinary nodes in the same graph. State =
        # (current hex, MP remaining, bitmask of waypoints collected,
        # bitmask of stations already refueled at this flight -- once per
        # station per flight, mirroring Step::Route's own @refueled_hexes)
        # explored via BFS with a visited-state memo, small enough (tens
        # of nodes x a handful of MP values x at most 2^holds x 2^stations
        # states) to run in milliseconds even though it's exhaustive.
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

        # Cheap, purely-geometric admissible pre-check: any real flight
        # visiting every hex in a combo (from whichever of the entity's
        # own bases turns out most convenient) must cover at least the
        # cost of the MINIMUM SPANNING TREE connecting those hexes plus
        # that launch point -- a provable lower bound on total travel
        # distance, since a spanning tree is the cheapest possible way to
        # touch every point at all, and any real path visiting the same
        # set can only be as long or longer. Comparing that lower bound
        # against the most generous possible MP budget (every one of the
        # entity's own refueling stations assumed freely usable, +3 MP
        # each, whether or not any actually sits along a real path) can
        # only ever REJECT combos that are truly impossible -- never one
        # that might still be reachable -- so a `false` here is always
        # safe to skip on, with search_goals still the real ground truth
        # for anything this doesn't reject.
        #
        # Exists because a combo's ceiling ranking (raw slot value only)
        # has no idea about map geometry at all: a high-value combo
        # mixing hexes near two of the entity's own distant bases can
        # rank near the top while being utterly unreachable in one trip.
        # On a spread-out board a huge fraction of the highest-ranked combos
        # can be exactly this kind of geometrically-absurd mix -- each one 
        # otherwise only discoverable as infeasible by paying for the full, 
        # much more expensive BFS in search_goals.
        def geometrically_feasible?(wp_ids)
          idx = @ctx[:index]
          wp_idxs = wp_ids.map { |id| idx[id] }
          budget = @ctx[:max_mp] + (3 * @ctx[:station_count])

          # The MST above only accounts for connecting the combo's own
          # hexes together -- it says nothing about the flight also
          # needing to END somewhere deliverable (a base or transship
          # point). If none of this combo's own hexes happen to already
          # be one, real extra travel beyond the tree is unavoidable.
          # ctx[:nearest_deliverable] is precomputed per node (distance
          # to ITS OWN closest deliverable hex, 0 if the node already
          # is one) -- the cheapest case across every combo member is a
          # safe, still-admissible lower bound on that unavoidable extra
          # cost, since the true endpoint could turn out to be whichever
          # member has the smallest such distance (never an
          # overestimate, so still never wrongly rejects a reachable
          # combo). Meaningfully tightens the common case of a combo made
          # up entirely of ordinary mines, none of which are themselves a
          # valid ending.
          ending_extra = wp_idxs.filter_map { |i| @ctx[:nearest_deliverable][i]&.first }.min || 0

          @ctx[:launch_idxs].any? { |launch_idx| mst_lower_bound([launch_idx, *wp_idxs]) + ending_extra <= budget }
        end

        # Prim's algorithm over the precomputed `dist` matrix -- `idxs`
        # is small (one launch node plus at most `holds` waypoints, so
        # under ~10 nodes total), so the naive O(n^2) approach is already
        # cheap next to a real BFS. Returns Float::INFINITY if any node
        # is unreachable from the rest within this node set (a nil
        # dist[a][b] entry), which correctly fails the budget comparison
        # above rather than needing its own special case there.
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

        # build_search_context represent everything about the state search 
        # that does NOT depend on the specific combo, computed once per 
        # suggest_route call instead of once per combo:
        #
        # - Every hex the search will ever visit (launch bases, entity's
        #   stations, home-bonus hexes, every candidate slot's hex) gets a
        #   small integer index, and pairwise distances become a plain 2D
        #   array -- integer array indexing instead of nested string-hash
        #   lookups in the hottest loop (a large constant-factor win in
        #   Opal especially, same lesson as the string-key fix before it).
        #
        # - nearest_deliverable[i]: the closest hex where a flight may
        #   legally END (any tokened base or transshipment hex, per Game#
        #   deliverable_destination?) from node i, with its distance. A 
        #   refuel-en-route ending is still covered: any helpful station is
        #   itself a node, so the state AT that station (post-refuel) is 
        #   where this per-node check gets applied.
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

        # search_goals is the state search for one waypoint-hex-set:
        # can a single flight visit every hex in `wp_ids` (some launch hex,
        # some visiting order, MAY refuel at entity's own stations --
        # §7.12, never automatic -- within MP budget), and if so, where
        # can it legally end? Returns nil if infeasible, else
        # { generic: <hex id of a plain no-bonus ending, or nil>,
        # specific: [in-graph ending hex ids -- notably the home-bonus
        # hexes, whose ending choice changes revenue] }.
        #
        # State = (node index, MP remaining, waypoints-collected bitmask,
        # stations-refueled bitmask), explored via an indexed-queue BFS
        # with dominance pruning on best-MP-per-(node, masks) | (node <<
        # v_bits+r_bits) | (visited << r_bits) | refueled -- the fastest
        # hash key both MRI and JS have. Visiting a not-yet-refueled
        # station branches into two separate states (refuel now / decline
        # -- see the transition loop's own comment) whenever declining
        # could plausibly pay off later; the two are distinguished by the
        # `refueled` bit in this same key, never conflated.
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
          # (Step::Route's TRANSSHIP dispatch calls finish_route right
          # after pick_up_transshipment!), unlike an ordinary mine pickup, 
          # which lets the ship keep flying. `transship_bit[b]` is
          # true when waypoint bit `b`'s hex is a transshipment pickup.
          transship_bit = wp_ids.map { |id| @game.transshipment_hex?(id) }

          nodes = (ctx[:core_idxs] + wp_idxs).uniq

          # State keys: the packed (node|visited|refueled) integer,
          # STRINGIFIED before use as the hash key. The packing keeps key
          # construction to one cheap arithmetic expression, but the
          # .to_s is load-bearing, not cosmetic: Opal's Hash only has a
          # native fast path for STRING keys -- integer keys fall through
          # to its slow generic bucket path, and this loop does 2-3 hash
          # ops per edge. 
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

            # A state sitting at a transshipment waypoint is a dead end
            # for further travel -- see the comment on transship_bit
            # above. This holds regardless of whether v == full_mask
            # yet: if other waypoints still haven't been visited, this
            # branch could never have legally continued to them either.
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
              # §7.12: refueling is a MAY, not a MUST. Once mp_spent
              # (max_mp - nmp) reaches 3, refueling right now already
              # gets the maximum possible +3, and per this class's own
              # comment on the math, deferring further can never do
              # better -- so past that point refuel-now weakly dominates
              # declining (same eventual best case, never less fuel in
              # the meantime) and there's no need to branch: apply it
              # unconditionally, same as before. Only while mp_spent < 3
              # is declining a genuine, potentially-better choice, worth
              # exploring as its own separate state (distinguished from
              # refueling by the `nr` bit, so dominance pruning below
              # never conflates the two).
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

        # Shared enqueue step for search_goals' transition loop: the
        # dead-branch prune (per the user: once every waypoint is
        # collected, a state can only ever become a valid ending if SOME
        # delivery point is still reachable, and nearest_deliverable[mi]
        # already gives the shortest possible remaining distance to one,
        # so it's a NECESSARY condition, not a guess -- crediting every
        # still-unrefueled station's full +3, whether or not a real path
        # would ever actually visit it, keeps this admissible, same
        # "assume the best case" reasoning #reachable_slots/
        # #geometrically_feasible? already use elsewhere) plus the
        # packed-key dominance check/update. Factored out so it runs once
        # per refuel-choice branch (see the call site) instead of being
        # duplicated inline for each.
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

        # Among every reachable valid ending, the real cargo revenue
        # (Game#trace_revenue, the same method a real submitted route
        # gets scored by) differs only by home_delivery_bonus -- so try
        # every specific in-graph ending (the bonus hexes) plus the
        # generic no-bonus one, and keep whichever actually maximizes it.
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

        # Turns an abstract "this combo is collectible, best ending X"
        # answer into a concrete, MP-verified hex-by-hex flight the
        # Step::Route suggestion machinery can actually apply/submit --
        # the same {hexes:, cargo:, revenue:} shape Autorouter::Result
        # carries. Returns nil if no legal concrete path could be built
        # (see the expansion fallback below); the caller then simply
        # doesn't accept the combo, keeping the search floor honest.
        #
        # The revenue returned is trace_revenue on the REAL built path
        # and cargo -- normally identical to the abstract claim, but
        # always recomputed rather than trusted, so anything surprising
        # in the concrete path (e.g. an ending pass-through) can never
        # inflate the reported number past what submitting would pay.
        def build_flight(combo, target_hex_id)
          node_path, refueled_hex_ids = plan_node_path(combo.map(&:hex_id).uniq, target_hex_id)
          return nil unless node_path

          # First expansion uses each leg's arbitrary BFS shortest path.
          # That can accidentally pass THROUGH one of entity's own
          # stations mid-leg -- but since flight_within_mp? below only
          # ever credits the PLANNED refueled_hex_ids (never an
          # incidental pass-through, matching the "no refueling anywhere
          # unplanned" rule), that no longer risks silently consuming a
          # station's once-per-flight use earlier than the abstract plan
          # assumed. If the MP walk still fails (e.g. an accidental
          # pass-through ate MP the plan didn't budget for some other
          # reason), retry with station-avoiding legs (planned refuel
          # stations are leg ENDPOINTS, so only accidental pass-throughs
          # get avoided); if even that can't produce a legal flight, give
          # up on this combo.
          hexes = expand_node_path(node_path, avoid_stations: false)
          hexes = expand_node_path(node_path, avoid_stations: true) unless hexes && flight_within_mp?(hexes, refueled_hex_ids)
          return nil unless hexes && hexes.size > 1 && flight_within_mp?(hexes, refueled_hex_ids)

          cargo = combo.map { |s| { hex_id: s.hex_id, mine_idx: s.mine_idx, ore: s.ore, value: s.raw_value } }
          { hexes: hexes, cargo: cargo, revenue: @game.trace_revenue(@entity, @ship, hexes, cargo),
            refueled_hex_ids: refueled_hex_ids }
        end

        # plan_node_path re-runs the same state search as #search_goals
        # (including its §7.12 refuel-or-decline branching), but tracking
        # parents and stopping at the FIRST state that satisfies the
        # chosen ending -- returns [path, refueled_hex_ids]: the
        # node-level hex-id path (launch first, ending last; the generic
        # ending hex appended if it isn't itself a graph node) and which
        # of those nodes the winning path actually chose to refuel at.
        # Runs once per ACCEPTED combo (a few dozen per suggest_route at
        # most), not per tried combo, so the double-search cost is
        # negligible next to the main loop.
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
          # See the matching comment in #search_goals: collecting
          # transshipment always ends the flight, so travel can never
          # continue past a visited transshipment waypoint.
          transship_bit = wp_ids.map { |id| @game.transshipment_hex?(id) }

          best_mp = {}
          parent = {}
          queue = []
          head = 0

          # Stringified packed-int state keys, same as #search_goals (and
          # for the same Opal-fast-path reason -- see the comment there).
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
              # target_idx alone isn't enough to know `target_hex_id` is
              # actually reachable as a normal transition node here --
              # ctx[:ids]/idx also covers this entity's own launch hexes
              # (kept there for the distance matrix/nearest_deliverable
              # lookups below), which are deliberately excluded from
              # `nodes` (this method never needs to travel THROUGH its
              # own launch point mid-flight). A generic ending can
              # legitimately resolve to one of those launch hexes --
              # flying out and back to base is a perfectly normal
              # delivery -- so without the `nodes.include?` guard this
              # fell through to expecting a literal revisit of a node
              # this search graph never offers a transition to, and
              # always failed to find it (found live: a real, better-
              # paying combo silently lost to build_flight returning nil
              # here, discarding an otherwise-winning route). Falling
              # back to the same nearest_deliverable check the `else`
              # branch already uses for a true non-graph target handles
              # this exactly like any other generic ending.
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

              # §7.12 refuel-or-decline branch -- see search_goals' own
              # comment for why this is only worth exploring as a
              # separate state while mp_spent < 3, and unconditional
              # (same as before) past that point.
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

          # Walk parent[] back from the goal, collecting the node-level
          # hex path AND -- new for §7.12 -- which of those nodes the
          # winning path actually chose to refuel at: a state's `r` bits
          # only ever differ from its parent's by the one station bit set
          # on the transition that reached it (see the branch above), so
          # a changed bit means a refuel happened arriving at that node.
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

        # Shared dominance-check-and-enqueue step for plan_node_path's
        # transition loop, factored out so it runs once per refuel-choice
        # branch (see the call site) instead of being duplicated inline.
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

        # The a->b hop sequence off Game#hex_bfs's (memoized) predecessor
        # tree -- excludes a, includes b.
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

        # Shortest a->b path treating `blocked_ids` hexes as impassable --
        # only used by the avoid-stations fallback, so it runs a handful
        # of times per suggest_route at most. Delegates to Game#hex_bfs's
        # own blocked:-aware walk (see that method's own comment) instead
        # of a second, hand-rolled BFS-over-neighbors implementation --
        # the two had identical core logic (skip empty hexes, track a
        # predecessor, breadth-first queue), duplicated in a way that
        # could silently drift if a future rule ever changed what counts
        # as a passable neighbor (e.g. a new impassable hex type) and
        # only one copy got updated.
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

        # Mirrors Step::Route#replay_path's MP accounting (1 MP per hop;
        # +3 capped at max) -- the concrete flight must survive this to
        # be accepted, since it's the same walk the real submission will
        # effectively perform. Only applies the bump at hexes in
        # `refueled_hex_ids` (the plan's own §7.12 decisions, from
        # plan_node_path) -- NOT at every eligible station encountered,
        # since an unplanned mid-leg pass-through (see build_flight's own
        # comment on avoid_stations) must never silently refuel either,
        # matching the "no incidental refueling anywhere" rule now used
        # everywhere else.
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
