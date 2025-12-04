# frozen_string_literal: true

require_relative 'meta'
require_relative '../base'
require_relative 'map'
require_relative 'entities'
require_relative 'round/draft'
require_relative 'round/operating'
require_relative 'step/draft'
require_relative 'step/dividend'
require_relative 'step/form_prussian'
require_relative 'step/merge_to_prussian'
require_relative '../../round/operating'
require_relative '../../round/stock'

module Engine
  module Game
    module G1835
      class Game < Game::Base
        include_meta(G1835::Meta)
        include G1835::Entities
        include G1835::Map

        # Enable player-to-player share purchases (nationalization)
        BUY_SHARE_FROM_OTHER_PLAYER = true

        # Minimum ownership percentage required to nationalize shares
        NATIONALIZATION_THRESHOLD = 55

        # Ownership threshold for certificate limit bonus
        CERT_LIMIT_BONUS_THRESHOLD = 80

        # Pre-Prussian companies that can merge into PR
        PRE_PRUSSIAN_MINORS = %w[P1 P3 P4 P5 P6].freeze
        PRE_PRUSSIAN_COMPANIES = %w[BB HB].freeze

        # Mapping of pre-Prussian entities to their reserved PR share indices
        # P2 (M2) gets the president's share (handled specially)
        # These indices correspond to the shares array in PR corporation definition
        PR_SHARE_MAPPING = {
          'P1' => 'PR_9',  # 5% share at index 9
          'P3' => 'PR_10', # 5% share at index 10
          'P4' => 'PR_3',  # 10% share at index 3
          'P5' => 'PR_11', # 5% share at index 11
          'P6' => 'PR_8',  # 5% share at index 8
          'BB' => 'PR_2',  # 10% share at index 2
          'HB' => 'PR_1',  # 10% share at index 1
        }.freeze

        EVENTS_TEXT = Base::EVENTS_TEXT.merge(
          'pr_optional' => ['Optional PR Formation', 'PR formation becomes optional for M2 owner'],
          'pr_mandatory' => ['Mandatory PR Formation', 'PR must form immediately if not already formed'],
          'mergers_mandatory' => ['Mandatory Mergers', 'All pre-Prussian companies must merge into PR'],
        ).freeze

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
        # money per initial share sold
        CAPITALIZATION = :incremental

        MUST_SELL_IN_BLOCKS = false

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

        PHASES = [
          {
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
                  {
                    name: '4',
                    distance: 4,
                    price: 360,
                    num: 3,
                    events: [{ 'type' => 'pr_optional' }],
                  },
                  {
                    name: '4+4',
                    distance: 4,
                    price: 440,
                    num: 1,
                    events: [{ 'type' => 'pr_mandatory' }],
                  },
                  {
                    name: '5',
                    distance: 5,
                    price: 500,
                    num: 2,
                    events: [{ 'type' => 'mergers_mandatory' }],
                  },
                  { name: '5+5', distance: 5, price: 600, num: 1 },
                  { name: '6', distance: 6, price: 600, num: 2 },
                  { name: '6+6', distance: 6, price: 720, num: 4 }].freeze

        LAYOUT = :pointy

        SELL_MOVEMENT = :down_block

        HOME_TOKEN_TIMING = :float

        attr_reader :pr_formed, :pr_formation_optional, :pr_formation_mandatory, :mergers_mandatory

        def setup
          @pr_formed = false
          @pr_formation_optional = false
          @pr_formation_mandatory = false
          @mergers_mandatory = false

          corporations.each do |i|
            @stock_market.set_par(i, @stock_market.par_prices.find do |p|
                                       p.price == PAR_PRICES[i.id]
                                     end)
            i.ipoed = true
          end

          # Reserve PR shares for pre-Prussian companies
          setup_pr_reserved_shares
        end

        def setup_pr_reserved_shares
          pr = corporation_by_id('PR')
          return unless pr

          # Mark the appropriate shares as reserved for each pre-Prussian entity
          # The share indices map to specific reserved shares
          PR_SHARE_MAPPING.each_value do |share_id|
            share_index = share_id.split('_').last.to_i
            share = pr.shares[share_index] if share_index < pr.shares.size
            share.buyable = false if share
          end

          # Also reserve the president's share for P2 (M2)
          pr.presidents_share.buyable = false
        end

        # Event handlers for PR formation triggers
        def event_pr_optional!
          @log << "-- Event: #{EVENTS_TEXT['pr_optional'][1]} --"
          @pr_formation_optional = true
        end

        def event_pr_mandatory!
          @log << "-- Event: #{EVENTS_TEXT['pr_mandatory'][1]} --"
          @pr_formation_mandatory = true

          # If PR hasn't formed yet, it must form now
          form_prussian_railroad! unless @pr_formed
        end

        def event_mergers_mandatory!
          @log << "-- Event: #{EVENTS_TEXT['mergers_mandatory'][1]} --"
          @mergers_mandatory = true

          # Force all remaining pre-Prussian mergers
          force_remaining_mergers!
        end

        # Check if PR formation is currently allowed
        def pr_formation_allowed?
          @pr_formation_optional || @pr_formation_mandatory
        end

        # Check if mergers are currently allowed
        def mergers_allowed?
          @pr_formed && (@pr_formation_optional || @mergers_mandatory)
        end

        # Get the M2 minor (P2)
        def m2_minor
          @minors.find { |m| m.id == 'P2' }
        end

        # Get PR corporation
        def pr_corporation
          corporation_by_id('PR')
        end

        # Get pre-Prussian minors that haven't merged yet
        def unmerged_pre_prussian_minors
          PRE_PRUSSIAN_MINORS.map { |sym| @minors.find { |m| m.id == sym } }
                             .compact
                             .reject(&:closed?)
        end

        # Get pre-Prussian companies that haven't merged yet
        def unmerged_pre_prussian_companies
          PRE_PRUSSIAN_COMPANIES.map { |sym| company_by_id(sym) }
                                .compact
                                .reject(&:closed?)
        end

        # All pre-Prussian entities that can still merge
        def mergeable_pre_prussian_entities
          unmerged_pre_prussian_minors + unmerged_pre_prussian_companies
        end

        # Form the Prussian Railroad from M2
        def form_prussian_railroad!
          m2 = m2_minor
          return unless m2
          return if m2.closed?
          return if @pr_formed

          pr = pr_corporation
          owner = m2.owner

          @log << "-- #{m2.name} forms the Prussian Railroad! --"

          # Transfer president's share to M2 owner
          presidents_share = pr.presidents_share
          presidents_share.buyable = true
          @share_pool.transfer_shares(ShareBundle.new([presidents_share]), owner)

          @log << "#{owner.name} receives the president's share of #{pr.name}"

          # Set PR owner
          pr.owner = owner

          # Transfer cash from M2 to PR
          if m2.cash.positive?
            @log << "#{pr.name} receives #{format_currency(m2.cash)} from #{m2.name}'s treasury"
            m2.spend(m2.cash, pr)
          end

          # Transfer trains from M2 to PR
          unless m2.trains.empty?
            trains_str = m2.trains.map(&:name).join(', ')
            @log << "#{pr.name} receives train(s): #{trains_str}"
            m2.trains.dup.each { |t| buy_train(pr, t, :free) }
          end

          # Replace M2's token with PR token
          replace_minor_token(m2, pr)

          # Close M2
          close_corporation(m2, quiet: true)

          # Float PR
          pr.floatable = true
          pr.floated = true

          @pr_formed = true
        end

        # Merge a pre-Prussian entity into PR
        def merge_entity_to_prussian!(entity, operated_this_or: false)
          pr = pr_corporation
          return unless pr
          return unless @pr_formed

          # Get entity identifier - companies have sym, minors have id/name
          entity_id = entity.respond_to?(:sym) ? entity.sym : entity.id
          share_id = PR_SHARE_MAPPING[entity_id]
          return unless share_id

          share_index = share_id.split('_').last.to_i

          # Find the share by its index attribute, not array position
          # The shares array can shift after transfers, but share.index stays the same
          share = pr.shares.find { |s| s.index == share_index }
          return unless share

          owner = entity.owner
          @log << "-- #{entity.name} merges into #{pr.name} --"

          # Make share buyable and transfer to owner
          share.buyable = true
          @share_pool.transfer_shares(ShareBundle.new([share]), owner, allow_president_change: true)
          @log << "#{owner.name} receives a #{share.percent}% share of #{pr.name}"

          # Track if this share should not pay dividends this OR
          @round.non_paying_shares[owner][pr] += 1 if operated_this_or && @round.respond_to?(:non_paying_shares)

          if entity.minor?
            # Transfer cash from minor to PR
            if entity.cash.positive?
              @log << "#{pr.name} receives #{format_currency(entity.cash)} from #{entity.name}'s treasury"
              entity.spend(entity.cash, pr)
            end

            # Transfer trains from minor to PR
            unless entity.trains.empty?
              if pr.trains.size >= train_limit(pr)
                @log << "#{entity.name}'s trains are discarded (#{pr.name} at train limit)"
                entity.trains.each { |t| @depot.reclaim_train(t) }
              else
                trains_str = entity.trains.map(&:name).join(', ')
                @log << "#{pr.name} receives train(s): #{trains_str}"
                entity.trains.dup.each { |t| buy_train(pr, t, :free) }
              end
            end

            # Replace token
            replace_minor_token(entity, pr)

            # Close the minor
            close_corporation(entity, quiet: true)
          else
            # It's a company - just close it
            entity.close!
          end

          graph.clear_graph_for(pr)
        end

        # Force all remaining pre-Prussian mergers
        def force_remaining_mergers!
          return unless @pr_formed

          mergeable_pre_prussian_entities.each do |entity|
            # Skip entities without player owners
            next unless entity.owner&.player?

            merge_entity_to_prussian!(entity, operated_this_or: false)
          end
        end

        # Replace a minor's token with a PR token
        def replace_minor_token(minor, pr)
          token = minor.tokens.first
          return unless token&.used

          new_token = Token.new(pr)
          pr.tokens << new_token
          token.swap!(new_token, check_tokenable: false)
          @log << "#{pr.name} receives token at #{new_token.city.hex.id}"
        end

        # Check if entity has operated this round
        def operated_this_round?(entity)
          entity.operating_history.include?([@turn, @round.round_num])
        end

        # Get player order for mergers, starting after PR director
        def merger_player_order
          pr_owner = pr_corporation&.owner
          return @players unless pr_owner

          index = @players.index(pr_owner)
          return @players unless index

          # Start with player after PR director, wrap around
          @players.rotate(index + 1)
        end

        def init_round
          @log << '-- Initial Draft Round --'
          new_draft_round
        end

        def new_draft_round
          G1835::Round::Draft.new(self, [G1835::Step::Draft], reverse_order: true)
        end

        def next_round!
          @round =
            case @round
            when G1835::Round::Draft
              if all_entities_drafted?
                # All purchased, move to stock round
                @log << '-- All entities purchased, starting stock round --'
                new_stock_round
              elsif @round.entities.all?(&:passed?)
                # Everyone passed, go to operating round
                @log << '-- Draft incomplete, moving to operating round --'
                @operating_rounds = @phase.operating_rounds
                new_operating_round
              else
                # Should not reach here during normal flow
                raise GameError, 'Unexpected draft round state'
              end
            when Engine::Round::Stock
              @operating_rounds = @phase.operating_rounds
              reorder_players
              new_operating_round
            when Engine::Round::Operating
              if @round.round_num < @operating_rounds
                # Continue OR set
                or_round_finished
                new_operating_round(@round.round_num + 1)
              elsif all_entities_drafted?
                # Draft complete, normal flow
                @turn += 1
                or_round_finished
                or_set_finished
                new_stock_round
              else
                # Return to draft round
                @log << '-- Returning to draft round --'
                new_draft_round
              end
            end
        end

        def all_entities_drafted?
          start_packet_entities.all? { |e| entity_drafted?(e) }
        end

        def start_packet_entities
          @start_packet_entities ||= begin
            entity_map = (companies + minors + corporations).to_h do |e|
              sym = e.respond_to?(:sym) ? e.sym : e.name
              [sym, e]
            end
            self.class::START_PACKET.map do |sym, _, _|
              entity = entity_map[sym]
              raise GameError, "START_PACKET references unknown entity: #{sym}" unless entity

              entity
            end
          end
        end

        def entity_drafted?(entity)
          if entity.corporation?
            # Corporation is drafted when a player owns the president's share
            entity.presidents_share.owner&.player?
          else
            entity.owner&.player?
          end
        end

        def operating_round(round_num)
          G1835::Round::Operating.new(self, [
            Engine::Step::Bankrupt,
            G1835::Step::FormPrussian,
            G1835::Step::MergeToPrussian,
            Engine::Step::SpecialTrack,
            Engine::Step::SpecialToken,
            Engine::Step::Track,
            Engine::Step::Token,
            Engine::Step::Route,
            G1835::Step::Dividend,
            Engine::Step::DiscardTrain,
            Engine::Step::BuyTrain,
          ], round_num: round_num)
        end

        def stock_round
          Engine::Round::Stock.new(self, [
            G1835::Step::FormPrussian,
            G1835::Step::MergeToPrussian,
            Engine::Step::DiscardTrain,
            Engine::Step::Exchange,
            Engine::Step::SpecialTrack,
            G1835::Step::BuySellParShares,
          ])
        end

        # Nationalization: player can only buy shares from another player if they own >= 55% of the corporation
        def can_gain_from_player?(entity, bundle)
          return false unless entity.player?

          corporation = bundle.corporation
          entity.percent_of(corporation) >= self.class::NATIONALIZATION_THRESHOLD
        end

        # Certificate limit with bonus for 80% ownership
        # Players get +1 to their certificate limit for each corporation they own >= 80% of
        def cert_limit(entity = nil)
          return @cert_limit unless entity&.player?

          bonus = @corporations.count do |corp|
            corp.ipoed && entity.percent_of(corp) >= self.class::CERT_LIMIT_BONUS_THRESHOLD
          end

          @cert_limit + bonus
        end
      end
    end
  end
end
