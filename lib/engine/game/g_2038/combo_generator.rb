# frozen_string_literal: true

module Engine
  module Game
    module G2038
      # Component 3 of the "optimal set" autorouter (see AI_CONTEXT.md/
      # conversation history for the full design) -- given a list of
      # candidate slots (Game#candidate_slots, each tagged with an
      # admissible value ceiling) and a hold count, lazily generates
      # r-sized combinations of slots in strictly decreasing total-value
      # order, one at a time, without ever enumerating the full C(n, r)
      # space up front (which blows up fast -- C(80, 7) is > 3 billion).
      #
      # The intended caller pattern is a feasibility loop:
      #   gen = ComboGenerator.new(slots, holds)
      #   while (combo = gen.next_combo)
      #     break if feasible?(combo)
      #   end
      # The FIRST feasible combo found this way is provably the best
      # achievable, since every combo emitted before it is guaranteed to
      # have an equal-or-higher total ceiling.
      #
      # Algorithm: represent a combo as a strictly increasing tuple of
      # indices into the value-sorted (descending) slot list. The best
      # possible combo is always (0, 1, ..., r-1). From any combo, its
      # "neighbors" are formed by incrementing exactly one position by 1
      # (staying strictly less than the next position's index, or below N
      # for the last position) -- the standard single-step neighbor
      # structure for enumerating r-subsets of a sorted list by sum via a
      # priority queue. A visited set (keyed on the index tuple itself,
      # using Ruby's built-in Array equality) prevents the same combo
      # from being generated twice via two different neighbor paths.
      #
      # The frontier itself is a real binary max-heap (array-based, each
      # entry its value precomputed once at push time), not a plain array
      # re-sorted on every pop -- found live on a real 39-candidate board:
      # with the frontier growing into the thousands over a single sweep,
      # an O(F log F) sort_by! on every #next_combo call (previously
      # re-deriving each combo's value from scratch on every comparison,
      # too) cost over 100 seconds by itself. A proper heap makes both
      # push and pop O(log F), with each combo's value computed exactly
      # once.
      class ComboGenerator
        def initialize(slots, holds)
          @sorted = slots.sort_by { |s| -s.value }
          @r = [holds, @sorted.size].min
          @n = @sorted.size
          @heap = []
          @visited = {}

          return if @r.zero?

          push((0...@r).to_a)
        end

        # Returns the next-best combo as an array of `holds` (or fewer,
        # if there simply aren't enough candidate slots) CandidateSlot
        # objects, or nil once every combination has been exhausted.
        def next_combo
          return nil if @heap.empty?

          _value, best = pop

          best.each_with_index do |idx, position|
            next_idx = idx + 1
            upper = position + 1 < @r ? best[position + 1] : @n
            next if next_idx >= upper

            candidate = best.dup
            candidate[position] = next_idx
            push(candidate)
          end

          best.map { |i| @sorted[i] }
        end

        private

        def combo_value(combo)
          combo.sum { |i| @sorted[i].value }
        end

        def push(combo)
          # A plain string key, not the combo array itself -- MRI Ruby
          # has an optimized native path for hashing/comparing arrays as
          # Hash keys, but Opal (this code's real runtime -- see
          # OptimalAutorouter's own note on this) has to emulate that on
          # top of JavaScript, which has no native array-value-equality
          # hashing at all. Found live in browser: a real comparison run
          # was SLOWER on the new engine than the old one, completely
          # contradicting server-side Ruby benchmarking that showed the
          # opposite -- string keys are natively fast hash/Map keys in
          # both MRI and JS, so this is a portable fix, not a JS-only one.
          key = combo.join(',')
          return if @visited[key]

          @visited[key] = true
          @heap << [combo_value(combo), combo]
          sift_up(@heap.size - 1)
        end

        def pop
          top = @heap[0]
          last = @heap.pop
          unless @heap.empty?
            @heap[0] = last
            sift_down(0)
          end
          top
        end

        def sift_up(i)
          while i.positive?
            parent = (i - 1) / 2
            break if @heap[parent][0] >= @heap[i][0]

            @heap[parent], @heap[i] = @heap[i], @heap[parent]
            i = parent
          end
        end

        def sift_down(i)
          size = @heap.size

          loop do
            left = (2 * i) + 1
            right = (2 * i) + 2
            largest = i
            largest = left if left < size && @heap[left][0] > @heap[largest][0]
            largest = right if right < size && @heap[right][0] > @heap[largest][0]
            break if largest == i

            @heap[i], @heap[largest] = @heap[largest], @heap[i]
            i = largest
          end
        end
      end
    end
  end
end
