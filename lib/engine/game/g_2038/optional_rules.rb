# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module OptionalRules
        def optional_short_game?
          @optional_rules&.include?(:optional_short_game)
        end

        # §13a: remove 2 Phase II ships (the '4/3'/'6/2' pool) from the game.
        # §13b: add one Phase III, one Phase V, and three Phase VI ships
        # once OSR/MR are in play.
        NEW_CORPORATIONS_EXTRA_SHIPS = { '5/4' => 1, '7/6' => 1, '9/7' => 3 }.freeze

        def num_trains(ship_data)
          count = super
          count -= 2 if optional_short_game? && ship_data[:name] == '4/3'
          count += NEW_CORPORATIONS_EXTRA_SHIPS[ship_data[:name]] || 0 if optional_new_corporations?
          # §13d: +2 Phase I ships.
          count += 2 if optional_variant_start_pack? && ship_data[:name] == '3/2'
          # Cutthroat: four Phase IV ships instead of five.
          count -= 1 if optional_cutthroat_game? && ship_data[:name] == '6/5'
          count
        end

        def optional_cutthroat_game?
          @optional_rules&.include?(:optional_cutthroat_game)
        end

        def optional_weaker_tsi?
          @optional_rules&.include?(:optional_weaker_tsi)
        end

        # §13d: reduce TSI's starting price to $89, $78, or $67 (Full Game
        # only -- growth_corporations.rb's after_buy_company already
        # forces $67 under the Short Game regardless).
        def weaker_tsi_price
          return nil unless optional_weaker_tsi?

          return 89 if @optional_rules&.include?(:optional_weaker_tsi_89)
          return 78 if @optional_rules&.include?(:optional_weaker_tsi_78)
          return 67 if @optional_rules&.include?(:optional_weaker_tsi_67)

          nil
        end

        def optional_variant_start_pack?
          @optional_rules&.include?(:optional_variant_start_pack)
        end

        # The Variant Start Packet always brings the other two expansion
        # rules along with it per the expansion text's own setup.
        def optional_new_corporations?
          optional_variant_start_pack? || @optional_rules&.include?(:optional_new_corporations)
        end

        # §13b: with OSR/MR in play, Phase VI ('9/7') needs two Phase V
        # ships bought first, not the base game's one. Shared by
        # Step::BuyShip#buyable_trains and #discountable_trains_for below
        # so both agree.
        def phase_vi_unlocked?
          return true unless optional_new_corporations?

          phase_v_bought = @depot.trains.count { |t| %w[7/6 9/5].include?(t.name) && t.owner != @depot }
          phase_v_bought >= 2
        end

        def discountable_trains_for(corporation)
          ships = super
          return ships if phase_vi_unlocked?

          # Not `|_train, discount_train, ...|` -- Opal's implicit
          # block-param destructuring of each yielded 4-element tuple
          # doesn't reliably match MRI's here. Indexing the single
          # yielded tuple directly sidesteps the runtime disagreement.
          ships.reject { |t| t[1].name == '9/7' }
        end

        # §13b: OSR/MR's home hexes (B14/O13) are plain pre-printed bases,
        # not randomly-explored asteroids -- moved from `blue` to `gray`
        # only when this rule is active. Builds fresh arrays/hashes since
        # HEXES's own nested structures are frozen.
        def optional_hexes
          return game_hexes unless optional_new_corporations?

          hexes = game_hexes.dup
          hexes[:blue] = { hexes[:blue].keys.first - Game::OSR_MR_HOME_HEXES => '' }
          hexes[:gray] = { hexes[:gray].keys.first + Game::OSR_MR_HOME_HEXES => 'city=revenue:0' }
          hexes
        end

        # base.rb's `init_hexes` builds home-hex reservations before
        # `setup` runs, so OSR/MR are still in `@corporations` at that
        # point regardless of optional_new_corporations?.
        def reservation_corporations
          return super if optional_new_corporations?

          super.reject { |c| %w[OSR MR].include?(c.id) }
        end

        def optional_stock_repurchases?
          optional_variant_start_pack? || @optional_rules&.include?(:optional_stock_repurchases)
        end
      end
    end
  end
end
