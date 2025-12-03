# frozen_string_literal: true

# game requires these files, which are the "meta", "map" and "entities" files for 1835,
# as well as the "base" and "round/operating" files from the engine
# unclear if this is all correct, the game might need new or other files as well as these.
# will keep this in mind as development continues.

require_relative '../base'
#why is this here?  1830 doesn't have this requirement?
require_relative '../../round/operating'
require_relative 'meta'
require_relative 'map'
require_relative 'entities'

module Engine
  module Game
    module G1835
      # gams is subclassed off of G-B
      class Game < Game::Base
        # this is where the required 1835 files are formally included
        # Where are the Game- files formally included?
        include_meta(G1835::Meta)
        # I assume that "G1835::" is optional here, as long as this file is in the same directory as the other two cited files.
        include G1835::Entities
        include G1835::Map

        # Definitions of the codes for each color?  Not sure this is working right.
        # changes to these colors don't seem to propogate to the screen itself.
        register_colors(black: '#37383a',
                        seRed: '#f72d2d',
                        bePurple: '#2d0047',
                        peBlack: '#000',
                        beBlue: '#c3deeb',
                        heGreen: '#78c292',
                        oegray: '#6e6966',
                        weYellow: '#ebff45',
                        beBrown: '#54230e',
                        gray: '#6e6966',
                        red: '#d81e3e',
                        turquoise: '#00a993',
                        blue: '#0189d1',
                        brown: '#7b352a')

        CURRENCY_FORMAT_STR = '%sM'
        # game end current or, when the bank is empty
        GAME_END_CHECK = { bank: :current_or }.freeze
        # bankrupt is allowed, player leaves game
        BANKRUPTCY_ALLOWED = true

        BANK_CASH = 12_000
        PAR_PRICES = {
          'PR' => 154,
          'BY' => 92,
          'SX' => 88,
          'BA' => 84,
          'WT' => 84,
          'HE' => 84,
          'MS' => 80,
          'OL' => 80,
        }.freeze
        CERT_LIMIT = { 3 => 19, 4 => 15, 5 => 12, 6 => 11, 7 => 9 }.freeze

        STARTING_CASH = { 3 => 600, 4 => 475, 5 => 390, 6 => 340, 7 => 310 }.freeze
        # company gets money per initial share sold
        CAPITALIZATION = :incremental

        # Shares may be sold individually, meaning that a given company can drop multiple spaces,
        # but the sellers sells each share for progressively less value.
        MUST_SELL_IN_BLOCKS = false

        # defines what the stock market looks like. Each [] is a row.
        # looks like the rows with blanks need to be formatted differently, no %w treatment there.

        MARKET = [['',
                   '',
                   '',
                   '',
                   '132',
                   '148',
                   '166',
                   '186',
                   '208',
                   '232',
                   '258',
                   '286',
                   '316',
                   '348',
                   '382',
                   '418'],
                  ['',
                   '',
                   '98',
                   '108',
                   '120',
                   '134',
                   '150',
                   '168',
                   '188',
                   '210',
                   '234',
                   '260',
                   '288',
                   '318',
                   '350',
                   '384'],
                  %w[82
                     86
                     92p
                     100
                     110
                     122
                     136
                     152
                     170
                     190
                     212
                     236
                     262
                     290
                     320],
                  %w[78
                     84p
                     88p
                     94
                     102
                     112
                     124
                     138
                     154p
                     172
                     192
                     214],
                  %w[72 80p 86 90 96 104 114 126 140],
                  %w[64 74 82 88 92 98 106],
                  %w[54 66 76 84 90]].freeze

        # defines the phases to the game (based on train purchases)
        PHASES = [
          {
            # This isn't using the modern convention, which names the phase based on the type of train, but this is how the rules are written.
            name: '1.1',
            on: '2',
            train_limit: { minor: 2, major: 4 },
            tiles: [:yellow],
            operating_rounds: 1,
          },
          {
            name: '1.2',
            on: '2+2',
            train_limit: { minor: 2, major: 4 },
            tiles: [:yellow],
            operating_rounds: 1,
          },
          {
            name: '2.1',
            on: '3',
            train_limit: { minor: 2, major: 4 },
            tiles: %i[yellow green],
            operating_rounds: 2,
          },
          {
            name: '2.2',
            on: '3+3',
            train_limit: { major: 4, minor: 2 },
            tiles: %i[yellow green],
            operating_rounds: 2,
          },
          {
            name: '2.3',
            on: '4',
            train_limit: { prussian: 4, major: 3, minor: 1 },
            tiles: %i[yellow green],
            operating_rounds: 2,
          },
          {
            name: '2.4',
            on: '4+4',
            train_limit: { prussian: 4, major: 3, minor: 1 },
            tiles: %i[yellow green],
            operating_rounds: 2,
          },
          {
            name: '3.1',
            on: '5',
            train_limit: { prussian: 3, major: 2 },
            tiles: %i[yellow green],
            operating_rounds: 3,
            events: { close_companies: true },
          },
          {
            name: '3.2',
            on: '5+5',
            train_limit: { prussian: 3, major: 2 },
            tiles: %i[yellow green brown],
            operating_rounds: 3,
          },
          {
            name: '3.3',
            on: '6',
            train_limit: { prussian: 3, major: 2 },
            tiles: %i[yellow green brown],
            operating_rounds: 3,
          },
          {
            name: '3.4',
            on: '6+6',
            train_limit: { prussian: 3, major: 2 },
            tiles: %i[yellow green brown],
            operating_rounds: 3,
          },
        ].freeze

        TRAINS = [{ name: '2', distance: 2, price: 80, rusts_on: '4', num: 9 },
                  { name: '2+2', distance: 2, price: 120, rusts_on: '4+4', num: 4 },
                  { name: '3', distance: 3, price: 180, rusts_on: '6', num: 4 },
                  { name: '3+3', distance: 3, price: 270, rusts_on: '6+6', num: 3 },
                  { name: '4', distance: 4, price: 360, num: 3 },
                  { name: '4+4', distance: 4, price: 440, num: 1 },
                  { name: '5', distance: 5, price: 500, num: 2 },
                  { name: '5+5', distance: 5, price: 600, num: 1 },
                  { name: '6', distance: 6, price: 600, num: 2 },
                  { name: '6+6', distance: 6, price: 720, num: 4 }].freeze

        # Not sure what this means
        LAYOUT = :pointy

        # I assume this indicates that you go down 1 per block, not 1 per share
        SELL_MOVEMENT = :down_block

        HOME_TOKEN_TIMING = :float

        def setup
          # for each corporation, set the par value and flag the coroporation as having been IPO'ed
          # not clear why this is necessary.
          corporations.each do |i|
            @stock_market.set_par(i, @stock_market.par_prices.find do |p|
                                       p.price == PAR_PRICES[i.id]
                                     end)
            i.ipoed = true
          end
        end

        # defines the private company draft phase.
        # unclear why "reverse_order" is set to "true" here.
        def init_round
          G1835::Round::Draft.new(self,
                                  [G1835::Step::Draft],
                                  reverse_order: true)
        end

        # defines an operating round as having the enumerated steps, all coming from the engine code.
        # this seems like a work in progress, likely where the prior developer stopped working on the code.
        # Each enumerated step is a class defined in the engine code, which does the actual work.
        # Thus, this list has steps for checking bankruptcies, building special track and tokens, laying track/token/routes, paying dividends, and discarding/buying trains.
        # By comparison, 1830 also has an "exchange" step, a "buy company" step, and a "home token" step.
        # These steps are not needed in 1835, as the game does not have these features.
        # Unclear whether 1835 needs any additional operating round steps, need to investigate this.
        def operating_round(round_num)
          Engine::Round::Operating.new(self, [
            Engine::Step::Bankrupt,
            Engine::Step::SpecialTrack,
            Engine::Step::SpecialToken,
            Engine::Step::Track,
            Engine::Step::Token,
            Engine::Step::Route,
            Engine::Step::Dividend,
            Engine::Step::DiscardTrain,
            Engine::Step::BuyTrain,
          ], round_num: round_num)
        end
        # Do we need to define a stock round?  I don't see one in the code.
        # The 1830 code has several steps defined in the stock round, but they
        # all appear to be extra things can happen in 1830 specifically.
      end
    end
  end
end
