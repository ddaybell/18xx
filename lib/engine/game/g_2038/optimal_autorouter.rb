# frozen_string_literal: true

require_relative 'combo_generator'

module Engine
  module Game
    module G2038
      # Component 4/5 of the "optimal set" autorouter (see conversation
      # history / AI_CONTEXT.md) -- a from-scratch alternative to
      # Autorouter, built and run *alongside* it (never replacing it) for
      # side-by-side comparison. Reuses Game#hex_bfs (component 1) and
      # Game#candidate_slots (component 2) and ComboGenerator (component
      # 3); this file is the feasibility solver (component 4) plus the
      # orchestrating #suggest_route entry point (component 5's engine
      # half -- the view-layer wiring to actually offer this as a second
      # "Auto" option is separate, not yet built).
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
      class OptimalAutorouter
        # Field-compatible with Autorouter::Result where it matters --
        # Step::Route#suggestion_from_result reads .hexes/.cargo/.revenue,
        # so a Result from either engine can flow through the exact same
        # apply/submit machinery. timed_out is always false here: this
        # engine has no time cap at all, it runs to proof (per the user --
        # accuracy first; the 4-ship UI warning is the safety valve).
        # certified_bound/proven_optimal: when a run stops at the user's
        # tolerance instead of full proof, certified_bound is the proven
        # maximum any route could still pay ("$430, and nothing can beat
        # $470") -- a bounded statement, never a guess. proven_optimal is
        # true only for a full run to proof (bound == revenue).
        Result = Struct.new(:hexes, :cargo, :revenue, :timed_out, :elapsed, :combos_tried,
                            :destination_hex_id, :certified_bound, :proven_optimal, keyword_init: true)

        # How long one #run_one_chunk! slice may run before yielding back
        # to the caller -- same value/purpose as Autorouter's own.
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
        # Synchronous entry point (the dev Compare button; scripts).
        # `timeout:` is accepted for old-engine call-site compatibility
        # and deliberately ignored -- this engine runs to proof (or to
        # the caller's chosen tolerance -- see start_chunk!).
        def suggest_route(entity, train, timeout: nil, tolerance_pct: 0) # rubocop:disable Lint/UnusedMethodArgument
          start_chunk!(entity, train, tolerance_pct: tolerance_pct)
          loop { break if run_one_chunk! }
          finish_chunk!
        end

        # Chunked interface, drop-in signature-compatible with
        # Autorouter's own (Step::Route#auto_route_all_tick! drives either
        # engine identically): start_chunk! sets up the whole run,
        # run_one_chunk! does at most CHUNK_DURATION of work and returns
        # true once genuinely finished, finish_chunk! returns the final
        # Result (or nil).
        #
        # `timeout:` accepted-and-ignored, same as suggest_route.
        #
        # `tolerance_pct:` is the user's own accuracy dial (see
        # #certified_bound for the machinery): 0 (the default) runs to
        # full proof, exactly as before; a positive value stops the
        # proof early the moment NO remaining untried combination could
        # beat the best-found revenue by more than that percentage --
        # e.g. 10 means "stop once it's proven nothing can be more than
        # 10% better than what's in hand." Per the user: let players
        # choose their own optimal-ish tolerance -- perfect if they'll
        # wait, provably-close if they won't -- with the caveat being a
        # certified bound, never a guess.
        def start_chunk!(entity, train, timeout: nil, tolerance_pct: 0) # rubocop:disable Lint/UnusedMethodArgument
          @entity = entity
          @train = train
          @started_at = Time.now
          @tolerance_pct = tolerance_pct.to_f
          @stopped_at_tolerance = false
          @stopped_bound = nil
          @best = nil
          @total_combos = 0
          @cur_ceiling = nil
          @generators = []
          @peeked = []
          @done = false

          # Always-on phase profiling (a few Time.now calls per combo,
          # negligible) -- kept permanently rather than as a temporary
          # hack because per-phase cost RATIOS between MRI and Opal have
          # now been badly misjudged twice (array keys, then a wrongly-
          # blamed integer-key theory); #profile_summary lets any browser
          # slowness report come with an exact in-browser breakdown
          # instead of another round of guessing from MRI numbers.
          @prof = Hash.new(0.0)
          @prof_n = Hash.new(0)

          @best_found_at_combo = nil
          # Calibration trajectory: (combo index, best-so-far, certified
          # bound) sampled every TRAJECTORY_SAMPLE_EVERY combos plus at
          # every accepted improvement -- the raw material for an
          # EMPIRICAL "probability this is already optimal" overlay on
          # the certified bound (per the user): across a corpus of test
          # boards, measure how often best-at-gap<=$G was already the
          # final optimum, then quote that frequency (clearly labeled as
          # test-board calibration, never theory) alongside the hard
          # bound. A few hundred small arrays per run -- negligible.
          @trajectory = []
          @holds = @game.cargo_holds_for_train(train)
          slots = @holds.zero? ? [] : reachable_slots(entity, train)
          @ctx = slots.empty? ? nil : build_search_context(entity, train, slots)
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
          sweep_slot_lists = focus_ores.map { |ore| scoped_slots_for(entity, train, slots, ore) }

          # One merged frontier across EVERY (ore-focus sweep, combo size)
          # generator, rather than running each sweep's own 1..holds
          # generators to exhaustion before starting the next sweep. Per
          # the user: sequential sweeps can spend a long stretch working
          # through one sweep's own low-ceiling tail while a DIFFERENT,
          # not-yet-opened sweep's top combo sits untried despite having
          # a higher ceiling right now -- a real priority inversion (the
          # search isn't trying the single most-promising combo available
          # at every step, only the most-promising one WITHIN whichever
          # sweep happens to be active). #best_peeked_index already picks
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

            # The user's accuracy dial: once NO remaining untried combo
            # could beat the best-found by more than tolerance_pct, stop
            # -- a certified within-X% result, not a guess. tolerance 0
            # never fires here (bound <= best is just the natural end,
            # reached through the sweeps' own termination).
            if @tolerance_pct.positive? && @best &&
               (bound = certified_bound) && bound <= @best[:revenue] * (1 + (@tolerance_pct / 100.0))
              @stopped_at_tolerance = true
              # Snapshot the bound BEFORE tearing down search state --
              # certified_bound reads that state live and returns nil
              # once it's cleared, which left finish_chunk!'s Result with
              # an empty bound (found in the tolerance smoke test).
              @stopped_bound = bound
              @done = true
              @cur_ceiling = nil
            end

            return false if !search_done? && Time.now > deadline
          end

          true
        end

        def finish_chunk!
          return nil unless @best

          Result.new(hexes: @best[:hexes], cargo: @best[:cargo], revenue: @best[:revenue],
                     timed_out: false, elapsed: (Time.now - @started_at).round(2),
                     combos_tried: @total_combos, destination_hex_id: @best[:hexes].last.id,
                     certified_bound: @stopped_at_tolerance ? @stopped_bound : @best[:revenue],
                     proven_optimal: !@stopped_at_tolerance)
        end

        # The certified maximum ANY untried combination could still pay
        # right now: simply the single highest ceiling among every
        # generator's currently-peeked candidate, across every sweep and
        # combo size at once -- every generator is always "open" under
        # the merged frontier (see #start_chunk!), so there's no separate
        # not-yet-opened-sweep case to account for any more. Every
        # generator's own emission is ceiling-descending, and ceilings
        # are admissible (never too low), so "best_found vs this bound"
        # is a proven statement about the whole remaining search space at
        # any moment -- the basis for both the tolerance stop above and
        # the live "no remaining route can beat $X" display.
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

        # User-initiated "accept what's in hand and stop proving" (the
        # per-ship skip button, per the user: total control over how
        # close to optimal each ship's run gets). Same teardown as the
        # tolerance stop -- the Result comes back with the honest
        # certified_bound at the moment of stopping and
        # proven_optimal: false. No-op until a first best exists;
        # there'd be nothing to accept.
        def stop_early!
          return unless @best

          @stopped_at_tolerance = true
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

        # Calibration samples -- see the comment at @trajectory's init.
        attr_reader :trajectory

        TRAJECTORY_SAMPLE_EVERY = 100

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
          msg = "OptimalAutorouter: combos=#{@total_combos} elapsed=#{elapsed}s " \
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
          idx = best_peeked_index(@peeked)
          @prof[:peek] += Time.now - t0
          floor = @best ? @best[:revenue] : -1
          @cur_ceiling = idx ? @peeked[idx].sum(&:value) : nil

          if !idx || @cur_ceiling <= floor
            @done = true
            @cur_ceiling = nil
            return
          end

          combo = @peeked[idx]
          @total_combos += 1
          log_progress! if (@total_combos % PROGRESS_LOG_EVERY).zero?
          @trajectory << [@total_combos, best_so_far, certified_bound] if (@total_combos % TRAJECTORY_SAMPLE_EVERY).zero?

          t0 = Time.now
          found = route_for_combo(@entity, @train, combo)
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
              @trajectory << [@total_combos, built[:revenue], certified_bound]
            end
          end

          t0 = Time.now
          @peeked[idx] = @generators[idx].next_combo
          @prof[:next_combo] += Time.now - t0
        end

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

          best_idx
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
        def scoped_slots_for(entity, train, slots, focus_ore)
          amount = focus_ore && @game.best_home_delivery_amount(focus_ore)

          slots.map do |slot|
            claimed = slot.mine_idx && @game.mine_state.dig(slot.hex_id, :mines, slot.mine_idx, :owner) == entity.id
            fixed = @game.entity_fixed_ore_bonus(entity, train, slot.ore, claimed: claimed)
            home = focus_ore && slot.ore == focus_ore ? amount : 0

            scoped = slot.dup
            scoped.value = slot.raw_value + fixed + home
            scoped
          end
        end

        # Game#candidate_slots (component 2) returns every currently
        # pickable slot game-wide, with no notion of distance at all --
        # fine for ranking, but combinatorially disastrous for the actual
        # search: with 39 candidates and holds=7 (a real board this was
        # tested against), C(39, 7) is over 15 million, and the ceiling-
        # first search order wastes enormous effort on near-optimal-BY-
        # VALUE combos that are wildly infeasible BY GEOGRAPHY (7 of the
        # highest-value mines scattered across a large board essentially
        # never all lie within one ship's reach) before ever reaching a
        # more plausible one -- found live, a real 7-base/3-station board
        # never finished within 590s even after the dominance-pruning fix
        # to #search_states.
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
        def reachable_slots(entity, train)
          max_mp = @game.ship_distance(entity, train)
          launch_hexes = entity.tokens.filter_map { |t| t.city&.hex }.uniq
          return [] if launch_hexes.empty?

          station_count = @game.hexes.count { |h| @game.refueling_station_owner(h.id) == entity }
          reach_cap = max_mp + (3 * station_count)
          launch_dists = launch_hexes.map { |hex| @game.hex_bfs(hex).first }

          @game.candidate_slots(entity, train).select do |slot|
            launch_dists.any? { |dist| (d = dist[slot.hex_id]) && d <= reach_cap }
          end
        end

        # Whether this specific combo (a fixed set of pickup slots) can
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
        # own refueling stations, and every home_delivery_bonus hex --
        # rather than the original Autorouter's hex-by-hex board walk.
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
        def route_for_combo(entity, train, combo)
          t0 = Time.now
          wp_ids = combo.map(&:hex_id).uniq.sort
          key = wp_ids.join(',')
          @prof[:key_build] += Time.now - t0

          # NOTE: no infeasible-SUBSET pruning here (any superset of an
          # unroutable hex-set is provably unroutable, so a scan of
          # recorded infeasible sets could skip some searches) -- it was
          # implemented, and removed after live browser profiling: the
          # scan's cost grows with every infeasible set recorded, and
          # under Opal that accumulation was ~90x more expensive than
          # MRI (the user's live console heartbeat showed it EQUALING
          # the entire state-search cost by combo 5,000 and still
          # accelerating), turning a marginal MRI win (14.6s spent to
          # save ~28s of searches) into the single biggest cost in the
          # runtime that matters. The exact-match memo below is cheap in
          # both runtimes and keeps the bulk of the benefit.
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
          revenue = best_revenue_for_goals(entity, train, combo, goals)
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
        # On a spread-out board (found live: AL's bases scattered across
        # a map with a large sparse, unexplored gap down the middle) a
        # huge fraction of the highest-ranked combos can be exactly this
        # kind of geometrically-absurd mix -- each one otherwise only
        # discoverable as infeasible by paying for the full, much more
        # expensive BFS in search_goals.
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

        # Everything about the state search that does NOT depend on the
        # specific combo, computed once per suggest_route call instead of
        # once per combo (profiling put the per-combo search at ~99% of a
        # real 313s run, and a chunk of that was re-deriving these same
        # structures tens of thousands of times):
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
        #   deliverable_destination?) from node i, with its distance. This
        #   also FIXES a latent accuracy gap, not just speed: the abstract
        #   graph previously only allowed endings at its own node set, so
        #   a combo whose only feasible ending was a nearby FOREIGN base
        #   (a legal, ordinary-revenue delivery) was wrongly judged
        #   infeasible. A refuel-en-route ending is still covered: any
        #   helpful station is itself a node, so the state AT that station
        #   (post-refuel) is where this per-node check gets applied.
        def build_search_context(entity, train, slots)
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
            # Deliberately excludes launch_ids (unlike the old version):
            # confirmed with the user, a G2038 flight only ever cares
            # about a base at its two endpoints -- launch (start) and any
            # base or transshipment point (end) -- mid-flight is
            # completely agnostic to bases, no rule of any kind attaches
            # to physically being at one along the way. A base's role as
            # a valid ENDING is already fully covered by
            # nearest_deliverable above, which scans every real
            # deliverable hex on the map regardless of whether it's in
            # this node set at all -- so dropping a base that's neither a
            # station (real refuel benefit) nor a bonus hex from the
            # ONGOING transition set costs no correctness, only shrinks
            # the per-state edge-expansion loop every single search pays
            # (own launch_idxs, used only for seeding the initial queue
            # states, is untouched).
            core_idxs: (station_ids + bonus_ids).uniq.map { |id| index[id] },
            max_mp: @game.ship_distance(entity, train),
          }
        end

        # The state search for one waypoint-hex-set: can a single flight
        # visit every hex in `wp_ids` (some launch hex, some visiting
        # order, refuels at entity's own stations, within MP budget), and
        # if so, where can it legally end? Returns nil if infeasible,
        # else { generic: <hex id of a plain no-bonus ending, or nil>,
        # specific: [in-graph ending hex ids -- notably the home-bonus
        # hexes, whose ending choice changes revenue] }.
        #
        # State = (node index, MP remaining, waypoints-collected bitmask,
        # stations-refueled bitmask), explored via an indexed-queue BFS
        # with dominance pruning on best-MP-per-(node, masks) -- see the
        # git history of this file for the full war stories behind the
        # indexed queue (O(n) shift blowup), the dominance pruning (a
        # real board that never finished without it), and why state keys
        # must never be Ruby arrays (Opal). Keys here are single
        # integers -- (node << v_bits+r_bits) | (visited << r_bits) |
        # refueled -- the fastest hash key both MRI and JS have.
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
          # after pick_up_transshipment! -- confirmed with the user
          # earlier this session), unlike an ordinary mine pickup, which
          # lets the ship keep flying. A combo that includes a
          # transshipment slot as one of several waypoints was being
          # scored as if the ship could collect it mid-route and then
          # continue on to the rest -- found live: a combo landed $330
          # in the abstract search (collect D2's transshipment, then
          # keep flying to 3 more mines before ending at A1) but only
          # $220 was ever actually submittable, since collecting D2
          # forces the route to end right there. `transship_bit[b]` is
          # true when waypoint bit `b`'s hex is a transshipment pickup.
          transship_bit = wp_ids.map { |id| @game.transshipment_hex?(id) }

          nodes = (ctx[:core_idxs] + wp_idxs).uniq

          # State keys: the packed (node|visited|refueled) integer,
          # STRINGIFIED before use as the hash key. The packing keeps key
          # construction to one cheap arithmetic expression, but the
          # .to_s is load-bearing, not cosmetic: Opal's Hash only has a
          # native fast path for STRING keys -- integer keys fall through
          # to its slow generic bucket path, and this loop does 2-3 hash
          # ops per edge. Found live in browser (the second time this
          # exact lesson got learned this session -- see the array-key
          # note on the git history of this method): a board this
          # searched in 168s in-browser before the integer-key rewrite
          # was still going at 540s+ after it, with MRI-side benchmarks
          # completely blind to the difference (integers are FASTER than
          # strings as MRI hash keys -- the two runtimes disagree, and
          # the browser is the runtime that matters).
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

              nr = r
              sb = station_bit[mi]
              if sb && (r & (1 << sb)).zero?
                nmp += 3
                nmp = max_mp if nmp > max_mp
                nr |= (1 << sb)
              end

              # Dead-branch prune (per the user): once every waypoint is
              # collected, a state can only ever become a valid ending if
              # SOME delivery point is still reachable -- and
              # nearest_deliverable[mi] (precomputed once, board-wide,
              # in #build_search_context) already gives the shortest
              # possible remaining distance to one, so it's a NECESSARY
              # condition, not a guess. Crediting every still-unrefueled
              # station's full +3 bonus, whether or not a real path would
              # ever actually visit it, keeps this admissible (only ever
              # too generous, never too strict) -- exactly the same
              # "assume the best case" reasoning #reachable_slots and
              # #geometrically_feasible? already use elsewhere. Found
              # live (see conversation history): 99.85% of combos that
              # passed the geometric pre-filter and paid for a full
              # search still turned out to have NO reachable ending at
              # all -- this stops the search from continuing to wander
              # such a state further once that's already provable,
              # rather than only checking for it at the point of
              # dequeuing (the previous behavior, which registered no
              # ending but let the state keep expanding regardless).
              if nv == full_mask
                nd = nearest[mi] && nearest[mi][0]
                if nd
                  refueled = nr.to_s(2).count('1')
                  next if nmp + (3 * (r_bits - refueled)) < nd
                end
              end

              nk = ((((mi << v_bits) | nv) << r_bits) | nr).to_s
              cur = best_mp[nk]
              next if cur && cur >= nmp

              best_mp[nk] = nmp
              queue << [mi, nmp, nv, nr]
            end
          end

          return nil if !generic && specific.empty?

          { generic: generic, specific: specific.keys }
        end

        # Among every reachable valid ending, the real cargo revenue
        # (Game#trace_revenue, the same method a real submitted route
        # gets scored by) differs only by home_delivery_bonus -- so try
        # every specific in-graph ending (the bonus hexes) plus the
        # generic no-bonus one, and keep whichever actually maximizes it.
        def best_revenue_for_goals(entity, train, combo, goals)
          cargo = combo.map { |slot| { hex_id: slot.hex_id, mine_idx: slot.mine_idx, ore: slot.ore, value: slot.raw_value } }

          candidates = goals[:specific].dup
          candidates << goals[:generic] if goals[:generic] && !candidates.include?(goals[:generic])

          best_hex_id = nil
          best_revenue = -1

          candidates.each do |hex_id|
            revenue = @game.trace_revenue(entity, train, [nil, @game.hex_by_id(hex_id)], cargo)
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
          node_path = plan_node_path(combo.map(&:hex_id).uniq, target_hex_id)
          return nil unless node_path

          # First expansion uses each leg's arbitrary BFS shortest path.
          # That can accidentally pass THROUGH one of entity's own not-
          # yet-refueled stations mid-leg -- triggering its once-per-
          # flight +3 refuel EARLIER than the abstract plan assumed,
          # where the max-MP cap can swallow part of it and leave the
          # flight short later (the abstract search only credits refuels
          # at planned node visits). If the MP walk fails, retry with
          # station-avoiding legs (planned refuel stations are leg
          # ENDPOINTS, so only accidental pass-throughs get avoided);
          # if even that can't produce a legal flight, give up on this
          # combo.
          hexes = expand_node_path(node_path, avoid_stations: false)
          hexes = expand_node_path(node_path, avoid_stations: true) unless hexes && flight_within_mp?(hexes)
          return nil unless hexes && hexes.size > 1 && flight_within_mp?(hexes)

          cargo = combo.map { |s| { hex_id: s.hex_id, mine_idx: s.mine_idx, ore: s.ore, value: s.raw_value } }
          { hexes: hexes, cargo: cargo, revenue: @game.trace_revenue(@entity, @train, hexes, cargo) }
        end

        # Re-runs the same state search as #search_goals, but tracking
        # parents and stopping at the FIRST state that satisfies the
        # chosen ending -- returns the node-level hex-id path (launch
        # first, ending last; the generic ending hex appended if it
        # isn't itself a graph node). Runs once per ACCEPTED combo (a
        # few dozen per suggest_route at most), not per tried combo, so
        # the double-search cost is negligible next to the main loop.
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
              if target_idx
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

              nr = r
              sb = station_bit[mi]
              if sb && (r & (1 << sb)).zero?
                nmp += 3
                nmp = max_mp if nmp > max_mp
                nr |= (1 << sb)
              end

              nk = ((((mi << v_bits) | nv) << r_bits) | nr).to_s
              cur = best_mp[nk]
              next if cur && cur >= nmp

              best_mp[nk] = nmp
              parent[nk] = k
              queue << [mi, nmp, nv, nr]
            end
          end

          return nil unless goal_key

          shift = v_bits + r_bits
          path = []
          k = goal_key
          while k
            path.unshift(ctx[:ids][k.to_i >> shift])
            k = parent[k]
          end
          path << target_hex_id unless path.last == target_hex_id
          path
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

        # Fresh BFS shortest a->b path treating `blocked_ids` hexes as
        # impassable -- only used by the avoid-stations fallback, so it
        # runs a handful of times per suggest_route at most.
        def bfs_leg(start_hex, target_id, blocked_ids)
          blocked = {}
          blocked_ids.each { |id| blocked[id] = true }

          pred = {}
          seen = { start_hex.id => true }
          queue = [start_hex]
          head = 0

          while head < queue.length
            hex = queue[head]
            head += 1
            break if hex.id == target_id

            hex.neighbors.each_value do |n|
              next if n.empty || seen[n.id] || blocked[n.id]

              seen[n.id] = true
              pred[n.id] = hex
              queue << n
            end
          end

          return nil unless seen[target_id]

          leg = []
          hex = @game.hex_by_id(target_id)
          while hex && hex.id != start_hex.id
            leg.unshift(hex)
            hex = pred[hex.id]
          end
          leg
        end

        # Mirrors Step::Route#replay_path's MP accounting exactly (1 MP
        # per hop; +3 capped at max on first entry of each of entity's
        # own stations) -- the concrete flight must survive this to be
        # accepted, since it's the same walk the real submission will
        # effectively perform.
        def flight_within_mp?(hexes)
          full = @ctx[:max_mp]
          mp = full
          refueled = {}

          hexes.each_cons(2) do |_a, b|
            mp -= 1
            return false if mp.negative?

            if !refueled[b.id] && @game.refueling_station_owner(b.id) == @entity
              mp = [mp + 3, full].min
              refueled[b.id] = true
            end
          end

          true
        end
      end
    end
  end
end
