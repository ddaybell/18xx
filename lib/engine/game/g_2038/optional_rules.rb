# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module OptionalRules
        def optional_short_game
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
        # optional_new_corporations and optional_short_game are mutually
        # exclusive, enforced in setup).
        NEW_CORPORATIONS_EXTRA_SHIPS = { '5/4' => 1, '7/6' => 1, '9/7' => 3 }.freeze

        def num_trains(ship_data)
          count = super
          count -= 2 if optional_short_game && ship_data[:name] == '4/3'
          count += NEW_CORPORATIONS_EXTRA_SHIPS[ship_data[:name]] || 0 if optional_new_corporations
          # §13d: "+2 Phase I ships" -- same double-sided-token pool as
          # '4/3'/'6/2' above, just added to '3/2''s own '5/1'-variant pool
          # instead of removed from it.
          count += 2 if optional_variant_start_pack && ship_data[:name] == '3/2'
          count
        end

        def optional_variant_start_pack
          @optional_rules&.include?(:optional_variant_start_pack)
        end

        # The Variant Start Packet always brings the other two expansion
        # rules along with it (per the expansion text's own setup: "Add
        # the two Corporations... Use the optional rule Stock
        # Repurchases..."), so each of these returns true whether its own
        # box was checked directly or only the Start Packet's was.
        def optional_new_corporations
          optional_variant_start_pack || @optional_rules&.include?(:optional_new_corporations)
        end

        # §13b: with OSR/MR in play, Phase VI ('9/7') needs *two* Phase V
        # ships bought first, not the base game's one -- shared by
        # Step::BuyShip#buyable_trains (the ordinary purchase list) and
        # #discountable_trains_for below (the separate exchange-discount
        # UI, assets/app/view/game/buy_trains.rb) so both actually agree.
        # Found live in browser: buyable_trains alone correctly hid 9/7
        # from the plain purchase list after only one Phase V ship, but
        # the base engine's own discountable_trains_for (which reads
        # @depot.depot_trains + Train#discount directly, never consulting
        # this step override at all) still offered a 9/5->9/7 Exchange
        # button regardless.
        def phase_vi_unlocked?
          return true unless optional_new_corporations

          phase_v_bought = @depot.trains.count { |t| %w[7/6 9/5].include?(t.name) && t.owner != @depot }
          phase_v_bought >= 2
        end

        def discountable_trains_for(corporation)
          ships = super
          return ships if phase_vi_unlocked?

          # Not `|_train, discount_train, ...|` -- Opal's implicit block-
          # param destructuring of each yielded 4-element tuple doesn't
          # reliably match MRI's here (found live in browser: `discount_
          # train` came back nil, crashing on `.name`, despite every
          # tuple `super` returns always being a real 4-element array).
          # Indexing the single yielded tuple directly sidesteps the
          # runtime disagreement entirely.
          ships.reject { |t| t[1].name == '9/7' }
        end

        # §13b: On-Site Refining's and Mining Robotics' starting bases are
        # plain pre-printed base hexes with no mine/ore content at all --
        # exactly like every other corp's home (TSI's K9, MM's A1, etc.),
        # not a randomly-explored asteroid tile.
        # `optional_hexes` (below) is what actually makes B14/O13 exist as
        # real base hexes at all; from there they go through the exact
        # same `place_home_token`/`coordinates:` flow as any other corp,
        # so this base is also automatically uncounted against
        # base_limit/bases.size the same way every other corp's home
        # already is (home placement never touches @base_hexes -- only
        # place_base! does).
        #
        # These two hexes don't exist as bases at all without this rule
        # -- unlike OPC/RCC (whose bases are part of the standard 13 and
        # exist regardless of any optional rule), B14/O13 are ordinary
        # unexplored blue hexes in the Full Game as printed. `optional_hexes`
        # (see Game::Base's own "use to modify hexes based on optional
        # rules" comment) is the designated override point -- moves both
        # coordinates from `blue` to `gray` only when the rule is active,
        # so a Full Game without the expansion keeps its normal 100
        # unexplored blue hexes untouched. Builds fresh arrays/hashes
        # rather than mutating HEXES's own (frozen) nested structures.
        #
        # OSR_MR_HOME_HEXES is defined on Game itself (currently in the
        # Infrastructure module) -- qualified with Game:: rather than a
        # specific module name since a bare reference here would only see
        # this module's OWN (empty) ancestry, not Game's; Game:: always
        # resolves via Game's full ancestry regardless of which included
        # module actually owns the constant.
        def optional_hexes
          return game_hexes unless optional_new_corporations

          hexes = game_hexes.dup
          hexes[:blue] = { hexes[:blue].keys.first - Game::OSR_MR_HOME_HEXES => '' }
          hexes[:gray] = { hexes[:gray].keys.first + Game::OSR_MR_HOME_HEXES => 'city=revenue:0' }
          hexes
        end

        # §13b: `init_hexes` (base.rb) builds every corp's home-hex
        # *reservation* from `reservation_corporations` (default:
        # `corporations`) -- and it does this *before* `setup` ever runs,
        # so OSR/MR are still sitting in `@corporations` at that point
        # regardless of whether optional_new_corporations is on (the
        # exclusion in `setup` happens later). Without this override,
        # B14/O13 correctly stay ordinary blank hexes (optional_hexes
        # above), but still end up with a stray, city-less reservation
        # label for OSR/MR floating over them.
        def reservation_corporations
          return super if optional_new_corporations

          super.reject { |c| %w[OSR MR].include?(c.id) }
        end

        def optional_stock_repurchases
          optional_variant_start_pack || @optional_rules&.include?(:optional_stock_repurchases)
        end
      end
    end
  end
end
