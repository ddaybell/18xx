# frozen_string_literal: true

module Engine
  module Game
    module G1835
      # Module contains all the definitions of each entity in the game (privates, majors, minors)
      module Entities
        # Constant array defining all the private companies
        COMPANIES = [
          {
            name: 'Leipzig-Dresdner Bahn',
            sym: 'LD',
            value: 190,
            revenue: 20,
            auction_row: 2,
            row_position: 2,
            desc: 'Leipzig-Dresdner Bahn - Sachsen Direktor Papier',
            # defines what abilities the private has.
            # LD comes with the director's share of the SX (SX_0)
            # LD cannot be bought by a major (Not sure why this is there, none of the privates can be bought)
            #    I think the prior developer just copied the B&O private text and forgot to change it.
            # LD closes when the SX buys a train
            abilities: [{ type: 'shares', shares: 'SX_0' },
                        { type: 'no_buy' },
                        { type: 'close', when: 'bought_train', corporation: 'SX' }],
            color: :red,
          },
          {
            name: 'Ostbayrische Bahn',
            sym: 'OBB',
            value: 120,
            revenue: 10,
            auction_row: 4,
            row_position: 4,
            desc: 'Ostbayrische Bahn - 2 Tiles on M15, M17 extra (one per OR) and without cost',
            # OB can "teleport" one of the indicated tiles to each of the indicated hexes
            # when owned by a player
            # tiles are free
            # during track and token phase
            # two tiles are available
            # OB comes with a BY share
            abilities: [
              {
                # Why is this type "teleport" instead of type "tile lay"?
                type: 'teleport',
                description: "Place a free track tile at m15, M17 at any time during the corporation's operations.",
                # Why is this "player" and not "corporation" like the NF?
                owner_type: 'player',
                hexes: %w[M15 M17],
                tiles: %w[3 4 7 8 9 58],
                free_tile_lay: true,
                # Why is this "track_and_token" instead of "owning_corp_or_turn"?
                when: 'track_and_token',
                count: 2,
              },
              { type: 'shares', shares: 'BY_1' },
            ],
            color: :turquoise,
          },
          {
            name: 'Nürnberg-Fürth',
            sym: 'NF',
            value: 100,
            revenue: 5,
            auction_row: 1,
            row_position: 1,
            desc: 'Nürnberg-Fürth Bahn, Director of AG may lay token on L14 north or south',
            # NF can lay a token
            # during an owners corporation's turn
            # by a corporation owned by owner
            # in the NF hex
            # it's free
            abilities: [{ type: 'shares', shares: 'BY_2' }, {
              type: 'token',
              when: 'owning_corp_or_turn',
              owner_type: 'corporation',
              hexes: ['L14'],
              city: 3,
              price: 0,
              teleport_price: 0,
              count: 1,
              extra_action: true,
            }],
            color: :turquoise,
          },
          {
            name: 'Hannoversche Bahn',
            sym: 'HB',
            value: 160,
            revenue: 30,
            auction_row: 4,
            row_position: 1,
            desc: '10 Percent Share of Preussische Bahn on Exchange',
            # HB can be exchanged for a share of the Prussian
            # during the indicated phases
            abilities: [
              {
                type: 'exchange',
                corporations: %w[PR_1],
                owner_type: 'player',
                when: ['Phase 2.3', 'Phase 2.4', 'Phase 3.1'],
                # reserved papers perhaps a option
                from: 'ipo',
              },
            ],
            color: :oegray,
          },
          {
            name: 'Pfalzbahnen',
            sym: 'PB',
            value: 150,
            revenue: 15,
            auction_row: 4,
            row_position: 5,
            desc: 'Can lay a tile on L6 and Token on L6 if Baden AG is active already',
            # PB can lay a tile on the indicated hex
            # during owner's corporation's turn
            # can also lay a token, but only after the BA has laid its token?
            # it's all free
            # comes with a BY share
            abilities: [
              {
                type: 'teleport',
                owner_type: 'player',
                free_tile_lay: true,
                hexes: ['L6'],
                when: 'track_and_token',
                tiles: %w[210 211 212 213 214 215],
              },
              { type: 'shares', shares: 'BY_3' },
              {
                type: 'token',
                when: 'owning_corp_or_turn',
                owner_type: 'corporation',
                hexes: ['L6'],
                city: 3,
                price: 0,
                teleport_price: 0,
                count: 1,
                extra_action: true,
              },
            ],
            color: :turquoise,
          },
          {
            name: 'Braunschweigische Bahn',
            sym: 'BB',
            value: 130,
            revenue: 25,
            auction_row: 3,
            row_position: 4,
            desc: 'Can be exchanged for a 10% share of Preussische Bahn',
            # BB can be exchanged for a share of the Prussian
            # during the indicated phases
            abilities: [
              {
                type: 'exchange',
                corporations: %w[PR_2],
                owner_type: 'player',
                when: ['Phase 2.3', 'Phase 2.4', 'Phase 3.1'],
                from: 'ipo',
              },
            ],
            color: :oegray,
          },
          {
            name: 'Bayerische Eisenbahn Direktor',
            sym: 'BYD',
            value: 184,
            revenue: 0,
            auction_row: 3,
            row_position: 3,
            desc: 'Bayerische Eisenbahn Direktor - 20% share of Bayrische Eisenbahn',
            # BYD comes with the director's share of the BY
            # it is exchanged for the director's share of the BY upon purchase
            abilities: [
              {
                type: 'shares',
                shares: 'BY_0',
                description: '20% share of Bayrische Eisenbahn',
              },
              {
                type: 'exchange',
                corporations: %w[BY_0],
                owner_type: 'player',
                when: ['sold'], # or ['bought'] depending on engine conventions 
                from: 'ipo',
              },
            ],
            color: :turquoise,
          }
        ].freeze

        # Constant array defining all the public companies/corporations
        CORPORATIONS = [
          {
            sym: 'BY',
            name: 'Bayrische Eisenbahn',
            logo: '1835/BY',
            simple_logo: '1835/BY.alt',
            tokens: [0, 0, 0, 0, 0],
            float_percent: 50,
            shares: [20, 10, 10, 10, 10, 10, 10, 10, 10],
            #home token
            coordinates: 'O15',
            color: :turquoise,
          },
          {
            sym: 'SX',
            name: 'Sächsische Eisenbahn',
            logo: '1835/SX',
            simple_logo: '1835/SX.alt',
            tokens: [0, 0, 0],
            float_percent: 50,
            shares: [20, 10, 10, 10, 10, 10, 10, 10, 10],
            coordinates: 'H16',
            color: '#d81e3e',
          },
          {
            sym: 'BA',
            name: 'Badische Eisenbahn',
            logo: '1835/BA',
            simple_logo: '1835/BA.alt',
            tokens: [0, 0],
            # indicates that this is a mid-tier company?
            type: 'mid',
            float_percent: 50,
            shares: [20, 10, 10, 10, 10, 10, 10, 20],
            coordinates: 'L6',
            color: '#7b352a',
          },
          {
            sym: 'WT',
            name: 'Württembergische Eisenbahn',
            logo: '1835/WT',
            simple_logo: '1835/WT.alt',
            tokens: [0, 0],
            float_percent: 50,
            # mid-tier company?
            type: 'mid',
            shares: [20, 10, 10, 10, 10, 10, 10, 20],
            # what is this used for?
            last_cert: ['WT_7'],
            coordinates: 'M9',
            color: :yellow,
            # needs this because background is a light color (yellow)
            text_color: 'oegray',
          },
          {
            sym: 'HE',
            name: 'Hessische Eisenbahn',
            logo: '1835/HE',
            simple_logo: '1835/HE.alt',
            tokens: [0, 0],
            # indicates that this is a mid-tier company?
            type: 'mid',
            float_percent: 50,
            shares: [20, 10, 10, 10, 10, 10, 10, 20],
            # what is this used for?  
            last_cert: %w[HE_7],
            coordinates: 'J8',
            color: :green,
          },
          {
            sym: 'MS',
            name: 'Eisenbahn Mecklenburg Schwerin',
            logo: '1835/MS',
            simple_logo: '1835/MS.alt',
            tokens: [0, 0],
            percent: 10,
            # lower tier company?
            type: 'low',
            float_percent: 60,
            shares: [20, 10, 20, 20, 10, 10, 10],
            # the shares order creates a 10 share company, but the first 3 sold papers are 20%
            # above line was a comment by the original coder, not sure what it means.
            coordinates: 'C13',
            color: :violet,
          },
          {
            sym: 'OL',
            name: 'Oldenburgische Eisenbahn',
            logo: '1835/OL',
            simple_logo: '1835/OL.alt',
            tokens: [0, 0],
            float_percent: 60,
            # lower tier company?
            type: 'low',
            shares: [20, 10, 20, 20, 10, 10, 10],
            # the shares order creates a 10 share company, but the first 3 sold papers are 20%
            # above comment was by the original coder, not sure what it means
            coordinates: 'D6',
            color: '#6e6966',
          },

          {
            sym: 'PR',
            name: 'Preussische Eisenbahn',
            logo: '1835/PR',
            simple_logo: '1835/PR.alt',
            tokens: [0, 0, 0, 0, 0],
            # 10% shares:PR_0 (P2)(Dir), PR_1 (HB), PR_2 (BB), PR_3 (P4), PR_4, PR_5, PR_6, PR_7; 
            # 5% shares PR_9 (P1), PR_10 (P3), PR_11 (P5), PR_12 (P6)
            # WARNING!! This doesn't look right.  Where is PR_8?  
            # Check this code and the minors below, once we get the conversion code operational.
            shares: [10, 10, 10, 10, 10, 10, 10, 10, 5, 5, 5, 5],
            # shares for minors and Privates should be reserved
            coordinates: 'E19',
            color: '#37383a',
          },
        ].freeze

        # Constant array defining all the minors
        MINORS = [
          {
            sym: 'P1',
            name: 'Bergisch Märkische Bahn',
            logo: '1835/PR',
            simple_logo: '1835/PR.alt',
            tokens: [0],
            auction_row: 2,
            row_position: 1,
            abilities: [
              {
                type: 'exchange',
                corporations: %w[PR_9],
                owner_type: 'player',
                when: ['Phase 2.3', 'Phase 2.4', 'Phase 3.1'],
                # reserved papers perhaps a option
                from: 'ipo',
              },
            ],
            coordinates: 'H2',
            color: '#37383a',
          },
          {
            sym: 'P2',
            name: 'Berlin Potsdamer Bahn',
            logo: '1835/PR',
            simple_logo: '1835/PR.alt',
            tokens: [0],
            auction_row: 2,
            row_position: 3,
            abilities: [
              {
                type: 'exchange',
                corporations: %w[PR_0x],
                owner_type: 'player',
                when: ['Phase 2.3', 'Phase 2.4', 'Phase 3.1'],
                # reserved papers perhaps a option
                from: 'ipo',
              },
            ],
            coordinates: 'E19',
            color: '#37383a',
          },
          {
            sym: 'P3',
            name: 'Magdeburger-Bahn',
            logo: '1835/PR',
            simple_logo: '1835/PR.alt',
            tokens: [0],
            auction_row: 3,
            row_position: 1,
            abilities: [
              {
                type: 'exchange',
                corporations: %w[PR_10],
                owner_type: 'player',
                when: ['Phase 2.3', 'Phase 2.4', 'Phase 3.1'],
                # reserved papers perhaps a option
                from: 'ipo',
              },
            ],
            coordinates: 'F14',
            color: '#37383a',
          },
          {
            sym: 'P4',
            name: 'Köln-Mindener Bahn',
            logo: '1835/PR',
            simple_logo: '1835/PR.alt',
            tokens: [0],
            auction_row: 3,
            row_position: 2,
            abilities: [
              {
                type: 'exchange',
                corporations: %w[PR_3],
                owner_type: 'player',
                when: ['Phase 2.3', 'Phase 2.4', 'Phase 3.1'],
                # reserved papers perhaps a option
                from: 'ipo',
              },
            ],
            coordinates: 'G5',
            color: '#37383a',
          },
          {
            sym: 'P5',
            name: 'Berlin Stettiner Bahn',
            logo: '1835/PR',
            simple_logo: '1835/PR.alt',
            tokens: [0],
            auction_row: 4,
            row_position: 2,
            abilities: [
              {
                type: 'exchange',
                corporations: %w[PR_11],
                owner_type: 'player',
                when: ['Phase 2.3', 'Phase 2.4', 'Phase 3.1'],
                # reserved papers perhaps a option
                from: 'ipo',
              },
            ],
            coordinates: 'E19',
            color: '#37383a',
          },
          {
            sym: 'P6',
            name: 'Altona Kiel Bahn',
            logo: '1835/PR',
            simple_logo: '1835/PR.alt',
            tokens: [0],
            auction_row: 4,
            row_position: 3,
            abilities: [
              {
                type: 'exchange',
                corporations: %w[PR_12],
                owner_type: 'player',
                when: ['Phase 2.3', 'Phase 2.4', 'Phase 3.1'],
                # reserved papers perhaps a option
                from: 'ipo',
              },
            ],
            coordinates: 'C11',
            color: '#37383a',
          },
        ].freeze
      end
    end
  end
end
