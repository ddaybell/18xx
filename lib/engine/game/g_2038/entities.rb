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
            # A corp may buy this for $1-$50 (its printed value), not the
            # engine's generic half-to-double-value default (§7.4).
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
            # TODO: Phase 7: add custom ability type for $15/round treasury income
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
                  ' $10 bonus per Ice ore delivered. Must draw a second tile if first drawn has no Ice mines.',
            delivery_bonus: :I,
            # TODO: Phase 7: add custom ability type for second-tile-draw-if-no-ice exploration rule
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
                  ' $10 bonus per Rare ore delivered. Must draw a second tile if first drawn has no Rare mines.',
            delivery_bonus: :R,
            # TODO: Phase 7: add custom ability type for second-tile-draw-if-no-rare exploration rule
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
                  ' $10 bonus per Nickel ore delivered.',
            delivery_bonus: :N,
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
            # TODO: Phase 7: add custom ability type for +1 MP bonus
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
            # TODO: Phase 7: add custom ability type for draw-2-choose-1 exploration rule
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
            # A corp may buy this for $1-$120 (its printed value), not the
            # engine's generic half-to-double-value default (§7.4).
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
            # Formation is a player-forced choice (Phase 3-4), not an
            # automatic share grant -- see G2038::Step::FormAsteroidLeague
            # and Game#form_asteroid_league!. Forced unconditionally by
            # Phase 5 if not yet used (event_independents_must_join_league!
            # implies AL already exists by then via the Phase 4 event).
            # No longer modeled as a choose_ability (that mechanism can
            # only ever be a non-blocking side option -- confirmed with the
            # user this must interrupt play and force a real yes/no).
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
            abilities: [],
          },
        ].freeze

        # Every CORPORATIONS background color is light enough for black
        # text (confirmed with the user) -- set once here instead of on
        # each entry (a few already redundantly set text_color: 'black'
        # themselves; those are harmless no-ops against this default).
        # Doesn't touch MINORS -- init_minors never applies
        # corporation_opts, and several of those independents' colors
        # (navy, purple, dark red, etc.) genuinely need white text.
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
            delivery_bonus: :r,
            delivery_bonus_amount: 20,
            coordinates: 'J2',
            color: '#3eb75b',
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
            delivery_bonus: :n,
            delivery_bonus_amount: 10,
            coordinates: 'O1',
            color: '#fefc5d',
            text_color: 'black',
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
            claim_limit: 6,
            delivery_bonus: :i,
            delivery_bonus_amount: 20,
            coordinates: 'A1',
            color: '#f66936',
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
            delivery_bonus: :i,
            delivery_bonus_amount: 10,
            coordinates: 'J18',
            color: '#cc4f8c',
            text_color: 'black',
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
            delivery_bonus: :n,
            delivery_bonus_amount: 10,
            coordinates: 'F18',
            color: '#FFDB58',
            text_color: 'black',
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
            # Home base bonus: +$10/Rare delivered by *anyone* (same
            # home_delivery_bonus mechanic as VP/MM/LE/OPC/RCC's own
            # bonuses -- confirmed with the user this one is plain Rare,
            # not "any ore," despite the setup instructions' separately-
            # described "+10/all claims" ability below being unrelated).
            delivery_bonus: :r,
            delivery_bonus_amount: 10,
            # Placement per §13b: "randomly draw two asteroid tiles...
            # place the On-Site Refining START base... on the tile
            # located near Drill Hound's starting hex" -- B14 confirmed
            # by the user as the correct hex.
            coordinates: 'B14',
            color: '#8ed957',
            text_color: 'black',
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
            # Placement per §13b: "...the Mining Robotics START base...
            # on the tile located near Ice Finder's starting hex" -- O13
            # confirmed by the user as the correct hex.
            coordinates: 'O13',
            color: '#FA8072',
            text_color: 'black',
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
            coordinates: 'H10',
            color: '#fa3d58',
            type: :group_d,
          },
        ].freeze
      end
    end
  end
end
