# frozen_string_literal: true

require_relative 'meta'
require_relative 'map'
require_relative 'entities'
require_relative '../base'
require_relative 'round/operating'
require_relative 'step/waterfall_auction'
require_relative 'step/buy_train'
require_relative 'step/dividend'
require_relative 'step/route'
require_relative 'step/form_asteroid_league'
require_relative 'step/buy_infrastructure'
require_relative 'autorouter'

module Engine
  module Game
    module G2038
      class Game < Game::Base
        include_meta(G2038::Meta)
        include Map
        include Entities

        attr_reader :mine_state, :al_reserved_shares, :al_independents_ever_offered, :al_corporation,
                    :fast_buck_income_recipient

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

        STARTING_CASH = { 3 => 600, 4 => 450, 5 => 360, 6 => 300 }.freeze

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
        # League doesn't exist as an operating entity until it forms (Phase 3+,
        # see asteroid_league_can_form/must_form below), so its limit is moot
        # before then; independents are gone by Phase 6, so that key is simply
        # absent there.
        TRAIN_LIMIT_PHASE_1_2 = { corporation: 4, asteroid_league: 4, independent: 2 }.freeze
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
            status: %w[can_buy_bases_stations can_buy_companies],
          },
          {
            name: '3',
            on: '5/4',
            train_limit: TRAIN_LIMIT_PHASE_3_5,
            tiles: %i[yellow],
            operating_rounds: 2,
            status: %w[can_buy_bases_stations can_buy_companies],
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
            num: 9,
            discount: {
              '5/4' => 700,
              '7/3' => 700,
              '6/5' => 700,
              '8/4' => 700,
              '7/6' => 700,
              '9/5' => 700,
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
            'Every private company still open (other than Space Transportation Co. and Asteroid '\
            'Export Co., which close on their own separate triggers) closes immediately when Phase V '\
            'begins. Any inherited pilot ability (Torch\'s +1 MP, Ice Finder/Drill Hound/Ore Crusher\'s '\
            'ore bonus, Lucky\'s extra tile draw) stops applying from that point on, though the ship '\
            'keeps flying.',
          ],
          'group_b_corps_available' => ['Group B Corporations become available'],
          'group_c_corps_available' => ['Group C Corporations become available'],
        ).freeze

        def bank_starting_cash
          optional_short_game ? 4_000 : BANK_CASH
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
          @log[before..].each do |entry|
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
            Engine::Step::DiscardTrain,
            Engine::Step::SpecialTrack,
            Engine::Step::CompanyPendingPar,
            G2038::Step::WaterfallAuction,
            G2038::Step::BuySellParShares,
          ])
        end

        def operating_round(round_num)
          G2038::Round::Operating.new(self, [
            G2038::Step::MergeIntoLeague,
            G2038::Step::FormAsteroidLeague,
            Engine::Step::Bankrupt,
            Engine::Step::DiscardTrain,
            G2038::Step::Route,
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

        def explore_hex!(hex_id, entity)
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
              self.class::MINE_DATA.fetch(tile_name, [])
            else
              []
            end

          @mine_state[hex_id] = {
            mines: mines.map { |m| m.merge(owner: nil, used: false) },
          }

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

          cargo.sum { |c| c[:value] } + independent_ore_bonus(entity, train, cargo) + home_delivery_bonus(trace.last, cargo)
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

        # Torch's spaceships all get +1 MP over their printed stats -- every
        # movement-point calculation should read this instead of
        # train.distance directly. A Growth Corp formed from Torch (Phase 8)
        # grants the same +1 MP, but only to the ship its pilot is
        # assigned to this OR.
        def ship_distance(entity, train)
          torch_bonus = entity.id == 'TH' || pilot_source_for_train(entity, train) == 'TH'
          train.distance + (torch_bonus ? 1 : 0)
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
          'IF' => '+$10 per Ice ore delivered (forces a second tile draw if the first lacks Ice)',
          'DH' => '+$10 per Rare ore delivered (forces a second tile draw if the first lacks Rare)',
          'OC' => '+$10 per Nickel ore delivered',
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
          return limit unless entity == @al_corporation

          [limit - (remaining_independents.size * 2), 0].max
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
          # single instance for those) -- update_tile_lists is the engine's
          # existing mechanism for replenishing it (duplicates the tile back
          # into @tiles) every time one is actually laid, same as any normal
          # tile-laying step does via Tracker#lay_tile. Without this call,
          # only the very first base placed in the whole game would ever
          # find an unused '2023' instance; every later one would crash
          # laying a nil tile.
          old_tile = hex.tile
          update_tile_lists(tile, old_tile)
          hex.lay(tile)
          tile.cities.first.place_token(entity, token, check_tokenable: false)
          add_station_slot_marker!(hex)
          @log << "#{entity.name} places a #{free ? 'free ' : ''}base at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        # Hex ids for every entity's starting home base (corp + independent +
        # AL) -- only used to know which hexes the edge-touching exclusion
        # below applies to. A base a company creates later via place_base!
        # is never in this set, so it's unconditionally eligible.
        def starting_base_hexes
          @starting_base_hexes ||= (self.class::CORPORATIONS + self.class::MINORS).map { |data| data[:coordinates] }
        end

        # Which bases may ever receive a refueling station (§7.42): every
        # interior (non-edge) starting base except AL's, plus any base a
        # company creates later via place_base! (always eligible, regardless
        # of position). Edge-touching starting bases (VP/LE/MM/OPC/RCC, all
        # with fewer than 6 neighbors) never get one.
        def station_eligible?(hex)
          return true unless starting_base_hexes.include?(hex.id)
          return hex.all_neighbors.size == 6 unless Array(@al_corporation.coordinates).include?(hex.id)

          # AL's home only becomes "just like any other base" -- including
          # eligible for a station -- once the League actually forms;
          # confirmed with the user. Before that it's just a placeholder
          # token with no corporation behind it yet.
          @asteroid_league_formed && hex.all_neighbors.size == 6
        end

        STATION_SLOT_NAME = 'g2038_station_slot'

        # Generic "may get a station here" placeholder (a white circle with
        # an outlined teardrop) shown on every eligible, not-yet-stationed
        # base -- replaced by the real per-corp colored icon the moment a
        # station is actually placed (see place_station!).
        def add_station_slot_marker!(hex)
          return if hex.tile.icons.any? { |i| i.name == STATION_SLOT_NAME }

          hex.tile.icons << Part::Icon.new('g_2038/station_slot', STATION_SLOT_NAME, true, false, false, large: true)
        end

        def remove_station_slot_marker!(hex)
          hex.tile.icons.reject! { |i| i.name == STATION_SLOT_NAME }
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
          remove_station_slot_marker!(hex)

          # Unlike a base, a station has no token/city slot of its own to
          # render through (the hex's one city slot is already the base
          # owner's) -- Part::Icon is the engine's existing generic
          # "extra thing pinned to a tile" mechanism (used by every game for
          # preprinted map decorations), so pushing one onto the tile's
          # live icons array at placement time gets it drawn with zero
          # shared view/engine code touched. public/icons/g_2038/ holds one
          # placeholder icon per corp, matching each one's own color.
          # large: true picks up the engine's existing Part::LargeIcons
          # rendering path (LARGE_RADIUS 25 vs. the normal 16) -- also
          # pre-existing/generic, not something added for this.
          hex.tile.icons << Part::Icon.new("g_2038/#{entity.id}_station", "station_#{entity.id}", true, false, false,
                                            large: true, owner: entity)

          @log << "#{entity.name} places a #{free ? 'free ' : ''}refueling station at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
        end

        # `free:` is Robot Smelters' one-time ability (Phase 10) -- the
        # claim still shows up in claim_hexes (the corp card's claim-flag
        # display), but claims_placed_lifetime excludes it, so it's an
        # uncounted extra rather than eating into the corp's claim_limit.
        def place_claim!(entity, hex, mine_idx, cost, free: false)
          entity.spend(cost, bank) if cost.positive?
          @mine_state[hex.id][:mines][mine_idx][:owner] = entity.id
          @mine_state[hex.id][:mines][mine_idx][:free] = true if free

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
          claimed_value = @mine_state[hex.id][:mines][mine_idx][:claimed]
          city.revenue = Part::RevenueCenter::PHASES.to_h { |phase| [phase, claimed_value] }
          city.instance_variable_set(:@uniq_revenues, nil)

          @log << "#{entity.name} claims a #{free ? 'free ' : ''}mine at #{hex.id}"\
                  "#{free ? '' : " (#{format_currency(cost)})"}"
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
          mine[:owner] = entity.id

          @log << "#{entity.name} buys #{seller.name}'s claim at #{hex.id} "\
                  "(#{format_currency(self.class::INDEPENDENT_CLAIM_PRICE)})"
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
          # path + which mines were picked up), so "Previous Route" can
          # offer a cheap replay instead of re-running the autorouter's
          # search -- see Step::Route#replay_previous_route!. Persists here
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

          # All 13 starting-base hexes are on the map and deliverable from
          # turn one -- unlike the engine's HOME_TOKEN_TIMING default of
          # :operate, a corp/independent's own home base doesn't wait for
          # it to float or take its first OR turn (§6/§7). This matters for
          # *other* entities delivering there before this one has floated,
          # not just for itself. place_home_token no-ops harmlessly if
          # called again later (it checks `tokens.first&.used`), so the
          # standard :operate-time call still fires without conflict once
          # each entity actually starts operating.
          (@corporations + @minors + [@al_corporation]).each { |entity| place_home_token(entity) }

          # Mark every eligible starting base with the generic "may get a
          # station" placeholder (§7.42) -- edge-touching starting bases are
          # excluded, and AL's isn't eligible until it forms (station_eligible?
          # picks it up separately in form_asteroid_league! below), but a
          # base a company creates later is unconditionally eligible (see
          # place_base!).
          starting_base_hexes.each do |hex_id|
            hex = hex_by_id(hex_id)
            add_station_slot_marker!(hex) if station_eligible?(hex)
          end

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
          # separate trigger long before now. Fast Buck never gets an
          # entry here at all (no PILOT_NAMES key, its $15/OR income is
          # unrelated and keeps flowing via @fast_buck_income_recipient),
          # so clearing the whole hash can't accidentally touch that.
          # Found live in browser: growth_corp_pilots kept returning
          # entries past Phase V, even though the Phase V event's own log
          # text already (incorrectly) claimed this was handled.
          return if @growth_corp_pilot.empty?

          @log << 'All inherited pilot bonuses are removed'
          @growth_corp_pilot = {}
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
          # AL's home is now a normal base like any other -- newly eligible
          # for a station (station_eligible?) -- so it needs the same "may
          # get a station" placeholder every other eligible base received
          # at setup.
          Array(@al_corporation.coordinates).each do |hex_id|
            hex = hex_by_id(hex_id)
            add_station_slot_marker!(hex) if station_eligible?(hex)
          end

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
          # moment of merger -- confirmed with the user.
          owner_gets_half = first_opportunity || !minor.trains.empty?
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
          minor.spend(half_cash, owner) if half_cash.positive?
          minor.spend(al_cash, @al_corporation) if al_cash.positive?

          reserved_share = @al_reserved_shares[minor.id]
          reserved_share.buyable = true
          share_pool.buy_shares(owner, reserved_share, exchange: :free)

          minor.trains.dup.each do |train|
            minor.trains.delete(train)
            train.owner = @al_corporation
            @al_corporation.trains << train
          end

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

          minor.trains.dup.each do |train|
            minor.trains.delete(train)
            train.owner = corp
            corp.trains << train
          end

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
                stock_market.set_par(share.corporation, share_price)
                share_pool.buy_shares(player, share, exchange: :free)
                after_par(share.corporation)
              else
                # Suppress president-share swap: TSI_0 must only move when ST is bought.
                # Without this, buying TSI_2+TSI_3 triggers a swap that pulls TSI_0 out of
                # the IPO early, causing "Cannot buy share from player" when ST is resolved.
                share_pool.buy_shares(player, share, exchange: :free, allow_president_change: false)
              end
            end
          end
        end

        def optional_short_game
          @optional_rules&.include?(:optional_short_game)
        end

        def optional_variant_start_pack
          @optional_rules&.include?(:optional_variant_start_pack)
        end

        # Suggest Route / Accept Route is on by default; the optional rule
        # is phrased as an opt-out (checking it turns the assist off) so
        # the common case needs no setup step, per the user.
        def autorouter_enabled?
          !@optional_rules&.include?(:disable_autorouter)
        end
      end
    end
  end
end
