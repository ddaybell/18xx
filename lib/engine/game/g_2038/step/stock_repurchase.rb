# frozen_string_literal: true

require_relative '../../../step/issue_shares'

module Engine
  module Game
    module G2038
      module Step
        # §13c rule 3: "A corporation (even a Public one) may, before
        # and/or after step 2 of the operating sequence and using only
        # its own funds, buy one or more of its shares from the Stock
        # Market at the current stock price, placing them in the Growth
        # Corporation box" -- this codebase's own established "Treasury
        # Shares" concept (Corporation#treasury_shares), already what
        # the standard corporation-card UI shows a count of whenever a
        # corp holds its own stock. Reuses the engine's own generic
        # redeem/issue mechanism (Engine::Step::IssueShares -- see
        # 1817/1822/1846's own use of the same base class) rather than
        # building a new action type from scratch; Game#issuable_shares
        # always returns [] since this rule is buyback-only, never a
        # share issue. Inserted twice into the OR step stack (see
        # operating_round), once before Step::Route and once after,
        # matching the rule's "before and/or after" window -- both
        # instances are ordinary, independent steps, each auto-skipped
        # (not blocking) the moment nothing's affordable/available (see
        # Game#redeemable_shares).
        class StockRepurchase < Engine::Step::IssueShares
          # "Redeem" (not "buy back") to match this codebase's own
          # established term for a corporation reacquiring its own shares
          # -- already what the base engine's own SharePool#buy_shares log
          # line uses (`verb = entity == corporation ? 'redeems' : 'buys'`)
          # and what IssueShares' own generic description/pass_description
          # say ('Issue or Redeem Shares' / 'Skip (Issue/Redeem)').
          def description
            'Redeem Shares'
          end

          def pass_description
            'Skip (Redeem Shares)'
          end

          # skip! is only ever called (via Round::Base#skip_steps) when
          # this step ISN'T blocking, i.e. there was never anything to
          # redeem in the first place -- either because the entity is an
          # independent/minor (no stock at all), or because it's a
          # corporation with no affordable/available shares to redeem
          # (Game#redeemable_shares). Neither case is a real decision
          # anyone made; logging "X skips Redeem Shares" for either is
          # just noise every single OR turn. A real skip -- a corporation
          # that COULD redeem shares but chooses not to -- goes through
          # process_pass instead, which still logs normally.
          def skip!
            pass!
          end
        end
      end
    end
  end
end
