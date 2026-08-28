# frozen_string_literal: true

require 'spec_helper'

# Cross-checks Autorouter's pruned branch-and-bound search against a
# genuinely independent, unpruned brute-force enumeration over small
# synthetic scenarios. Full brute force over a real board is not
# practical (MP budgets of 6-10+ hops with a branching factor around 6
# per hex blow up combinatorially long before finishing) -- but the
# search is only *supposed* to prune away outcomes that are provably no
# better than the best one already found (bound() is meant to be an
# admissible/never-too-low upper bound). That soundness property is
# exactly what a small scenario can test cheaply: keep the MP budget and
# local neighborhood small enough that raw brute force finishes in
# milliseconds, and assert the pruned search still finds the same
# optimum. This is the concrete risk bound() has actually hit twice
# before (see autorouter.rb's own comments on the home-delivery-bonus
# and independent-ore-bonus bound fixes, both live-in-browser-discovered
# under-counts that pruned away a genuinely better route) -- this spec
# exists to catch a regression of that same failure mode automatically.
describe Engine::Game::G2038::Autorouter do
  # A fresh game + a real cargo-holding ship for TSI, pulled straight out
  # of the depot (TSI only owns its starting Probe -- which always scores
  # 0 revenue -- until real train-buying actions run, so the normal buy
  # flow is skipped entirely here).
  def setup_game(seed:, train_name: '3/2')
    game = Engine::Game::G2038::Game.new(%w[P1 P2 P3], seed: seed)
    entity = game.corporations.find { |c| c.id == 'TSI' }
    train = game.depot.depot_trains.find { |t| t.name == train_name }
    game.depot.remove_train(train)
    train.owner = entity
    entity.trains << train
    [game, entity, train]
  end

  # Hexes within `radius` hops of `start`, breadth-first -- the small
  # local neighborhood brute force is allowed to consider.
  def hexes_within(start, radius)
    dist = { start.id => 0 }
    queue = [start]
    result = []
    until queue.empty?
      hex = queue.shift
      hex.neighbors.each_value do |n|
        next if n.empty || dist.key?(n.id)

        dist[n.id] = dist[hex.id] + 1
        next if dist[n.id] > radius

        result << n
        queue << n
      end
    end
    result
  end

  # Seeds fixed (non-random), deterministic mine_state entries at the
  # given hexes -- ore cycles n/i/r, values increase per hex so the
  # scenario has a real "better vs. worse" choice to make, not a flat
  # tie. Skips any hex that already has a city on its tile (a base, an
  # already-placed mine, etc.) to avoid clobbering real map state.
  def seed_mines!(game, hexes, base_value: 10)
    ores = %i[n i r]
    mine_state = game.instance_variable_get(:@mine_state)
    hexes.each_with_index do |hex, i|
      next if hex.tile.cities.any?

      value = base_value + (i * 5)
      mine_state[hex.id] = {
        mines: [{ ore: ores[i % 3], owner: nil, used: false, unclaimed: value, claimed: value + 10 }],
      }
    end
  end

  # Genuinely independent ground truth: exhaustive enumeration (no
  # bound()-based pruning, no visited-state dedup, no neighbor-ordering
  # heuristic) over the same MP/cargo/refuel rules the real search uses,
  # reusing the same Game methods (trace_revenue/pickup_value/
  # deliverable_destination?/transshipment_value) for scoring so this
  # tests the *search*, not a second copy of the revenue math.
  def brute_force_best_revenue(game, entity, train, start_hexes, full_mp)
    holds = game.cargo_holds_for_train(train)
    best = 0

    explore = lambda do |hex, mp_left, cargo, used, refueled, path|
      if path.size > 1 && game.deliverable_destination?(hex)
        revenue = game.trace_revenue(entity, train, path, cargo)
        best = revenue if revenue > best

        if game.transshipment_hex?(hex.id) && cargo.size < holds
          ts_value = game.transshipment_value(hex, train)
          ts_cargo = cargo + [{ hex_id: hex.id, mine_idx: nil, ore: nil, value: ts_value }]
          ts_revenue = game.trace_revenue(entity, train, path, ts_cargo)
          best = ts_revenue if ts_revenue > best
        end
      end

      next if mp_left <= 0

      hex.neighbors.each_value do |neighbor|
        next if neighbor.empty

        next_mp = mp_left - 1
        next if next_mp.negative?

        next_refueled = refueled
        if game.refueling_station_owner(neighbor.id) == entity && !refueled.include?(neighbor.id)
          next_mp = [next_mp + 3, full_mp].min
          next_refueled = refueled + [neighbor.id]
        end

        state = game.mine_state[neighbor.id]
        combos = [[]]
        if state
          available = state[:mines].each_index.reject do |idx|
            mine = state[:mines][idx]
            mine[:used] || used.include?([neighbor.id, idx]) || (mine[:owner] && mine[:owner] != entity.id)
          end
          available.each { |idx| combos += combos.map { |c| c + [idx] } }
          combos = combos.select { |idxs| cargo.size + idxs.size <= holds }
        end

        combos.each do |idxs|
          extra_cargo = idxs.map do |idx|
            mine = state[:mines][idx]
            { hex_id: neighbor.id, mine_idx: idx, ore: mine[:ore], value: game.pickup_value(entity, neighbor.id, idx) }
          end
          extra_used = idxs.map { |idx| [neighbor.id, idx] }
          explore.call(neighbor, next_mp, cargo + extra_cargo, used + extra_used, next_refueled, path + [neighbor])
        end
      end
    end

    start_hexes.each { |hex| explore.call(hex, full_mp, [], [], [], [hex]) }
    best
  end

  # Small enough (MP <= 5, neighborhood radius <= 3) that brute force
  # finishes in well under a second, but with enough mines/branching to
  # give the search real pruning decisions to make -- exactly the
  # regime bound()'s own admissibility matters in.
  [
    { seed: 1001, mp: 4, radius: 3, mine_count: 8 },
    { seed: 2002, mp: 5, radius: 3, mine_count: 10 },
    { seed: 3003, mp: 5, radius: 2, mine_count: 5 },
    { seed: 4004, mp: 3, radius: 2, mine_count: 4 },
  ].each do |scenario|
    it "matches brute force for seed=#{scenario[:seed]} mp=#{scenario[:mp]}" do
      game, entity, train = setup_game(seed: scenario[:seed])
      home_hex = entity.tokens.filter_map { |t| t.city&.hex }.first
      full_mp = scenario[:mp]

      mine_hexes = hexes_within(home_hex, scenario[:radius]).first(scenario[:mine_count])
      seed_mines!(game, mine_hexes)

      # suggest_route always uses the entity's real ship_distance for MP,
      # so pin it down to this scenario's small budget by stubbing the
      # one call site rather than needing a specific train/phase
      # combination that happens to produce exactly this MP value.
      allow(game).to receive(:ship_distance).and_return(full_mp)

      pruned_result = game.autorouter.suggest_route(entity, train, timeout: 5.0)
      pruned_revenue = pruned_result&.revenue || 0

      start_hexes = entity.tokens.filter_map { |t| t.city&.hex }.uniq
      brute_revenue = brute_force_best_revenue(game, entity, train, start_hexes, full_mp)

      expect(pruned_result&.timed_out).to be_falsy
      expect(pruned_revenue).to eq(brute_revenue)
    end
  end
end
