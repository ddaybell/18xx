# frozen_string_literal: true

module Engine
  module Game
    module G2038
      # Lazily generates r-sized combinations of slots in strictly
      # decreasing total-value order, one at a time, without ever
      # enumerating the full C(n, r) space up front (C(80, 7) is > 3
      # billion). Caller pattern:
      #   gen = ComboGenerator.new(slots, holds)
      #   while (combo = gen.next_combo)
      #     break if feasible?(combo)
      #   end
      # The FIRST feasible combo found this way is provably the best
      # achievable, since every combo emitted before it has an
      # equal-or-higher total ceiling.
      #
      # The frontier is a real binary max-heap, not a plain array
      # re-sorted on every pop -- on a real 39-candidate board, with the
      # frontier growing into the thousands, an O(F log F) sort_by! on
      # every #next_combo call measured over 100 seconds by itself.
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
          # String key, not the array itself -- Opal has no native
          # array-value-equality hashing on top of JS.
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
            # Opal's Integer#/ is browser float division, not Ruby's --
            # plain (i - 1) / 2 produced 0.5 and crashed @heap[0.5].
            parent = ((i - 1).to_f / 2).floor
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
