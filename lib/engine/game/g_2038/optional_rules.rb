# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module OptionalRules
        def optional_short_game?
          @optional_rules&.include?(:optional_short_game)
        end

        # §13a: "Remove $6,000 and 2 Phase II ships from the game." Phase
        # I/II ships are physically double-sided tokens (one face '4/3',
        # the other its '6/2' variant -- confirmed in the rules text:
        # "printed on opposite sides of the same certificate"), so
        # there's a single pool of 10 to remove 2 from, not two separate
        # counts for the base name and its variant.
        # §13b: "Add one Phase III, one Phase V and three Phase VI
        # spaceships" once OSR/MR are in play -- on top of the base
        # game's own counts, additive with the Short Game's -2 to '4/3'
        # (though the two can never actually combine in practice --
        # optional_new_corporations? and optional_short_game? are mutually
        # exclusive, enforced in setup).
        NEW_CORPORATIONS_EXTRA_SHIPS = { '5/4' => 1, '7/6' => 1, '9/7' => 3 }.freeze

        def num_trains(ship_data)
          count = super
          count -= 2 if optional_short_game? && ship_data[:name] == '4/3'
          count += NEW_CORPORATIONS_EXTRA_SHIPS[ship_data[:name]] || 0 if optional_new_corporations?
          # §13d: "+2 Phase I ships" -- same double-sided-token pool as
          # '4/3'/'6/2' above, just added to '3/2''s own '5/1'-variant pool
          # instead of removed from it.
          count += 2 if optional_variant_start_pack? && ship_data[:name] == '3/2'
          # "Play with only four Phase IV spaceships instead of five" --
          # guarantees someone must buy a Phase VI ship at full price.
          count -= 1 if optional_cutthroat_game? && ship_data[:name] == '6/5'
          count
        end

        def optional_cutthroat_game?
          @optional_rules&.include?(:optional_cutthroat_game)
        end

        def optional_weaker_tsi?
          @optional_rules&.include?(:optional_weaker_tsi)
        end

        # §13d: "Reduce TSI's initial stock price, par value and starting
        # capital to (choose one): $89/890; 78/780; or 67/670" -- Full Game
        # only (growth_corporations.rb's after_buy_company already forces
        # $67 under the Short Game regardless, so these are simply ignored
        # if somehow both were checked at once). Gated on the top-level
        # optional_weaker_tsi? box, not just its three sub-options, since
        # create_game.rb's own parent/child checkbox UI already disables
        # (and clears) the sub-options whenever the parent is unchecked --
        # this is just the matching engine-side guarantee.
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
        # rules along with it (per the expansion text's own setup: "Add
        # the two Corporations... Use the optional rule Stock
        # Repurchases..."), so each of these returns true whether its own
        # box was checked directly or only the Start Packet's was.
        def optional_new_corporations?
          optional_variant_start_pack? || @optional_rules&.include?(:optional_new_corporations)
        end

        # §13b: with OSR/MR in play, Phase VI ('9/7') needs *two* Phase V
        # ships bought first, not the base game's one -- shared by
        # Step::BuyShip#buyable_trains and #discountable_trains_for below
        # so both agree; the base engine's own discountable_trains_for
        # reads @depot.depot_trains + Train#discount directly and never
        # consults this step override on its own.
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

        # §13b: On-Site Refining's and Mining Robotics' starting bases
        # are plain pre-printed base hexes with no mine/ore content,
        # exactly like every other corp's home -- not a randomly-
        # explored asteroid tile. These two hexes (B14/O13) don't exist
        # as bases at all without this rule, unlike OPC/RCC; this moves
        # both coordinates from `blue` to `gray` only when the rule is
        # active, building fresh arrays/hashes rather than mutating
        # HEXES's own (frozen) nested structures.
        #
        # OSR_MR_HOME_HEXES is defined on Game itself -- qualified with
        # Game:: since a bare reference here would only see this
        # module's OWN (empty) ancestry, not Game's.
        def optional_hexes
          return game_hexes unless optional_new_corporations?

          hexes = game_hexes.dup
          hexes[:blue] = { hexes[:blue].keys.first - Game::OSR_MR_HOME_HEXES => '' }
          hexes[:gray] = { hexes[:gray].keys.first + Game::OSR_MR_HOME_HEXES => 'city=revenue:0' }
          hexes
        end

        # §13b: `init_hexes` (base.rb) builds every corp's home-hex
        # *reservation* from `reservation_corporations`, and does this
        # *before* `setup` runs, so OSR/MR are still in `@corporations`
        # at that point regardless of optional_new_corporations? (the
        # exclusion in `setup` happens later). Without this override,
        # B14/O13 stay blank but still get a stray reservation label.
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
