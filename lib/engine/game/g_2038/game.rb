# frozen_string_literal: true

require_relative 'meta'
require_relative 'map'
require_relative 'entities'
require_relative 'corporation'
require_relative '../base'
require_relative 'round/operating'
require_relative 'step/waterfall_auction'
require_relative 'step/company_pending_par'
require_relative 'step/buy_train'
require_relative 'step/discard_train'
require_relative 'step/dividend'
require_relative 'step/route'
require_relative 'step/form_asteroid_league'
require_relative 'step/buy_infrastructure'
require_relative 'autorouter'
require_relative 'combo_generator'
require_relative 'optimal_autorouter'

module Engine
  module Game
    module G2038
      class Game < Game::Base
        include_meta(G2038::Meta)
        include Map
        include Entities

        attr_reader :mine_state, :al_reserved_shares, :al_independents_ever_offered, :al_corporation,
                    :fast_buck_income_recipient, :hex_assignments

        CORPORATION_CLASS = G2038::Corporation

        TILE_TYPE = :lawson
        TRACK_RESTRICTION = :permissive
        SELL_BUY_ORDER = :sell_buy
        SELL_AFTER = :p_any_operate
        # A corporation's stock price drops one row per sale, regardless of
        # how many shares are sold in it -- confirmed with the user; the
        # base engine's own default (SELL_MOVEMENT = :down_share) instead
        # drops once per share sold, which doesn't match.
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

        CERT_LIMIT = { 3 => 22, 4 => 16, 5 => 13, 6 => 11 }.freeze
        # §13a: "The certificate limits are reduced." Confirmed with the
        # user (not in the extractable rules text -- the printed chart
        # didn't survive PDF/text extraction).
        SHORT_GAME_CERT_LIMIT = { 3 => 17, 4 => 13, 5 => 10, 6 => 9 }.freeze
        # §13b: "The Certificate Limit is increased" once OSR/MR are in
        # play -- confirmed from the expansion's own printed chart
        # ("w/10 Corps."), mutually exclusive with the Short Game (see
        # optional_new_corporations' incompatibility check in setup).
        NEW_CORPORATIONS_CERT_LIMIT = { 3 => 27, 4 => 20, 5 => 16, 6 => 13 }.freeze

        STARTING_CASH = { 3 => 600, 4 => 450, 5 => 360, 6 => 300 }.freeze

        # §13d: variant charter cards for 6 of the 12 Private/Independent
        # companies -- cheaper certificates, and PI/TS/VA/RS/ST/AE income
        # unchanged. Critically, TS/VA/RS no longer grant a TSI share at
        # all in this variant (their `shares` ability is simply dropped);
        # PI/ST/AE keep their existing abilities untouched. ST is also
        # renamed to Space Exploration Co. here (confirmed from the
        # variant's own printed charter card). Only the overridden fields
        # are listed -- game_companies below merges each of these onto its
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
          'ST' => { name: 'Space Exploration Co.', value: 160, revenue: 20 },
          'AE' => { value: 160, revenue: 30 },
        }.freeze

        def game_companies
          return super unless optional_variant_start_pack

          super.map do |company|
            overrides = self.class::VARIANT_START_PACK_COMPANIES[company[:sym]]
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
          par: :grey,
          par_1: :brown,
          par_2: :blue,
        )

        ENTITY_DISPLAY_ORDER = %w[FB IF DH OC TH LY TSI RU VP LE MM OPC RCC AL].freeze
        HIDE_TILE_TRACK = true

        # Three categories -- every non-AL corporation shares the same limit
        # regardless of its group_a/b/c release-timing group (see #train_limit
        # below, which reads this directly rather than going through the
        # generic Phase#train_limit's per-entity.type hash lookup; group_a/b/c/d
        # remain solely about release phase, not train limits). The Asteroid
        # League cannot exist at all before Phase 3 (it forms no earlier than
        # the asteroid_league_can_form event on the '5/4' train, which is what
        # brings in Phase 3 -- see event_asteroid_league_can_form!/PHASES
        # below), so TRAIN_LIMIT_PHASE_1_2 carries no asteroid_league key at
        # all, not just a moot one; independents are gone by Phase 6, so that
        # key is simply absent there too.
        TRAIN_LIMIT_PHASE_1_2 = { corporation: 4, independent: 2 }.freeze
        TRAIN_LIMIT_PHASE_3_5 = { corporation: 3, asteroid_league: 4, independent: 1 }.freeze
        TRAIN_LIMIT_PHASE_6 = { corporation: 2, asteroid_league: 3 }.freeze

        PHASES = [
          {
            name: '1',
            train_limit: TRAIN_LIMIT_PHASE_1_2,
            tiles: [:yellow],
            operating_rounds: 2,
          },
          {
            name: '2',
            on: '4/3',
            train_limit: TRAIN_LIMIT_PHASE_1_2,
            tiles: %i[yellow],
            operating_rounds: 2,
            status: %w[can_buy_bases_stations can_buy_companies can_form_growth_corps],
          },
          {
            name: '3',
            on: '5/4',
            train_limit: TRAIN_LIMIT_PHASE_3_5,
            tiles: %i[yellow],
            operating_rounds: 2,
            status: %w[can_buy_bases_stations can_buy_companies can_form_growth_corps],
          },
          {
            name: '4',
            on: '6/5',
            train_limit: TRAIN_LIMIT_PHASE_3_5,
            tiles: %i[yellow gray],
            operating_rounds: 2,
            status: %w[can_buy_bases_stations can_buy_companies],
          },
          {
            name: '5',
            on: '7/6',
            train_limit: TRAIN_LIMIT_PHASE_3_5,
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
            train_limit: TRAIN_LIMIT_PHASE_6,
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
            # NOTE: this was previously 'close_companies', a generic engine
            # event that closes every company without a matching 'close'
            # ability -- there's no rule closing PI/TS/VA/RS at Phase 4, so
            # that would have wrongly wiped them out. AE has its own 'close'
            # (fires when AL buys a spaceship, not on phase change), so this
            # event only needs to force AL's formation if AE's owner hasn't
            # already triggered it.
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
            # Phase#buying_train!/#setup_phase!): only a *train's* own
            # events actually get dispatched (train.events.each, fired
            # from buying_train!); a phase hash's own events: key is read
            # into Phase#@events but never iterated/dispatched anywhere.
            # Attaching it to the train that triggers Phase 5 (`on: '7/6'`
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
            # are in play -- see Step::BuyTrain#buyable_trains, which
            # filters '9/7' back out of the depot list until then (this
            # available_on can't express a *count*, only a phase name).
            available_on: '5',
            num: 9,
            # Train#price subtracts this from the 9/7's own $950 -- a $250
            # discount, landing at $700, not $700 charged outright (found
            # live in browser charging $250: this was storing the
            # post-discount price instead of the discount amount).
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
            'begins, or at the beginning of each Operating round thereafter.',
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
          optional_short_game ? 4_000 : BANK_CASH
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
          return self.class::SHORT_GAME_CERT_LIMIT if optional_short_game
          return self.class::NEW_CORPORATIONS_CERT_LIMIT if optional_new_corporations

          self.class::CERT_LIMIT
        end

        # Shared engine code (BuyTrain's buy_train_action, Game::Base#
        # rust_trains!, etc.) hardcodes "train"/"trains" in its own log
        # text, with no hook to override the wording -- 2038's vehicles are
        # spaceships. Rather than duplicating any of that logic just to
        # change a word, rewrite whatever it logged after the fact; cheap
        # and safe since every action already routes through here.
        #
        # Also where the exploration-undo warning (Decision B / ROADMAP
        # Phase 4i) is injected: an Undo whose action.is_a?(Action::Undo)
        # short-circuits Game::Base#process_action into `clone(@raw_actions)`
        # -- a brand new Game instance, replayed from scratch -- rather than
        # mutating self, so any warning has to be computed from *this*
        # (pre-undo) instance's still-intact @log, then appended as a
        # genuine follow-up action on the *returned* (post-undo) instance.
        # A real Action::Message is the vehicle because it's the one action
        # type Game::Base.filtered_actions guarantees can never itself be
        # undone (`when 'message'`), so the warning survives every future
        # replay of this game once it's added -- not just the live moment.
        def process_action(action, **kwargs)
          action = Action::Base.action_from_h(action, self) if action.is_a?(Hash)

          if action.is_a?(Action::Undo)
            # Action::Base#to_h memoizes into @_h the first time it's ever
            # called on a given action instance -- exploration_undo_warning
            # below calls .to_h on this same action (to compare
            # filtered_actions before/after), and if that happens before
            # Game::Base#process_action assigns action.id (its very first
            # line, inside `super`), the memoized hash permanently misses
            # its 'id' key. That corrupts every later .to_h call on this
            # SAME object too, including the one `super` itself relies on
            # to append this action to @raw_actions for the real clone --
            # actions without an id blow up process_to_action's replay
            # ("comparison of Integer with nil failed") for every future
            # load of this game, not just this one. Assigning the id
            # myself first (the exact value `super` would assign anyway)
            # means the first .to_h call -- whichever code makes it --
            # caches the correct hash from the start.
            action.id ||= current_action_id + 1
            warning = exploration_undo_warning(action)
            result = super
            if warning
              # Step::Message#actions requires a player entity -- action.
              # entity here can be a corporation (undoing mid-OR-turn), so
              # resolve to whoever's actually behind it the same way the
              # rest of the game already does (Game::Base#acting_for_entity,
              # e.g. a corp's president), or Step::Message would never
              # match as the blocking step and raise instead.
              messenger = action.entity.player? ? action.entity : result.acting_for_entity(action.entity)
              result.process_action(Action::Message.new(messenger, message: warning))
            end
            return result
          end

          before = @log.size
          result = super
          # @log[before..] can be nil, not [] -- a submitted ship flight
          # (Step::Route's SUBMIT_FLIGHT) rolls back its own local
          # preview's log lines (@log.slice!) before replaying the real
          # flight, and if the real replay logs fewer lines than the
          # local preview did, @log ends up *shorter* than `before`.
          # Indexing a Ruby array from a start past its own length
          # returns nil, not an empty array, and #each on that raised
          # "undefined method `each' for nil" -- found live in browser,
          # crashing every Submit that hit this shrink-then-regrow case
          # and (from the player's perspective) appearing to roll the
          # whole turn back, since the action never actually committed.
          @log[before..]&.each do |entry|
            next unless entry.message.is_a?(String)

            entry.message = shipify_log(entry.message)
            entry.message = tsi_pre_float_operates_message(entry.message)
          end
          result
        end

        # Round::Operating#start_operating logs "<acting player> operates
        # TSI" the same generic way as any normal corp's turn -- misleading
        # here, since TSI's pre-float turn is really just "the ST owner
        # flies the Probe," not a full corporate turn. Confirmed with the
        # user: rewrite that one line to say so explicitly. Gated on
        # tsi_pre_float? being true right now (not just matching the
        # text), so a genuinely-floated TSI's ordinary "X operates TSI"
        # line is left alone.
        def tsi_pre_float_operates_message(message)
          tsi = corporation_by_id('TSI')
          return message unless tsi && tsi_pre_float?(tsi)

          match = message.match(/^(.+) operates TSI$/)
          return message unless match

          "#{match[1]} (ST private owner) operates TSI's Probe"
        end

        # Whether this specific undo reaches back far enough to un-happen
        # an exploration -- reuses Game::Base.filtered_actions itself (the
        # exact logic that decides what an undo removes) rather than
        # guessing from the raw action's shape: running it once on the
        # actions so far, and once with this undo appended, shows exactly
        # which action ids flip from kept to undone. Cross-referencing
        # those ids against @log (still the live, pre-undo log at this
        # point -- every entry is already tagged with the action_id that
        # produced it, GameLog::Entry#action_id) finds any "explores
        # <hex>:" line among them. Deliberately reports only who and which
        # hex, not what was found there -- confirmed with the user this
        # should announce the peek without disclosing the hidden
        # information any more broadly than the peek already did.
        def exploration_undo_warning(undo_action)
          before_filtered, = self.class.filtered_actions(@raw_actions)
          after_filtered, = self.class.filtered_actions(@raw_actions + [undo_action.to_h])

          newly_undone_ids = before_filtered.each_index
                                             .select { |i| before_filtered[i] && !after_filtered[i] }
                                             .map { |i| before_filtered[i]['id'] }
          return if newly_undone_ids.empty?

          crossed = @log.filter_map do |entry|
            next unless newly_undone_ids.include?(entry.action_id)
            next unless entry.message.is_a?(String)

            match = entry.message.match(/^(.+?) explores (\S+):/)
            match && "#{match[1]} explored #{match[2]}"
          end
          return if crossed.empty?

          "Undo reversed an exploration -- #{crossed.join('; ')}"
        end

        def shipify_log(message)
          message.gsub(/\btrains\b/, 'ships').gsub(/\btrain\b/, 'ship')
        end

        # Shared train-buying/Info-tab UI text built from this instead of a
        # hardcoded "train" (see Game::Base#train_word) says "ship" for 2038.
        def train_word
          'ship'
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

        # There is no separate pre-game "auction phase" -- confirmed with
        # the user the very first round is a normal Stock round, it just
        # happens to also carry the WaterfallAuction step (see stock_round
        # below) since that's how privates/independents get sold. The base
        # engine's default `init_round` (`new_auction_round`, a dedicated
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
        # the ordinary Stock round instead. Confirmed with the user: as
        # long as any private/independent remains unsold, WaterfallAuction
        # blocks ahead of BuySellParShares for whoever's turn comes up (its
        # own `actions` goes empty the instant nothing's left to sell, at
        # which point a turn flows straight into ordinary share buying with
        # no extra step to pass through first) -- and the Stock round ends
        # the exact same way any SR ever does, via Round::Stock's own
        # all-entities-passed check, whether or not everything happened to
        # sell out first.
        def stock_round
          Engine::Round::Stock.new(self, [
            G2038::Step::MergeIntoLeague,
            G2038::Step::DiscardTrain,
            Engine::Step::SpecialTrack,
            G2038::Step::CompanyPendingPar,
            G2038::Step::WaterfallAuction,
            G2038::Step::BuySellParShares,
          ])
        end

        def operating_round(round_num)
          G2038::Round::Operating.new(self, [
            G2038::Step::MergeIntoLeague,
            G2038::Step::FormAsteroidLeague,
            Engine::Step::Bankrupt,
            G2038::Step::DiscardTrain,
            G2038::Step::StockRepurchase,
            G2038::Step::Route,
            G2038::Step::StockRepurchase,
            G2038::Step::Dividend,
            G2038::Step::BuyTrain,
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

        def cargo_holds_for_train(train)
          return 0 if train.name == 'Probe'

          train.name.split('/').last.to_i
        end

        def route_trains(entity)
          entity.runnable_trains
        end

        def can_run_route?(entity)
          route_trains(entity).any?
        end

        # Single-ship route optimizer (see autorouter.rb) -- reused across
        # calls since it holds no state of its own between suggest_route
        # invocations.
        def autorouter
          @autorouter ||= Autorouter.new(self)
        end

        # The from-scratch "optimal set" alternative (see optimal_
        # autorouter.rb) -- built and run alongside #autorouter for
        # comparison, never replacing it.
        def optimal_autorouter
          @optimal_autorouter ||= OptimalAutorouter.new(self)
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
          return true if self.class::TRANSSHIPMENT_HEXES.include?(hex.id)

          hex.tile.cities.any? { |c| c.tokens.any? }
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
              self.class::MINE_DATA.fetch(tile_name, [])
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
        # post-Route steps entirely during this turn (Dividend/BuyTrain/
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
        def trace_revenue(entity, train, trace, cargo)
          return 0 if train.name == 'Probe' || trace.size < 2
          return 0 unless deliverable_destination?(trace.last)

          cargo.sum { |c| c[:value] } + independent_ore_bonus(entity, train, cargo) +
            home_delivery_bonus(trace.last, cargo) + osr_claim_delivery_bonus(entity, cargo)
        end

        # A transshipment point's printed value works like a mine with
        # unlimited availability -- any ship passing through with a free
        # hold picks it up automatically (no click needed, unlike ore),
        # and it stacks with whatever ore the ship is already carrying.
        # See Step::Route#move_to, which calls this on every hex entered.
        # Phase-scaled values (§8): A13/D2/H10/O11 go $30 -> $60 and H18
        # goes $20 -> $70 once gray tiles unlock at Phase 4 -- already
        # handled for free by the standard route_revenue(phase, train)
        # mechanism, since map.rb's tile codes for these hexes are already
        # `yellow_X|gray_Y`. Rendered as an offboard part (not a city) so
        # the standard off-board box display shows both values -- H10
        # carries a separate zero-revenue city alongside it purely for
        # AL's home token, so this only ever needs to look at .offboards.
        def transshipment_value(hex, train)
          hex.tile.offboards.sum { |o| o.route_revenue(@phase, train) }
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
          return false unless self.class::TRANSSHIPMENT_HEXES.include?(hex_id)

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
        # though it doesn't actually close until AL buys its first ship --
        # confirmed with the user. CERT_LIMIT_INCLUDES_PRIVATES (true, the
        # base default) otherwise counts every held private uniformly.
        def num_certs(entity)
          certs = super
          certs -= 1 if @asteroid_league_formed && entity.respond_to?(:companies) &&
            entity.companies.any? { |c| c.id == 'AE' }
          certs
        end

        # Despite the name, this covers two distinct groups sharing one
        # mechanism: the three Independents (Phase 7 company abilities)
        # AND the five standard Corporations VP/LE/MM/OPC/RCC, each of
        # which also earns a flat bonus for its own favored ore delivered
        # ANYWHERE (not tied to any specific hex) -- confirmed with the
        # user, and NOT the same thing as home_delivery_bonus below (that
        # one pays whoever delivers to a specific hex, regardless of who
        # they are; this one pays a specific entity, regardless of where
        # they deliver). The two amounts happen to both be $10, but are
        # conceptually independent and can stack with each other and with
        # a home_delivery_bonus in the same trace_revenue call.
        INDEPENDENT_ORE_BONUS = {
          'IF' => :i, 'DH' => :r, 'OC' => :n,
          'VP' => :r, 'LE' => :n, 'MM' => :i, 'OPC' => :n, 'RCC' => :n,
        }.freeze
        INDEPENDENT_ORE_BONUS_AMOUNT = 10

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
        def independent_ore_bonus(entity, train, cargo)
          ore = self.class::INDEPENDENT_ORE_BONUS[entity.id]
          own_bonus = ore ? cargo.count { |c| c[:ore] == ore } * self.class::INDEPENDENT_ORE_BONUS_AMOUNT : 0

          own_bonus + pilot_ore_bonus(entity, train, cargo)
        end

        # The ore bonus this SPECIFIC train's assigned pilot grants, if any
        # -- 0 for an unconverted independent (handled directly above, via
        # entity.id) or a train with no pilot assigned, or one assigned to
        # a pilot without an ore bonus (LY/TH).
        def pilot_ore_bonus(entity, train, cargo)
          ore = self.class::INDEPENDENT_ORE_BONUS[pilot_source_for_train(entity, train)]
          return 0 unless ore

          cargo.count { |c| c[:ore] == ore } * self.class::INDEPENDENT_ORE_BONUS_AMOUNT
        end

        # Hex id -> [ore, amount] for every corp whose *home* base (its
        # starting `coordinates`, not any base it later places elsewhere)
        # pays a bonus for a matching ore delivered there by anyone --
        # built once from entities.rb's static data (Company/Corporation
        # Summary table: MM +$20/Ice, VP +$20/Rare, LE +$20/Nickel,
        # RCC +$10/Nickel, OPC +$10/Ice; TSI/AL have none).
        def home_delivery_bonuses
          @home_delivery_bonuses ||= self.class::CORPORATIONS.each_with_object({}) do |data, h|
            next unless data[:delivery_bonus]
            # OSR (§13b) is the only corp here whose entities.rb entry
            # exists regardless of optional rules but whose hex (B14)
            # isn't a real base without optional_new_corporations --
            # without this, a Full Game without the expansion would
            # still silently pay OSR's bonus to anyone delivering to
            # what's just an ordinary mine hex there.
            next if data[:sym] == 'OSR' && !optional_new_corporations

            h[data[:coordinates]] = [data[:delivery_bonus], data[:delivery_bonus_amount]]
          end
        end

        # Paid alongside the normal cargo revenue (and independent_ore_bonus,
        # if applicable) to WHOEVER's route ends at the bonus hex -- not just
        # the home corp itself (Phase 7b).
        def home_delivery_bonus(delivery_hex, cargo)
          ore, amount = home_delivery_bonuses[delivery_hex.id]
          return 0 unless ore

          cargo.count { |c| c[:ore] == ore } * amount
        end

        # §13b: On-Site Refining's *own* bonus -- distinct from its home
        # base's delivery_bonus (:r/+10, paid to *anyone* delivering Rare
        # there, same mechanism as VP/MM/LE/OPC/RCC's own home bonuses).
        # This one instead pays OSR itself +$10 for every delivery it
        # makes from a mine *it has claimed* (any ore type) -- "+10 /
        # claimed delivery." Checked against @mine_state directly (not
        # cargo's own recorded :value, which already reflects the
        # claimed-vs-unclaimed price split via pickup_value) since this
        # is a flat bonus stacked on top of that value, not a
        # replacement for it.
        OSR_CLAIM_DELIVERY_BONUS = 10

        def osr_claim_delivery_bonus(entity, cargo)
          return 0 unless entity.id == 'OSR'

          claimed = cargo.count do |c|
            c[:mine_idx] && @mine_state.dig(c[:hex_id], :mines, c[:mine_idx], :owner) == entity.id
          end
          claimed * self.class::OSR_CLAIM_DELIVERY_BONUS
        end

        # One pickable slot -- either a specific mine (mine_idx set) or a
        # transshipment hex (mine_idx/ore nil). `value` is the admissible
        # ranking ceiling (raw + best-case bonus, see #candidate_slots);
        # `raw_value` is the real pickup/transshipment value alone, with
        # no bonus assumption baked in -- the feasibility solver (Game::
        # OptimalAutorouter's own component) needs this to build a real
        # cargo list and let Game#trace_revenue compute actual bonuses
        # for whatever destination a specific route really reaches, since
        # `value`'s bonus assumption is only a safe over-estimate for
        # ranking, not necessarily achievable for any single combo.
        CandidateSlot = Struct.new(:hex_id, :mine_idx, :ore, :value, :raw_value, keyword_init: true)

        # Public: every slot this entity+train could currently pick up --
        # every unclaimed-or-entity-owned, not-yet-used-this-OR mine, plus
        # every currently-paying transshipment hex -- each tagged with an
        # admissible (never too low) ceiling on what a single unit there
        # could ever contribute: its own pickup/transshipment value, plus
        # #best_case_ore_bonus for whatever ore it is. The alternative-
        # ordering search (component 2 of the "optimal set" autorouter --
        # see also Autorouter#solo_ceiling, the earlier per-ship version
        # of this same idea) ranks candidate cargo combinations by summing
        # these values, highest first.
        def candidate_slots(entity, train)
          slots = []

          @mine_state.each do |hex_id, state|
            state[:mines].each_with_index do |mine, idx|
              next if mine[:used]
              next if mine[:owner] && mine[:owner] != entity.id

              bonus = best_case_ore_bonus(entity, train, mine[:ore], claimed: mine[:owner] == entity.id)
              raw = pickup_value(entity, hex_id, idx)
              slots << CandidateSlot.new(hex_id: hex_id, mine_idx: idx, ore: mine[:ore],
                                          value: raw + bonus, raw_value: raw)
            end
          end

          self.class::TRANSSHIPMENT_HEXES.each do |hex_id|
            next unless transshipment_hex?(hex_id)

            value = transshipment_value(hex_by_id(hex_id), train)
            next unless value.positive?

            slots << CandidateSlot.new(hex_id: hex_id, mine_idx: nil, ore: nil, value: value, raw_value: value)
          end

          slots
        end

        # The best-case additional bonus (beyond raw pickup/transshipment
        # value) a single unit of `ore` could ever contribute for this
        # entity+train -- entity's own INDEPENDENT_ORE_BONUS, its assigned
        # pilot's ore bonus, OSR's own claim-delivery bonus (if this unit
        # is a mine OSR itself has claimed), and whichever home_delivery_
        # bonuses hex pays the MOST for this ore.
        #
        # Deliberately loose, not exact: a real route only ever ends at
        # ONE hex, so at most one home_delivery_bonus can actually be
        # realized across the whole cargo -- crediting every slot its own
        # independently-best bonus assumes they could all somehow deliver
        # to their own ideal destination at once, which overstates the
        # true achievable total if two slots' best-paying hexes differ.
        # That's fine and intentional here, the same admissible-bound
        # philosophy Autorouter#solo_ceiling already uses for ranking/
        # pruning candidates against each other -- it can only ever fail
        # to prune something early, never wrongly discard a genuinely-
        # better combination. transshipment slots (ore nil) never get a
        # bonus -- none of these bonus types key off a nil ore.
        def best_case_ore_bonus(entity, train, ore, claimed:)
          return 0 unless ore

          entity_fixed_ore_bonus(entity, train, ore, claimed: claimed) + best_home_delivery_amount(ore)
        end

        # Just the destination-INDEPENDENT slice of #best_case_ore_bonus
        # -- entity's own INDEPENDENT_ORE_BONUS, its assigned pilot's ore
        # bonus, and OSR's own claim-delivery bonus -- every one of these
        # applies no matter where the route ends, unlike the home_
        # delivery_bonus portion. Pulled out so OptimalAutorouter's per-
        # destination-ore-focused sweeps (see that file's own comment on
        # why summing every slot's own independently-best home bonus made
        # the search's stopping point too slow to reach on a rich board)
        # can credit this exact, non-estimated part unconditionally, and
        # only add a home bonus when a slot's ore matches that sweep's
        # one assumed destination -- keeping each sweep's own per-slot
        # values genuinely additive/separable, unlike the combined bound.
        def entity_fixed_ore_bonus(entity, train, ore, claimed:)
          return 0 unless ore

          bonus = 0
          bonus += self.class::INDEPENDENT_ORE_BONUS_AMOUNT if self.class::INDEPENDENT_ORE_BONUS[entity.id] == ore
          pilot_ore = self.class::INDEPENDENT_ORE_BONUS[pilot_source_for_train(entity, train)]
          bonus += self.class::INDEPENDENT_ORE_BONUS_AMOUNT if pilot_ore == ore
          bonus += self.class::OSR_CLAIM_DELIVERY_BONUS if entity.id == 'OSR' && claimed
          bonus
        end

        # The most any single home_delivery_bonuses hex pays for `ore` --
        # 0 if none do.
        def best_home_delivery_amount(ore)
          home_delivery_bonuses.values.select { |bonus_ore, _| bonus_ore == ore }.map { |_, amt| amt }.max.to_i
        end

        # Torch's spaceships all get +1 MP over their printed stats -- every
        # movement-point calculation should read this instead of
        # train.distance directly. A Growth Corp formed from Torch (Phase 8)
        # grants the same +1 MP, but only to the ship its pilot is
        # assigned to this OR.
        def ship_distance(entity, train)
          torch_bonus = entity.id == 'TH' || pilot_source_for_train(entity, train) == 'TH'
          train.distance + (torch_bonus ? 1 : 0)
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
        def hex_bfs(start)
          @hex_bfs_cache ||= {}
          @hex_bfs_cache[start.id] ||= begin
            dist = { start.id => 0 }
            predecessor = {}
            queue = [start]

            until queue.empty?
              hex = queue.shift
              hex.neighbors.each_value do |neighbor|
                next if neighbor.empty || dist.key?(neighbor.id)

                dist[neighbor.id] = dist[hex.id] + 1
                predecessor[neighbor.id] = hex
                queue << neighbor
              end
            end

            [dist, predecessor]
          end
        end

        # Ice Finder/Drill Hound must draw a second tile if their first
        # draw has none of their favored ore; Lucky always draws twice.
        # See ROADMAP.md Decision D. A Growth Corp formed from one of these
        # three (Phase 8) inherits the same power, but only for the ship
        # its specific pilot is assigned to this OR.
        def needs_second_draw?(entity, train, first_mines)
          source = entity.minor? ? entity.id : pilot_source_for_train(entity, train)
          case source
          when 'LY' then true
          when 'IF' then first_mines.none? { |m| m[:ore] == :i }
          when 'DH' then first_mines.none? { |m| m[:ore] == :r }
          else false
          end
        end

        # Which of this corp's inherited pilot sources (if any) is assigned
        # to this specific train this OR -- each pilot the corp holds is
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
        def pilot_source_for_train(entity, train)
          # Inherited pilot abilities (Torch's +1 MP, IF/DH/OC's ore bonus,
          # LY's extra tile draw) stop applying from Phase 5 on, once the
          # underlying private closes -- confirmed with the user the ship
          # itself keeps flying, it just loses the bonus.
          return nil if phase.name.to_i >= 5

          step = round.steps.find { |s| s.is_a?(G2038::Step::Route) }
          return nil unless step.respond_to?(:pilot_source_for_train)

          step.pilot_source_for_train(entity, train)
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
          'LY' => 'draws 2 tiles when exploring and places the better one',
          'IF' => '+$10 per Ice (draws second tile if first lacks Ice)',
          'DH' => '+$10 per Rare (draws second tile if first lacks Rare)',
          'OC' => '+$10 per Nickel',
          'TH' => '+1 movement point to spaceships',
        }.freeze

        # Human-readable description of this corp's inherited pilot
        # ability/abilities (Phase 8), named per source rather than a
        # generic "Pilot:" label -- nil if it wasn't formed via Growth Corp
        # conversion (or hasn't absorbed any independent yet). Joins
        # multiple entries if the corp has more than one (e.g. AL). No
        # "(assignable to one ship per OR)" note -- per the user, the game
        # already enforces that, and restating it on every pilot just
        # clutters the charter.
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
          [name, self.class::MINE_DATA.fetch(name, [])]
        end

        # A throwaway tile instance for preview purposes (Lucky's tile-
        # choice popup) -- built straight from TILES' raw color/code
        # rather than pulled from @tiles, so it never consumes a pool slot
        # or risks clobbering a real instance's `.hex` when wrapped in a
        # preview Engine::Hex for rendering.
        def preview_tile(tile_name)
          val = self.class::TILES[tile_name]
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

        DEFAULT_CLAIM_COSTS = [60, 100].freeze

        # Flat price for a corporation buying an already-placed claim
        # directly from the independent holding it (§7.4x) -- confirmed
        # with the user this is a fixed price, not negotiated, and
        # distinct from the escalating DEFAULT_CLAIM_COSTS schedule used
        # for placing a brand new claim.
        INDEPENDENT_CLAIM_PRICE = 60

        # §13b: On-Site Refining pays an extra +$20 whenever it buys a
        # claim from an Independent this way -- unlike INDEPENDENT_CLAIM_
        # PRICE itself, this surcharge goes to the bank, not the selling
        # Independent.
        OSR_INDEPENDENT_CLAIM_SURCHARGE = 20

        # Raw CORPORATIONS config for this entity -- `bases:`/`stations:`/
        # `claim_costs:` are custom per-corp fields (§7.4) that the base
        # engine's Corporation/Operator classes don't consume or store, so
        # they're looked up here rather than added to shared engine code.
        def corp_data(entity)
          self.class::CORPORATIONS.find { |c| c[:sym] == entity.id }
        end

        # Cost of the *next* base/station this entity places, indexed by how
        # many it's already placed over the whole game (lifetime, not
        # per-round) -- costs aren't always constant across the array (e.g.
        # Outer Planet Consortium's first station is free, the rest aren't).
        def base_cost(entity)
          costs = corp_data(entity)&.dig(:bases) || [50]
          costs[@base_hexes[entity].size] || costs.last
        end

        def station_cost(entity)
          costs = corp_data(entity)&.dig(:stations) || [50]
          costs[@station_hexes[entity].size] || costs.last
        end

        # Hex ids where this entity has placed a base/refueling station so
        # far, in placement order -- the source of truth for both cost
        # indexing above and the corporation card's token-style display
        # (View::Game::Corporation#render_infrastructure_tokens).
        def base_hexes(entity)
          @base_hexes[entity]
        end

        def station_hexes(entity)
          @station_hexes[entity]
        end

        # Extra, uncounted bases already placed for this entity -- see the
        # comment on @extra_base_hexes in #setup for what lands here.
        def extra_base_hexes(entity)
          @extra_base_hexes[entity]
        end

        # The hex path + mine picks from this ship's last completed flight
        # (any OR, manually flown or accepted-suggestion), or nil if it's
        # never finished a run. Values aren't stored -- replay recomputes
        # them fresh against current mine_state/phase, same as a brand new
        # suggestion would.
        def last_route(train)
          @last_route[train.id]
        end

        def record_last_route!(train, hexes, cargo)
          @last_route[train.id] = {
            hexes: hexes.map(&:id),
            cargo: cargo.map { |c| { hex_id: c[:hex_id], mine_idx: c[:mine_idx] } },
          }
        end

        # Rollback counterpart to record_last_route! -- restores whatever
        # was on file before a locally-finished, not-yet-submitted flight
        # overwrote it (see Step::Route#rollback_local_flight!), rather
        # than leaving a stale pointer at a route that never really
        # happened.
        def restore_last_route!(train, value)
          if value
            @last_route[train.id] = value
          else
            @last_route.delete(train.id)
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
        # or is forced in. Doesn't affect bases/claims independents bring
        # *with* them on merger (those transfer as extras, same as a Growth
        # Corp's inherited base, Phase 8) -- only AL's own fresh placements.
        def base_limit(entity)
          limit = corp_data(entity)&.dig(:bases)&.size || Float::INFINITY
          return limit unless entity == @al_corporation

          [limit - remaining_independents.size, 0].max
        end

        def station_limit(entity)
          corp_data(entity)&.dig(:stations)&.size || Float::INFINITY
        end

        # Placeholder refueling-station token art (public/logos/g_2038/
        # *_station.svg, one per corp) so the corporation card's token strip
        # can show a distinct icon for stations vs bases, same as any other
        # game's per-corp logo files -- no shared view/engine code involved.
        def station_logo(entity)
          "/logos/g_2038/#{entity.id}_station.svg"
        end

        # Placeholder claim token art (public/logos/g_2038/*_claim.svg, one
        # per corp/independent) for the corporation card's claims display.
        def claim_logo(entity)
          "/logos/g_2038/#{entity.id}_claim.svg"
        end

        # Hex ids this entity holds a claim on, one entry per claimed mine
        # (a double-mine hex claimed twice by the same entity appears
        # twice) -- derived from @mine_state directly rather than tracked
        # separately, same source claims_placed_lifetime already reads.
        def claim_hexes(entity)
          @mine_state.flat_map { |hex_id, state| [hex_id] * state[:mines].count { |m| m[:owner] == entity.id } }
        end

        # Same one-entry-per-claimed-mine list as claim_hexes above, but
        # with the specific ore/claimed-value each entry needs to render
        # as its own mine-colored circle on the corporation card (see
        # View::Game::Corporation#render_claim_column) rather than a
        # generic flag icon -- claim_hexes alone only has the hex id,
        # which isn't enough to know which of a double-mine hex's two
        # (possibly differently-valued/ore'd) mines a given slot is.
        def claim_details(entity)
          @mine_state.flat_map do |hex_id, state|
            state[:mines].select { |m| m[:owner] == entity.id }
                          .map { |m| { hex_id: hex_id, ore: m[:ore], value: m[:claimed], used: m[:used] } }
          end
        end

        def claim_cost_schedule(entity)
          corp_data(entity)&.dig(:claim_costs) || DEFAULT_CLAIM_COSTS
        end

        # Independents' lifetime claim cap is a flat 2, always (§7.4).
        # Corporations' varies by corp (Company/Corporation Summary table,
        # `claim_limit:` in entities.rb); Float::INFINITY for the (currently
        # none) corps without one on record rather than silently capping.
        # Same reservation idea as base_limit above, but 2 claims per
        # remaining independent instead of 1 base (§8.12/Phase 9h).
        def claim_limit(entity)
          return 2 if entity.minor?

          limit = corp_data(entity)&.dig(:claim_limit) || Float::INFINITY
          # §13b: "Mars Mining gains 2 more Claims" once OSR/MR are in play.
          limit += 2 if entity.id == 'MM' && optional_new_corporations
          return limit unless entity == @al_corporation

          [limit - (remaining_independents.size * 2), 0].max
        end

        # Overrides Game::Base's own token-availability count/string --
        # both used only by the Spreadsheet view's "Tokens" column.
        # G2038's corp.tokens are bases, a small fixed count (1-3) that
        # says little on its own; claims (lifetime-capped, escalating cost,
        # the resource players actually track over a game) are what's
        # meaningful there instead. Confirmed with the user.
        def count_available_tokens(entity)
          claim_limit(entity) - claims_placed_lifetime(entity)
        end

        def token_string(entity)
          "#{count_available_tokens(entity)}/#{claim_limit(entity)}"
        end

        def trains_label
          'Ships'
        end

        def tokens_label
          'Claims'
        end

        # How many of AL's base/claim slots are currently held back for
        # independents that haven't merged in yet -- 0 for anyone else.
        # Purely derived from remaining_independents.size (the same count
        # base_limit/claim_limit already subtract), so it shrinks on its
        # own the instant an independent merges or closes for good -- no
        # separate "release" step needed, just re-render. Used by the
        # corporation card to mark held-back slots as "Res." instead of
        # leaving them looking like any other still-open, unreserved slot.
        def reserved_base_count(entity)
          return 0 unless entity == @al_corporation

          [remaining_independents.size, corp_data(entity)&.dig(:bases)&.size || 0].min
        end

        def reserved_claim_count(entity)
          return 0 unless entity == @al_corporation

          [remaining_independents.size * 2, corp_data(entity)&.dig(:claim_limit) || 0].min
        end

        # Used both to enforce lifetime claim caps (BuyInfrastructure) and to
        # display "claims remaining" on the corporation/minor card. Excludes
        # free claims (Robot Smelters' one-time ability, Phase 10) -- those
        # are an uncounted extra, same as a Growth Corp's inherited base.
        def claims_placed_lifetime(entity)
          @mine_state.values.sum { |s| s[:mines].count { |m| m[:owner] == entity.id && !m[:free] } }
        end

        def refueling_station_owner(hex_id)
          @refueling_stations[hex_id]
        end

        # Hexes reachable by at least one of entity's own spaceships from any
        # of its placed bases (§7.4), refueling at entity's own stations
        # along the way. BFS over hex neighbors, mirroring how ships actually
        # move in `G2038::Step::Route` -- "in range" is the same reachability
        # question as "could a ship fly there."
        def hexes_in_range(entity)
          base_hexes = entity.tokens.filter_map { |t| t.city&.hex }.uniq
          max_mp = entity.trains.map { |t| ship_distance(entity, t) }.max || 0
          return [] if base_hexes.empty? || max_mp.zero?

          best = {}
          base_hexes.each { |h| best[h.id] = max_mp }
          queue = base_hexes.dup

          until queue.empty?
            hex = queue.shift
            remaining = best[hex.id]
            hex.neighbors.each_value do |neighbor|
              next_remaining = remaining - 1
              next if next_remaining.negative?

              next_remaining = [next_remaining + 3, max_mp].min if refueling_station_owner(neighbor.id) == entity
              next if best[neighbor.id] && best[neighbor.id] >= next_remaining

              best[neighbor.id] = next_remaining
              queue << neighbor
            end
          end

          best.keys.map { |id| hex_by_id(id) }
        end

        # A base may be placed on any explored hex with no claimed mine (§7.4,
        # §7.41). Bases and mines are mutually exclusive on a hex -- laying
        # the base tile replaces whatever mines were there.
        def can_place_base?(hex)
          state = @mine_state[hex.id]
          return false unless state

          state[:mines].none? { |m| m[:owner] }
        end

        # `free:` is Tunnel Systems' one-time ability (Phase 10) -- placed at
        # no cost and never pushed into @base_hexes, so it's an uncounted
        # extra beyond the corp's own base allotment (same idea as a Growth
        # Corp's inherited base, Phase 8).
        def place_base!(entity, hex, free: false)
          token = entity.tokens.find { |t| !t.used }
          raise GameError, "#{entity.name} has no tokens left" unless token

          cost = free ? 0 : base_cost(entity)
          entity.spend(cost, bank) if cost.positive?
          if free
            @extra_base_hexes[entity] << hex.id
          else
            @base_hexes[entity] << hex.id
          end
          @mine_state.delete(hex.id)

          tile = @tiles.find { |t| t.name == '2023' && !t.hex }
          raise GameError, 'No base tiles available' unless tile

          # '2023' is an 'unlimited'-count tile (init_tile only ever pools a
          # single instance for those) -- add_extra_tile is the engine's
          # existing mechanism for replenishing it (duplicates a fresh
          # instance back into @tiles) every time one is actually laid.
          # Without this call, only the very first base placed in the whole
          # game would ever find an unused '2023' instance; every later one
          # would crash laying a nil tile.
          #
          # Not update_tile_lists (the normal tile-laying counterpart to
          # this) -- that also returns the *replaced* tile to @tiles, which
          # is right for an ordinary upgrade (the old tile goes back into
          # circulation) but wrong here: the mine tile a base covers is
          # gone for good, not available to be drawn again -- found live in
          # browser inflating the Tile Manifest's remaining count for that
          # tile type every time a base got placed over one.
          add_extra_tile(tile) if tile.unlimited
          @tiles.delete(tile)
          hex.lay(tile)
          tile.cities.first.place_token(entity, token, check_tokenable: false)
          @log << "#{entity.name} places a #{free ? 'free ' : ''}base at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        # Hex ids for every entity's starting home base (corp + independent +
        # AL) -- only used to know which hexes the edge-touching exclusion
        # below applies to. A base a company creates later via place_base!
        # is never in this set, so it's unconditionally eligible. OSR/MR's
        # own home hexes (B14/O13) are excluded here unless New Corporations
        # is active -- otherwise base_tile? below would still treat them as
        # a placed base (and hex.rb would draw the ring-station art on an
        # otherwise-ordinary, unexplored blue hex) even with the rule off.
        def starting_base_hexes
          @starting_base_hexes ||= (self.class::CORPORATIONS + self.class::MINORS).map { |data| data[:coordinates] }
          return @starting_base_hexes if optional_new_corporations

          @starting_base_hexes - self.class::OSR_MR_HOME_HEXES
        end

        # Which bases may ever receive a refueling station (§7.42): every
        # interior (non-edge) starting base except AL's, plus any base a
        # company creates later via place_base! (always eligible, regardless
        # of position). Edge-touching starting bases (VP/LE/MM/OPC/RCC, all
        # with fewer than 6 neighbors) never get one. §13b: OSR's/MR's own
        # starting bases (B14/O13) are an explicit exception on top of
        # that -- "Refueling Stations may not be placed at either of these
        # two starting bases".
        OSR_MR_HOME_HEXES = %w[B14 O13].freeze

        def station_eligible?(hex)
          return false if optional_new_corporations && self.class::OSR_MR_HOME_HEXES.include?(hex.id)
          return true unless starting_base_hexes.include?(hex.id)
          return hex.all_neighbors.size == 6 unless Array(@al_corporation.coordinates).include?(hex.id)

          # AL's home only becomes "just like any other base" -- including
          # eligible for a station -- once the League actually forms;
          # confirmed with the user. Before that it's just a placeholder
          # token with no corporation behind it yet.
          @asteroid_league_formed && hex.all_neighbors.size == 6
        end

        # A refueling station may be placed on any base within range that
        # doesn't already have one -- including a base owned by a *different*
        # corporation (§7.42 is explicit about this). "Has a base" reuses the
        # same token-presence check as `deliverable_destination?`.
        def can_place_station?(hex)
          hex.tile.cities.any? { |c| c.tokens.any? } && !refueling_station_owner(hex.id) && station_eligible?(hex)
        end

        # `free:` is Vacuum Associates' one-time ability (Phase 10) -- see
        # place_base! above for the same "free, uncounted extra" pattern.
        def place_station!(entity, hex, free: false)
          cost = free ? 0 : station_cost(entity)
          entity.spend(cost, bank) if cost.positive?
          @station_hexes[entity] << hex.id unless free
          @refueling_stations[hex.id] = entity

          @log << "#{entity.name} places a #{free ? 'free ' : ''}refueling station at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        # `free:` is Robot Smelters' one-time ability (Phase 10) -- the
        # claim still shows up in claim_hexes (the corp card's claim-flag
        # display), but claims_placed_lifetime excludes it, so it's an
        # uncounted extra rather than eating into the corp's claim_limit.
        def place_claim!(entity, hex, mine_idx, cost, free: false)
          entity.spend(cost, bank) if cost.positive?
          mine = @mine_state[hex.id][:mines][mine_idx]
          mine[:owner] = entity.id
          mine[:free] = true if free

          # The claimed value is now the only one that matters on the map --
          # only the claim owner may pick up here, always at the claimed rate.
          # A plain integer tile revenue parses to the same value under every
          # phase color (see Part::RevenueCenter#parse_revenue), so mirror
          # that shape directly rather than re-parsing a string. That bypass
          # skips `uniq_revenues`'s memoization too, though -- clear it by
          # hand or the map keeps showing the stale unclaimed value until
          # something else (e.g. a full reload) rebuilds the tile from
          # scratch.
          city = hex.tile.cities[mine_idx]
          city.revenue = Part::RevenueCenter::PHASES.to_h { |phase| [phase, mine[:claimed]] }
          city.instance_variable_set(:@uniq_revenues, nil)

          @log << "#{entity.name} claims a #{free ? 'free ' : ''}mine (#{claim_label(mine)}) at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        # "R:30"-style identifier for a mine -- the ore's one-letter code,
        # a colon, its claimed value -- used in claim-related log lines
        # so the log itself says what was actually claimed, not just
        # where. Per the user.
        def claim_label(mine)
          "#{mine[:ore].to_s.upcase}:#{mine[:claimed]}"
        end

        # A corporation buying an already-placed claim off the independent
        # holding it -- confirmed with the user this is a flat
        # INDEPENDENT_CLAIM_PRICE, paid to the independent, not the bank.
        # The mine's revenue was already set to its claimed value back when
        # the independent originally claimed it (place_claim! above), so
        # only ownership needs to change here.
        def buy_claim_from_independent!(entity, hex, mine_idx)
          mine = @mine_state[hex.id][:mines][mine_idx]
          seller = minor_by_id(mine[:owner])
          entity.spend(self.class::INDEPENDENT_CLAIM_PRICE, seller)

          surcharge = entity.id == 'OSR' ? self.class::OSR_INDEPENDENT_CLAIM_SURCHARGE : 0
          entity.spend(surcharge, bank) if surcharge.positive?
          mine[:owner] = entity.id

          total = self.class::INDEPENDENT_CLAIM_PRICE + surcharge
          @log << "#{entity.name} buys #{seller.name}'s claim (#{claim_label(mine)}) at #{hex.id} "\
                  "(#{format_currency(total)})"
        end

        # A corp buying an independent's claim is a cross-player
        # transaction whenever that independent belongs to a different
        # player than the buying corp's president -- same caution other
        # games show for share exchanges/purchases between players, via
        # the shared consent-popup mechanism (Actionable#check_consent in
        # the view layer). Only BuyInfrastructure's BUY_CLAIM choice ever
        # needs this; every other choice in the game returns nil (no
        # consent required), the same as the engine default.
        def consenter_for_choice(entity, choice, _label)
          step = @round.active_step(entity)
          return unless step.is_a?(G2038::Step::BuyInfrastructure)

          seller = step.claim_seller_for(entity, choice)
          owner = seller&.owner
          owner if owner&.player? && owner != entity.owner
        end

        def setup
          # §13-pre: the expansion's own "New Corporations" text is
          # explicit -- "to the full game (but not the Short Game)" --
          # and the Variant Start Packet transitively implies New
          # Corporations (optional_new_corporations above), so this one
          # check covers both. Raised here (not at the lobby/options
          # level) since @optional_rules is only assembled once game
          # setup actually runs -- matches how other invalid-combination
          # checks in this codebase surface (a GameError at setup time,
          # not a silent ignore).
          if optional_short_game && optional_new_corporations
            raise GameError, 'The Short Game cannot be combined with New Corporations or the Variant Start Packet'
          end

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
          # Systems' free-base ability (place_base!'s free: kwarg), a
          # Growth Corp's inherited independent base (Phase 8), and the
          # AL's inherited base from each independent it merges in
          # (Phase 9) all land here so the charter can show them.
          @extra_base_hexes = Hash.new { |h, k| h[k] = [] }
          # Most recently completed flight for each ship (train id -> hex
          # path + which mines were picked up), so "Modify"/"Submit" can
          # offer a cheap replay instead of re-running the autorouter's
          # search -- see Step::Route#preview_last_route. Persists here
          # (not on the round-local @route_stats_by_train) because it needs
          # to survive into the *next* OR, when Step::Route is rebuilt fresh.
          @last_route = {}
          # Growth Corp id -> the original independent's id it was formed
          # from (Phase 8), e.g. 'MM' => 'LY' -- used by independent_ore_bonus/
          # ship_distance/needs_second_draw? to find the inherited special
          # ability once it's only usable via the per-OR pilot assignment.
          @growth_corp_pilot = {}
          # Fast Buck's $15/OR treasury income (see G2038::Round::Operating#
          # pay_fast_buck_treasury) needs to follow FB into whichever corp
          # absorbs it (Growth Corp conversion or an AL merger) -- Minor#
          # close! unconditionally sets @floated = false, so paying the FB
          # minor directly would otherwise just silently stop the income
          # forever the moment it's absorbed, rather than continuing to
          # whoever now owns that treasury.
          @fast_buck_income_recipient = minor_by_id('FB')
          assign_exploration_tiles

          # The Probe is never sold from the Depot; TSI owns it from the start
          # of the game so it can be flown (by ST's owner) before TSI floats
          # (§6). See `operating_order`/`acting_for_entity`/`probe_bonus_recipient`.
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

          @al_corporation = corporation_by_id('AL')
          @al_corporation.capitalization = :incremental
          @asteroid_league_formed = false

          # §13c: "IPO shares" (a corp's own still-unsold allocation)
          # must NOT pay the corp dividends once this rule is active,
          # while genuinely repurchased "Treasury Shares" (rule 3) must.
          # Both currently show `owner == corp` with no way to tell them
          # apart -- confirmed with the user, following the same pattern
          # 1862 uses for its own chartered/full-capitalization
          # companies (Game#convert_to_full!): point `ipo_owner` at the
          # bank instead of the corp itself, so a corp's *unsold* shares
          # live with the bank while only genuinely *repurchased* ones
          # ever end up owned by the corp again. Every G2038 corp starts
          # `:full` capitalization; AL just switched to `:incremental`
          # immediately above (Growth Corps switch similarly later, on
          # formation) -- both correctly skipped here and left alone,
          # already handled by rule 1's own capitalization check
          # elsewhere. Must run *after* AL's own capitalization switch
          # above, not before, or AL (still `:full` at that point) would
          # get its own IPO shares wrongly redirected to the bank too.
          # Otherwise run as early as possible, before any shares have
          # actually moved, so "every currently self-held share" is
          # unambiguously the entire unsold allotment.
          if optional_stock_repurchases
            @corporations.each do |corp|
              next if corp.capitalization == :incremental

              corp.ipo_owner = bank
              corp.shares_by_corporation[corp].dup.each { |share| transfer_treasury_share!(share, bank) }
            end
          end

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
          # least once, ever (Phase 9c/9d) -- lets a Stock round host the one
          # true "as soon as AL forms" initial pass without ever re-offering
          # an already-declined independent there again (recurring re-offers
          # are Operating-round-only; see Step::MergeIntoLeague).
          @al_independents_ever_offered = []

          @corporations.reject! { |c| c.id == 'AL' }

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

          # §13a: "The two group 'C' Corporations, the Outer Planet
          # Consortium and the Ring Construction Corp., are not used."
          # Dropped from @corporations *after* their bases are placed
          # above (see that comment) so they never operate, never appear
          # on the stock market, and never show up in any other
          # bookkeeping that iterates @corporations, while their bases
          # remain in play.
          @corporations.reject! { |c| %w[OPC RCC].include?(c.id) } if optional_short_game

          # §13b: On-Site Refining and Mining Robotics only exist under
          # the New Corporations expansion rule (or the Variant Start
          # Packet, which implies it) -- same "drop from @corporations,
          # base stays real" pattern as OPC/RCC above, just gated the
          # opposite way (present unless the rule is *off*). NOTE: this
          # wires entities.rb data, the on/off toggle, and the starting-
          # base placement -- still not yet implemented: OSR/MR "start
          # the game already in play" with no normal IPO/float at all
          # (today, with the rule on, they still wait for the ordinary
          # group_c unlock and float like any other corp -- see ROADMAP
          # 13b).
          @corporations.reject! { |c| %w[OSR MR].include?(c.id) } unless optional_new_corporations

          return if optional_variant_start_pack

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
          hex_ids = self.class::HEXES[:blue].keys.flatten.sort

          pool = []
          ('2001'..'2022').each do |name|
            self.class::TILES[name]['count'].times { pool << name }
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
          # Found live in browser: growth_corp_pilots kept returning
          # entries past Phase V, even though the Phase V event's own log
          # text already (incorrectly) claimed this was handled.
          #
          # Fast Buck's $15/OR treasury income counts as its pilot
          # certificate too (confirmed with the user -- an earlier reading
          # of this code treated it as a separate, permanent perk instead,
          # which was wrong), so it stops the same way: clearing
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
        # meaningful only for release timing (see TRAIN_LIMIT_PHASE_* above),
        # not the three train-limit categories the rules actually define.
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

        # Companies may not buy trains from each other before Phase II (§5.x
        # Sequence of Play) -- depot trains are unaffected either way.
        def can_buy_train_from_others?
          after_phase_1?
        end

        # Phase 11b: a corporation with no spaceship must buy one (EMR, then
        # bankruptcy if it still can't afford one) -- but independents are
        # governed entirely by their own rule (Phase 9f: merge into AL once
        # it exists; before that, an independent with no ship simply sits
        # idle with no consequence, confirmed with the user). The base
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

        def event_asteroid_league_can_form!
          @log << 'Asteroid League may now be formed'
          @corporations << @al_corporation
        end

        # Backstop for §8: if AE's owner hasn't already declared formation
        # via G2038::Step::FormAsteroidLeague, it's forced the moment
        # Phase 4 begins.
        def event_asteroid_league_must_form!
          return if @asteroid_league_formed

          form_asteroid_league!(company_by_id('AE')&.owner)
        end

        # Phase 5 mandatory merger (§9e): every independent still active
        # merges into the AL immediately, no player choice involved -- AL is
        # guaranteed to already exist by this point (Phase 4's
        # asteroid_league_must_form event above always runs first). Mirrors
        # 1835's event_forced_pr_exchange! (force-loop + direct merge calls,
        # bypassing the voluntary MergeIntoLeague step entirely).
        def event_independents_must_join_league!
          remaining_independents.dup.each { |minor| merge_independent_into_al!(minor) }
        end

        # §7.39/Phase 9f: an independent that owns no ship and can't afford
        # the cheapest one left in the Depot must merge into the AL rather
        # than go bankrupt -- checked at the start of its own OR turn (see
        # G2038::Round::Operating#skip_entity?). Moot before the AL exists,
        # since there's nowhere for it to merge into yet.
        def independent_must_merge?(minor)
          return false unless @asteroid_league_formed
          return false unless minor.minor?
          return false if minor.closed?
          return false unless minor.trains.empty?

          cheapest = depot.depot_trains.map(&:price).min
          cheapest.nil? || minor.cash < cheapest
        end

        # AL is neither a Public Corp (needs 50% floated) nor a Growth Corp
        # (the engine has no such distinction) -- per the rules it's active
        # immediately on formation with a fixed $250 grant, so `floated` is
        # set directly rather than via `float_corporation` (which would pay
        # out par x total_shares, the wrong amount here).
        def form_asteroid_league!(owner)
          return if @asteroid_league_formed
          return unless owner

          @asteroid_league_formed = true

          share_price = stock_market.par_prices.find { |pp| pp.price == 125 }
          stock_market.set_par(@al_corporation, share_price)
          share_pool.buy_shares(owner, @al_corporation.presidents_share, exchange: :free)
          bank.spend(250, @al_corporation)
          @al_corporation.floated = true

          ae = company_by_id('AE')
          ae.all_abilities.select { |a| a.type == :choose_ability }.each { |a| ae.remove_ability(a) }

          @log << "#{owner.name} forms the Asteroid League, receiving its President's certificate "\
                  "and #{format_currency(250)} initial capital"

          insert_al_into_current_or_if_eligible!
        end

        # AL forms mid-OR (buying a Phase III ship, which triggers
        # eligibility, is itself an OR action) but wasn't in this round's
        # @entities snapshot -- confirmed with the user: it may still slot
        # into *this* OR, at its rightful $125 position ahead of any
        # corporation priced $124 or lower, but only if no such corporation
        # has operated yet this round. Once one has, it's too late to
        # insert AL fairly ahead of it, so AL simply waits for the next OR
        # (where it's included from the start in the normal way).
        def insert_al_into_current_or_if_eligible!
          return unless round.is_a?(Engine::Round::Operating)

          already_acted = round.entities.first(round.entity_index + 1)
          return if already_acted.any? { |e| e.corporation? && e.share_price && e.share_price.price <= 124 }

          pending_ids = round.entities.last(round.entities.size - round.entity_index - 1).map(&:id)
          pending_ids << @al_corporation.id
          round.entities = already_acted + operating_order.select { |e| pending_ids.include?(e.id) }
        end

        def asteroid_league_formed?
          @asteroid_league_formed
        end

        # Independents (minors) that haven't yet merged into the AL or
        # converted into a Growth Corp -- the pool Step::MergeIntoLeague
        # offers each round, and the Phase 5/bankruptcy mandatory triggers
        # sweep in directly (Phase 9).
        def remaining_independents
          @minors.reject(&:closed?)
        end

        # Merges `minor` into the Asteroid League (Phase 9c, and the forced
        # paths: event_independents_must_join_league! at Phase 5, and
        # independent bankruptcy). Mirrors form_growth_corporation!'s asset
        # transfer shape (Phase 8) minus the par/president's-cert dance --
        # AL already exists, already floated, at this point.
        def merge_independent_into_al!(minor, first_opportunity: !@al_independents_ever_offered.include?(minor.id))
          owner = minor.owner
          # The owner only receives half the treasury on the independent's
          # first opportunity to merge (when the AL forms). Any later merge
          # -- a decline followed by accepting a subsequent offer, the
          # Phase 5 forced merge, or a bankruptcy-forced merge -- gives the
          # owner nothing unless the independent still owns a ship at the
          # moment of merger -- confirmed with the user. Short Game
          # exception (§13a): "Independent owners receive 1/2 of their
          # cash-on-hand only if they join the Asteroid League when it
          # first forms (regardless of whether they still possess a
          # spaceship if they join later)" -- the "still owns a ship"
          # exception for a later merge simply doesn't exist under this
          # optional rule; only the first-opportunity case ever pays out.
          owner_gets_half = first_opportunity || (!optional_short_game && !minor.trains.empty?)
          # .round guards against a non-integer minor.cash -- money here
          # should always be whole dollars, but this is defensive in case
          # some earlier turn's arithmetic left a fractional residue (found
          # live in browser: a stale $72.5 in a log line, from an odd
          # total run through plain float division somewhere upstream).
          # Confirmed with the user: the owner's share rounds UP, the AL
          # treasury's share rounds DOWN -- the opposite of what this used
          # to do (owner got floor(total/2), AL got the ceil remainder).
          # Both amounts are computed up front from the same rounded
          # total, rather than spending the owner's half and then relying
          # on whatever's left in minor.cash for the AL's share, so a
          # leftover fractional cent can never carry over into AL's own
          # treasury via the second spend.
          total_cash = minor.cash.round
          half_cash = owner_gets_half ? (total_cash + 1) / 2 : 0
          al_cash = total_cash - half_cash
          # check_positive: false on top of the .positive? guards themselves
          # (not just belt-and-suspenders) -- matches Step::Dividend#
          # payout_entity's own zero-guard + check_positive: false pairing
          # for the same "split revenue between multiple parties, some
          # shares legitimately zero" shape. Found live in browser: a
          # zero-cash independent's merge raised "Cannot spend zero or
          # negative money in Spender.spend(0)" from one of these two
          # calls despite total_cash/half_cash/al_cash all replaying as
          # clean zero Integers server-side -- never reproduced outside
          # the browser's own Opal runtime, so the guard alone isn't
          # trustworthy enough here; check_positive: false makes a $0
          # transfer a harmless no-op no matter what.
          minor.spend(half_cash, owner, check_positive: false) if half_cash.positive?
          minor.spend(al_cash, @al_corporation, check_positive: false) if al_cash.positive?

          reserved_share = @al_reserved_shares[minor.id]
          reserved_share.buyable = true
          share_pool.buy_shares(owner, reserved_share, exchange: :free)

          # transfer (not a manual owner-reassign loop) -- it also
          # invalidates Game::Base's own @crowded_corps memoization
          # (checked by Step::DiscardTrain#active?/crowded_corps to force
          # an over-limit discard). A manual loop bypasses that
          # invalidation entirely, so a merge that pushes AL over its own
          # train_limit (§9g -- AL's own train_limit is real, just like
          # any corp's) went completely undetected until something else
          # happened to touch @crowded_corps later -- found live in
          # browser: AL sitting at 5 ships with its own limit at 4, no
          # discard ever prompted.
          transfer(:trains, minor, @al_corporation)

          # Extra, uncounted base -- same as a Growth Corp's inherited base
          # (Phase 8): never pushed into @base_hexes[@al_corporation], so
          # base_limit/base_cost don't count it against AL's own allotment.
          # Still tracked in @extra_base_hexes so the charter can show it.
          if (token = minor.tokens.find(&:used))
            new_token = Token.new(@al_corporation)
            @al_corporation.tokens << new_token
            token.swap!(new_token, check_tokenable: false)
            @extra_base_hexes[@al_corporation] << minor.coordinates
          end

          # Claims transfer too, and DO count against AL's claim_limit (same
          # as Phase 8) -- a plain ownership reassignment.
          @mine_state.each_value do |state|
            state[:mines].each { |m| m[:owner] = @al_corporation.id if m[:owner] == minor.id }
          end

          # Fast Buck has no in-flight pilot ability (its $15/OR income is
          # passive, unrelated to any ship) -- only push a pilot source for
          # independents PILOT_NAMES actually recognizes, or pilot_
          # description would render a blank "<nil>: <nil>" entry for it
          # (confirmed via the user's own screenshot: a stray leading ": ; "
          # in the AL card's pilot text, from exactly this).
          (@growth_corp_pilot[@al_corporation.id] ||= []) << minor.id if self.class::PILOT_NAMES.key?(minor.id)

          # Fast Buck's own $15/OR treasury income follows it into the AL --
          # otherwise Minor#close! (below) sets FB's own @floated to false
          # forever, and pay_fast_buck_treasury would just silently stop
          # paying anyone once FB is absorbed.
          @fast_buck_income_recipient = @al_corporation if minor.id == 'FB'

          private_company = company_by_id(minor.id)
          minor.close!
          private_company&.close!

          if half_cash.positive?
            @log << "#{minor.name} merges into #{@al_corporation.name}; #{owner.name} receives "\
                    "#{format_currency(half_cash)} and a 10% #{@al_corporation.name} share "\
                    "(#{@al_corporation.name} keeps the other half of #{minor.name}'s treasury)"
          else
            @log << "#{minor.name} merges into #{@al_corporation.name}; #{owner.name} receives "\
                    "a 10% #{@al_corporation.name} share (#{@al_corporation.name} keeps all of "\
                    "#{minor.name}'s treasury)"
          end
        end

        # Unfloated, non-AL corps currently unlocked into @corporations --
        # the same pool the normal cash-par path already offers, since
        # trading in an independent is just a second way to start any of
        # them (Phase 8).
        # Growth Corp conversion is only available in Phases 2-3, and never
        # once the Asteroid League has formed (§8).
        # §13d: "Growth Corporations still may not be launched during Phase
        # I even so" -- already true unconditionally, variant or not: a
        # corp only ever becomes a Growth Corp via the trade-in-an-
        # independent conversion path (form_growth_corporation!, which sets
        # capitalization = :incremental as ITS OWN result -- see below), and
        # that path is already gated to Phases 2-3 here regardless of any
        # group-partition timeline. No separate check needed under
        # optional_variant_start_pack.
        def growth_conversion_allowed?
          %w[2 3].include?(phase.name) && !@asteroid_league_formed
        end

        def growth_convertible_corporations
          return [] unless growth_conversion_allowed?

          @corporations.select { |c| c.corporation? && !c.ipoed && c.id != 'AL' }
        end

        def growth_convertible_minors(player)
          @minors.select { |m| m.owner == player && !m.closed? }
        end

        # Trades in `minor` (one of the player's own still-active
        # independents) for `corp`'s president's certificate (Phase 8).
        # `corp` always pars at $67 (fixed treasury share price -- see
        # Share#price_per_share, which reads par_price for as long as a
        # share's owner is still the corp itself) while its market token
        # starts at the separately-labeled $10/par_2 cell -- mirrors
        # form_asteroid_league!'s pattern of bypassing float_corporation
        # entirely for full control over exactly what cash moves.
        def form_growth_corporation!(player, minor, corp)
          par_67 = stock_market.par_prices.find { |pp| pp.price == 67 }
          price_10 = stock_market.par_prices.find { |pp| pp.price == 10 }

          corp.capitalization = :incremental

          # §13c's ipo_owner migration (Game#setup) runs at game start,
          # before any corp's eventual capitalization is knowable -- every
          # corp still shows :full at that point (this one only becomes
          # :incremental right here, via conversion), so under
          # optional_stock_repurchases it was already swept into the bank
          # along with every genuinely full-cap corp. Reclaim it now: this
          # corp hasn't parred/floated yet, so nothing but the bank could
          # possibly hold any of its shares at this exact moment -- safe
          # to move all of them back unconditionally. Without this,
          # SharePool#buy_shares' own incremental-cap payment routing
          # (keyed on `bundle.owner.corporation?`) never matches, since
          # the shares stay bank-owned forever, and every share a player
          # buys from this corp's own IPO box silently pays the bank
          # instead of the corp -- found live: a Growth Corp showing only
          # its inherited independent's treasury cash, none of what
          # players had actually paid for its shares.
          if corp.ipo_owner != corp
            corp.ipo_owner = corp
            bank.shares_by_corporation[corp].dup.each { |share| transfer_treasury_share!(share, corp) }
          end

          stock_market.set_par(corp, par_67)
          # set_par (above) also pushes corp onto par_67.corporations, which
          # is what actually draws a token on the stock market chart --
          # that must not stay, or the corp shows up at BOTH $67 and $10.
          # par_price staying at par_67 (for treasury pricing) doesn't
          # require the token to render there too.
          par_67.corporations.delete(corp)
          corp.share_price = price_10
          price_10.corporations << corp

          share_pool.buy_shares(player, corp.presidents_share, exchange: :free)

          minor.spend(minor.cash, corp) if minor.cash.positive?

          # transfer (not a manual owner-reassign loop) -- see
          # merge_independent_into_al!'s identical fix/comment for why: a
          # manual loop never invalidates Game::Base's own @crowded_corps
          # memoization, so a conversion that pushes the new Growth Corp
          # over its own train_limit would go completely undetected.
          transfer(:trains, minor, corp)

          # The independent's base transfers as an EXTRA base -- never
          # pushed into @base_hexes[corp], so base_limit/base_cost (both
          # keyed off that array's size, not entity.tokens) don't count it
          # against the corp's own allotment. Still tracked in
          # @extra_base_hexes so the charter can actually show it (it's a
          # real, already-placed token, at the independent's old home hex)
          # instead of being invisible.
          if (token = minor.tokens.find(&:used))
            new_token = Token.new(corp)
            corp.tokens << new_token
            token.swap!(new_token, check_tokenable: false)
            @extra_base_hexes[corp] << minor.coordinates
          end

          # Claims transfer too, but DO count against the corp's own
          # claim_limit (unlike the base) -- a plain ownership reassignment,
          # since claims_placed_lifetime/claim_limit are always computed
          # fresh from @mine_state, nothing else to keep in sync.
          @mine_state.each_value do |state|
            state[:mines].each { |m| m[:owner] = corp.id if m[:owner] == minor.id }
          end

          # Fast Buck has no in-flight pilot ability (its $15/OR income is
          # passive, unrelated to any ship) -- only push a pilot source for
          # independents PILOT_NAMES actually recognizes, or pilot_
          # description would render a blank "<nil>: <nil>" entry for it.
          (@growth_corp_pilot[corp.id] ||= []) << minor.id if self.class::PILOT_NAMES.key?(minor.id)

          # Fast Buck's own $15/OR treasury income follows it into the
          # Growth Corp -- same reasoning as merge_independent_into_al!.
          @fast_buck_income_recipient = corp if minor.id == 'FB'

          corp.floated = true

          # This independent will never merge into the AL now (it's closing
          # permanently as an independent) -- its reserved AL share (Phase 9a2)
          # is released as ordinary buyable AL stock rather than granted to
          # anyone, since no merge is happening here.
          @al_reserved_shares[minor.id].buyable = true

          private_company = company_by_id(minor.id)
          minor.close!
          private_company&.close!

          @log << "#{player.name} trades in #{minor.name} for #{corp.name}'s president's certificate "\
                  "(par #{format_currency(67)}, market price #{format_currency(10)})"

          # Bypasses the normal par step (set_par/buy_shares called
          # directly, above) same as after_buy_company's TSI formation --
          # after_par is what actually fires event_group_b/c_corps_available!
          # once every corp in the current group has launched (§ "Once all
          # of a group is launched, the next group is immediately
          # available" -- launched means the President's cert is
          # acquired, not sold out; a Growth Corp is launched/active the
          # instant this happens). Without this call, a Growth-Corp-only
          # completion of a group could never unlock the next one, no
          # matter how much of its stock later sold. Found live in
          # browser: RU formed as a Growth Corp, sold out, and the next
          # group still never became available.
          after_par(corp)
        end

        def company_header(company)
          is_minor = @minors.find { |m| m.id == company.id }
          is_minor ? 'INDEPENDENT COMPANY' : 'PRIVATE COMPANY'
        end

        def after_par(corporation)
          super

          return unless @corporations.all?(&:ipoed)

          case @available_corp_group
          when :group_a
            event_group_b_corps_available!
          when :group_b
            event_group_c_corps_available!
          end
        end

        def after_buy_company(player, company, _price)
          target_price = optional_short_game ? 67 : 100
          share_price = stock_market.par_prices.find { |pp| pp.price == target_price }

          # NOTE: This should only ever be TSI
          abilities(company, :shares) do |ability|
            ability.shares.each do |share|
              if share.president
                if optional_variant_start_pack
                  # §13d: "TSI's par price is player-chosen" -- and must be
                  # chosen immediately, interrupting the auction right when
                  # ST is bought (confirmed with the user -- waiting for
                  # the ordinary ipo/par UI, which only ever becomes
                  # reachable once WaterfallAuction stops blocking for
                  # *everyone*, was too late whenever other companies were
                  # still unsold). `@round.companies_pending_par` is the
                  # base engine's own mechanism for exactly this shape (a
                  # private grants a president's cert, its buyer must
                  # immediately pick a par price before anyone else can
                  # act) -- already wired into stock_round via
                  # G2038::Step::CompanyPendingPar (this game's own
                  # subclass, fixing the base version's `corporation.
                  # shares.first` to `ipo_shares.first` -- needed since
                  # optional_variant_start_pack always implies
                  # optional_stock_repurchases, which relocates an unparred
                  # full-cap corp's shares to the bank at setup), which is
                  # positioned *before* WaterfallAuction in that array so
                  # it wins Round::Base#process_action's first-blocking-
                  # step lookup and genuinely blocks everyone else's turn
                  # until this resolves.
                  @round.companies_pending_par << company
                else
                  stock_market.set_par(share.corporation, share_price)
                  share_pool.buy_shares(player, share, exchange: :free)
                  after_par(share.corporation)
                end
              else
                # Suppress president-share swap: TSI_0 must only move when ST is bought.
                # Without this, buying TSI_2+TSI_3 triggers a swap that pulls TSI_0 out of
                # the IPO early, causing "Cannot buy share from player" when ST is resolved.
                share_pool.buy_shares(player, share, exchange: :free, allow_president_change: false)
              end
            end
          end
        end

        # TSI is never parrable through the *ordinary* cash-par UI, baseline
        # or variant -- its president's cert only ever comes from ST's own
        # `shares` ability (see after_buy_company above), either an
        # immediate fixed-price grant (baseline) or a forced player choice
        # via G2038::Step::CompanyPendingPar (optional_variant_start_pack).
        # Without this, nothing stops any player from cash-parring TSI
        # directly through the ordinary par UI before ST is even bought --
        # a real gap in both modes.
        #
        # The exception below is required, not just belt-and-suspenders:
        # assets/app/view/game/{par,form_corporation}.rb both gate their
        # own price-selection buttons behind this exact method ("Cannot
        # Par" otherwise) -- CompanyPendingPar#process_par itself never
        # calls can_par? at all, but the UI the player actually clicks
        # through to submit that Par action does, for every corp. Found
        # live: the interrupt correctly blocked every other player, but
        # the intended buyer saw "Cannot Par" too, with no way to ever
        # submit a price. `round.respond_to?` guards against Operating-
        # round contexts, where companies_pending_par was never declared
        # (round_state only merges keys the current round's own steps
        # opted into) and would otherwise raise via method_missing.
        def can_par?(corporation, parrer)
          if corporation.id == 'TSI'
            pending = round.respond_to?(:companies_pending_par) &&
              round.companies_pending_par.find { |c| c.id == 'ST' }
            return false unless pending && pending.owner == parrer
          end

          super
        end

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
        NEW_CORPORATIONS_EXTRA_TRAINS = { '5/4' => 1, '7/6' => 1, '9/7' => 3 }.freeze

        def num_trains(train)
          count = super
          count -= 2 if optional_short_game && train[:name] == '4/3'
          count += self.class::NEW_CORPORATIONS_EXTRA_TRAINS[train[:name]] || 0 if optional_new_corporations
          # §13d: "+2 Phase I ships" -- same double-sided-token pool as
          # '4/3'/'6/2' above, just added to '3/2''s own '5/1'-variant pool
          # instead of removed from it.
          count += 2 if optional_variant_start_pack && train[:name] == '3/2'
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
        # Step::BuyTrain#buyable_trains (the ordinary purchase list) and
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
          trains = super
          return trains if phase_vi_unlocked?

          trains.reject { |_train, discount_train, _variant_name, _price| discount_train.name == '9/7' }
        end

        # §13b: On-Site Refining's and Mining Robotics' starting bases are
        # plain pre-printed base hexes with no mine/ore content at all --
        # exactly like every other corp's home (TSI's K9, MM's A1, etc.),
        # not a randomly-explored asteroid tile. Confirmed with the user
        # after two wrong earlier guesses (a fixed hex with no setup
        # change, then a real explored mine tile) -- this one holds:
        # `optional_hexes` (below) is what actually makes B14/O13 exist as
        # real base hexes at all; from there they go through the exact
        # same `place_home_token`/`coordinates:` flow as any other corp,
        # so this base is also automatically uncounted against
        # base_limit/bases.size the same way every other corp's home
        # already is (home placement never touches @base_hexes -- only
        # place_base! does).
        #
        # These two hexes don't exist as cities at all without this rule
        # -- unlike OPC/RCC (whose bases are part of the standard 13 and
        # exist regardless of any optional rule), B14/O13 are ordinary
        # unexplored blue hexes in the Full Game as printed. `optional_hexes`
        # (see Game::Base's own "use to modify hexes based on optional
        # rules" comment) is the designated override point -- moves both
        # coordinates from `blue` to `gray` only when the rule is active,
        # so a Full Game without the expansion keeps its normal 100
        # unexplored blue hexes untouched. Builds fresh arrays/hashes
        # rather than mutating HEXES's own (frozen) nested structures.
        def optional_hexes
          return game_hexes unless optional_new_corporations

          hexes = game_hexes.dup
          hexes[:blue] = { hexes[:blue].keys.first - self.class::OSR_MR_HOME_HEXES => '' }
          hexes[:gray] = { hexes[:gray].keys.first + self.class::OSR_MR_HOME_HEXES => 'city=revenue:0' }
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
        # label for OSR/MR floating over them -- found live in browser as
        # a bare "OSR" text label and generic gray marker with no real
        # base underneath, on a Full Game with the rule off entirely.
        def reservation_corporations
          return super if optional_new_corporations

          super.reject { |c| %w[OSR MR].include?(c.id) }
        end

        def optional_stock_repurchases
          optional_variant_start_pack || @optional_rules&.include?(:optional_stock_repurchases)
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
          tile && self.class::MINE_DATA.key?(tile.name)
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
          return false unless tile.hex == hex_by_id(tile.hex.id)

          !(Array(@al_corporation.coordinates).include?(tile.hex.id) && !@asteroid_league_formed)
        end

        # Opt-in hook for assets/app/view/game/hex.rb: how many separate
        # mines (and so how many asteroid-rock silhouettes, one per
        # city) this tile has -- 1 or 2.
        def mine_count(tile)
          self.class::MINE_DATA[tile.name]&.size || 0
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
