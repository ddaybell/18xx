# frozen_string_literal: true

require_relative '../../../step/buy_sell_par_shares'

module Engine
  module Game
    module G2038
      module Step
        # Adds a second way to start any unfloated, non-AL corporation (§8):
        # trading in an owned independent for that corp's president's
        # certificate instead of paying cash. Surfaced as extra buttons
        # directly in the par UI (assets/app/view/game/par.rb) alongside the
        # normal par-price buttons, rather than a separate step/action -- see
        # Game#form_growth_corporation! for the actual asset transfer.
        class BuySellParShares < Engine::Step::BuySellParShares
          GROW = 'grow_'

          # Two market cells exist solely for special-cased formation paths,
          # never a player-chosen cash par: $10/par_2 is Growth Corp
          # conversion's fixed market-token start (Game#
          # form_growth_corporation!, set directly via `share_price=`), and
          # $125/par_1 is the Asteroid League's own fixed par
          # (Game#form_asteroid_league!, via stock_market.set_par). Neither
          # should appear among the regular 67/77/88/100 par choices.
          def get_par_prices(entity, corp)
            super.reject { |p| [10, 125].include?(p.price) }
          end

          # Base can_buy_any_from_ipo?/can_ipo_any? look at corporation.shares
          # (shares literally owned by the corporation object) to find what's
          # still buyable pre-sellout -- correct only when ipo_owner == self,
          # true for every game except this one. Once optional_stock_
          # repurchases points a full-cap corp's ipo_owner at the bank (see
          # Game#setup), those same still-unsold shares move to the bank and
          # corporation.shares goes permanently empty, even for a corp
          # nobody has parred yet -- can_ipo_any? and can_buy_any_from_ipo?
          # then find nothing to buy/par for ANY corporation, for ANY
          # player, for the rest of the game (found live: right after the
          # last private sold, the whole Stock round returned empty actions
          # for every player and fell straight through into the first OR).
          # corporation.ipo_shares (Corporation#ipo_shares, `@ipo_owner.
          # shares.select { corporation == self }`) tracks the *right*
          # holder regardless of where ipo_owner points, exactly the same
          # fix 1862 already uses for its own chartered companies (see
          # G1862::Step::BuySellParShares#can_buy_any_from_ipo?/
          # #can_ipo_any?) -- process_par (base class) already gets this
          # right on its own via ipo_shares.first, so only these two
          # discovery methods need the override. Deliberately NOT also
          # exposing genuine treasury shares (corporation.shares, shares
          # actually bought back into the corp via StockRepurchase) here --
          # the rules describe those as parked in the Growth Corporation
          # box, not up for resale, and Game#issuable_shares already
          # enforces that (always []).
          def can_buy_any_from_ipo?(entity)
            @game.corporations.each do |corporation|
              next unless corporation.ipoed
              return true if can_buy_shares?(entity, corporation.ipo_shares)
            end

            false
          end

          def can_ipo_any?(entity)
            !bought? && @game.corporations.any? do |c|
              @game.can_par?(c, entity) && can_buy?(entity, c.ipo_shares.first&.to_bundle)
            end
          end

          def actions(entity)
            result = super
            return result unless choice_available?(entity)

            result = result.dup
            result << 'choose' unless result.include?('choose')
            result << 'pass' unless result.include?('pass')
            result
          end

          # Without the bought? guard, a player who still holds a second
          # growth-convertible minor (and another convertible corporation
          # remains unfloated) would keep 'choose'/'pass' in `actions`
          # forever, even after already exchanging once this turn -- since
          # base `actions` only appends 'pass' when something else is
          # non-empty, this alone made the step stay blocking? (current_
          # actions non-empty) and the round would never auto-advance,
          # forcing an unnecessary manual Done click with no visible
          # explanation (the second exchange button lives on a different
          # corporation's row in par.rb, easy to miss). sell_buy only
          # allows one purchase-type action per turn, and a growth
          # exchange is one (see `bought?` above), so it must be blocked
          # exactly like a second buy_shares/par would be.
          def choice_available?(entity)
            return false unless entity&.player?
            return false if bought?

            !@game.growth_convertible_minors(entity).empty? && !@game.growth_convertible_corporations.empty?
          end

          # The base class's `bought?` (gates further buying/parring, and --
          # via can_sell_any?/pass availability -- whether the round
          # auto-advances) only recognizes PURCHASE_ACTIONS (BuyCompany/
          # BuyShares/Par). A growth-exchange choice dispatches via
          # Action::Choose, which isn't in that list, so without this
          # override the engine never registered the exchange as "having
          # acted" -- the player could still also buy/par separately, and
          # the round wouldn't advance once the queried player had nothing
          # else to do, since it still looked like they had a full turn
          # left. Scoped to growth-exchange choices specifically (the
          # "grow_" prefix) so it doesn't affect unrelated Choose actions
          # from other steps.
          def bought?
            super || @round.current_actions.any? { |x| x.is_a?(Action::Choose) && x.choice.to_s.start_with?(GROW) }
          end

          # The exchange buttons render directly in par.rb (growth_exchange_
          # choices, scoped to one corporation at a time) rather than via
          # the generic bottom-panel Choose component or a map hex click --
          # explicitly no-op'd here so assets/app/view/game/choose.rb's
          # `step.choice_name` (called unconditionally once 'choose' is an
          # action, no respond_to? guard) and hex.rb's `step.choices.
          # include?(@hex.id)` dispatch (same story) never crash or
          # misfire for this step.
          def entity_choices(_entity)
            {}
          end

          def choice_name
            nil
          end

          def choices(_entity = current_entity)
            {}
          end

          # Called from par.rb: this player's exchange options specifically
          # for `corporation` (one button per owned independent).
          def growth_exchange_choices(entity, corporation)
            return {} unless choice_available?(entity) && @game.growth_convertible_corporations.include?(corporation)

            @game.growth_convertible_minors(entity).each_with_object({}) do |minor, result|
              result["#{GROW}#{corporation.id}_#{minor.id}"] = "Exchange #{minor.name}"
            end
          end

          def process_choose(action)
            entity = action.entity
            _prefix, corp_id, minor_id = action.choice.split('_')
            corp = @game.corporation_by_id(corp_id)
            minor = @game.minor_by_id(minor_id)
            unless corp && minor && @game.growth_convertible_corporations.include?(corp) &&
                   @game.growth_convertible_minors(entity).include?(minor)
              raise GameError, "Invalid growth conversion choice: #{action.choice}"
            end

            @game.form_growth_corporation!(entity, minor, corp)

            # Base-class buy/par actions self-record via track_action (see
            # process_par/process_buy_shares) -- process_choose has no such
            # call by default, so without this the exchange would never
            # actually land in @round.current_actions for `bought?` (above)
            # to find.
            track_action(action, corp)
          end
        end
      end
    end
  end
end
