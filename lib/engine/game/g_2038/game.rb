# frozen_string_literal: true

require_relative 'meta'
require_relative 'map'
require_relative 'entities'
require_relative 'corporation'
require_relative '../base'
require_relative 'round/operating'
require_relative 'step/waterfall_auction'
require_relative 'step/company_pending_par'
require_relative 'step/buy_ship'
require_relative 'step/discard_ship'
require_relative 'step/dividend'
require_relative 'step/route'
require_relative 'step/form_asteroid_league'
require_relative 'step/buy_infrastructure'
require_relative 'combo_generator'
require_relative 'autorouter'
require_relative 'optional_rules'
require_relative 'autorouter_support'
require_relative 'infrastructure'
require_relative 'asteroid_league'
require_relative 'growth_corporations'

module Engine
  module Game
    module G2038
      class Game < Game::Base
        include_meta(G2038::Meta)
        include Map
        include Entities
        include OptionalRules
        include Autorouting
        include Infrastructure
        include AsteroidLeague
        include GrowthCorporations

        attr_reader :mine_state, :al_reserved_shares, :al_independents_ever_offered, :al_corporation,
                    :fast_buck_income_recipient, :hex_assignments

        CORPORATION_CLASS = G2038::Corporation

        TILE_TYPE = :lawson
        TRACK_RESTRICTION = :permissive
        SELL_BUY_ORDER = :sell_buy
        SELL_AFTER = :p_any_operate
        SELL_MOVEMENT = :down_block
        CURRENCY_FORMAT_STR = '$%s'

        # The base game's default (`%i[blue gray red]`) treats these colors
        # as impassable terrain unless a hex's tile has a path pointing back
        # (`Hex#targeting?`, checked in `Game::Base#connect_hexes`) -- a
        # normal assumption when blue/gray mean water/mountains. For us they
        # just mean unexplored/explored asteroids, and since going trackless
        # (see map.rb) our tiles have no paths/exits at all, so every
        # blue/gray hex was silently cut off from its neighbors. There's no
        # genuinely impassable terrain in this game -- ships fly anywhere.
        IMPASSABLE_HEX_COLORS = [].freeze

        # A bid only commits cash while it's the current high bid on that
        # private; being outbid releases the cash for other bids/purchases
        # (rule 5.12).
        ONLY_HIGHEST_BID_COMMITTED = true

        BANK_CASH = 10_000
        SHORT_GAME_BANK_CASH = 4_000

        CERT_LIMIT = { 3 => 22, 4 => 16, 5 => 13, 6 => 11 }.freeze
        # §13a (short game): "The certificate limits are reduced." 
        SHORT_GAME_CERT_LIMIT = { 3 => 17, 4 => 13, 5 => 10, 6 => 9 }.freeze
        # §13b (extra companies variant): "The Certificate Limit is increased" 
        # once OSR/MR are in play mutually exclusive with the Short Game (see
        # optional_new_corporations' incompatibility check in setup).
        NEW_CORPORATIONS_CERT_LIMIT = { 3 => 27, 4 => 20, 5 => 16, 6 => 13 }.freeze

        STARTING_CASH = { 3 => 600, 4 => 450, 5 => 360, 6 => 300 }.freeze

        # §13d: variant charter cards for 6 of the 12 Private
        # companies -- cheaper certificates, and PI/TS/VA/RS/ST/AE income
        # unchanged. Critically, TS/VA/RS no longer grant a TSI share at
        # all in this variant (their `shares` ability is simply dropped);
        # PI/ST/AE keep their existing abilities untouched. Only the overridden 
        # fields are listed -- game_companies below merges each of these onto its
        # matching COMPANIES entry by sym, leaving every other field (incl.
        # every non-listed company, FB/IF/DH/OC/TH/LY) untouched.
        VARIANT_START_PACK_COMPANIES = {
          'PI' => { value: 35, max_price: 35 },
          'TS' => { value: 20, max_price: 20,
                    desc: 'If owned by a corporation, may place 1 free Base on ANY explored and unclaimed tile.',
                    color: nil,
                    abilities: [
                      { type: 'generic', subtype: 'free_base', description: 'Free base, any explored hex',
                        when: 'owning_corp_or_turn', count: 1, remove: '5' },
                    ] },
          'VA' => { value: 40, max_price: 40,
                    desc: 'If owned by a corporation, may place 1 free Refueling Station within range.',
                    color: nil,
                    abilities: [
                      { type: 'generic', subtype: 'free_station', description: 'Free refueling station, in range',
                        when: 'owning_corp_or_turn', count: 1, remove: '5' },
                    ] },
          'RS' => { value: 60, max_price: 60,
                    desc: 'If owned by a corporation, may place 1 free Claim within range.',
                    color: nil,
                    abilities: [
                      { type: 'generic', subtype: 'free_claim', description: 'Free claim, in range',
                        when: 'owning_corp_or_turn', count: 1, remove: '5' },
                    ] },
          'ST' => { value: 160, revenue: 20 },
          'AE' => { value: 160, revenue: 30 },
        }.freeze

        def game_companies
          return super unless optional_variant_start_pack

          super.map do |company|
            overrides = VARIANT_START_PACK_COMPANIES[company[:sym]]
            overrides ? company.merge(overrides) : company
          end
        end

        MARKET = [
          %w[71 80 90 101 113 126 140 155 171 188 206 225 245 266 288 311 335 360 386 413 441 470 500],
          %w[62 70 79 89 100p 112 125x 139 154 170 187 205 224 244 265 287 310 334 359 385 412 440 469],
          %w[54 61 69 78 88p 99 111 124 138 153 169 186 204 223 243 264],
          %w[46 53 60 68 77p 87 98 110 123 137 152 168 185],
          %w[36 45 52 59 67p 76 86 97 109 122 136],
          %w[24 35 44 51 58 66 75 85 96],
          %w[10z 23 34 43 50 57 65],
        ].freeze

        MARKET_TEXT = Base::MARKET_TEXT.merge(
          par: 'Public Corps Par',
          par_1: 'Asteroid League Par',
          par_2: 'All Growth Corps Par',
        )

        STOCKMARKET_COLORS = Base::STOCKMARKET_COLORS.merge(
          par: :gray,
          par_1: :brown,
          par_2: :blue,
        )

        ENTITY_DISPLAY_ORDER = %w[FB IF DH OC TH LY TSI RU VP LE MM OPC RCC AL].freeze
        HIDE_TILE_TRACK = true

        # Three categories -- every non-AL corporation shares the same limit
        # regardless of its group_a/b/c release-timing group (see #train_limit
        # below, which reads this directly rather than going through the
        # generic Phase#train_limit's per-entity.type hash lookup; group_a/b/c/d
        # remain solely about release phase, not ship limits). The Asteroid
        # League cannot exist at all before Phase 3 (it forms no earlier than
        # the asteroid_league_can_form event on the '5/4' ship, which is what
        # brings in Phase 3 -- see event_asteroid_league_can_form!/PHASES
        # below), so SHIP_LIMIT_PHASE_1_2 carries no asteroid_league key at
        # all, not just a moot one; independents are gone by Phase 6, so that
        # key is simply absent there too.
        SHIP_LIMIT_PHASE_1_2 = { corporation: 4, independent: 2 }.freeze
        SHIP_LIMIT_PHASE_3_5 = { corporation: 3, asteroid_league: 4, independent: 1 }.freeze
        SHIP_LIMIT_PHASE_6 = { corporation: 2, asteroid_league: 3 }.freeze

        PHASES = [
          {
            name: '1',
            train_limit: SHIP_LIMIT_PHASE_1_2,
            tiles: [:yellow],
            operating_rounds: 2,
          },
          {
            name: '2',
            on: '4/3',
            train_limit: SHIP_LIMIT_PHASE_1_2,
            tiles: %i[yellow],
            operating_rounds: 2,
            status: %w[can_buy_bases_stations can_buy_companies can_form_growth_corps],
          },
          {
            name: '3',
            on: '5/4',
            train_limit: SHIP_LIMIT_PHASE_3_5,
            tiles: %i[yellow],
            operating_rounds: 2,
            status: %w[can_buy_bases_stations can_buy_companies can_form_growth_corps],
          },
          {
            name: '4',
            on: '6/5',
            train_limit: SHIP_LIMIT_PHASE_3_5,
            tiles: %i[yellow gray],
            operating_rounds: 2,
            status: %w[can_buy_bases_stations can_buy_companies],
          },
          {
            name: '5',
            on: '7/6',
            train_limit: SHIP_LIMIT_PHASE_3_5,
            tiles: %i[yellow gray],
            operating_rounds: 2,
            # can_buy_companies drops out here: every remaining private
            # closes and every independent merges into the AL this phase
            # (close_remaining_companies/independents_must_join_league),
            # so there's nothing left to buy from a player and no
            # independent left to buy a claim from. Bases/stations/ship-
            # trading (can_buy_bases_stations) stay available the rest of
            # the game.
            status: ['can_buy_bases_stations'],
          },
          {
            name: '6',
            on: '9/7',
            train_limit: SHIP_LIMIT_PHASE_6,
            tiles: %i[yellow gray],
            operating_rounds: 2,
            status: ['can_buy_bases_stations'],
          },
        ].freeze

        # 'can_buy_companies' is also the shared engine's own literal
        # status-flag name (see Step::BuyCompany#can_buy_company?) for
        # "corporations may buy private companies from players" -- kept
        # unrenamed so that stays correctly gated for free, and reused
        # here for the (same-lifecycle) independent-claim-purchase
        # extension. 'can_buy_bases_stations' is G2038-specific, covering
        # base/refueling-station purchases and placement plus inter-
        # company ship trading (Game#can_buy_train_from_others?) -- three
        # things that all unlock together in Phase 2 and, unlike the
        # companies/claims status, never turn back off.
        STATUS_TEXT = Base::STATUS_TEXT.merge(
          'can_buy_companies' =>
            ['Can Buy Companies', 'Corporations may buy private companies from players and buy claims from '\
                                   'independents'],
          'can_buy_bases_stations' =>
            ['Can Buy Bases/Stations', 'Corporations may buy and place bases and refueling stations, and buy '\
                                        'spaceships from other companies/corporations'],
          'can_form_growth_corps' =>
            ['Can Form Growth Corporations', 'Growth Corporations may be formed in Phases II and III, until the '\
                                              'Asteroid League forms.'],
        ).freeze

        # Spaceship names are movement/cargo_holds (e.g. '3/2' = 3 MP, 2 cargo holds),
        # matching the physical spaceship card naming. cargo_holds: is stored in
        # Train#@opts by the base engine; a custom Train subclass will expose it properly.
        TRAINS = [
          {
            name: 'Probe',
            distance: 4,
            cargo_holds: 0,
            price: 1,
            rusts_on: %w[4/3 6/2],
            num: 1,
          },
          {
            name: '3/2',
            distance: 3,
            cargo_holds: 2,
            price: 100,
            rusts_on: %w[5/4 7/3],
            num: 10,
            variants: [
              {
                name: '5/1',
                distance: 5,
                cargo_holds: 1,
                price: 100,
                rusts_on: %w[5/4 7/3],
              },
            ],
          },
          {
            name: '4/3',
            distance: 4,
            cargo_holds: 3,
            price: 200,
            rusts_on: %w[7/6 9/5],
            num: 10,
            variants: [
              {
                name: '6/2',
                distance: 6,
                cargo_holds: 2,
                price: 175,
                rusts_on: %w[7/6 9/5],
              },
            ],
          },
          {
            name: '5/4',
            distance: 5,
            cargo_holds: 4,
            price: 325,
            # Confirmed by the official Expansion Set rules clarifications:
            # "Upgrading a spaceship to a Phase VI ship IS a purchase. Thus,
            # upgrading a Phase III spaceship immediately advances the game
            # to Phase VI (removing all other Phase III spaceships from the
            # game)." Phase III specifically -- 6/5/7/6/9/7 (Phase IV-VI)
            # are confirmed permanent and do NOT rust, a separate, later
            # correction that doesn't apply here.
            rusts_on: '9/7',
            num: 6,
            variants: [
              {
                name: '7/3',
                distance: 7,
                cargo_holds: 3,
                price: 275,
                rusts_on: '9/7',
              },
            ],
            events: [{ 'type' => 'asteroid_league_can_form' }],
          },
          {
            name: '6/5',
            distance: 6,
            cargo_holds: 5,
            price: 450,
            num: 5,
            variants: [
              {
                name: '8/4',
                distance: 8,
                cargo_holds: 4,
                price: 400,
              },
            ],

            events: [{ 'type' => 'asteroid_league_must_form' }],
          },
          {
            name: '7/6',
            distance: 7,
            cargo_holds: 6,
            price: 600,
            num: 2,
            variants: [
              {
                name: '9/5',
                distance: 9,
                cargo_holds: 5,
                price: 550,
              },
            ],
            # close_remaining_companies lives here, not on Phase 5's own
            # hash entry -- confirmed live in browser (and by reading
            # Phase#buying_train!/#setup_phase!): only a *ship's* own
            # events actually get dispatched (ship.events.each, fired
            # from buying_train!); a phase hash's own events: key is read
            # into Phase#@events but never iterated/dispatched anywhere.
            # Attaching it to the ship that triggers Phase 5 (`on: '7/6'`
            # above) is what actually makes it fire, same as
            # independents_must_join_league already correctly does here.
            events: [{ 'type' => 'independents_must_join_league' }, { 'type' => 'close_remaining_companies' }],
          },
          {
            name: '9/7',
            distance: 9,
            cargo_holds: 7,
            price: 950,
            # §7.32's exception: "Phase VI ships may be purchased once
            # one Phase V spaceship has been bought" -- Phase name '5'
            # itself only begins once the first '7/6' is bought (`on:
            # '7/6'` above), so tying availability to that phase name is
            # exactly "after one Phase V ship," with no extra bookkeeping
            # needed. §13b overrides this specific count to 2 once OSR/MR
            # are in play -- see Step::BuyShip#buyable_trains, which
            # filters '9/7' back out of the depot list until then (this
            # available_on can't express a *count*, only a phase name).
            available_on: '5',
            num: 9,
            discount: {
              '5/4' => 250,
              '7/3' => 250,
              '6/5' => 250,
              '8/4' => 250,
              '7/6' => 250,
              '9/5' => 250,
            },
          },
        ].freeze

        EVENTS_TEXT = Base::EVENTS_TEXT.merge(
          'asteroid_league_can_form' => [
            'Asteroid League may be formed',
            'Owner of Asteroid Export Company may form the Asteroid League immediately when Phase III '\
            'begins, or at the beginning of each Stock or Operating round thereafter.',
          ],
          'asteroid_league_must_form' => [
            'Asteroid League must now form',
            'Owner of Asteroid Export Company must form Asteroid League immediately when Phase IV begins.',
          ],
          'independents_must_join_league' => [
            'Independents must join the Asteroid League',
            'Every Independent Company still active must merge into the Asteroid League immediately '\
            'when Phase V begins.',
          ],
          'close_remaining_companies' => [
            'Private companies close',
            'All private companies close. All pilots are removed from play.',
          ],
          'group_b_corps_available' => ['Group B Corporations become available'],
          'group_c_corps_available' => ['Group C Corporations become available'],
        ).freeze

        def bank_starting_cash
          optional_short_game ? SHORT_GAME_BANK_CASH : BANK_CASH
        end

        # §13d: "+$300 total starting money, divided by player count" --
        # confirmed as a flat addition on top of the base game's own
        # STARTING_CASH (the variant's printed totals -- $700/$525/$420/
        # $350 for 3/4/5/6 players -- are each exactly STARTING_CASH plus
        # 300/player_count, with no remainder at any player count).
        def init_starting_cash(players, bank)
          super
          return unless optional_variant_start_pack

          bonus = 300 / players.size
          players.each { |player| bank.spend(bonus, player) }
        end

        def game_cert_limit
          return SHORT_GAME_CERT_LIMIT if optional_short_game
          return NEW_CORPORATIONS_CERT_LIMIT if optional_new_corporations

          CERT_LIMIT
        end

        # Shared engine code (BuyTrain's buy_train_action, Game::Base#
        # rust_trains!, etc.) hardcodes "train"/"trains" in its own log
        # text, with no hook to override the wording -- 2038's vehicles are
        # spaceships. Rather than duplicating any of that logic just to
        # change a word, rewrite whatever it logged after the fact; cheap
        # and safe since every action already routes through here.
        def process_action(action, **kwargs)
          action = Action::Base.action_from_h(action, self) if action.is_a?(Hash)

          before = @log.size
          result = super
          rewrite_new_log_lines!(before)
          result
        end

        # @log[before..] can be nil, not [] -- a submitted ship flight
        # (Step::Route's SUBMIT_FLIGHT) rolls back its own local preview's
        # log lines (@log.slice!) before replaying the real flight, and if
        # the real replay logs fewer lines than the local preview did,
        # @log ends up *shorter* than `before`. Indexing a Ruby array
        # from a start past its own length returns nil, not an empty
        # array, and #each on that raised "undefined method `each' for
        # nil" -- found live in browser, crashing every Submit that hit
        # this shrink-then-regrow case and (from the player's
        # perspective) appearing to roll the whole turn back, since the
        # action never actually committed.
        def rewrite_new_log_lines!(before)
          @log[before..]&.each do |entry|
            next unless entry.message.is_a?(String)

            entry.message = shipify_log(entry.message)
            entry.message = tsi_pre_float_operates_message(entry.message)
          end
        end

        # Round::Operating#start_operating logs "<acting player> operates
        # TSI" the same generic way as any normal corp's turn -- misleading
        # here, since TSI's pre-float turn is really just "the ST owner
        # flies the Probe," not a full corporate turn. We rewrite that one 
        # line to say so explicitly. Gated on tsi_pre_float? being true right 
        # now (not just matching the text), so a genuinely-floated TSI's 
        # ordinary "X operates TSI" line is left alone.
        def tsi_pre_float_operates_message(message)
          tsi = corporation_by_id('TSI')
          return message unless tsi && tsi_pre_float?(tsi)

          match = message.match(/^(.+) operates TSI$/)
          return message unless match

          "#{match[1]} (ST private owner) operates TSI's Probe"
        end

        def shipify_log(message)
          message.gsub(/\btrains\b/, 'ships').gsub(/\btrain\b/, 'ship')
        end

        # Shared train-buying/Info-tab UI text built from this instead of a
        # hardcoded "train" (see Game::Base#train_word) says "ship" for 2038.
        def train_word
          'ship'
        end

        # Route-building is entirely client-side/local past the first
        # click (base selection) -- see View::Game::MapG2038#dim_by_hex_validity?
        # for the full reasoning. A non-active viewer's browser never
        # receives that local progress, so hex-validity dimming would
        # otherwise just show them a frozen, almost-entirely-dimmed map
        # for the whole turn -- confirmed with the user this conveys
        # nothing useful to them.
        def dim_only_active_player?
          true
        end

        def on_train_header
          'On Ship'
        end

        def train_limit_header
          'Ship Limit'
        end

        # The base implementation only shows the first entry of a phase's
        # `on:` list -- 2038 phases can have two ship types unlocked at
        # once (e.g. Phase 6 lists both 7/6 and 9/5), and buying either one
        # in the same tranche can trigger the phase change, so both need to
        # show, not just the first.
        def info_on_trains(phase)
          Array(phase[:on]).join(', ')
        end

        # Overrides the generic Game::Base#trains_str (used by the
        # corporation/minor charter's "Trains" line): shows this entity's
        # ships slowest-first, matching the same order Step::Route#
        # ship_rows and the auto-router's own turn-start priority use
        # (Step::Route#start_slowest_ship_search!) -- per the user.
        # Display-only, same shape as the base implementation otherwise
        # (obsolete ships still parenthesized) -- doesn't touch
        # entity.trains' own stored (acquisition) order.
        def trains_str(corporation)
          (corporation.system? ? corporation.shells : [corporation]).map do |c|
            if c.trains.empty?
              'None'
            else
              c.trains.sort_by { |t| ship_distance(c, t) }.map { |t| t.obsolete ? "(#{t.name})" : t.name }.join(' ')
            end
          end
        end

        # There is no separate pre-game "auction phase" -- the very first 
        # round is a normal Stock round, it just happens to also carry the 
        # WaterfallAuction step (see stock_round below) since that's how 
        # privates/independents get sold. The base engine's default 
        # `init_round` (`new_auction_round`, a dedicated 
        # Engine::Round::Auction) doesn't apply here.
        #
        # Can't just call new_stock_round -- its log line calls
        # round_description, which falls back to `@round.round_num` when
        # no explicit number is given, and @round is still nil this early
        # in Game::Base#initialize (this call *is* what @round is about to
        # become). Passing round_number explicitly sidesteps that.
        def init_round
          @log << "-- #{round_description('Stock', 1)} --"
          @round_counter += 1
          stock_round
        end

        # Only companies never yet bought (owner still nil) and not closed
        # -- WaterfallAuction#setup re-populates @companies fresh every
        # time a new Stock round is built, and a later Stock round must
        # only re-list whatever's actually still unsold, never something
        # already bought in an earlier round. Overrides Game::Base's
        # default (`@companies`, unfiltered), which is only ever correct
        # for a single one-shot auction.
        def initial_auction_companies
          super.select { |c| c.owner.nil? && !c.closed? }
        end

        # AE's owner may declare Asteroid League formation at the start of
        # any Stock or Operating round (§8), so the choice step is added to
        # both round types rather than just one. G2038::Step::BuySellParShares
        # (Phase 8) adds the option to trade in an independent for an
        # unfloated corp's president's certificate, surfaced directly in the
        # par UI alongside the normal par-price buttons.
        #
        # CompanyPendingPar/WaterfallAuction -- elsewhere the sole contents
        # of a dedicated pre-game Auction round -- are folded directly into
        # the ordinary Stock round instead. As long as any private/independent 
        # remains unsold, WaterfallAuction blocks ahead of BuySellParShares 
        # for whoever's turn comes up (its own `actions` goes empty the instant 
        # nothing's left to sell, at which point a turn flows straight into 
        # ordinary share buying with no extra step to pass through first) -- 
        # and the Stock round ends the exact same way any SR ever does, via 
        # Round::Stock's own all-entities-passed check, whether or not everything 
        # happened to sell out first.
        def stock_round
          Engine::Round::Stock.new(self, [
            G2038::Step::FormAsteroidLeague,
            G2038::Step::MergeIntoLeague,
            G2038::Step::DiscardShip,
            Engine::Step::SpecialTrack,
            G2038::Step::CompanyPendingPar,
            G2038::Step::WaterfallAuction,
            G2038::Step::BuySellParShares,
          ])
        end

        def operating_round(round_num)
          G2038::Round::Operating.new(self, [
            G2038::Step::FormAsteroidLeague,
            G2038::Step::MergeIntoLeague,
            Engine::Step::Bankrupt,
            G2038::Step::DiscardShip,
            G2038::Step::StockRepurchase,
            G2038::Step::Route,
            G2038::Step::StockRepurchase,
            G2038::Step::Dividend,
            G2038::Step::BuyShip,
            [G2038::Step::BuyCompany, { blocks: true }],
            G2038::Step::BuyInfrastructure,
          ], round_num: round_num)
        end

        # No special-casing needed for the very first round -- init_round
        # (above) is already a plain new_stock_round, so the ordinary
        # Stock -> Operating case below handles it uniformly with every
        # later Stock round, whether or not WaterfallAuction sold
        # everything during it.
        def next_round!
          @round =
            case @round
            when Engine::Round::Stock
              @operating_rounds = @phase.operating_rounds
              reorder_players
              new_operating_round
            when G2038::Round::Operating
              if @round.round_num < @operating_rounds
                or_round_finished
                new_operating_round(@round.round_num + 1)
              else
                @turn += 1
                or_round_finished
                or_set_finished
                new_stock_round
              end
            end
        end

        def bank_sort(entities)
          entities.sort_by { |e| ENTITY_DISPLAY_ORDER.index(e.id) || ENTITY_DISPLAY_ORDER.size }
        end

        def or_round_finished
          @mine_state.each_value do |state|
            state[:mines].each { |mine| mine[:used] = false }
          end
        end

        def cargo_holds_for_ship(ship)
          return 0 if ship.name == 'Probe'

          ship.name.split('/').last.to_i
        end

        def route_trains(entity)
          entity.runnable_trains
        end

        def can_run_route?(entity)
          !route_trains(entity).empty?
        end

        def revenue_str(route)
          route.hexes.map(&:id).join(' - ')
        end

        def route_distance(route)
          [route.hexes.size - 1, 0].max
        end

        def route_distance_str(route)
          "#{route_distance(route)}H"
        end

        # A hex counts as a deliverable destination if it is a transshipment
        # point or contains any placed base token (any company/corp).
        def deliverable_destination?(hex)
          return true if TRANSSHIPMENT_HEXES.include?(hex.id)

          hex_has_base?(hex)
        end

        # Shared by deliverable_destination? and can_place_station? -- both
        # need "does this hex have a placed base token (any company/corp)."
        # `city.tokens` is an array of token SLOTS, not placed tokens --
        # an unfilled slot holds `nil` rather than being absent from the
        # array (confirmed: an ordinary mine tile's city, `city=revenue:
        # 10` with no explicit `slots:0`, already carries one such empty
        # slot, `tokens == [nil]`). `!tokens.empty?` checks the SLOT COUNT
        # and is therefore true for that empty slot too -- `tokens.compact.
        # empty?` is the real "is anything actually placed here" check.
        def hex_has_base?(hex)
          hex.tile.cities.any? { |c| !c.tokens.compact.empty? }
        end

        EXPLORATION_BONUS = 10

        # `pay:` is false while G2038::Step::Route is still building a route
        # locally, unsubmitted (see Step::Route#local_choose!/@committing) --
        # the corp can't do anything with the bonus until the route step
        # ends anyway, so there's no need to move real cash (and log it)
        # for a flight that might still be discarded before it's ever
        # submitted. The real payment happens once, when the submitted
        # choice is actually replayed (live or on reload) with `pay: true`.
        def explore_hex!(hex_id, entity, pay: true)
          hex = hex_by_id(hex_id)
          tile_name = @hex_assignments[hex_id]

          mines =
            if tile_name && (tile = @tiles.find { |t| t.name == tile_name && !t.hex })
              # Random rotation (deterministic via the engine's seeded rand,
              # not Kernel#rand) so identically-typed mine tiles don't all
              # look the same way round -- purely cosmetic, tiles are
              # topologically symmetric under any rotation.
              tile.rotate!(rand % 6)
              hex.lay(tile)
              # Not update_tile_lists -- that's built for a normal upgrade
              # (new tile drawn from the pool, old one returned to it), but
              # a revealed mine tile never goes back into circulation. Just
              # remove it, so the Tile Manifest's count reflects what's
              # left un-revealed (Step::Route#rollback_local_flight!
              # reverses this if the exploring flight gets discarded).
              @tiles.delete(tile)
              MINE_DATA.fetch(tile_name, [])
            else
              []
            end

          @mine_state[hex_id] = {
            mines: mines.map { |m| m.merge(owner: nil, used: false) },
          }

          return unless pay

          recipient = probe_bonus_recipient(entity)
          bank.spend(EXPLORATION_BONUS, recipient)
          mine_count = mines.size
          @log << "#{entity.name} explores #{hex_id}: #{mine_count} #{mine_count == 1 ? 'mine' : 'mines'} found; "\
                  "#{recipient.name} receives #{format_currency(EXPLORATION_BONUS)}"
        end

        # True for TSI's own special pre-float turn -- flying the Probe
        # under ST's owner's control, not a normal operating turn (no real
        # president, no real revenue/price mechanics yet). Shared check
        # used both for who acts/collects (below) and for suppressing the
        # post-Route steps entirely during this turn (Dividend/BuyShip/
        # BuyCompany/BuyInfrastructure -- see their own `active?`
        # overrides).
        def tsi_pre_float?(entity)
          entity.respond_to?(:id) && entity.id == 'TSI' && !entity.floated?
        end

        # While TSI hasn't floated, the Probe's exploration bonus goes to the
        # owner of the ST private (who is flying it), not to TSI's treasury
        # (§6, Let's Play sheet).
        def probe_bonus_recipient(entity)
          return entity unless tsi_pre_float?(entity)

          st_owner = company_by_id('ST')&.owner
          # A leftover, never-bought ST sits owned by the bank (Case 3 --
          # see G2038::Step::WaterfallAuction#round_end_auction_complete),
          # not a real player -- that's not a valid bonus recipient, so
          # fall back to TSI itself same as if ST had no owner at all.
          st_owner&.player? ? st_owner : entity
        end

        def pickup_value(entity, hex_id, mine_idx)
          mine = @mine_state.dig(hex_id, :mines, mine_idx)
          return 0 unless mine

          mine[:owner] == entity.id ? mine[:claimed] : mine[:unclaimed]
        end

        # Revenue for a completed run. Loads are picked up (or not) hex by hex
        # during the trace and cannot be jettisoned; they only pay out when the
        # run ends at a base or transshipment point (§7.1). Ending at a
        # transshipment point with EMPTY holds earns its printed value instead.
        # Note that trace.size = 1 means that the ship has launched but not left
        # the starting hex yet.
        def trace_revenue(entity, ship, trace, cargo)
          return 0 if ship.name == 'Probe' || trace.size < 2
          return 0 unless deliverable_destination?(trace.last)

          cargo.sum { |c| c[:value] } + company_ore_bonus(entity, ship, cargo) +
            home_delivery_bonus(trace.last, cargo) + claim_delivery_bonus(entity, cargo)
        end

        # A transshipment point's printed value works like a mine with
        # unlimited availability (no "used" marker, any ship any number of
        # times) -- but unlike an ore pickup, collecting it is never
        # automatic: it requires an explicit click on the hex, same as any
        # mine (see Step::Route#transshipment_choice/pick_up_transshipment!,
        # the latter's own comment on why -- the rules permit ending a
        # flight at a transshipment point without collecting there), and
        # choosing to collect ends the ship's flight immediately. The
        # collected load still occupies one cargo hold like any other,
        # stacking with whatever ore the ship is already carrying.
        # Phase-scaled values (§8): A13/D2/H10/O11 go $30 -> $60 and H18
        # goes $20 -> $70 once gray tiles unlock at Phase 4 -- already
        # handled for free by the standard route_revenue(phase, train)
        # mechanism, since map.rb's tile codes for these hexes are already
        # `yellow_X|gray_Y`. Rendered as an offboard part (not a city) so
        # the standard off-board box display shows both values -- H10
        # carries a separate zero-revenue city alongside it purely for
        # AL's home token, so this only ever needs to look at .offboards.
        def transshipment_value(hex, ship)
          hex.tile.offboards.sum { |o| o.route_revenue(@phase, ship) }
        end

        # H10 (AL's home) stops paying the flat transshipment credit once
        # AL has actually formed and set up shop there -- it's a
        # competitive corp base now, not a neutral drop-off point. Still a
        # valid delivery destination for ordinary cargo either way
        # (deliverable_destination? also passes it via the "has a placed
        # base token" check, since AL's home token sits there from turn
        # one regardless of whether AL has formed) -- only the flat bonus
        # itself goes away.
        def transshipment_hex?(hex_id)
          return false unless TRANSSHIPMENT_HEXES.include?(hex_id)

          !(@asteroid_league_formed && Array(@al_corporation.coordinates).include?(hex_id))
        end

        # Phase 11c: a private company's face value only counts toward a
        # player's final score if the game ends *before* Phase 5. In the
        # ordinary case this is already moot by Phase 5 -- every private a
        # player could still hold (TS/VA/RS/PI) closes outright at that
        # point (event_close_remaining_companies!), dropping out of
        # player.companies on its own. This guard only still matters for
        # the rare edge case where ST is still open past Phase 5 (TSI
        # hasn't floated yet) -- ST keeps its own separate close trigger
        # and is deliberately exempt from the Phase 5 close event, so it
        # can otherwise linger as a player-held asset indefinitely.
        # Player#value's default formula
        # (cash + share prices + companies' face value - debt - penalty)
        # already handles everything else correctly out of the box,
        # including AL shares (AL is just a normal corporation with a
        # share_price once formed, no special-casing needed) and excluding
        # corp/company treasuries (never reached by Player#value at all).
        def player_value(player)
          value = super
          value -= player.companies.sum(&:value) unless phase.name.to_i < 5
          value
        end

        # AE stops counting as a certificate the moment the AL forms, even
        # though it doesn't actually close until AL buys its first ship. 
        # CERT_LIMIT_INCLUDES_PRIVATES (true, the base default) otherwise 
        # counts every held private uniformly.
        def num_certs(entity)
          certs = super
          certs -= 1 if @asteroid_league_formed && entity.respond_to?(:companies) &&
            entity.companies.any? { |c| c.id == 'AE' }
          certs
        end

        # Covers two distinct groups sharing one mechanism: the three
        # Independents (Phase 7 company abilities) AND the five standard
        # Corporations VP/LE/MM/OPC/RCC, each of
        # which earns a flat bonus for its own favored ore delivered
        # ANYWHERE (not tied to any specific hex).
        # This is NOT the same thing as home_delivery_bonus below (that
        # one pays whoever delivers to a specific hex, regardless of who
        # they are; this one pays a specific entity, regardless of where
        # they deliver). The amounts happen to all be $10 today, but each
        # is its own entities.rb value (own_delivery_bonus_amount) and can
        # stack with each other and with a home_delivery_bonus in the same
        # trace_revenue call.

        # Entity id -> [favored ore, amount], built from entities.rb's
        # own_delivery_bonus/own_delivery_bonus_amount fields on IF/DH/OC
        # (COMPANIES) and VP/LE/MM/OPC/RCC (CORPORATIONS) -- same
        # each_with_object pattern as home_delivery_bonuses below, just
        # keyed by sym instead of hex.
        def company_ore_bonuses
          @company_ore_bonuses ||= (COMPANIES + CORPORATIONS).each_with_object({}) do |data, h|
            next unless data[:own_delivery_bonus]

            h[data[:sym]] = [data[:own_delivery_bonus], data[:own_delivery_bonus_amount]]
          end
        end

        # Independent/pilot source ids whose own explore-time tile choice
        # always chains straight into a guaranteed follow-up popup (see
        # Step::Route#chain_hex_choice_popup?'s own comment for why this
        # is only ever safe for a power shaped exactly like Lucky's) --
        # built from entities.rb's chain_explore_popup field, same
        # each_with_object pattern as company_ore_bonuses, so a future
        # independent with the same kind of power is just a new field in
        # its own entities.rb entry, no route.rb changes needed.
        def chain_explore_popup_sources
          @chain_explore_popup_sources ||= COMPANIES.each_with_object([]) do |data, sources|
            sources << data[:sym] if data[:chain_explore_popup]
          end
        end

        # Independent/pilot source ids whose second draw is a genuine
        # player choice (which tile to place) rather than an automatic
        # placement -- built from entities.rb's chooses_own_redraw field,
        # same each_with_object pattern as chain_explore_popup_sources, so
        # a future independent with the same kind of power is just a new
        # field in its own entities.rb entry, no route.rb changes needed.
        def chooses_own_redraw_sources
          @chooses_own_redraw_sources ||= COMPANIES.each_with_object([]) do |data, sources|
            sources << data[:sym] if data[:chooses_own_redraw]
          end
        end

        # Ice Finder/Drill Hound/Ore Crusher/VP/LE/MM/OPC/RCC each earn a
        # flat bonus per unit of their favored ore actually delivered --
        # paid alongside the normal cargo revenue, not instead of it
        # (Phase 7 company abilities for the first three; a plain
        # Corporation Summary table entry for the other five). A Growth
        # Corp formed from one of the three Independents (Phase 8)
        # inherits the same bonus, but only for whichever ship its
        # specific pilot is assigned to this OR (pilot_ore_bonus) -- each
        # inherited pilot is assigned independently to its OWN ship (never
        # shared), so a corp holding two ore-bonus pilots at once (only
        # possible for AL, via Phase 9 mergers) would need two different
        # ships, each carrying its own bonus. VP/LE/MM/OPC/RCC's own bonus
        # comes directly from their own entity.id instead, no pilot
        # machinery involved -- it applies the same way whether that corp
        # was cash-started or reached via Growth Corp conversion from some
        # independent, since either way its entity.id ends up as (say)
        # 'MM', and this bonus is keyed off entity.id either way.
        def company_ore_bonus(entity, ship, cargo)
          ore, amount = company_ore_bonuses[entity.id]
          own_bonus = ore ? cargo.count { |c| c[:ore] == ore } * amount : 0

          own_bonus + pilot_ore_bonus(entity, ship, cargo)
        end

        # The ore bonus this SPECIFIC ship's assigned pilot grants, if any
        # -- 0 for an unconverted independent (handled directly above, via
        # entity.id) or a ship with no pilot assigned, or one assigned to
        # a pilot without an ore bonus (LY/TH).
        def pilot_ore_bonus(entity, ship, cargo)
          ore, amount = company_ore_bonuses[pilot_source_for_ship(entity, ship)]
          return 0 unless ore

          cargo.count { |c| c[:ore] == ore } * amount
        end

        # Hex id -> [ore, amount] for every corp whose *home* base (its
        # starting `coordinates`, not any base it later places elsewhere)
        # pays a bonus for a matching ore delivered there by anyone --
        # built once from entities.rb's static data (Company/Corporation
        # Summary table: MM +$20/Ice, VP +$20/Rare, LE +$20/Nickel,
        # RCC +$10/Nickel, OPC +$10/Ice; TSI/AL have none).
        def home_delivery_bonuses
          @home_delivery_bonuses ||= CORPORATIONS.each_with_object({}) do |data, h|
            next unless data[:delivery_bonus]
            # entities.rb's requires_optional_new_corporations flag (OSR
            # today -- see its own entry's comment) excludes a corp whose
            # entry exists regardless of optional rules but whose home hex
            # isn't a real base without them, so a Full Game without the
            # expansion doesn't silently pay a bonus for what's just an
            # ordinary mine hex there.
            next if data[:requires_optional_new_corporations] && !optional_new_corporations

            h[data[:coordinates]] = [data[:delivery_bonus], data[:delivery_bonus_amount]]
          end
        end

        # Paid alongside the normal cargo revenue (and company_ore_bonus,
        # if applicable) to WHOEVER's route ends at the bonus hex -- not just
        # the home corp itself (Phase 7b).
        def home_delivery_bonus(delivery_hex, cargo)
          ore, amount = home_delivery_bonuses[delivery_hex.id]
          return 0 unless ore

          cargo.count { |c| c[:ore] == ore } * amount
        end

        # Entity id -> claimed_delivery_bonus_amount, built from entities.rb --
        # today only OSR (§13b) has this field, but any future entity with
        # the same "+bonus per delivery from a mine it has claimed" ability
        # just needs the field added to its own CORPORATIONS entry, no
        # method changes here.
        def claim_delivery_bonuses
          @claim_delivery_bonuses ||= CORPORATIONS.each_with_object({}) do |data, h|
            next unless data[:claimed_delivery_bonus_amount]

            h[data[:sym]] = data[:claimed_delivery_bonus_amount]
          end
        end

        # Company id -> flat per-OR treasury income amount, from
        # entities.rb's treasury_income_amount field (Fast Buck today) --
        # same each_with_object pattern as company_ore_bonuses, so which
        # company has this ability is never hardcoded anywhere. Only one
        # entry is actually usable right now, since @fast_buck_income_
        # recipient/carry_over_independent_special_status! track a single
        # current holder, not a list -- a second company with this field
        # would need that part generalized too.
        def treasury_income_sources
          @treasury_income_sources ||= COMPANIES.each_with_object({}) do |data, h|
            next unless data[:treasury_income_amount]

            h[data[:sym]] = data[:treasury_income_amount]
          end
        end

        # The one company id currently defined as a treasury_income
        # source (Fast Buck) -- nil if none is. Used wherever the code
        # needs to know "which company's ability is this" without a bare
        # 'FB' literal: the initial recipient (setup), whether a minor
        # being absorbed is the one to carry it over
        # (carry_over_independent_special_status!), and the log-wording
        # branch in Round::Operating#pay_fast_buck_treasury.
        def treasury_income_source_sym
          @treasury_income_source_sym ||= treasury_income_sources.keys.first
        end

        def fast_buck_income_amount
          @fast_buck_income_amount ||= treasury_income_sources[treasury_income_source_sym]
        end

        # §13b: On-Site Refining's *own* bonus -- distinct from its home
        # base's delivery_bonus (:r/+10, paid to *anyone* delivering Rare
        # there, same mechanism as VP/MM/LE/OPC/RCC's own home bonuses).
        # This one instead pays the claiming entity a flat bonus for every
        # delivery it makes from a mine *it has claimed* (any ore type) --
        # "+10 / claimed delivery" for OSR today. Checked against
        # @mine_state directly (not cargo's own recorded :value, which
        # already reflects the claimed-vs-unclaimed price split via
        # pickup_value) since this is a flat bonus stacked on top of that
        # value, not a replacement for it.
        def claim_delivery_bonus(entity, cargo)
          amount = claim_delivery_bonuses[entity.id]
          return 0 unless amount

          claimed = cargo.count do |c|
            c[:mine_idx] && @mine_state.dig(c[:hex_id], :mines, c[:mine_idx], :owner) == entity.id
          end
          claimed * amount
        end

        # One pickable slot -- either a specific mine (mine_idx set) or a
        # transshipment hex (mine_idx/ore nil). `value` is the admissible
        # ranking ceiling (raw + best-case bonus, see #candidate_slots);
        # `raw_value` is the real pickup/transshipment value alone, with
        # Independent abilities that grant a flat MP bonus to every ship
        # they pilot -- keyed the same way as company_ore_bonuses: by
        # whichever independent (itself, or inherited via a Growth Corp's
        # pilot assignment) is granting it. Torch is the only one today;
        # a future independent with a similar MP bonus is just a new hash
        # entry here, no method changes needed.
        INDEPENDENT_MP_BONUS = { 'TH' => 1 }.freeze

        # Every movement-point calculation should read this instead of
        # train.distance directly, so an independent's own MP bonus (or a
        # Growth Corp's inherited one, for whichever ship its pilot is
        # assigned to this OR) is never missed.
        def ship_distance(entity, ship)
          source = entity.minor? ? entity.id : pilot_source_for_ship(entity, ship)
          ship.distance + (INDEPENDENT_MP_BONUS[source] || 0)
        end

        # Plain BFS shortest-hop tree from `start`, ignoring refueling/MP
        # entirely (1 MP per hop, unconstrained) -- memoized per source hex
        # for the life of this game. The underlying hex-adjacency graph
        # (which hexes are real vs. .empty, and which are neighbors) never
        # changes over a game, only what's explored/placed on top of it
        # does, so this exact same walk from a given source hex would
        # otherwise get recomputed byte-for-byte identically every time
        # it's asked for -- found live in browser: a single multi-ship
        # Auto click on a well-developed board re-ran this same BFS from
        # the same launch hexes dozens of times over (once per ship per
        # ordering trial), all with identical results. Shared by
        # Autorouter#seed_transshipment_baseline! and Step::Route#
        # plain_shortest_paths, previously two independent copies of this
        # same algorithm.
        #
        # Returns [dist, predecessor]: dist is {hex_id => hop count},
        # predecessor is {hex_id => the hex reached just before it} for
        # every hex reachable from start (excluding start itself).
        # `blocked:` (a hex-id set to treat as impassable) bypasses the
        # cache entirely rather than being folded into the cache key --
        # every caller that needs it (Autorouter#bfs_leg, the avoid-
        # stations fallback) only runs a handful of times per
        # suggest_route with a different blocked set each time, so
        # caching those results would rarely hit anyway; the common,
        # hot, heavily-reused case (no blocked set) keeps its existing
        # cached behavior completely unchanged.
        def hex_bfs(start, blocked: nil)
          @hex_bfs_cache ||= {}
          return @hex_bfs_cache[start.id] if !blocked && @hex_bfs_cache.key?(start.id)

          dist = { start.id => 0 }
          predecessor = {}
          queue = [start]

          until queue.empty?
            hex = queue.shift
            hex.neighbors.each_value do |neighbor|
              next if neighbor.empty || dist.key?(neighbor.id) || blocked&.include?(neighbor.id)

              dist[neighbor.id] = dist[hex.id] + 1
              predecessor[neighbor.id] = hex
              queue << neighbor
            end
          end

          result = [dist, predecessor]
          @hex_bfs_cache[start.id] = result unless blocked
          result
        end

        # Independent abilities that force a second exploration-tile draw
        # -- keyed the same way as company_ore_bonuses/INDEPENDENT_MP_
        # BONUS, by whichever independent (itself, or inherited via a
        # Growth Corp's pilot assignment) grants it. A value of `true`
        # means an unconditional second draw (Lucky); an ore symbol means
        # "redraw only if the first draw had none of this ore" (Ice
        # Finder/Drill Hound). See ROADMAP.md Decision D. A future
        # independent with either shape of redraw rule is just a new hash
        # entry here, no method changes needed.
        INDEPENDENT_REDRAW_RULE = { 'LY' => true, 'IF' => :i, 'DH' => :r }.freeze

        def needs_second_draw?(entity, ship, first_mines)
          source = entity.minor? ? entity.id : pilot_source_for_ship(entity, ship)
          rule = INDEPENDENT_REDRAW_RULE[source]
          return false unless rule
          return true if rule == true

          first_mines.none? { |m| m[:ore] == rule }
        end

        # Which of this corp's inherited pilot sources (if any) is assigned
        # to this specific ship this OR -- each pilot the corp holds is
        # assigned independently to its OWN ship (never shared across
        # pilots, and never more than one pilot per ship), delegating to
        # the Route step's own per-OR assignment state (reset every OR
        # automatically, since a fresh step instance is built each round;
        # mirrors 1822's Pullman).
        #
        # Finds the Route step directly by type rather than via
        # `round.active_step` -- that computes `blocking?`, which calls
        # `actions`/`choices` on every step, including BuyInfrastructure's
        # `claim_choices` -> `hexes_in_range` -> `ship_distance` ->
        # this method, right back here: infinite recursion (the same
        # documented pitfall `Game::Base#ability_right_time?` already works
        # around, via `ability_blocking_step` instead of `active_step`).
        def pilot_source_for_ship(entity, ship)
          # Inherited pilot abilities (Torch's +1 MP, IF/DH/OC's ore bonus,
          # LY's extra tile draw) stop applying from Phase 5 on, once the
          # underlying private closes.
          return nil if phase.name.to_i >= 5

          step = round.steps.find { |s| s.is_a?(G2038::Step::Route) }
          return nil unless step.respond_to?(:pilot_source_for_ship)

          step.pilot_source_for_ship(entity, ship)
        end

        # This corp's inherited special-ability source(s), if it was formed
        # via Growth Corp conversion (Phase 8) -- e.g. ['LY'] for a corp
        # formed from Lucky. Usually a single entry, but a corp that
        # absorbs multiple independents over time (AL, via Phase 9
        # mergers) can accumulate more than one. Empty for a normally-
        # floated corp or an unconverted independent.
        def growth_corp_pilots(entity)
          @growth_corp_pilot[entity.id] || []
        end

        PILOT_NAMES = {
          'LY' => 'Lucky',
          'IF' => 'Ice Finder',
          'DH' => 'Drill Hound',
          'OC' => 'Ore Crusher',
          'TH' => 'Torch',
        }.freeze

        PILOT_DESCRIPTIONS = {
          'LY' => 'draw 2 tiles and choose which to place',
          'IF' => '+$10 per Ice (draws second tile if first lacks Ice)',
          'DH' => '+$10 per Rare (draws second tile if first lacks Rare)',
          'OC' => '+$10 per Nickel',
          'TH' => '+1 movement point to spaceships',
        }.freeze

        # Human-readable description of this corp's inherited pilot
        # ability/abilities (Phase 8), named per source rather than a
        # generic "Pilot:" label -- nil if it wasn't formed via Growth Corp
        # conversion (or hasn't absorbed any independent yet). Joins
        # multiple entries if the corp has more than one (e.g. AL). 
        
        def pilot_description(entity)
          sources = growth_corp_pilots(entity)
          return nil if sources.empty?

          sources.map { |source| "#{PILOT_NAMES[source]}: #{PILOT_DESCRIPTIONS[source]}" }.join('; ')
        end

        # Peeks at hex_id's assigned tile without laying anything -- [name,
        # mines]. @hex_assignments is server-side only (never sent to
        # clients, see ROADMAP Decision D), so this is the only way
        # Step::Route can learn what's there before committing to it.
        def peek_tile(hex_id)
          name = @hex_assignments[hex_id]
          [name, MINE_DATA.fetch(name, [])]
        end

        # A throwaway tile instance for preview purposes (Lucky's tile-
        # choice popup) -- built straight from TILES' raw color/code
        # rather than pulled from @tiles, so it never consumes a pool slot
        # or risks clobbering a real instance's `.hex` when wrapped in a
        # preview Engine::Hex for rendering.
        def preview_tile(tile_name)
          val = TILES[tile_name]
          Tile.from_code(tile_name, val['color'], val['code'])
        end

        # Borrows a second tile from a random still-unexplored hex
        # (deterministic rand, so replays match -- Decision D). Returns
        # [borrowed_hex_id, tile_name], or nil if nothing's left to borrow.
        def borrow_second_tile(exclude_hex_id)
          candidates = @hex_assignments.keys.select { |id| id != exclude_hex_id && !@mine_state.key?(id) }
          return nil if candidates.empty?

          borrowed_hex_id = candidates[rand % candidates.size]
          [borrowed_hex_id, @hex_assignments[borrowed_hex_id]]
        end

        # Commits the choice between the two drawn tiles: the chosen one
        # becomes hex_id's real assignment (so the next explore_hex! call
        # lays it normally), the other is quietly returned to whichever
        # hex it was borrowed from -- no one ever learns what was behind
        # that hex's tile.
        def resolve_second_draw!(hex_id, chosen_tile_name, borrowed_hex_id, other_tile_name)
          @hex_assignments[hex_id] = chosen_tile_name
          @hex_assignments[borrowed_hex_id] = other_tile_name
        end

        def mark_mine_used!(hex_id, mine_idx, used = true)
          @mine_state.dig(hex_id, :mines, mine_idx)&.store(:used, used)
        end

        def mine_used?(hex_id, mine_idx)
          !!@mine_state.dig(hex_id, :mines, mine_idx, :used)
        end

        # The corporation or independent that holds a claim on this mine, if
        # any (nil once claim placement is unowned or not yet implemented).
        def mine_claim_owner(hex_id, mine_idx)
          owner_id = @mine_state.dig(hex_id, :mines, mine_idx, :owner)
          return nil unless owner_id

          corporation_by_id(owner_id) || minor_by_id(owner_id)
        end

        # The hex path + mine picks from this ship's last completed flight
        # (any OR, manually flown or accepted-suggestion), or nil if it's
        # never finished a run. Revenue/MP aren't stored -- replay
        # recomputes them fresh against current mine_state/phase, same as
        # a brand new suggestion would. refueled_hex_ids is the one
        # documented exception: unlike revenue/MP, WHICH hexes a flight
        # actually chose to refuel at (§7.12 is optional, not automatic)
        # is a genuine player decision, the same category as cargo's own
        # mine_idx picks -- it can't be safely re-derived by assuming
        # "refuel whenever eligible," since that can strand a replayed
        # path short of where the real flight (which may have deferred a
        # refuel to a later, bigger-gain visit) actually ended up.
        def last_route(ship)
          @last_route[ship.id]
        end

        def record_last_route!(ship, hexes, cargo, refueled_hex_ids)
          @last_route[ship.id] = {
            hexes: hexes.map(&:id),
            cargo: cargo.map { |c| { hex_id: c[:hex_id], mine_idx: c[:mine_idx] } },
            refueled_hex_ids: refueled_hex_ids.dup,
          }
        end

        # Rollback counterpart to record_last_route! -- restores whatever
        # was on file before a locally-finished, not-yet-submitted flight
        # overwrote it (see Step::Route#rollback_local_flight!), rather
        # than leaving a stale pointer at a route that never really
        # happened.
        def restore_last_route!(ship, value)
          if value
            @last_route[ship.id] = value
          else
            @last_route.delete(ship.id)
          end
        end

        # Read/write access to the seeded LCG's own state (a single
        # integer -- see Game::Base#rand/#initialize_seed), so
        # Step::Route can snapshot it before a local, unsubmitted flight
        # consumes randomness (tile rotation, Lucky's second-draw borrow)
        # and rewind precisely on discard. Rewinding this one integer is
        # enough to make a later real replay draw identically to what the
        # discarded local preview already showed -- no need to separately
        # track which random calls happened or in what order.
        def rand_state
          @rand
        end

        def rand_state=(value)
          @rand = value
        end

        # Lifetime cap on total bases/stations a corp may ever place -- the
        # length of its own `bases:`/`stations:` cost array (base_cost/
        # station_cost fall back to the array's last entry past that count,
        # which previously meant "keep paying the last price forever" with
        # no actual cap; ROADMAP's Phase 5c note flagged this as an
        # intentional simplification, since revisited after live play).
        # §8.12/Phase 9h: the AL must hold back 1 base for each independent
        # that hasn't merged in yet -- its *own* new-placement capacity
        # shrinks while any remain, growing back by 1 each time one merges
        # or is forced in. This reservation is what keeps the combined
        # total (self-placed + inherited) capped at the true allotment: a
        # merged-in base counts against @base_hexes too (see
        # transfer_independent_base!, counted: true for AL), consuming
        # exactly the capacity this formula just gave back. Claims
        # inherited via merger also count, against claim_limit -- see
        # transfer_independent_mine_claims!'s own comment; that one was
        # never in question, only bases were.
        def setup
          validate_optional_rule_combination!
          init_setup_state!
          setup_probe!
          setup_asteroid_league!
          finish_al_setup!
          place_starting_bases!
          apply_optional_corporation_availability!

          return if optional_variant_start_pack

          partition_corporation_groups!
        end

        # §13-pre: the expansion's own "New Corporations" text is explicit
        # -- "to the full game (but not the Short Game)" -- and the
        # Variant Start Packet transitively implies New Corporations
        # (optional_new_corporations above), so this one check covers
        # both. Raised here (not at the lobby/options level) since
        # @optional_rules is only assembled once game setup actually runs
        # -- matches how other invalid-combination checks in this
        # codebase surface (a GameError at setup time, not a silent
        # ignore).
        def validate_optional_rule_combination!
          return unless optional_short_game && optional_new_corporations

          raise GameError, 'The Short Game cannot be combined with New Corporations or the Variant Start Packet'
        end

        def init_setup_state!
          @log << '2038 is a game of exploration, involving reveals of hidden tiles. Using Undo to revert '\
                  'a revealed tile to its hidden state could give a player an unfair benefit. Please exercise '\
                  'care in exploration, and refrain from undoing actions that have revealed tiles.'
          @mine_state = {}
          @refueling_stations = {}
          @base_hexes = Hash.new { |h, k| h[k] = [] }
          @station_hexes = Hash.new { |h, k| h[k] = [] }
          # Extra, uncounted bases -- never pushed into @base_hexes (so
          # base_limit/base_cost don't count them against a corp's own
          # allotment), but still real, already-placed tokens that were
          # previously invisible on the charter card entirely: Tunnel
          # Systems' free-base ability (place_base!'s free: kwarg) and a
          # Growth Corp's inherited independent base (Phase 8) land here
          # so the charter can show them. The AL's inherited base from
          # each independent it merges in (Phase 9) does NOT land here --
          # confirmed with the user that one DOES count against AL's own
          # base_limit, so it goes into @base_hexes instead (see
          # transfer_independent_base!'s own comment for why).
          @extra_base_hexes = Hash.new { |h, k| h[k] = [] }
          # Same idea as @extra_base_hexes just above, but for Vacuum
          # Associates' free-station ability (place_station!'s free:
          # kwarg) -- never pushed into @station_hexes (stations have no
          # lifetime allotment/cost schedule to protect the way bases do,
          # but the placement-order list is still what the charter builds
          # its token strip from), so without this a free station was
          # invisible on the charter entirely rather than just uncounted.
          @extra_station_hexes = Hash.new { |h, k| h[k] = [] }
          # Most recently completed flight for each ship (ship id -> hex
          # path + which mines were picked up), so "Modify"/"Submit" can
          # offer a cheap replay instead of re-running the autorouter's
          # search -- see Step::Route#preview_last_route. Persists here
          # (not on the round-local @route_stats_by_ship) because it needs
          # to survive into the *next* OR, when Step::Route is rebuilt fresh.
          @last_route = {}
          # Growth Corp id -> the original independent's id it was formed
          # from (Phase 8), e.g. 'MM' => 'LY' -- used by company_ore_bonus/
          # ship_distance/needs_second_draw? to find the inherited special
          # ability once it's only usable via the per-OR pilot assignment.
          @growth_corp_pilot = {}
          # Whichever company entities.rb marks as a treasury_income
          # source (Fast Buck today; see treasury_income_source_sym)
          # earns its flat per-OR income (G2038::Round::Operating#
          # pay_fast_buck_treasury) into its own treasury -- and that
          # needs to follow it into whichever corp absorbs it (Growth
          # Corp conversion or an AL merger) -- Minor#close!
          # unconditionally sets @floated = false, so paying the source
          # minor directly would otherwise just silently stop the income
          # forever the moment it's absorbed, rather than continuing to
          # whoever now owns that treasury. nil if no company currently
          # has this field.
          @fast_buck_income_recipient = minor_by_id(treasury_income_source_sym)
          assign_exploration_tiles
        end

        # The Probe is never sold from the Depot; TSI owns it from the start
        # of the game so it can be flown (by ST's owner) before TSI floats
        # (§6). See `operating_order`/`acting_for_entity`/`probe_bonus_recipient`.
        def setup_probe!
          @probe = depot.upcoming.find { |t| t.name == 'Probe' }
          depot.remove_train(@probe)
          @probe.buyable = false

          # Assign ownership directly rather than via `buy_train` -- that
          # fires `close_companies_on_event!(tsi, 'bought_train')`, which
          # would immediately close ST (whose own `close` ability fires on
          # "TSI bought_train") before the initial auction even starts.
          # ST's closure must only happen when TSI buys a *real* spaceship.
          tsi = corporation_by_id('TSI')
          @probe.owner = tsi
          tsi.trains << @probe
          @log << "#{tsi.name} receives the Probe"
        end

        def setup_asteroid_league!
          @al_corporation = corporation_by_id('AL')
          @al_corporation.capitalization = :incremental
          @asteroid_league_formed = false

          # §13c: "IPO shares" (a corp's own still-unsold allocation)
          # must NOT pay the corp dividends once this rule is active,
          # while genuinely repurchased "Treasury Shares" (rule 3) must.
          # Both currently show `owner == corp` with no way to tell them
          # apart.  We follow the same pattern 1862 uses for its own 
          # chartered/full-capitalization companies (Game#convert_to_full!): 
          # point `ipo_owner` at the bank instead of the corp itself, so 
          # a corp's *unsold* shares live with the bank while only genuinely 
          # *repurchased* ones ever end up owned by the corp again. Every 
          # G2038 corp starts `:full` capitalization; AL just switched to 
          # `:incremental` immediately above (Growth Corps switch similarly 
          # later, on formation) -- both correctly skipped here and left alone,
          # already handled by rule 1's own capitalization check
          # elsewhere. Must run *after* AL's own capitalization switch
          # above, not before, or AL (still `:full` at that point) would
          # get its own IPO shares wrongly redirected to the bank too.
          # Otherwise run as early as possible, before any shares have
          # actually moved, so "every currently self-held share" is
          # unambiguously the entire unsold allotment.
          return unless optional_stock_repurchases

          @corporations.each do |corp|
            next if corp.capitalization == :incremental

            corp.ipo_owner = bank
            corp.shares_by_corporation[corp].dup.each { |share| transfer_treasury_share!(share, bank) }
          end
        end

        def finish_al_setup!
          # One of AL's 8 non-president shares reserved per independent, from
          # the very start of the game (not just once AL forms) -- guarantees
          # a share is available if and when that specific independent later
          # merges in (Phase 9), mirrors 1835's `prussian.reserved_shares`
          # (`share.buyable = false` at setup, flipped back at merge time).
          # AL's remaining 2 non-president shares stay normally buyable from
          # the moment it floats, same as today.
          @al_reserved_shares = @minors.to_h do |minor|
            share = @al_corporation.shares_by_corporation[@al_corporation].find { |s| s.buyable && !s.president }
            share.buyable = false
            [minor.id, share]
          end

          # Independent ids that have been offered a merge-into-AL choice at
          # least once, ever (Phase 9c/9d). The instant AL forms, every
          # remaining independent is asked in one atomic, uninterruptible
          # sweep (confirmed with the user: never deferred, never split
          # across rounds) -- this list is what lets a LATER Stock round
          # tell "never offered" (would only happen if AL forms mid-SR,
          # handled within that same sweep) apart from "declined earlier"
          # (must never be re-offered in a Stock round; recurring re-offers
          # are Operating-round-only -- see Step::MergeIntoLeague).
          @al_independents_ever_offered = []

          @corporations.reject! { |c| c.id == 'AL' }
        end

        def place_starting_bases!
          # §13b: OSR/MR's home hexes (B14/O13) only exist as real base
          # cities when optional_new_corporations makes optional_hexes
          # carve them out of the blue/unexplored set -- without the
          # rule they're ordinary unexplored hexes, so place_home_token
          # would crash looking for a city that was never placed. Pulled
          # out of the generic placement loop for that one case only;
          # with the rule on they go through the exact same
          # place_home_token/coordinates: flow as any other corp below.
          osr_mr = @corporations.select { |c| %w[OSR MR].include?(c.id) }
          placement_entities = @corporations + @minors + [@al_corporation]
          placement_entities -= osr_mr unless optional_new_corporations

          # All 13 starting-base hexes are on the map and deliverable from
          # turn one -- unlike the engine's HOME_TOKEN_TIMING default of
          # :operate, a corp/independent's own home base doesn't wait for
          # it to float or take its first OR turn (§6/§7). This matters for
          # *other* entities delivering there before this one has floated,
          # not just for itself. place_home_token no-ops harmlessly if
          # called again later (it checks `tokens.first&.used`), so the
          # standard :operate-time call still fires without conflict once
          # each entity actually starts operating. Placed for OPC/RCC too,
          # even under optional_short_game (where they're about to be
          # excluded from @corporations below) -- confirmed with the user:
          # the Short Game section only says the *corporations* aren't
          # used, and "Points to Remember" separately states, twice and
          # unconditionally, "All 13 bases printed on the map start/begin
          # the game in play" -- combined with the Short Game's own "uses
          # all the Full Game rules except the following" framing, their
          # bases stay real, deliverable destinations for everyone else
          # even though OPC/RCC themselves never operate. OSR/MR's own
          # bases, when the expansion rule is on, are exactly as real and
          # permanent as any of these 13 -- see optional_hexes.
          placement_entities.each { |entity| place_home_token(entity) }
        end

        def apply_optional_corporation_availability!
          # §13a: "The two group 'C' Corporations, the Outer Planet
          # Consortium and the Ring Construction Corp., are not used."
          # Dropped from @corporations *after* their bases are placed
          # above (see place_starting_bases!) so they never operate,
          # never appear on the stock market, and never show up in any
          # other bookkeeping that iterates @corporations, while their
          # bases remain in play.
          @corporations.reject! { |c| %w[OPC RCC].include?(c.id) } if optional_short_game

          # §13b: On-Site Refining and Mining Robotics only exist under
          # the New Corporations expansion rule (or the Variant Start
          # Packet, which implies it) -- same "drop from @corporations,
          # base stays real" pattern as OPC/RCC above, just gated the
          # opposite way (present unless the rule is *off*). "Start the
          # game already in play" refers only to their base (real and
          # placed from the start, same as every other corp's), not to
          # any bypass of the normal IPO/float process -- confirmed with
          # the user (see ROADMAP 13b): they unlock on the ordinary
          # group_c timeline and float like any other corp, no special
          # handling needed.
          @corporations.reject! { |c| %w[OSR MR].include?(c.id) } unless optional_new_corporations
        end

        def partition_corporation_groups!
          @available_corp_group = :group_a

          @corporations, @b_group_corporations = @corporations.partition do |corporation|
            corporation.type == :group_a
          end

          @b_group_corporations, @c_group_corporations = @b_group_corporations.partition do |corporation|
            corporation.type == :group_b
          end
        end

        # Pre-assign an asteroid tile to every blue space hex (Decision D).
        # Derived deterministically from the game seed via the engine's LCG rand,
        # so every clone/undo rebuilds the identical assignment without storing
        # it in the action history. Never revealed to clients until explored.
        def assign_exploration_tiles
          hex_ids = HEXES[:blue].keys.flatten.sort

          pool = []
          ('2001'..'2022').each do |name|
            TILES[name]['count'].times { pool << name }
          end

          @hex_assignments = hex_ids.zip(pool.sort_by { rand }).to_h
        end

        # Before TSI floats, it still gets an OR turn (to fly the Probe),
        # inserted right after the independents and before other corporations
        # (§6). Once floated, TSI is already included via the default order.
        def operating_order
          order = super
          return order unless (tsi = corporation_by_id('TSI')) && !tsi.floated?
          # No one to act for TSI's pre-float turn (flying the Probe) until
          # ST has a real (player) owner -- a leftover, never-bought ST
          # (Case 3) sits owned by the bank in the meantime, so skip
          # giving TSI a turn at all rather than crash on a nil
          # acting_for_entity.
          return order unless company_by_id('ST')&.owner&.player?

          order.insert(@minors.count(&:floated?), tsi)
          order
        end

        # While TSI hasn't floated, its pre-float OR turn (flying the Probe)
        # is acted on by the owner of the ST private, per the rules -- not by
        # TSI's nominal president (TSI has no real president until it floats).
        def acting_for_entity(entity)
          if tsi_pre_float?(entity)
            st_owner = company_by_id('ST')&.owner
            # Same bank-vs-real-owner distinction as probe_bonus_recipient
            # above -- a leftover, never-bought ST is bank-owned, not a
            # real player, so there's no one to act for TSI yet.
            return st_owner if st_owner&.player?
          end

          super
        end

        # Phase 5 (§7.4x): every private company still open closes, except
        # ST and AE -- those already have their own dedicated close
        # triggers (TSI/AL buying a ship) which must stay authoritative
        # even if, in a rare case, TSI still hasn't floated by Phase 5
        # (the ST-flies-the-Probe fallback needs ST to still exist then).
        # Companies with a still-open independent behind them (FB/IF/DH/
        # OC/TH/LY) are normally already closed via
        # event_independents_must_join_league! (also Phase 5) by the time
        # this runs; the closed? guard makes call order irrelevant.
        def event_close_remaining_companies!
          @companies.each do |company|
            next if company.closed?
            next if %w[ST AE].include?(company.id)

            company.close!
            @log << "#{company.name} closes"
          end

          # §7.14: "its pilot certificate is placed in that Corporation
          # (until removed in Phase V)" -- every inherited pilot bonus
          # (Growth Corp conversion, Phase 8, or AL merger, Phase 9) stops
          # applying the instant Phase V begins, regardless of whether
          # the original independent itself already closed on its own
          # separate trigger long before now.
         
          # Fast Buck's $15/OR treasury income counts as its pilot
          # certificate too, so it stops the same way: clearing
          # @fast_buck_income_recipient makes pay_fast_buck_treasury's
          # `recipient&.floated?` guard a no-op from here on, whether FB
          # was absorbed via Growth Corp conversion or an AL merger.
          had_pilots = !@growth_corp_pilot.empty?
          had_fast_buck_income = !@fast_buck_income_recipient.nil?
          return unless had_pilots || had_fast_buck_income

          @log << 'All inherited pilot bonuses are removed' if had_pilots
          @log << "Fast Buck's treasury income stops" if had_fast_buck_income
          @growth_corp_pilot = {}
          @fast_buck_income_recipient = nil
        end

        def event_group_b_corps_available!
          @log << 'Group B corporations are now available'

          @corporations.concat(@b_group_corporations)
          @b_group_corporations = []
          @available_corp_group = :group_b
        end

        def event_group_c_corps_available!
          @log << 'Group C corporations are now available'

          @corporations.concat(@c_group_corporations)
          @c_group_corporations = []
          @available_corp_group = :group_c
        end

        # Overrides Game::Base#train_limit's generic Phase#train_limit(entity)
        # call, which looks up entity.type directly -- that's group_a/b/c/d,
        # meaningful only for release timing (see SHIP_LIMIT_PHASE_* above),
        # not the three ship-limit categories the rules actually define.
        def train_limit(entity)
          key =
            if entity.minor?
              :independent
            elsif entity.id == 'AL'
              :asteroid_league
            else
              :corporation
            end

          (phase.current[:train_limit][key] || 0) + Array(abilities(entity, :train_limit)).sum(&:increase)
        end

        # True from Phase II onward, for the rest of the game (the phase
        # status flag that gates base/refueling-station buying and
        # placement -- see Step::BuyInfrastructure#after_phase_1?, which
        # now delegates here -- plus inter-company ship trading, just
        # below). Distinct from can_buy_companies_or_claims?, which shares
        # the same Phase II start but stops at Phase 5.
        def after_phase_1?
          phase.status.include?('can_buy_bases_stations')
        end

        # True from Phase II through Phase 4 -- corporations may buy
        # private companies from players (the shared engine's own
        # Step::BuyCompany#can_buy_company? reads 'can_buy_companies'
        # directly for that, unrelated to this method) and buy claims from
        # independents (Step::BuyInfrastructure#buy_independent_claim_choices).
        # Both stop being meaningful at Phase 5, when every remaining
        # private closes and every independent merges into the AL --
        # nothing left to buy from a player, and no independent left to
        # sell a claim.
        def can_buy_companies_or_claims?
          phase.status.include?('can_buy_companies')
        end

        # Companies may not buy ships from each other before Phase II (§5.x
        # Sequence of Play) -- the depot's own ships are unaffected either way.
        def can_buy_train_from_others?
          after_phase_1?
        end

        # Phase 11b: a corporation with no spaceship must buy one (EMR, then
        # bankruptcy if it still can't afford one) -- but independents are
        # governed entirely by their own rule (Phase 9f: merge into AL once
        # it exists; before that, an independent with no ship simply sits
        # idle with no consequence). The base
        # engine's default (`MUST_BUY_TRAIN == :route`, checking `@graph.
        # route_info`) is permanently inert for G2038 regardless of entity
        # type, since this game has no tile-path graph at all -- overriding
        # the method directly (rather than the constant, which has no
        # per-entity-type option) is what actually lets this apply only to
        # corporations.
        def must_buy_train?(entity)
          return false if entity.minor?

          entity.trains.empty? && !depot.depot_trains.empty?
        end

        # §13c rule 3: standard engine redeem/issue hooks (see
        # Step::StockRepurchase/Step::IssueShares -- the same reusable
        # mechanism 1817/1822/1846 use for their own corporate share
        # dealing). Buyback-only: `issuable_shares` always returns []
        # since nothing in this rule lets a corp sell treasury shares
        # for cash, only buy its own back. Bundles come straight from
        # `bundles_for_corporation(share_pool, entity)` -- shares
        # currently sitting in the open market, priced at the entity's
        # own current `share_price` via each Share's own default
        # price_per_share (no override needed here, unlike rule 1's
        # Growth-Corp-box pricing above, which is a genuinely different
        # price source) -- filtered to whatever the corp's own treasury
        # can actually afford.
        def redeemable_shares(entity)
          return [] unless optional_stock_repurchases && entity.corporation?

          bundles_for_corporation(share_pool, entity).reject { |bundle| entity.cash < bundle.price }
        end

        def issuable_shares(_entity)
          []
        end

        # Basic share move with no payment/president-change side effects
        # -- mirrors 1862's own Game#transfer_share, used the same way
        # here: once at setup to relocate a corp's still-unsold shares
        # to the bank (see the ipo_owner switch in #setup above).
        def transfer_treasury_share!(share, new_owner)
          corp = share.corporation
          corp.share_holders[share.owner] -= share.percent
          corp.share_holders[new_owner] += share.percent
          share.owner.shares_by_corporation[corp].delete(share)
          new_owner.shares_by_corporation[corp] << share
          share.owner = new_owner
        end

        # §13c rule 1: "All shares in the Growth Corporation share box
        # (only) are bought at the higher of that Corporation's par or
        # current stock value" -- i.e. this codebase's own established
        # "Treasury Shares" concept (Corporation#treasury_shares), for
        # the specific case of a Growth Corp/AL's still-unsold IPO
        # shares. Without this rule, those are always priced at par
        # (Share#price_per_share reads par_price for as long as owner ==
        # ipo_owner, see form_growth_corporation!'s own comment on that),
        # never reflecting a market price that's since climbed above it.
        # ShareBundle#share_price (settable, nil by default) is the
        # designed override point -- falls back to the normal per-share
        # calculation whenever left unset. Scoped to `share_holder ==
        # corporation` (i.e. actually querying the corp's own IPO/
        # treasury shares, not some other holder's bundles of it) and
        # `capitalization == :incremental` (Growth Corps and the AL,
        # both of which price their own unsold shares via ipo_owner --
        # an ordinary Public corp's shares were never IPO-owned this way
        # in the first place, so this never applies to one just because
        # it's holding some Treasury Shares back via a rule-3 buyback).
        def bundles_for_corporation(share_holder, corporation, shares: nil)
          bundles = super
          return bundles unless optional_stock_repurchases && share_holder == corporation &&
            corporation.capitalization == :incremental

          price = [corporation.par_price.price, corporation.share_price.price].max
          bundles.each { |b| b.share_price = price }
          bundles
        end

        # A Growth Corp's (or AL's) still-unsold shares sit with the corp
        # itself (Game#form_growth_corporation! resets ipo_owner to self
        # right at conversion -- see that method's own comment), the exact
        # same place a redeemed Treasury Share ends up; per the user
        # they're conceptually one and the same holding, so the corp card's
        # own "Shareholder" table should say so instead of splitting them
        # into a separate "IPO" row. An ordinary Public corp's unsold
        # shares (still genuinely at the bank, or self pre-repurchases)
        # keep the standard "IPO" label -- only capitalization ==
        # :incremental corps get the rename.
        def ipo_name(entity = nil)
          return super unless entity&.corporation? && entity.capitalization == :incremental

          'Treasury'
        end

        # Opt-in hook for assets/app/view/game/hex.rb: whether this tile
        # should get the starfield pattern (its own per-hex, randomly-
        # rotated <defs><pattern>, built entirely in hex.rb) instead of
        # a flat color -- "open space" is the actual state a still-
        # unexplored hex (blue), an explored asteroid mine, and a base
        # station all represent here, not just an unused map color the
        # way blue or gray might be in a track game. Not `tile.color ==
        # :gray` on its own -- that would also catch every corp's home
        # hex before a base is actually placed there, which shouldn't
        # get this. `mine_tile?`/`base_tile?` below are the precise
        # checks (by tile name), shared with hex.rb's own asteroid_rock/
        # ring_station gating.
        def hex_fill_override(tile)
          tile&.color == :blue || mine_tile?(tile) || base_tile?(tile)
        end

        # Opt-in hook for assets/app/view/game/hex.rb: white hex borders
        # read better against the starfield backdrop than the engine's
        # default black -- per the user.
        def hex_border_color
          'white'
        end

        # Opt-in hook for assets/app/view/game/hex.rb: whether to draw
        # the generative asteroid-rock silhouette behind an explored
        # mine tile's own city/revenue circle (see hex.rb#asteroid_rock).
        def mine_tile?(tile)
          tile && MINE_DATA.key?(tile.name)
        end

        # Opt-in hook for assets/app/view/game/hex.rb: whether to draw
        # the rotating-ring-station art behind a placed base's own city/
        # token (see hex.rb#ring_station). Two ways a hex ends up with a
        # base: '2023' is the one gray tile code `place_base!` ever lays
        # down for a base created during play; every corp/minor's
        # starting home base, though, is never laid at all -- it's
        # preprinted directly on its own hex from setup (see map.rb's
        # `gray` HEXES entry, placed via the generic engine's
        # place_home_token, not place_base!) -- so it needs its own
        # check by hex id (starting_base_hexes) rather than tile name.
        # AL is itself one of the CORPORATIONS entries (see entities.rb),
        # so its own H10 home is technically in starting_base_hexes too --
        # but H10 is also a transshipment point, and stays one (satellite
        # art, see transshipment_hex?) right up until the League actually
        # forms and takes it over as a normal base "like any other" (same
        # cutover transshipment_hex? itself already makes) -- so this
        # excludes it until that flips, then includes it.
        #
        # The `hex_by_id` identity check guards against detached preview
        # tiles (Lucky's tile-choice popup, the standard TileSelector fan)
        # -- these are wrapped in a throwaway Engine::Hex always named
        # 'A1' (see `delivery_bonus`'s own comment on the same quirk),
        # which coincidentally collides with Mars Mining's real home
        # coordinate. Without this, a Lucky redraw preview showing an
        # ordinary mine tile started rendering the ring-station base art
        # on top of it -- found live in browser.
        def base_tile?(tile)
          return false unless tile
          return true if tile.name == '2023'
          return false unless tile.hex && starting_base_hexes.include?(tile.hex.id)
          # Self-contained check against the tile's OWN hex, never `self`'s
          # own hex_by_id -- this method can be called on a DIFFERENT game
          # instance than the one that actually owns `tile` (see
          # assets/app/view/game/map.rb's Starting Map toggle: @hexes comes
          # from `@game.clone([]).hexes`, a separate cloned instance, while
          # the Hex view component's own @game stays the live one). Found
          # live in browser: every non-AL starting base rendered as a flat,
          # ring-less gray hex specifically in the Starting Map preview,
          # never in the live game itself -- `tile.hex == hex_by_id(tile.
          # hex.id)` was comparing a CLONED hex object against a LIVE-
          # game-owned one with the same id, two different objects that
          # can never be == to each other, so this always failed there.
          return false unless tile.hex.tile == tile
          # ...but that check alone isn't enough: Engine::Hex#initialize
          # unconditionally sets `tile.hex = self` for whatever tile it's
          # constructed with, so `tile.hex.tile == tile` is trivially true
          # for ANY throwaway preview hex too, not just a real cloned/live
          # one. HexChoicePopup#render_tile_choice (Lucky's tile-redraw
          # popup, the standard TileSelector fan) wraps a real candidate
          # tile in exactly such a throwaway `Engine::Hex.new('A1', tile:
          # tile)` for rendering -- and 'A1' coincidentally IS a real
          # starting_base_hexes entry (Mars Mining's home), which used to
          # be caught by comparing against `self`'s own hex_by_id (a
          # different, real object), but that comparison is gone now.
          # A detached preview hex like this is never wired into any real
          # map's neighbor graph (only the Grid/Map builder does that), so
          # `neighbors.empty?` reliably tells the two apart regardless of
          # which Game instance is asking. Found live in browser (again):
          # a Lucky-redrawn mine tile candidate rendering the ring-station
          # base art on top of it.
          return false if tile.hex.neighbors.empty?

          !(Array(@al_corporation.coordinates).include?(tile.hex.id) && !@asteroid_league_formed)
        end

        # Opt-in hook for assets/app/view/game/hex.rb: how many separate
        # mines (and so how many asteroid-rock silhouettes, one per
        # city) this tile has -- 1 or 2.
        def mine_count(tile)
          MINE_DATA[tile.name]&.size || 0
        end

        # Opt-in hook for assets/app/view/game/part/revenue.rb: pushes a
        # transshipment point's printed revenue box to the bottom of the
        # hex, leaving the center clear for the satellite icon (hex.rb).
        def offboard_forced_bottom?(hex)
          transshipment_hex?(hex.id)
        end

        # Opt-in hook for assets/app/view/game/part/revenue.rb: H10's
        # printed "gray" phase box would otherwise show "$0" -- accurate
        # (transshipment_hex? already stops paying it the moment the AL
        # forms, well before gray phase could ever be reached), but
        # misleading, since the hex becomes the AL's own home base at
        # that exact point rather than a transshipment point worth
        # nothing. "AL" is clearer, and can never be confused for a
        # real payable value since gray phase can't arrive before the
        # AL is forced to form (Phase 4's asteroid_league_must_form!).
        def revenue_text_override(hex, phase)
          'AL' if hex.id == 'H10' && phase == :gray
        end

        # Opt-in hooks for assets/app/view/game/part/location_name.rb: the
        # generic engine's black-on-translucent-white Location Names label
        # (the map's own "Location Names" toggle) reads fine against every
        # other game's light hex backgrounds, but is illegible against
        # G2038's dark starfield -- flip to white text on a dark box.
        def location_name_text_color
          '#ffffff'
        end

        def location_name_background_color
          '#0a1128'
        end

        # Opt-in hook for assets/app/view/game/tile.rb's Hex Coordinates
        # and Tile Numbers map toggles -- same reasoning as location_
        # name_text_color just above: hardcoded black text reads fine on
        # every other game's light hex backgrounds, illegible against
        # G2038's dark starfield.
        def map_text_color
          '#ffffff'
        end

        # Opt-in hook for assets/app/view/game/part/city.rb: hides H10's
        # empty AL-reserved city slot for as long as the hex is still
        # acting as a transshipment point -- the token circle read as
        # "a base is already here" well before the AL exists to occupy
        # it. Once the AL actually forms and takes H10 over as its home
        # base, transshipment_hex? flips to false and the city (with
        # the AL's real token) renders normally from that point on.
        def hide_city?(hex, _city)
          hex && transshipment_hex?(hex.id)
        end

        # Opt-in hook for assets/app/view/game/part/revenue.rb: the
        # opposite lifecycle from hide_city? above -- H10's printed
        # transshipment value (and the gray-phase "AL" override, see
        # revenue_text_override) is only ever meaningful while the hex
        # is still acting as a transshipment point. Once the League
        # actually forms and takes it over as a normal base (revenue:0,
        # same as every other base), that printed box is stale/
        # misleading and should disappear entirely -- a real base
        # doesn't show a revenue box at all (Part::Revenue#should_render?
        # already skips a plain 0/nil revenue; this covers H10's
        # lingering non-zero transshipment value once it no longer
        # applies).
        def hide_revenue?(hex)
          hex && Array(@al_corporation.coordinates).include?(hex.id) && @asteroid_league_formed
        end
      end
    end
  end
end
