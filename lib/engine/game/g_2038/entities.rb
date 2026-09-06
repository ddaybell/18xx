# frozen_string_literal: true

module Engine
  module Game
    module G2038
      module Entities
        COMPANIES = [
          {
            name: 'Planetary Imports',
            sym: 'PI',
            value: 50,
            revenue: 10,
            desc: 'No special abilities',
            # A corp may buy this for $1-$50 (its printed value)(§7.4).
            min_price: 1,
            max_price: 50,
            color: nil,
          },
          {
            name: 'Fast Buck',
            sym: 'FB',
            value: 100,
            revenue: 0,
            desc: 'May form a Growth Corporation OR join the Asteroid League for 1 share.'\
                  ' Earns $15/round into company treasury.',
            # Paid at the start of every OR by Round::Operating#pay_fast_buck_treasury
            # (Game#fast_buck_income_amount) -- follows this company's
            # treasury wherever it's absorbed, per Game#
            # fast_buck_income_recipient/carry_over_independent_special_status!.
            treasury_income_amount: 15,
            abilities: [
              { type: 'no_buy' },
            ],
            color: 'white',
          },
          {
            name: 'Ice Finder',
            sym: 'IF',
            value: 100,
            revenue: 0,
            desc: 'May form a Growth Corporation OR join the Asteroid League for 1 share.'\
                  ' $10 bonus per Ice ore delivered. When exploring, must draw a second tile if first drawn has'\
                  ' no Ice mines.',
            own_delivery_bonus: :i,
            own_delivery_bonus_amount: 10,
            abilities: [
              { type: 'no_buy' },
            ],
            color: 'white',
          },
          {
            name: 'Drill Hound',
            sym: 'DH',
            value: 100,
            revenue: 0,
            desc: 'May form a Growth Corporation OR join the Asteroid League for 1 share.'\
                  ' $10 bonus per Rare ore delivered. When exploring, must draw a second tile if first drawn has'\
                  ' no Rare mines.',
            own_delivery_bonus: :r,
            own_delivery_bonus_amount: 10,
            abilities: [
              { type: 'no_buy' },
            ],
            color: 'white',
          },
          {
            name: 'Ore Crusher',
            sym: 'OC',
            value: 100,
            revenue: 0,
            desc: 'May form a Growth Corporation OR join the Asteroid League for 1 share.'\
                  ' $10 bonus per Nickel delivered.',
            own_delivery_bonus: :n,
            own_delivery_bonus_amount: 10,
            abilities: [
              { type: 'no_buy' },
            ],
            color: 'white',
          },
          {
            name: 'Torch',
            sym: 'TH',
            value: 100,
            revenue: 0,
            desc: 'May form a Growth Corporation OR join the Asteroid League for 1 share.'\
                  ' All spaceships operated by this company get +1 movement point.',
            abilities: [
              { type: 'no_buy' },
            ],
            color: 'white',
          },
          {
            name: 'Lucky',
            sym: 'LY',
            value: 100,
            revenue: 0,
            desc: 'May form a Growth Corporation OR join the Asteroid League for 1 share.'\
                  ' When exploring, draw 2 tiles and choose which to place (discard the other).',
            # This entity's own explore-time choice (which tile to place)
            # always triggers a guaranteed follow-up popup (the tile
            # redraw choice) with nothing else for the player to decide in
            # between -- see Game#chain_explore_popup_sources/
            # Step::Route#chain_hex_choice_popup?.
            chain_explore_popup: true,
            # This entity's second draw is a genuine player choice (which
            # of the two tiles to place) -- unlike IF/DH, whose second
            # draw only ever happens because the first tile already
            # failed their ore requirement, so there's nothing left to
            # decide and it's placed automatically. See Game#
            # chooses_own_redraw_sources/Step::Route#move_to.
            chooses_own_redraw: true,
            abilities: [
              { type: 'no_buy' },
            ],
            color: 'white',
          },
          {
            name: 'Tunnel Systems',
            sym: 'TS',
            value: 120,
            revenue: 5,
            desc: 'Buyer receives a TSI Share. If owned by a corporation, may place 1 free Base on ANY'\
                  ' explored and unclaimed tile.',
            # A corp may buy this for $1-$120 (its printed value) (§7.4).
            min_price: 1,
            max_price: 120,
            abilities: [
              { type: 'shares', shares: 'TSI_3' },
              { type: 'generic', subtype: 'free_base', description: 'Free base, any explored hex',
                when: 'owning_corp_or_turn', count: 1, remove: '5' },
            ],
            color: '#40b1b9',
          },
          {
            name: 'Vacuum Associates',
            sym: 'VA',
            value: 140,
            revenue: 10,
            desc: 'Buyer receives a TSI Share. If owned by a corporation, may place 1 free'\
                  ' Refueling Station within range.',
            # A corp may buy this for $1-$140 (its printed value) (§7.4).
            min_price: 1,
            max_price: 140,
            abilities: [
              { type: 'shares', shares: 'TSI_2' },
              { type: 'generic', subtype: 'free_station', description: 'Free refueling station, in range',
                when: 'owning_corp_or_turn', count: 1, remove: '5' },
            ],
            color: '#40b1b9',
          },
          {
            name: 'Robot Smelters, Inc.',
            sym: 'RS',
            value: 160,
            revenue: 15,
            desc: 'Buyer receives a TSI Share. If owned by a corporation, may place 1 free Claim within range.',
            # A corp may buy this for $1-$160 (its printed value) (§7.4).
            min_price: 1,
            max_price: 160,
            abilities: [
              { type: 'shares', shares: 'TSI_1' },
              { type: 'generic', subtype: 'free_claim', description: 'Free claim, in range',
                when: 'owning_corp_or_turn', count: 1, remove: '5' },
            ],
            color: '#40b1b9',
          },
          {
            name: 'Space Transportation Co.',
            sym: 'ST',
            value: 180,
            revenue: 20,
            desc: "Buyer receives TSI president's Share and flies the Probe if TSI isn't active. May not be owned"\
                  ' by a corporation. Remove from the game after TSI buys a spaceship.',
            abilities: [
              { type: 'shares', shares: 'TSI_0' },
              { type: 'no_buy' },
              { type: 'close', when: 'bought_train', corporation: 'TSI' },
            ],
            color: '#40b1b9',
          },
          {
            name: 'Asteroid Export Co.',
            sym: 'AE',
            value: 180,
            revenue: 30,
            desc: "Forms Asteroid League, receiving its President's certificate. May not be bought by a"\
                  ' corporation. Remove from the game after AL acquires a spaceship.',
            abilities: [
              { type: 'close', when: 'bought_train', corporation: 'AL' },
              { type: 'no_buy' },
            ],
            
            color: '#fa3d58',
          },
        ].freeze

        MINORS = [
          {
            sym: 'FB',
            name: 'Fast Buck',
            value: 100,
            coordinates: 'G7',
            logo: 'g_2038/FB',
            simple_logo: 'g_2038/FB.alt',
            tokens: [0],
            color: '#1f3a5f',
            text_color: 'white',
            type: 'independent',
            # §7.4: every independent's lifetime claim cap is a flat 2 --
            # see Game#claim_limit.
            claim_limit: 2,
            abilities: [],
          },
          {
            sym: 'IF',
            name: 'Ice Finder',
            value: 100,
            coordinates: 'M13',
            logo: 'g_2038/IF',
            simple_logo: 'g_2038/IF.alt',
            tokens: [0],
            color: '#6a3d9a',
            text_color: 'white',
            type: 'independent',
            claim_limit: 2,
            abilities: [
              {
                type: 'description',
                description: '+$10 per Ice delivered',
              },
            ],
          },
          {
            sym: 'DH',
            name: 'Drill Hound',
            value: 100,
            coordinates: 'D14',
            logo: 'g_2038/DH',
            simple_logo: 'g_2038/DH.alt',
            tokens: [0],
            color: '#8b5a2b',
            text_color: 'white',
            type: 'independent',
            claim_limit: 2,
            abilities: [
              {
                type: 'description',
                description: '+$10 per Rare delivered',
              },
            ],
          },
          {
            sym: 'OC',
            name: 'Ore Crusher',
            value: 100,
            coordinates: 'M5',
            logo: 'g_2038/OC',
            simple_logo: 'g_2038/OC.alt',
            tokens: [0],
            color: '#556b2f',
            text_color: 'white',
            type: 'independent',
            claim_limit: 2,
            abilities: [
              {
                type: 'description',
                description: '+$10 per Nickel delivered',
              },
            ],
          },
          {
            sym: 'TH',
            name: 'Torch',
            value: 100,
            coordinates: 'B6',
            logo: 'g_2038/TH',
            simple_logo: 'g_2038/TH.alt',
            tokens: [0],
            color: '#7f1d1d',
            text_color: 'white',
            type: 'independent',
            claim_limit: 2,
            abilities: [],
          },
          {
            sym: 'LY',
            name: 'Lucky',
            value: 100,
            coordinates: 'H14',
            logo: 'g_2038/LY',
            simple_logo: 'g_2038/LY.alt',
            tokens: [0],
            color: '#374151',
            text_color: 'white',
            type: 'independent',
            claim_limit: 2,
            abilities: [],
          },
        ].freeze

        def corporation_opts
          { float_percent: 50, text_color: 'black' }
        end

        CORPORATIONS = [
          {
            sym: 'TSI',
            name: 'Trans-Space Incorporated',
            logo: 'g_2038/TSI',
            simple_logo: 'g_2038/TSI.alt',
            tokens: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            bases: [50],
            stations: [50, 50, 50],
            claim_limit: 10,
            # home base information
            coordinates: 'K9',
            color: '#40b1b9',
            type: :group_a,
          },
          {
            sym: 'RU',
            name: 'Resources Unlimited',
            logo: 'g_2038/RU',
            simple_logo: 'g_2038/RU.alt',
            tokens: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            bases: [50],
            stations: [50],
            claim_costs: [0, 100],
            claim_limit: 12,
            # home base information
            coordinates: 'D8',
            color: '#C66F53',
            type: :group_a,
          },
          {
            sym: 'VP',
            name: 'Venus Prospectors Limited',
            logo: 'g_2038/VP',
            simple_logo: 'g_2038/VP.alt',
            tokens: [0, 0, 0, 0, 0],
            bases: [50, 50, 50],
            stations: [25, 25, 25, 25],
            claim_limit: 5,
            # home base information
            coordinates: 'J2',
            color: '#3eb75b',
            # This is the delivery bonus available to all deliveries made to this hex,
            # regardless of which entity makes the delivery.
            delivery_bonus: :r,
            delivery_bonus_amount: 20,
            # This is the delivery bonus VP itself earns for its own deliveries, made
            # anywhere.
            own_delivery_bonus: :r,
            own_delivery_bonus_amount: 10,
            type: :group_b,
            abilities: [
              { type: 'description',
                description: '+$10 per Rare delivered' },
            ],
          },
          {
            sym: 'LE',
            name: 'Lunar Enterprises',
            logo: 'g_2038/LE',
            simple_logo: 'g_2038/LE.alt',
            tokens: [0, 0, 0, 0, 0, 0, 0, 0, 0],
            bases: [50],
            stations: [50, 50],
            claim_limit: 9,
            # home base information
            coordinates: 'O1',
            color: '#fefc5d',
            # This is the delivery bonus available to all deliveries made to this hex,
            # regardless of which entity makes the delivery.
            delivery_bonus: :n,
            delivery_bonus_amount: 10,
            # This is the delivery bonus LE itself earns for its own deliveries, made
            # anywhere.
            own_delivery_bonus: :n,
            own_delivery_bonus_amount: 10,
            type: :group_b,
            abilities: [
              { type: 'description',
                description: '+$10 per Nickel delivered' },
            ],
          },
          {
            sym: 'MM',
            name: 'Mars Mining',
            logo: 'g_2038/MM',
            simple_logo: 'g_2038/MM.alt',
            tokens: [0, 0, 0, 0, 0, 0],
            bases: [25, 25, 25],
            stations: [50, 50, 50],
            # §13b: "Mars Mining gains 2 more Claims" once OSR/MR (the new
            # corporations) are in play -- a Proc rather than a plain
            # number since entities.rb's CORPORATIONS is a constant built
            # once at load time, before any specific game's optional rules
            # are known; Game#claim_limit calls this with itself once that
            # IS known.
            claim_limit: ->(game) { game.optional_new_corporations ? 8 : 6 },
            # home base information
            coordinates: 'A1',
            color: '#f66936',
            # This is the delivery bonus available to all deliveries made to this hex,
            # regardless of which entity makes the delivery.
            delivery_bonus: :i,
            delivery_bonus_amount: 20,
            # This is the delivery bonus MM itself earns for its own deliveries, made
            # anywhere.
            own_delivery_bonus: :i,
            own_delivery_bonus_amount: 10,
            type: :group_b,
            abilities: [
              { type: 'description',
                description: '+$10 per Ice delivered' },
            ],
          },
          {
            sym: 'OPC',
            name: 'Outer Planet Consortium',
            logo: 'g_2038/OPC',
            simple_logo: 'g_2038/OPC.alt',
            tokens: [0, 0, 0, 0, 0, 0, 0],
            bases: [50, 50],
            stations: [0, 50, 50],
            claim_limit: 7,
            # home base information
            coordinates: 'J18',
            color: '#cc4f8c',
            # This is the delivery bonus available to all deliveries made to this hex,
            # regardless of which entity makes the delivery.
            delivery_bonus: :i,
            delivery_bonus_amount: 10,
            # This is the delivery bonus OPC itself earns for its own deliveries, made
            # anywhere.
            own_delivery_bonus: :n,
            own_delivery_bonus_amount: 10,
            type: :group_c,
            abilities: [
              { type: 'description',
                description: '+$10 per Nickel delivered' },
            ],
          },
          {
            sym: 'RCC',
            name: 'Ring Construction Corporation',
            logo: 'g_2038/RCC',
            simple_logo: 'g_2038/RCC.alt',
            tokens: [0, 0, 0, 0, 0, 0, 0, 0],
            bases: [50, 50],
            stations: [50, 50],
            claim_limit: 8,
            # home base information
            coordinates: 'F18',
            color: '#FFDB58',
            # This is the delivery bonus available to all deliveries made to this hex, 
            # regardless of which entity makes the delivery.
            delivery_bonus: :n,
            delivery_bonus_amount: 10,
            # This is the delivery bonus RCC itself earns for its own deliveries, made
            # anywhere.
            own_delivery_bonus: :n,
            own_delivery_bonus_amount: 10,
            type: :group_c,
            abilities: [
              { type: 'description',
                description: '+$10 per Nickel delivered' },
            ],
          },
          {
            sym: 'OSR',
            name: 'On-Site Refining',
            logo: 'g_2038/OSR',
            simple_logo: 'g_2038/OSR.alt',
            tokens: [0, 0, 0, 0, 0, 0],
            bases: [50],
            stations: [50],
            claim_limit: 6,
            claim_costs: [80, 120],
            # §13b: OSR pays an extra +$20 (to the bank, not the selling
            # independent) whenever it buys an already-placed claim off an
            # Independent -- see Game#buy_claim_from_independent!/
            # #independent_claim_price.
            independent_claim_surcharge: 20,
            # home base information
            coordinates: 'B14',
            color: '#8ed957',
            # This is the delivery bonus available to all deliveries made to this hex,
            # regardless of which entity makes the delivery.
            delivery_bonus: :r,
            delivery_bonus_amount: 10,
            # §13b: OSR's entities.rb entry exists regardless of optional
            # rules, but its home hex (B14) isn't a real base without
            # optional_new_corporations -- this flags that its home
            # delivery_bonus above must NOT be paid otherwise (see
            # Game#home_delivery_bonuses), since a Full Game without the
            # expansion would otherwise silently pay it to anyone
            # delivering to what's just an ordinary mine hex there.
            requires_optional_new_corporations: true,
            # This is the bonus OSR itself earns for delivering ore (any type) from a
            # mine it has claimed.
            claimed_delivery_bonus_amount: 10,
            type: :group_c,
            abilities: [
              { type: 'description',
                description: '+$10 per claimed mine delivery' },
            ],
          },
          {
            sym: 'MR',
            name: 'Mining Robotics',
            logo: 'g_2038/MR',
            simple_logo: 'g_2038/MR.alt',
            tokens: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            bases: [50, 50],
            stations: [50, 50],
            claim_limit: 14,
            claim_costs: [40, 40],
            # home base information
            coordinates: 'O13',
            color: '#FA8072',
            type: :group_c,
          },
          {
            sym: 'AL',
            name: 'Asteroid League',
            logo: 'g_2038/AL',
            simple_logo: 'g_2038/AL.alt',
            tokens: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            bases: [50, 50, 50, 50, 50, 50, 50],
            stations: [50, 50, 50, 50],
            claim_costs: [60, 75, 100],
            claim_limit: 15,
            # AL (Phases IV-V) is the only corp that can ever actually hold
            # 4 ships at once -- see Game#warn_on_four_ships?/ship_selector.
            # rb's four_ship_warning for why that specific count is what
            # can make a single Auto click slow.
            warn_on_four_ships: true,
            # home base information
            coordinates: 'H10',
            color: '#fa3d58',
            type: :group_d,
          },
        ].freeze
      end
    end
  end
end
