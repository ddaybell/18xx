# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G2038
      module Step
        # Spaceship routes are traced one hex at a time via the `choose` action:
        # each hex click (or choice button) fires Action::Choose with the hex id.
        # The trace lives in step state and is rebuilt identically on undo/replay.
        # Entering an unexplored blue hex reveals its pre-assigned tile
        # immediately, so the player sees what they found before flying on.
        # Loads are picked up by explicit choice while on a mine hex — once
        # aboard they cannot be jettisoned (§7.1), so choosing carefully matters.
        class Route < Engine::Step::Base
          ACTIONS = %w[choose pass].freeze

          FINISH = 'finish'
          CANCEL = 'cancel'
          CANCEL_COMPLETED = 'cancel_completed_'
          PICKUP = 'pickup_'
          TRANSSHIP = 'transship'
          SHIP = 'ship_'
          FLYOVER = 'flyover_'
          SHORTCUT_EXPLORE = 'shortcut_explore_'
          REDRAW = 'redraw_'
          PILOT = 'pilot_'
          SUGGEST = 'suggest_route'
          ACCEPT_SUGGESTION = 'accept_suggested_route'
          PREVIOUS_ROUTE = 'previous_route'
          # The one real action a hand-flown route ever submits now,
          # mirroring ACCEPT_SUGGESTION's self-contained-choice-string
          # pattern -- see local_choose!/submit_flight_choice/
          # replay_submitted_flight!. Unlike Accept Route's hexes+cargo
          # encoding, a hand-flown flight can hit every choice type this
          # step supports (explore vs flyover, shortcuts, pickups,
          # transship, Lucky's redraw), so rather than re-deriving a
          # second parallel replay format, this just carries the literal
          # sequence of `choice` values the player clicked, replayed
          # through the exact same dispatch_choice! table that built it.
          SUBMIT_FLIGHT = 'submit_flight'
          FLIGHT_SEP = '~'
          # A dedicated choice key for undo_last_hex! (see its comment) --
          # never a real hex id, so it can be dispatched unambiguously
          # whether it arrives via a hex-choice popup's own button or as
          # the sole aliased action on a directly-clicked hex.
          UNDO_HEX = 'undo_hex'

          ORE_NAMES = { n: 'Nickel', i: 'Ice', r: 'Rare' }.freeze

          def description
            'Fly Spaceships'
          end

          def help
            base = 'Click a base to launch, then click adjacent hexes to fly. '\
                   'Entering a hex costs 1 MP; exploring an unexplored hex costs '\
                   '1 MP extra. Pick up loads while on a mine hex — they cannot '\
                   'be jettisoned later. End the route at a base or transshipment '\
                   'point to collect payment.'
            # View::Game::Help renders each array element as its own line; a
            # trailing blank line adds breathing room before the ship list
            # renders below it. A plain '' would collapse to zero height, so
            # use a non-breaking space to force real line height.
            blank_line = " "
            return [base, blank_line] if @cargo.empty?

            loads = @cargo.map { |c| "#{c[:ore] ? ORE_NAMES[c[:ore]] : 'Transshipment credit'} (#{@game.format_currency(c[:value])})" }
                          .join(', ')
            ["#{base} Cargo aboard: #{loads}.", blank_line]
          end

          def setup
            @trace = []
            @cargo = []
            @ran_trains = []
            @explored_in_trace = false
            @mp_spent = 0
            @selected_train_id = nil
            # This OR's Growth Corp pilot assignments (Phase 8): pilot
            # source string ('LY'/'TH'/etc) => the Train it's assigned to.
            # Each inherited pilot gets its OWN ship -- never shared, never
            # doubled up on one ship -- explicitly chosen (or auto-assigned
            # when there's only one real pairing left), and always reset
            # here each OR since a fresh step instance is built every
            # round, mirroring 1822's Pullman-to-train assignment.
            @pilot_assignments = {}
            @choices_memo = nil
            @round.laid_hexes = []
            # Set while Ice Finder/Drill Hound/Lucky's second-draw power is
            # being resolved -- a hash of {hex_id:, first_name:,
            # borrowed_hex_id:, second_name:} -- see move_to/resolve_redraw!.
            @pending_redraw = nil
            # Per-train {explored:, mines:} snapshot, taken at `finish_route`
            # -- `route_summary` runs later (once this ship is done and a
            # different one may already be flying), by which point @cargo/
            # @hexes_explored_this_trip have moved on to the next trip, and
            # every hex in a finished route already looks explored regardless
            # of who explored it. Neither figure can be recomputed post-hoc
            # from the stored Engine::Route alone.
            @route_stats_by_train = {}
            # A computed-but-not-yet-accepted "Suggest Route" result:
            # {train:, hexes:, cargo:, revenue:, timed_out:}, or nil. Shown
            # as a live preview (map trace + ship-row summary) same as an
            # in-progress hand-flown route, but produces no log entries
            # and touches no real game state until "Accept Route" actually
            # replays it -- confirmed with the user: a suggestion the
            # player never accepts shouldn't pollute the log.
            @pending_suggestion = nil
            # The literal sequence of `choice` values clicked locally for
            # the ship currently being built (or just finished, awaiting
            # Submit) -- see local_choose!/SUBMIT_FLIGHT. Reset here each
            # round, and again by rollback_local_flight! once that flight
            # is submitted or discarded.
            @local_flight_log = []
            # Monotonic count of hexes appended to @trace (launch_at/
            # move_to), used by local_choose! instead of @trace.size to
            # detect "did this dispatch enter a new hex" -- @trace.size
            # alone misses a hex whose own arrival immediately auto-
            # finished the route (maybe_auto_finish! resets @trace to []
            # within the very same dispatch that just grew it), which
            # otherwise left that hex's mark never recorded and
            # undo_last_hex! silently rolling back one hex further than
            # intended. Found live in browser: reaching a base with 0 MP
            # left undid both that hex and the one before it in a single
            # click.
            @hexes_entered = 0
            # Non-nil while a local, unsubmitted flight has mutated real
            # game state (mine reveals, hex tiles, pickups, log lines) --
            # everything needed to precisely undo it, captured the moment
            # local building starts (see local_choose!/rollback_local_flight!).
            # nil whenever there's nothing pending: no local flight has
            # started, or the last one was submitted/discarded.
            @rollback = nil
            # True only while replaying an already-submitted flight for
            # real (live, right after the player clicks Submit, or later
            # on reload/for another client) -- gates the one-time-only
            # side effects a flight can't safely run twice: the
            # exploration bonus payment (Game#explore_hex!'s `pay:`) and
            # finish_route's auto-pass. False during ordinary local
            # building, so neither fires on a preview that might still be
            # discarded.
            @committing = false
            resolve_unambiguous_pilots!
          end

          def round_state
            super.merge({ routes: [], extra_revenue: 0, laid_hexes: [] })
          end

          # Always both choose (Submit/pilot/cancel-completed) and pass
          # (Submit All Routes, or Cancel/Discard while a flight's in
          # progress or pending) for as long as it's this entity's turn --
          # never [] just because every ship has flown. The corp's turn
          # only actually ends once the player explicitly clicks Submit
          # All Routes (see pass_description/finish_route's now-
          # removed auto-pass) -- confirmed with the user: building
          # routes entirely client-side means nothing should silently
          # jump to Dividend on its own, since there's no longer a
          # per-hex real action for the player to have "seen" happen.
          def actions(entity)
            return [] unless entity == current_entity
            return [] unless entity.operator?
            # A company that owns no ships at all -- not just none left
            # unrun this turn, see route_trains vs available_trains --
            # has nothing to confirm here; skip straight past this step
            # (and, since it'll earn exactly $0, Dividend's own actions
            # already auto-skips on total_revenue.zero? too) rather than
            # making the player click Submit All Routes for a turn
            # that could never have had anything in it.
            return [] if @game.route_trains(entity).empty?

            ACTIONS
          end

          # nil -- suppresses the generic Choose panel's "X:" header
          # entirely (see assets/app/view/game/choose.rb, which already
          # treats a falsy choice_name as "no header"). Used to read "Fly
          # 3/2:", but that's redundant now: which ship is flying is
          # already shown by the bordered/highlighted row in
          # ShipSelector (or trivially implied for a single-ship entity),
          # and every button choose.rb might show below this (pilot
          # assignment, cancelling an already-submitted route) already
          # names the ship in its own label.
          def choice_name
            nil
          end

          # Memoized: `available_hex` calls this once per hex on the map (a
          # full render pass), but the result only changes when this step's
          # state is mutated -- invalidated in `setup`/`process_choose`/
          # `process_pass`, the only places that happens.
          def choices
            @choices_memo ||= compute_choices
          end

          # Mid-flight, every hex is either an immediate neighbor (reachable
          # for 1 MP) or not reachable at all this turn -- a fixed,
          # trivially-predictable pattern that greying out the rest of the
          # map doesn't help convey, unlike e.g. BuyInfrastructure's range
          # highlighting (which varies hex to hex). Only dim the map before
          # launch, when it's actually useful to see which of this
          # entity's (possibly several, scattered) bases are valid to fly
          # from.
          def available_hex(entity, hex)
            return false unless entity == current_entity
            return true unless @trace.empty?

            choices.key?(hex.id)
          end

          # Opt-in hook the generic Choose view prefers over `choices` for
          # its bottom-panel button list (see assets/app/view/game/choose.rb).
          # Hex-based choices (launch/move/explore/flyover/pickup/Lucky's
          # tile redraw) are fully redundant with clicking the relevant hex
          # directly on the map (`available_hex` above, and
          # `hex_choice_popup` below for the explore/flyover/multi-pickup/
          # tile-redraw disambiguation). FINISH is deliberately left out
          # too, even though it has no map-click equivalent of its own --
          # ShipSelector's Submit button now covers it (see submit_ready?/
          # finish_and_submit_choice), so a route that could end here with
          # MP still left shows the same one "Submit ($X)" button a route
          # that already auto-finished from running out of MP does,
          # instead of a separate "Finish"/"End route" button the player
          # would click before *also* needing to click Submit -- found
          # live in browser: those two clicks were fully redundant of each
          # other. CANCEL is left out on purpose too: the generic Pass
          # button already offers it (see `pass_description` below, which
          # returns 'Cancel' whenever @trace isn't empty) -- including it
          # here too just draws the same "cancel this route" action as two
          # buttons at once. `choices` itself is unchanged: it's still the
          # source of truth for hex-click validation and `process_choose`.
          def entity_choices(_entity)
            entity = current_entity
            return {} unless entity
            # A just-finished, not-yet-submitted flight blocks everything
            # else here too (see compute_choices) -- Submit/Discard (Pass)
            # are the only live moves until it resolves one way or the
            # other. cancel_completed_choices is unaffected: those are
            # earlier, already-*submitted* routes from this same turn.
            return cancel_completed_choices if @rollback&.dig(:finished)

            pilot_choices(entity).merge(cancel_completed_choices)
          end

          # A completed route may be undone -- but only the most recent ones
          # in an unbroken run of never-explored routes (walking backward
          # from the last ship flown this turn). Exploration reveals hidden
          # information that can't be taken back, and the $10 exploration
          # bonus is already paid at explore time (not deferred to
          # Dividend) -- so the moment we hit an explored route, it and
          # everything before it are locked in for good. Anything strictly
          # after that explored route is still fair game, since undoing it
          # doesn't touch the already-revealed state at all. Plain revenue
          # (unlike the exploration bonus) is never paid until the
          # Dividend step, which can't run until this step stops blocking,
          # so removing a route here is always safe pre-payout.
          def cancellable_trains
            return [] unless @trace.empty?

            blocked = false
            result = []
            @ran_trains.reverse_each do |train|
              # The currently pending (local, not-yet-submitted) flight
              # has its own undo path -- Discard, via local_pass! -- and
              # isn't real yet, so it neither belongs in this list nor
              # should its own explored-ness block earlier, genuinely
              # already-submitted routes from being reachable here.
              next if @rollback&.dig(:finished_train) == train

              if @route_stats_by_train[train][:explored].positive?
                blocked = true
                next
              end
              result << train unless blocked
            end
            result
          end

          def cancel_completed_choices
            cancellable_trains.to_h { |t| ["#{CANCEL_COMPLETED}#{t.id}", "Cancel completed route for #{ship_label(t)}"] }
          end

          # Growth Corp pilot assignment (Phase 8), mirroring 1822's
          # Pullman-to-train attachment: only offered pre-launch, only when
          # this corp has an unresolved pilot-ship pairing. Each inherited
          # pilot gets its own ship -- never shared, never doubled up --
          # and a choice is only ever shown when there's real ambiguity:
          # one pilot contending for 2+ un-run ships, or (the mirror image,
          # e.g. the AL running 2+ pilots) 2+ pilots contending for the one
          # ship left. With exactly one pilot and one ship, there's nothing
          # to pick -- `pilot_source_for_train`/`resolve_unambiguous_pilots!`
          # auto-assign it instead, announced via a log message rather than
          # a click. Only one axis of ambiguity is ever surfaced per call
          # (the first still-unassigned pilot, or all pilots against the
          # sole remaining ship); once resolved, the next render offers
          # whatever's still unresolved, if anything.
          def pilot_choices(entity)
            return {} unless @trace.empty?

            sources = @game.growth_corp_pilots(entity) - @pilot_assignments.keys
            return {} if sources.empty?

            trains = available_trains(entity) - @pilot_assignments.values
            return {} if trains.empty?

            if trains.one? && sources.size > 1
              train = trains.first
              return sources.to_h do |s|
                ["#{PILOT}#{s}_#{train.id}", "Assign #{@game.class::PILOT_NAMES[s]}'s pilot to #{ship_label(train)}"]
              end
            end
            return {} if trains.size <= 1

            source = sources.first
            trains.to_h do |t|
              ["#{PILOT}#{source}_#{t.id}", "Assign #{@game.class::PILOT_NAMES[source]}'s pilot to #{ship_label(t)}"]
            end
          end

          # Public: called from Game#pilot_source_for_train for the actual
          # bonus checks (independent_ore_bonus/ship_distance/
          # needs_second_draw?) -- returns which pilot source (if any) is
          # assigned to this specific train. Auto-assigns (and announces,
          # once, via assign_pilot!) the sole remaining (source, train)
          # pairing once there's no real choice left, same idiom
          # current_train already uses for ship selection itself.
          def pilot_source_for_train(entity, train)
            sources = @game.growth_corp_pilots(entity)
            return nil if sources.empty?

            assigned_source = @pilot_assignments.key(train)
            return assigned_source if assigned_source

            unassigned_sources = sources - @pilot_assignments.keys
            return nil unless unassigned_sources.one?

            assignable_trains = available_trains(entity) - @pilot_assignments.values
            return nil unless assignable_trains.one? && assignable_trains.first == train

            source = unassigned_sources.first
            assign_pilot!(entity, source, train)
            source
          end

          # Records a pilot-ship pairing and announces it in the log --
          # shared by the auto-assign paths above (unambiguous from the
          # start of the turn, or becoming unambiguous mid-turn as ships
          # finish flying) and the explicit PILOT choice in process_choose,
          # so every pairing is announced exactly once regardless of how
          # it was resolved.
          def assign_pilot!(entity, source, train)
            @pilot_assignments[source] = train
            @rollback[:pilots_assigned] << source if @rollback
            @log << "#{entity.name}: Pilot #{@game.class::PILOT_NAMES[source]} (#{source}) assigned to #{ship_label(train)}"
          end

          # Called from `setup`, before a single ship has flown this turn:
          # announces the one truly unambiguous case (exactly one pilot,
          # exactly one ship) right at the start of the Route phase rather
          # than waiting for the first bonus check to trigger it lazily.
          # Anything with real ambiguity is deliberately left alone here --
          # pilot_choices offers it, and pilot_source_for_train picks up
          # the announcement once (if ever) it resolves on its own as ships
          # finish flying this turn.
          def resolve_unambiguous_pilots!
            entity = current_entity
            return unless entity

            sources = @game.growth_corp_pilots(entity)
            return unless sources.one?

            trains = available_trains(entity)
            return unless trains.one?

            assign_pilot!(entity, sources.first, trains.first)
          end

          # Optional hook for the map view: when a hex needing a click-time
          # decision is clicked directly, offer a popup with the relevant
          # choices instead of dispatching a default immediately. Three
          # cases: Lucky's tile-image choice (takes priority since it's
          # also anchored to @trace.last), else a pickup decision on the
          # hex the ship is already sitting on (ambiguous only when a
          # double-mine hex has 2 unclaimed-by-others ores still
          # available), else an explore/flyover decision -- for a direct
          # neighbor (1 hop) or a shortcut destination (2+ hops) alike;
          # only the choice keys differ (see shortcut_choices/compute_choices).
          # Pass-through hexes along a shortcut never get this popup at
          # all -- exploring them isn't offered as a choice in the first
          # place (see shortcut_paths/fly_shortcut_to!), only the final
          # hex of the flight can be explored, same as a hand-flown route
          # ending there.
          def hex_choice_popup(entity, hex)
            return nil unless entity == current_entity

            if @trace.empty?
              # Nothing left flying -- the only thing a hex click can mean
              # here is undoing an already-finished, not-yet-submitted
              # route's last hex, and only a popup (forcing an explicit
              # confirm) when that would un-reveal a tile. Otherwise the
              # direct click already dispatches it (see compute_choices'
              # matching branch); no popup needed.
              return nil unless @rollback&.dig(:finished) && hex == undo_click_hex
              return { UNDO_HEX => undo_hex_label } if undoing_last_hex_reveals_tile?

              return nil
            end

            return redraw_tile_popup if @pending_redraw && hex == @trace.last
            return pickup_popup if hex == @trace.last

            neighbor = @trace.last.neighbors.value?(hex)
            explore_key = neighbor ? hex.id : "#{SHORTCUT_EXPLORE}#{hex.id}"
            flyover_key = neighbor ? "#{FLYOVER}#{hex.id}" : hex.id
            popup = {}
            popup[explore_key] = 'Explore (2 MP)' if choices.key?(explore_key)
            popup[flyover_key] = 'Skip (1 MP)' if choices.key?(flyover_key)
            popup.size > 1 ? popup : nil
          end

          # Mid-flight version of the same "force a popup if undo would
          # un-reveal a tile, otherwise let a single option dispatch
          # directly" rule hex_choice_popup's finished-route branch above
          # uses -- current_hex_action_choices already folds Undo in
          # alongside pickup/transship, so this only needs to decide
          # *when* that combined set needs a popup instead of a direct
          # click.
          def pickup_popup
            matches = current_hex_action_choices
            return matches if matches.size > 1
            return matches if matches.key?(UNDO_HEX) && undoing_last_hex_reveals_tile?

            nil
          end

          # The current hex's own action set: pickup/transship (if any
          # ore/credit is still there to collect) plus Undo (if there's a
          # previous hex to back up to) -- one combined pool so
          # alias_current_hex_pickup!/pickup_popup/dispatch_choice! all
          # agree on what a click (or a popup button) on the ship's own
          # hex can mean.
          def current_hex_action_choices
            matches = choices.select { |key, _label| key.start_with?(PICKUP) || key == TRANSSHIP }
            return matches unless undo_last_hex_available?(current_entity)

            matches.merge(UNDO_HEX => undo_hex_label)
          end

          # Opt-in hook for assets/app/view/game/hex_choice_popup.rb: chain
          # straight into a follow-up popup ONLY for Lucky choosing to
          # Explore -- that's the one case where a second popup (the
          # tile-redraw choice) is guaranteed to open right after, with
          # nothing left for the player to decide in between. Every other
          # transition (a plain explore/flyover with no redraw power, IF/DH
          # whose redraw is automatic and silent, or picking a tile/ore)
          # requires a fresh hex click for its own popup -- in particular,
          # explore must NOT chain into a pickup popup, since choosing to
          # explore is not the same decision as choosing to pick up ore.
          # Checks the pilot actually assigned to the ship in flight (not
          # just entity.id == 'LY'), so a Growth Corp flying a ship with
          # LY's inherited pilot gets the same immediate chain a bare LY
          # minor does -- entity.id alone would only ever match LY itself.
          def chain_hex_choice_popup?(entity, hex, choice)
            return false unless choice == hex.id && needs_exploration?(hex)

            train = current_train(entity)
            pilot_source = entity.minor? ? entity.id : pilot_source_for_train(entity, train)
            pilot_source == 'LY'
          end

          # Lucky's tile choice, shown as real tile art (see
          # assets/app/view/game/hex_choice_popup.rb, which renders an
          # Engine::Tile value as a clickable preview instead of a text
          # button) rather than the plain-text redraw_choices used as this
          # hex's bare-id alias (see compute_choices) -- that alias only
          # exists so hex.rb's dispatch gate finds a key to look for a
          # popup at all; it's never dispatched directly since this popup
          # always has 2 entries.
          def redraw_tile_popup
            r = @pending_redraw
            {
              "#{REDRAW}first" => @game.preview_tile(r[:first_name]),
              "#{REDRAW}second" => @game.preview_tile(r[:second_name]),
            }
          end

          # Opt-in hook Part::CitySlot prefers over the hex-level dispatch
          # (see assets/app/view/game/part/city_slot.rb): clicking directly
          # on a specific mine's circle picks up that ore in one click,
          # rather than needing the popup above to disambiguate a
          # double-mine hex's two pickups.
          def city_choice(entity, city)
            return nil unless entity == current_entity && !@trace.empty? && city.hex == @trace.last

            key = "#{PICKUP}#{city.tile.cities.index(city)}"
            choices[key] ? key : nil
          end

          # Opt-in hook Part::CitySlot checks when city_choice above comes
          # back nil, so a click on a mine claimed by someone else gives an
          # explanatory flash instead of silently doing nothing.
          def mine_pickup_blocked_reason(entity, city)
            return nil unless entity == current_entity && !@trace.empty? && city.hex == @trace.last

            mine = @game.mine_state.dig(city.hex.id, :mines, city.tile.cities.index(city))
            return nil unless mine&.dig(:owner) && mine[:owner] != entity.id

            'Cannot pick up: mine claimed by another company.'
          end

          # The warning icon rides directly in the button's plain text --
          # no shared frontend file needs to know this exists. Shown only
          # when cancelling would actually roll back a real reveal --
          # checked via @rollback[:laid_hexes], not @explored_in_trace,
          # since that flag resets at finish_route, but a just-finished,
          # not-yet-submitted flight that explored something is still
          # exactly as cancellable, and just as much a real reveal to
          # warn about.
          # "Submit All Routes" whenever nothing's locally pending --
          # replaces the old "Skip Remaining Ships"/"Done Flying" wording
          # (and their auto-pass-on-last-ship behavior, now removed from
          # finish_route): with every route built client-side, ending the
          # corp's turn is now always an explicit confirmation, regardless
          # of whether every ship has flown or the player is choosing to
          # leave some unflown.
          def pass_description
            return 'Submit All Routes' if @trace.empty? && @rollback&.dig(:finished) != true

            return 'Cancel (⚠️ un-reveals tile)' if @rollback && @rollback[:laid_hexes].any?

            'Cancel'
          end

          # Opt-in hook for assets/app/view/game/actionable.rb: every
          # ordinary Choose click while a route is being hand-flown runs
          # locally (no process_action, no network, no permanent action
          # history entry) until the whole flight is done and the player
          # explicitly hits Submit -- see SUBMIT_FLIGHT/local_choose!/
          # replay_submitted_flight!. Everything that must still go
          # through the real pipeline, submitted immediately in its own
          # one and only click, is excluded: the self-contained
          # SUBMIT_FLIGHT string itself; CANCEL_COMPLETED (undoing an
          # *already-submitted* route from earlier this same turn, which
          # is real state other clients need to see change); and the
          # ACCEPT_SUGGESTION: string (plus its legacy exact-match
          # formats) -- these are never generated going forward (Accept
          # now replays through apply_pending_suggestion! and submits the
          # normal SUBMIT_FLIGHT way, same as Modify), but old recorded
          # games still carry them, and replaying one must dispatch it for
          # real through accept_route!, never treat it as a local preview.
          def local_choose?(entity, choice)
            choice = choice.to_s
            entity == current_entity &&
              !choice.start_with?("#{SUBMIT_FLIGHT}:") &&
              !choice.start_with?(CANCEL_COMPLETED) &&
              !choice.start_with?("#{ACCEPT_SUGGESTION}:") &&
              choice != ACCEPT_SUGGESTION &&
              choice != SUGGEST &&
              choice != PREVIOUS_ROUTE
          end

          # Runs one hop of a hand-flown route entirely locally: records
          # the literal choice for later replay (see submit_flight_choice)
          # and dispatches it through the same table a real action would
          # use, so the live preview and the eventual real replay can
          # never diverge in what they do for a given choice. Lazily
          # snapshots rollback state on the very first local choice since
          # the last submit/discard (covers a pre-launch PILOT choice,
          # not just the launch hex itself).
          def local_choose!(entity, choice)
            @rollback ||= capture_rollback!
            hexes_entered_before = @hexes_entered
            log_index = @local_flight_log.size
            @local_flight_log << choice
            dispatch_choice!(entity, choice)
            # A hex-mark records the log index of whichever choice caused
            # a new hex to be entered -- launch, an ordinary move, a
            # flyover, or a shortcut hop -- so undo_last_hex! can later
            # truncate the log to "everything before the most recent
            # hex" without having to reparse choice strings to tell moves
            # apart from pickups/pilot/redraw choices that don't enter a
            # hex at all. Compares @hexes_entered (a monotonic counter),
            # not @trace.size -- a hex whose own arrival immediately
            # auto-finishes the route (maybe_auto_finish! resets @trace
            # to [] within this same dispatch) would otherwise look like
            # no growth happened at all, and its mark would never get
            # recorded.
            @rollback[:hex_marks] << log_index if @hexes_entered > hexes_entered_before
          end

          # Opt-in hook mirroring local_choose? for Action::Pass: true
          # whenever there's local, unsubmitted flight state to throw
          # away (mid-flight, or finished but not yet submitted). False
          # once nothing's pending, so an ordinary end-of-turn Pass still
          # goes through as a real, recorded action exactly as before.
          # Not just !@rollback.nil? -- @rollback gets created lazily on
          # *any* local click (see local_choose!), including a bare ship-
          # tab selection or pilot assignment that hasn't launched
          # anything yet. Neither has a real effect worth offering to
          # cancel, so this only counts a flight actually in progress
          # (@trace non-empty) or one that's finished but not yet
          # submitted (@rollback[:finished]) -- found live in browser: a
          # freshly-selected, never-launched ship's row showed a Cancel
          # button with nothing behind it to cancel.
          def local_pass?(entity)
            entity == current_entity && (!@trace.empty? || @rollback&.dig(:finished) == true)
          end

          def local_pass!(_entity)
            rollback_local_flight!
          end

          # Opt-in hook for assets/app/view/game/pass.rb: suppresses the
          # standalone Pass button exactly when ShipSelector's own per-row
          # Cancel is already showing for the same thing (see
          # local_pass?/cancel_flight_button) -- the two would otherwise
          # both read "Cancel" for the identical action. Once nothing's
          # pending this returns false, since the standalone button is
          # then the only way to reach the real "Skip Remaining
          # Ships"/"Done Flying" end-of-turn pass, which has no per-row
          # equivalent.
          def suppress_standalone_pass?(entity)
            local_pass?(entity)
          end

          # Public: the self-contained choice this ship's just-finished,
          # not-yet-submitted flight would submit -- nil until finish_route
          # has actually run locally (see FLIGHT_SEP/replay_submitted_flight!).
          def submit_flight_choice(entity)
            return nil unless entity == current_entity
            return nil unless @rollback&.dig(:finished)
            return nil if @local_flight_log.empty?

            "#{SUBMIT_FLIGHT}:#{@local_flight_log.join(FLIGHT_SEP)}"
          end

          # Public: whether ShipSelector's Submit button should be showing
          # right now -- either the flight has already finished (running
          # out of MP auto-finishes it; so does a previous click of this
          # same button), or it's simply sitting on a hex where finishing
          # is currently a legal move (mirrors compute_choices' old FINISH
          # gate: @trace.size > 1, same as "End route" used to check).
          # Read-only -- safe to call on every render, unlike
          # finish_and_submit_choice below.
          def submit_ready?(entity)
            return false unless entity == current_entity
            return false if @rollback.nil?

            @rollback[:finished] || @trace.size > 1
          end

          # Public: whether undo_last_hex! has anything to undo -- at
          # least two hexes recorded (the launch plus one more), whether
          # the flight is still in progress or already finished but not
          # yet submitted. With only the launch hex on record there's
          # nothing meaningful to back up to short of discarding the
          # whole flight, which Cancel already covers.
          def undo_last_hex_available?(entity)
            entity == current_entity && (@rollback&.dig(:hex_marks)&.size || 0) > 1
          end

          # Public: undoes the most recently entered hex -- whether the
          # route is still in progress or already finished but not yet
          # submitted -- leaving the ship back at the hex before it, free
          # to fly a different direction from there. Implemented as a
          # full rollback (the exact same one Cancel/local_pass! uses)
          # followed by replaying every local choice up to (not
          # including) the discarded hex's own move -- see
          # local_choose!'s hex_marks comment. Deliberately not a second,
          # narrower undo path: reusing rollback_local_flight! wholesale
          # means this can never drift out of sync with what a full
          # Cancel already knows how to reverse (explored tiles, the
          # deferred exploration bonus, pickups, PRNG state).
          def undo_last_hex!(entity)
            return unless @rollback

            marks = @rollback[:hex_marks]
            return if marks.size <= 1

            replay_log = @local_flight_log[0...marks.last]

            rollback_local_flight!
            replay_log.each { |c| local_choose!(entity, c) }
          end

          # Public: which hex a click means "undo the last hex" for --
          # the ship's current position while still flying, or (since
          # finish_route empties @trace) the endpoint of the route it
          # just flew, once finished but not yet submitted. nil once
          # nothing's pending at all. Shared by available_hex/
          # hex_choice_popup/compute_choices/dispatch_choice! so all four
          # always agree on the exact same hex.
          def undo_click_hex
            return @trace.last unless @trace.empty?
            return nil unless @rollback&.dig(:finished)

            train = @rollback[:finished_train]
            @round.routes.find { |r| r.train == train }&.hexes&.last
          end

          # Public: whether undoing the last hex would take back an
          # exploration -- the deciding factor for whether a click needs
          # a confirmation popup first (see hex_choice_popup/pickup_popup)
          # rather than acting immediately.
          def undoing_last_hex_reveals_tile?
            return false unless @rollback

            last_explored = @rollback[:laid_hexes].last
            hex = undo_click_hex
            !!(last_explored && hex && last_explored[:hex_id] == hex.id)
          end

          def undo_hex_label
            undoing_last_hex_reveals_tile? ? 'Undo (⚠️ un-reveals tile)' : 'Undo'
          end

          # Public: the Submit button's label -- the route's real,
          # already-computed revenue if it's already finished, or a live
          # preview of what finishing right now would earn otherwise (the
          # same figure the old, now-removed "Finish"/"End route" choice
          # button used to show). Ending a route with MP still available
          # now looks identical to running out of MP: same button, same
          # label, same code, regardless of which way the flight actually
          # ends. Read-only.
          def submit_button_label(entity)
            revenue =
              if @rollback&.dig(:finished)
                train = @rollback[:finished_train]
                @round.routes.find { |r| r.train == train }&.revenue
              elsif @trace.size > 1 && (train = current_train(entity))
                @game.trace_revenue(entity, train, @trace, @cargo)
              end
            revenue ? "Submit (#{@game.format_currency(revenue)})" : 'Submit'
          end

          # Public: the Submit button's actual click handler. Finishes the
          # flight locally first if it hasn't already (the same effect the
          # old "Finish"/"End route" choice button used to have on its
          # own) and only then returns the self-contained choice to submit
          # for real -- so ending a route with MP still left takes the
          # exact same one click as a route that already auto-finished
          # from running out of MP, instead of a separate Finish click
          # before Submit even appears. Mutating -- only call from a click
          # handler, never from render (see submit_ready?/
          # submit_button_label for the read-only render-time checks).
          def finish_and_submit_choice(entity)
            local_choose!(entity, FINISH) if @trace.size > 1 && !@rollback&.dig(:finished)
            submit_flight_choice(entity)
          end

          # Optional hook for the map view: the in-progress trace, so it can
          # be drawn as a live route line while the ship is still flying
          # (before `finish` turns it into a real Engine::Route).
          def live_route_hexes(entity)
            return [] unless entity == current_entity
            return @pending_suggestion[:hexes] if suggestion_pending?(entity) && @trace.empty?

            @trace
          end

          # Optional hook for the map view: this entity's already-finished
          # routes for this OR turn, so each stays visible in its own color
          # even after control moves on to Dividend/BuyTrain/etc (this step
          # stops blocking once every ship has flown, but @ran_trains isn't
          # cleared until `setup` runs again for the next entity's turn).
          def current_turn_routes(entity)
            return [] unless entity == current_entity

            @round.routes.select { |r| @ran_trains.include?(r.train) }
          end

          # Public interface for the dedicated ship-selector tab UI (mirrors
          # the standard train-selector look from other games). Empty when
          # there's nothing to pick (0 or 1 available, unrun ship) -- the
          # single-ship case skips straight to base selection with no click
          # needed, same as before this existed -- or once a flight is under
          # way (@trace non-empty), since switching ships mid-flight would
          # abandon the current ship's in-progress trace/cargo/MP spend.
          # Switching back is only possible via Cancel/End Route.
          def ship_choices(entity)
            return {} unless @trace.empty?

            trains = available_trains(entity)
            return {} if trains.size <= 1

            trains.to_h { |t| ["#{SHIP}#{t.id}", ship_label(t)] }
          end

          # The currently-resolved ship's choice key, for highlighting the
          # selected tab (nil if nothing's resolved yet -- 2+ ships, none
          # picked).
          def current_ship_choice(entity)
            train = current_train(entity)
            train && "#{SHIP}#{train.id}"
          end

          # Public: one row per owned train, for the ship-selector UI --
          # covers both still-pickable ships and ones that already finished
          # this OR (with their mines-visited/revenue summary), so a
          # multi-ship entity doesn't lose sight of what each ship did once
          # it moves on to the next. Empty when there was never a real ship
          # choice to make (this entity has 1 or 0 trains total).
          #
          # `blocked` distinguishes "not clickable because mid-flight" (the
          # view should still respond to a click, with an explanatory flash
          # message) from "not clickable because this ship already finished
          # this OR" (a genuine dead end -- no message needed).
          def ship_rows(entity)
            trains = @game.route_trains(entity)
            return [] if trains.empty?

            selected = current_ship_choice(entity)
            # Blocks switching ships both while actively flying and while
            # a just-finished flight is still awaiting Submit/Discard --
            # see compute_choices' matching guard.
            mid_flight = !@trace.empty? || @rollback&.dig(:finished)
            pending_train = @rollback&.dig(:finished_train)
            trains.map do |train|
              if @ran_trains.include?(train)
                route = @round.routes.find { |r| r.train == train }
                # Not unconditionally false -- a locally-finished,
                # not-yet-submitted flight (train == pending_train) is
                # still the one the player's action bar belongs to, same
                # as an unrun ship mid-flight below; only a genuinely
                # already-*submitted* route (any other @ran_trains entry)
                # is a settled, non-selected fact.
                { choice: nil, blocked: false, label: ship_label(train), selected: train == pending_train,
                  summary: route && route_summary(route), color_index: route_color_index(entity, train) }
              else
                ship_choice = "#{SHIP}#{train.id}"
                is_selected = ship_choice == selected
                live_summary = if mid_flight && is_selected
                                 cargo_summary(train)
                               elsif @pending_suggestion && @pending_suggestion[:train] == train
                                 suggestion_summary(@pending_suggestion)
                               end
                { choice: mid_flight ? nil : ship_choice, blocked: mid_flight && !is_selected,
                  label: ship_label(train), selected: is_selected, summary: live_summary,
                  color_index: route_color_index(entity, train) }
              end
            end
          end

          # Public: the same per-route color index View::Game::Map's
          # render_route_lines would assign this train's route on the map
          # (0-based, current_turn_routes order, with the live in-progress
          # or pending-suggestion route -- if any -- appended last, exactly
          # matching that method's own draw order) -- lets ShipSelector
          # highlight each row in the same color its route line is drawn
          # in. nil for a ship with no route currently drawn at all (not
          # yet run, not selected, no pending suggestion).
          def route_color_index(entity, train)
            routes = current_turn_routes(entity)
            submitted_index = routes.index { |r| r.train == train }
            return submitted_index if submitted_index

            live = live_route_hexes(entity)
            return routes.size if !live.empty? && train == current_train(entity)

            nil
          end

          # Public: whether "Suggest Route" is meaningful right now -- a
          # ship must be selected (single-ship case auto-resolves this; a
          # multi-ship entity needs its tab clicked first, same as
          # launching by hand) and not already mid-flight, since the
          # autorouter always plans a fresh flight from a base, never a
          # continuation of one already underway.
          def suggestable?(entity)
            return false if @rollback&.dig(:finished)

            @game.autorouter_enabled? && @trace.empty? && !current_train(entity).nil?
          end

          # Public: whether this ship finished a run in some earlier OR
          # that "Previous Route" could try to replay -- cheap to check
          # (just a hash lookup), independent of whether that route is
          # still fully flyable today; replay_previous_route! is the one
          # that actually re-validates it hop by hop against current state.
          def previous_route_available?(entity)
            return false unless suggestable?(entity)

            !@game.last_route(current_train(entity)).nil?
          end

          # Public: whether a computed-but-unaccepted suggestion is
          # currently on offer for this entity's selected ship -- the UI
          # uses this to show "Accept Route" alongside "Suggest Route".
          def suggestion_pending?(entity)
            !@pending_suggestion.nil? && @pending_suggestion[:train] == current_train(entity)
          end

# Public: drops the last hex of the pending suggestion (and any
          # cargo picked up there), recomputing revenue for the shortened
          # route. Purely an edit to the still-unaccepted preview -- like
          # suggest_route!, this touches no real game state and logs
          # nothing; only accept_route!/accept_suggested_route! do that.
          # Called directly by the view now (see that pair's comment) --
          # no longer routed through a map hex click, since that would
          # mean touching the shared hex-click dispatch (hex.rb) to teach
          # it about a G2038-specific "this click means trim, not launch"
          # case. A button is a smaller, self-contained change.
          def trim_pending_suggestion!(entity)
            suggestion = @pending_suggestion
            hexes = suggestion[:hexes].dup
            removed = hexes.pop
            cargo = suggestion[:cargo].reject { |c| c[:hex_id] == removed.id }

            if hexes.size <= 1
              @pending_suggestion = nil
              @round.laid_hexes = []
              return
            end

            revenue = @game.trace_revenue(entity, suggestion[:train], hexes, cargo)
            @pending_suggestion = { train: suggestion[:train], hexes: hexes, cargo: cargo,
                                     revenue: revenue, timed_out: suggestion[:timed_out] }
            @round.laid_hexes = hexes
          end

          # Public: discards the pending suggestion outright -- back to
          # square one (just "Last"/"Suggest" on offer again), same as
          # trimming all the way down but in one click. Touches no real
          # game state, same as suggest_route!/trim_pending_suggestion!.
          def clear_pending_suggestion!(_entity)
            @pending_suggestion = nil
            @round.laid_hexes = []
          end

          # Public: hands the pending suggestion off to hand-flying --
          # shared by both Accept and Modify (see ship_selector.rb), since
          # both now land in the exact same place: a fully local,
          # not-yet-submitted flight the player can either Submit as-is or
          # back out of the tail end (clicking the route's own endpoint,
          # repeatedly, to taste) and fly on from wherever they backed up
          # to. Confirmed with the user: Accept must never silently finish
          # and submit the route in one click -- every route, suggested or
          # hand-flown, needs its own explicit Submit so the player always
          # gets a last chance to change their mind (found live in browser:
          # an earlier version routed Accept through a single self-
          # contained recorded action, which also turned out to crash on
          # replay whenever 2+ ships were still unrun -- see SUBMIT_FLIGHT/
          # local_flight_log for the replayable trail this local-first
          # approach produces instead).
          #
          # Replays the suggestion through local_choose! itself, hop by
          # hop -- exactly as if the player had clicked each of those
          # hexes by hand. A suggestion never routes through unexplored
          # territory (the autorouter only plans over already-known
          # hexes), so this never explores anything and needs no rollback
          # concerns beyond what local_choose!/pick_up already handle for
          # an ordinary hand-flown pickup. Once this returns, either the
          # flight auto-finished (MP exhausted) and Submit/Cancel are on
          # offer, or @trace is non-empty and normal map clicks
          # (compute_choices) take over from the suggested endpoint
          # exactly like any other in-progress local flight -- same
          # Discard/Submit machinery, nothing new to keep in sync.
          def apply_pending_suggestion!(entity)
            suggestion = @pending_suggestion
            return unless suggestion

            @pending_suggestion = nil
            @round.laid_hexes = []

            hexes = suggestion[:hexes]
            cargo_by_hex = suggestion[:cargo].group_by { |c| c[:hex_id] }

            local_choose!(entity, hexes.first.id)

            hexes.each_cons(2) do |from, to|
              break if @trace.empty? # maybe_auto_finish! already closed it out

              # A suggestion never *explores* a hex it doesn't need to
              # (autorouter search never reveals a tile speculatively --
              # see accept_route!'s comment), but it does fly straight
              # through unexplored ones it has no reason to stop at, same
              # as a player would by hand. compute_choices only offers a
              # bare hex id for a genuine "Move to" (destination already
              # explored) or a no-stop shortcut hop; an unexplored direct
              # neighbor is only ever reachable as FLYOVER (Skip) or the
              # 2-MP Explore, and since the latter never applies here, the
              # former is always the right one -- found live in browser as
              # "Invalid route choice" the moment a suggestion happened to
              # fly over a not-yet-explored hex on its way to somewhere
              # else.
              choice = from.neighbors.value?(to) && needs_exploration?(to) ? "#{FLYOVER}#{to.id}" : to.id
              local_choose!(entity, choice)
              next if @trace.empty?

              (cargo_by_hex[to.id] || []).each do |c|
                pickup_choice = c[:mine_idx] ? "#{PICKUP}#{c[:mine_idx]}" : TRANSSHIP
                # Re-validate right before applying, same graceful-skip-if-
                # no-longer-available philosophy as replay_cargo/Previous
                # Route -- a suggestion computed against a mine another
                # ship (or another player, in a hotseat game) has since
                # claimed would otherwise dispatch a choice compute_choices
                # no longer offers, raising "Invalid route choice" instead
                # of just quietly not picking it up. Found live in browser
                # picking up cargo mid-suggestion.
                local_choose!(entity, pickup_choice) if choices.key?(pickup_choice)
              end
            end
          end

          # Public: whether the pending suggestion's search hit its time
          # budget before exhausting the search space -- it's still the best
          # candidate found, but may not be the true optimum. The UI flashes
          # a transient banner for this (not logged: it isn't game state,
          # just a heads-up about search quality).
          def pending_suggestion_timed_out?(entity)
            suggestion_pending?(entity) && @pending_suggestion[:timed_out]
          end

          # Public opt-in hook for View::Game::Map#render_ship_marker: the
          # hex the currently-flying ship sits on, which marker icon to
          # show there, and where on the hex to center it, or nil if
          # nothing's mid-flight. Previously this was a Part::Icon attached
          # to the hex's own tile (like the refueling-station marker) --
          # but that ties the marker's size to the small-icon slot system
          # (which shrinks/repositions icons to avoid overlapping others on
          # the same hex, clipping a marker bigger than its slot) and to
          # per-hex DOM paint order (a later-drawn neighboring hex can
          # visually cover an overflowing icon). Confirmed with the user:
          # since the marker is transient, it's fine for it to spill into a
          # neighbor or cover part of its own hex -- rendering it instead
          # as a top-level map overlay (same technique already used for
          # route lines, Map#render_route_lines/Hex.coordinates) lets it
          # paint above every hex unconditionally and be sized
          # independently of any per-hex layout. Positioning: dead center
          # for a double-mine hex (both mine circles are already
          # symmetric around center, so centering the marker doesn't favor
          # either one); a bit below center, horizontally centered, for
          # everything else (leaves the hex's own top-standardized label/
          # single mine circle/city token clear -- confirmed with the
          # user).
          def ship_marker(entity)
            return nil unless entity == current_entity && !@trace.empty?

            train = current_train(entity)
            return nil unless train

            mp = [[mp_left(entity, train), 0].max, SHIP_MARKER_MAX_MP].min
            hex = @trace.last
            position = double_mine_hex?(hex) ? :center : :below_center
            [hex, ship_marker_icon_name(train, mp), position]
          end

          # Public: runs the single-ship autorouter (see Game#autorouter/
          # G2038::Autorouter) for the currently-selected ship and stores
          # whatever it finds as a pending suggestion -- shown as a live
          # preview (map trace + ship-row summary, see live_route_hexes/
          # ship_rows) but not yet replayed against real game state.
          # Confirmed with the user: a suggestion the player never accepts
          # shouldn't leave any log entries behind, so nothing here calls
          # launch_at/move_to/pick_up -- that only happens in
          # accept_suggested_route!, once the player commits to it.
          # Clicking Suggest Route again (before accepting) just recomputes
          # and replaces whatever was pending.
          def suggest_route!(entity, timeout: Autorouter::DEFAULT_TIMEOUT)
            train = current_train(entity)
            return unless train

            result = @game.autorouter.suggest_route(entity, train, timeout: timeout)
            unless result
              @pending_suggestion = nil
              @log << "No profitable route found for #{ship_label(train)}"
              return
            end

            @pending_suggestion = { train: train, hexes: result.hexes, cargo: result.cargo,
                                     revenue: result.revenue, timed_out: result.timed_out,
                                     elapsed: result.elapsed }
            @round.laid_hexes = result.hexes
          end

          # Public: cheap alternative to suggest_route! for the late-game
          # case the user asked for -- once claims settle down and a ship's
          # best flight stops changing OR to OR, replaying the exact same
          # hex-by-hex path it flew last time is usually just as good as
          # (and far cheaper than) re-running the search from scratch.
          # Re-walks the stored path applying real MP/refuel rules fresh
          # (a station's owner can change since the recorded flight), and
          # only re-collects a pickup if that specific mine is still
          # available to this entity -- if MP runs out partway, the replay
          # simply stops there rather than failing outright (same
          # "always offer whatever's still valid" philosophy as an
          # unexplored hex being a zero-value flyover). Populates
          # @pending_suggestion exactly like suggest_route! so the rest of
          # the Suggest/Accept/Trim flow (map preview, ship-row summary,
          # nothing logged until accepted) needs no special-casing.
          def replay_previous_route!(entity)
            train = current_train(entity)
            return unless train

            stored = @game.last_route(train)
            unless stored
              @log << "No previous route on record for #{ship_label(train)}"
              return
            end

            path = replay_path(entity, train, stored[:hexes])
            cargo = replay_cargo(entity, train, path, stored[:cargo])
            revenue = @game.trace_revenue(entity, train, path, cargo)

            if revenue.zero? || path.size < 2
              @pending_suggestion = nil
              @log << "#{ship_label(train)}'s previous route is no longer available"
              return
            end

            @pending_suggestion = { train: train, hexes: path, cargo: cargo, revenue: revenue,
                                     timed_out: false, source: :replay }
            @round.laid_hexes = path
          end

          # Re-walks a stored hex-id path with today's MP/refuel rules,
          # stopping early (rather than raising) the moment MP would go
          # negative -- e.g. a refueling station along the way changed
          # owners since this flight was recorded.
          def replay_path(entity, train, hex_ids)
            hexes = hex_ids.map { |id| @game.hex_by_id(id) }
            return [] if hexes.empty?

            full_mp = @game.ship_distance(entity, train)
            mp_left = full_mp
            refueled = []
            path = [hexes.first]

            hexes.each_cons(2) do |_prev, nxt|
              mp_left -= 1
              break if mp_left.negative?

              if @game.refueling_station_owner(nxt.id) == entity && !refueled.include?(nxt.id)
                mp_left = [mp_left + 3, full_mp].min
                refueled << nxt.id
              end
              path << nxt
            end

            path
          end

          # Re-collects only the stored pickups that fall within the
          # (possibly truncated) replayed path and are still actually
          # available to this entity -- claimed by someone else since, or
          # already used elsewhere this OR, and that one load is simply
          # skipped rather than blocking the rest of the replay.
          def replay_cargo(entity, train, path, stored_cargo)
            holds = @game.cargo_holds_for_train(train)
            reached = path.map(&:id)
            cargo = []

            stored_cargo.each do |c|
              break if cargo.size >= holds
              next unless reached.include?(c[:hex_id])

              if c[:mine_idx]
                mine = @game.mine_state.dig(c[:hex_id], :mines, c[:mine_idx])
                next unless mine && !mine[:used] && (!mine[:owner] || mine[:owner] == entity.id)

                cargo << { hex_id: c[:hex_id], mine_idx: c[:mine_idx], ore: mine[:ore],
                           value: @game.pickup_value(entity, c[:hex_id], c[:mine_idx]) }
              else
                hex = @game.hex_by_id(c[:hex_id])
                next unless @game.transshipment_hex?(hex.id)

                cargo << { hex_id: hex.id, mine_idx: nil, ore: nil,
                           value: @game.transshipment_value(hex, train) }
              end
            end

            cargo
          end

          # Public: commits the pending suggestion for real -- replays it
          # hop by hop through the exact same launch_at/move_to/pick_up/
          # pick_up_transshipment! methods a hand-flown route uses (never a
          # shortcut that bypasses the normal validation/state updates:
          # mine-used marking, refuel bookkeeping, exploration gating), so
          # this is the point where log entries and real state changes
          # finally happen.
          #
          # LEGACY, kept only so existing recorded games still replay
          # correctly: earlier builds submitted 'suggest_route'/
          # 'previous_route'/this exact string as real Choose actions,
          # baking every *preview* (not just the accepted flight) into the
          # permanent action history -- meaning replaying an old game
          # re-ran the full autorouter search for every Suggest Route
          # click that ever happened, accepted or not (found live in
          # browser: a since-reverted 300s test timeout turned this into
          # an actual multi-minute page-load hang). Going forward, see
          # accept_route! below -- Suggest/Previous/Trim are now plain,
          # unrecorded method calls the view makes directly (mirroring how
          # the standard Engine::AutoRouter computes purely client-side),
          # and only the final Accept becomes one self-contained action.
          def accept_suggested_route!(entity)
            suggestion = @pending_suggestion
            return unless suggestion

            @pending_suggestion = nil
            @log << "#{entity.name}: suggested route ran out of search time -- may not be the best possible" if suggestion[:timed_out]

            hexes = suggestion[:hexes]
            cargo_by_hex = suggestion[:cargo].group_by { |c| c[:hex_id] }
            launch_at(entity, hexes.first.id)

            hexes.each_cons(2) do |_from, to|
              move_to(entity, to.id, explore: false)
              next if @trace.empty? # maybe_auto_finish! already closed it out

              (cargo_by_hex[to.id] || []).each do |c|
                if c[:mine_idx]
                  pick_up(entity, c[:mine_idx])
                else
                  pick_up_transshipment!(entity, @trace.last)
                end
              end
            end

            finish_route(entity) unless @trace.empty?
          end

          # Legacy replay only -- games recorded while Accept still
          # submitted itself as one self-contained real action (the
          # ACCEPT_SUGGESTION: choice string built by the since-removed
          # accept_choice_for_pending) still need this to replay correctly.
          # Accept going forward never produces a new one of these; it
          # replays through apply_pending_suggestion! instead, the same
          # local-then-explicit-Submit path Modify uses (see that method's
          # comment for why). Re-validates each pickup against current
          # mine_state right as it's reached (same graceful-skip-if-no-
          # longer-available philosophy as replay_cargo/Previous Route)
          # rather than trusting the payload blindly.
          def accept_route!(entity, choice)
            _prefix, rest = choice.split(':', 2)
            # New format carries the train id explicitly, ahead of the
            # hexes: "train_id:hexes|cargo" -- see accept_choice_for_
            # pending's comment. Old recorded games (from before that fix)
            # used a plain "hexes|cargo" payload with no train id; the two
            # are distinguished by whether a ':' appears before the first
            # '|', since no hex id ever contains one.
            if rest.to_s.split('|', 2).first.to_s.include?(':')
              train_id, rest = rest.split(':', 2)
              train = @game.route_trains(entity).find { |t| t.id == train_id }
              @selected_train_id = train.id if train
            end
            hex_part, cargo_part = rest.to_s.split('|', 2)
            hex_ids = hex_part.to_s.split(',')
            cargo_tokens = cargo_part.to_s.split(',').filter_map do |token|
              next if token.empty?

              hex_id, _sep, idx = token.rpartition('_')
              { hex_id: hex_id, mine_idx: idx == 'x' ? nil : idx.to_i }
            end

            @pending_suggestion = nil
            hexes = hex_ids.map { |id| @game.hex_by_id(id) }
            return if hexes.size < 2

            launch_at(entity, hexes.first.id)

            hexes.each_cons(2) do |_from, to|
              move_to(entity, to.id, explore: false)
              next if @trace.empty? # maybe_auto_finish! already closed it out

              cargo_tokens.each do |c|
                next unless c[:hex_id] == to.id

                if c[:mine_idx]
                  mine = @game.mine_state.dig(c[:hex_id], :mines, c[:mine_idx])
                  pick_up(entity, c[:mine_idx]) if mine && !mine[:used] && (!mine[:owner] || mine[:owner] == entity.id)
                elsif @game.transshipment_hex?(to.id)
                  pick_up_transshipment!(entity, @trace.last)
                end
              end
            end

            finish_route(entity) unless @trace.empty?
          end

          # Live cargo status for the ship currently mid-flight: how many
          # holds are used out of its total, and which commodities are
          # aboard so far -- updates every render as pickups happen,
          # renders in the same ship-selector row as the ship's own label
          # (see ShipSelector#render_row).
          def cargo_summary(train)
            holds = @game.cargo_holds_for_train(train)
            used = "#{@cargo.size}/#{holds} #{holds == 1 ? 'hold' : 'holds'} used"
            return used if @cargo.empty?

            loads = @cargo.map { |c| c[:ore] ? ORE_NAMES[c[:ore]] : 'Transshipment credit' }.join(', ')
            "#{used}: #{loads}"
          end

          def process_choose(action)
            entity = action.entity
            choice = action.choice

            return replay_submitted_flight!(entity, choice) if choice.to_s.start_with?("#{SUBMIT_FLIGHT}:")

            dispatch_choice!(entity, choice)
          end

          # The complete choose-action dispatch table -- shared by
          # process_choose (a real, recorded action: CANCEL_COMPLETED, one
          # of the legacy formats below, or one hop of
          # replay_submitted_flight!'s loop, with @committing true) and
          # local_choose! (every live click while a route is still being
          # built locally and unsubmitted, @committing false). One
          # dispatch table for both guarantees a submitted flight replays
          # through exactly the logic that built it live, hop for hop.
          def dispatch_choice!(entity, choice)
            valid = choices.key?(choice) || ship_choices(entity).key?(choice) || pilot_choices(entity).key?(choice) ||
              cancel_completed_choices.key?(choice) ||
              # Legacy -- only ever reachable while replaying an existing
              # game recorded before Suggest/Previous/Trim stopped being
              # real actions (see accept_route!'s comment). New games
              # never submit these anymore.
              (choice == SUGGEST && suggestable?(entity)) ||
              (choice == ACCEPT_SUGGESTION && suggestion_pending?(entity)) ||
              (choice == PREVIOUS_ROUTE && previous_route_available?(entity)) ||
              # Current: the one and only action Suggest Route's flow ever
              # submits now -- self-contained, so no prior action needs to
              # have populated any pending state for this to be valid.
              (choice.start_with?("#{ACCEPT_SUGGESTION}:") && @trace.empty?)
            raise GameError, "Invalid route choice: #{choice}" unless valid

            @choices_memo = nil

            if choice == FINISH
              finish_route(entity)
            elsif choice == CANCEL
              cancel_route
            elsif choice.start_with?(CANCEL_COMPLETED)
              cancel_completed_route(entity, choice.delete_prefix(CANCEL_COMPLETED))
            elsif choice == UNDO_HEX
              undo_last_hex!(entity)
            elsif @rollback&.dig(:finished) && choice == undo_click_hex&.id
              # Only reachable once nothing else is offered (see
              # compute_choices' finished-flight branch) -- a direct click
              # on an already-finished, not-yet-submitted route's last
              # hex, with nothing to un-reveal (the popup already
              # intercepted the case where there was).
              undo_last_hex!(entity)
            elsif choice.start_with?(REDRAW)
              resolve_redraw!(entity, choice)
            elsif choice.start_with?(PICKUP)
              pick_up(entity, choice.delete_prefix(PICKUP).to_i)
            elsif choice == TRANSSHIP
              pick_up_transshipment!(entity, @trace.last)
              finish_route(entity)
            elsif choice.start_with?(SHIP)
              @selected_train_id = choice.delete_prefix(SHIP)
            elsif choice.start_with?(PILOT)
              source, _sep, train_id = choice.delete_prefix(PILOT).rpartition('_')
              train = available_trains(entity).find { |t| t.id == train_id }
              assign_pilot!(entity, source, train) if train
            elsif choice == SUGGEST # legacy, see accept_route!'s comment
              suggest_route!(entity)
            elsif choice == PREVIOUS_ROUTE # legacy
              replay_previous_route!(entity)
            elsif choice == ACCEPT_SUGGESTION # legacy (exact match, no payload)
              accept_suggested_route!(entity)
            elsif choice.start_with?("#{ACCEPT_SUGGESTION}:") # current, self-contained
              accept_route!(entity, choice)
            elsif choice.start_with?(FLYOVER)
              move_to(entity, choice.delete_prefix(FLYOVER), explore: false)
            elsif choice.start_with?(SHORTCUT_EXPLORE)
              fly_shortcut_to!(entity, choice.delete_prefix(SHORTCUT_EXPLORE), explore_destination: true)
            elsif @trace.empty? && suggestion_pending?(entity) && choice == @pending_suggestion[:hexes].last.id
              trim_pending_suggestion!(entity)
            elsif @trace.empty?
              launch_at(entity, choice)
            elsif choice == @trace.last.id
              matches = current_hex_action_choices
              raise GameError, "Ambiguous pickup at #{choice}" if matches.size != 1

              match = matches.keys.first
              if match == TRANSSHIP
                pick_up_transshipment!(entity, @trace.last)
                finish_route(entity)
              elsif match == UNDO_HEX
                undo_last_hex!(entity)
              else
                pick_up(entity, match.delete_prefix(PICKUP).to_i)
              end
            elsif @trace.last.neighbors.values.map(&:id).include?(choice)
              move_to(entity, choice, explore: true)
            else
              fly_shortcut_to!(entity, choice)
            end

            # The @trace.last.id branch above (transshipment/pickup
            # disambiguation) calls `choices` mid-method, re-populating
            # @choices_memo from the *pre-finish* trace, then finish_route
            # (right below it) empties @trace without invalidating that
            # cache again -- leaving the next ship's turn looking at a
            # stale, mid-flight choice list (still offering the just-
            # finished hex as a "choice", never the real launch hexes).
            # Since launch_at never validates its hex against the entity's
            # own tokens, that stale entry then gets silently accepted as
            # a legitimate launch point -- found live in browser: TSI's
            # next ship launched from a transshipment hex a previous ship
            # had just finished at, with its real base hex not offered at
            # all. Resetting here, unconditionally, after every branch has
            # run, guarantees the next `choices` call is always freshly
            # computed regardless of how many times something upstream
            # recomputed and cached it mid-dispatch.
            @choices_memo = nil
          end

          def process_pass(action)
            @choices_memo = nil

            if @trace.empty?
              if @pending_suggestion
                @pending_suggestion = nil
                @round.laid_hexes = []
              end
              log_pass(action.entity)
              pass!
            elsif @explored_in_trace
              raise GameError, 'Cannot cancel a route after exploring — finish the route instead'
            else
              cancel_route
            end
          end

          private

          def compute_choices
            entity = current_entity
            return {} unless entity
            # A flight that finished locally but hasn't been submitted yet
            # blocks starting (or switching to) another ship -- at most one
            # flight is ever pending discard/submit at a time, so there's
            # nothing to interleave (see local_choose!/rollback_local_flight!).
            # The one exception is undoing its own last hex -- clicking the
            # route's endpoint (or, if that would un-reveal a tile, the
            # popup's confirm button) is still offered.
            if @rollback&.dig(:finished)
              hex = undo_click_hex
              return hex ? { hex.id => undo_hex_label, UNDO_HEX => undo_hex_label } : {}
            end
            return redraw_choices if @pending_redraw

            train = current_train(entity)
            return {} unless train

            return start_choices(entity, train).merge(trim_suggestion_choice(entity)) if @trace.empty?

            result = {}
            @trace.last.neighbors.each_value do |hex|
              next if hex.empty

              if needs_exploration?(hex)
                if mp_left(entity, train) >= 2
                  result[hex.id] = "Explore #{hex.id} (2 MP: 1 fly + 1 explore; #{mp_left(entity, train) - 2} left)"
                end
                if mp_left(entity, train) >= 1
                  result["#{FLYOVER}#{hex.id}"] =
                    "Skip #{hex.id} (1 MP; #{mp_left(entity, train) - 1} left)"
                end
              elsif mp_left(entity, train) >= 1
                result[hex.id] = "Move to #{hex.id} (1 MP; #{mp_left(entity, train) - 1} left)"
              end
            end
            result.merge!(shortcut_choices(entity, train))
            pickup_choices(entity, train, result)
            transshipment_choice(entity, train, result)
            alias_current_hex_pickup!(result)
            if @trace.size > 1
              revenue = @game.trace_revenue(entity, train, @trace, @cargo)
              result[FINISH] = "End route (#{@game.format_currency(revenue)})"
            end
            # Exploration reveals hidden information, so a route that has
            # explored is committed — it can be finished but not taken back.
            result[CANCEL] = 'Cancel route' unless @explored_in_trace
            result
          end

          def available_trains(entity)
            @game.route_trains(entity).reject { |t| @ran_trains.include?(t) }
          end

          # Before launch, the player may own several unrun ships; let them
          # pick (and switch) which one flies before committing to a base.
          # With only one available ship there's nothing to pick, so skip
          # straight to base selection.
          #
          # A flight that finished locally but hasn't been submitted yet
          # always wins over that fallback, regardless of how many (or
          # how few) other ships remain unrun -- @rollback[:finished_train]
          # is already in @ran_trains at this point (finish_route put it
          # there), so once it was the *last* unrun ship, available_trains
          # would otherwise narrow to size 1 and silently hand focus to
          # whatever ship comes next, even though the pending flight is
          # still what the player's looking at (its Submit/Cancel bar,
          # its route on the map). Found live in browser: rerouting a
          # suggestion that used up all its MP auto-finished it, and with
          # no other ship left unrun, the UI jumped straight to the next
          # ship's "Fly" panel while the just-finished one's Submit button
          # kept showing the right revenue anyway (that path reads
          # @rollback directly, not this method) -- just under the wrong
          # ship's name, with no way to tell the two apart.
          def current_train(entity)
            return @rollback[:finished_train] if @rollback&.dig(:finished_train)

            trains = available_trains(entity)
            return nil if trains.empty?
            return trains.first if trains.size == 1

            trains.find { |t| t.id == @selected_train_id }
          end

          def mp_left(entity, train)
            @game.ship_distance(entity, train) - @mp_spent
          end

          # Flight shortcut: lets the player click a hex more than one hop
          # away and fly there by the shortest route, instead of clicking
          # every intermediate hex by hand. Pass-through hexes along the
          # way are always flyovers regardless of whether they've been
          # explored (1 MP, tile stays hidden) -- exploring one of those is
          # a real decision (reveals hidden information, costs an extra
          # MP) the shortcut can't make on the player's behalf. The FINAL
          # hex is different: that's exactly where a hand-flown route
          # would stop and decide whether to explore too, so it gets the
          # same Explore/Fly-over choice a direct neighbor would (see
          # hex_choice_popup), just at the shortcut's own MP cost. Adjacent
          # hexes are excluded here since the normal per-hex choice
          # already covers them.
          def shortcut_choices(entity, train)
            neighbor_ids = @trace.last.neighbors.values.map(&:id)
            shortcut_paths(entity, train).each_with_object({}) do |(hex_id, entry), result|
              next if neighbor_ids.include?(hex_id)

              hops = entry[:path].size
              result[hex_id] = "Fly to #{hex_id} via shortest route (#{hops} hexes, no exploring)"

              hex = @game.hex_by_id(hex_id)
              next unless needs_exploration?(hex) && entry[:remaining] >= 1

              result["#{SHORTCUT_EXPLORE}#{hex_id}"] =
                "Fly to #{hex_id} via shortest route and explore (#{hops} hexes, 1 extra MP; "\
                "#{entry[:remaining] - 1} left)"
            end
          end

          # Shortcut destinations, one entry per reachable hex 2+ hexes
          # away: {hex_id => {path: [hex, hex, ...], remaining: N}}.
          #
          # Prefers the fewest-hop route whenever it's affordable at all,
          # and only ever detours through a refueling station when that's
          # the only way to reach the hex -- never merely to arrive with
          # more fuel to spare. A refuel bonus is order-independent (visit
          # the station before or after a stop, same total benefit), so
          # front-loading it into the route to *this* hex specifically
          # only pays off if the direct route wouldn't have reached here
          # at all; otherwise it just forces a detour (or, if the player
          # later backtracks to the station instead of passing it
          # naturally, a strictly worse outcome than going direct and
          # refueling whenever convenient) for no real gain. Confirmed
          # with the user via a worked example: a direct route arriving
          # low on fuel, followed by a single hop to an adjacent station,
          # always beats routing through that same station first and
          # backtracking to it afterward -- same total hops, better or
          # equal final fuel, no detour required up front.
          def shortcut_paths(entity, train)
            start = @trace.last
            mp = mp_left(entity, train)
            plain = plain_shortest_paths(start)

            direct = plain.each_with_object({}) do |(hex_id, path), result|
              next if path.size > mp

              result[hex_id] = { path: path, remaining: mp - path.size }
            end

            unaffordable_ids = plain.keys - direct.keys
            return direct if unaffordable_ids.empty?

            fueled = refuel_shortcut_paths(entity, train)
            unaffordable_ids.each { |hex_id| direct[hex_id] = fueled[hex_id] if fueled[hex_id] }
            direct
          end

          # Plain BFS shortest-hop-path tree from `start`, completely
          # ignoring refueling stations -- 1 MP per hop, unconstrained by
          # how much MP is actually available (shortcut_paths compares
          # against that separately). Cost is strictly monotonic hop by
          # hop here (no bonuses to create non-monotonic relaxation), so a
          # plain FIFO queue is correct and sufficient -- no predecessor
          # cycles are possible, unlike refuel_shortcut_paths below.
          # Returns {hex_id => [hex, hex, ...]}, the hops after `start`,
          # for every hex on the (fully connected, minus empty hexes)
          # board.
          def plain_shortest_paths(start)
            predecessor = {}
            visited = { start.id => true }
            queue = [start]

            until queue.empty?
              hex = queue.shift

              hex.neighbors.each_value do |neighbor|
                next if neighbor.empty || visited[neighbor.id]

                visited[neighbor.id] = true
                predecessor[neighbor.id] = hex
                queue << neighbor
              end
            end

            visited.each_key.reject { |id| id == start.id }.to_h do |id|
              path = []
              hex = @game.hex_by_id(id)
              while hex && hex.id != start.id
                path.unshift(hex)
                hex = predecessor[hex.id]
              end
              [id, path]
            end
          end

          # Best-first search (Dijkstra, maximizing remaining MP rather
          # than minimizing cost) from the current position, refueling-
          # aware (same modeling as Game#hexes_in_range -- including
          # respecting @refueled_hexes, so a station already used earlier
          # this flight isn't optimistically double-counted here). Used
          # by shortcut_paths only as a fallback, for hexes the plain,
          # refuel-ignorant search (above) can't afford to reach at all --
          # see shortcut_paths' own comment for why favoring maximum fuel
          # unconditionally (this method's original role, before that
          # fallback split existed) turned out to be the wrong default.
          # Returns {hex_id => {path: [hex, hex, ...], remaining: N}}, the
          # hops after the current position and the MP left assuming a
          # pure flyover arrival, for every hex reachable with remaining
          # MP (via some refuel-assisted route; hexes already reachable
          # without one are never looked up here).
          #
          # Settling hexes in decreasing order of remaining MP (rather
          # than plain FIFO BFS order) matters here specifically because
          # of the refuel bump below (+3 MP, capped at full_mp): it makes
          # "remaining" non-monotonic hop by hop, so a plain FIFO walk can
          # reassign a hex's predecessor again after that hex has already
          # served as someone else's predecessor -- occasionally forming
          # a genuine cycle (A's predecessor is B, B's predecessor is A)
          # that would loop forever when reconstructed below (found live
          # in browser: this hung the whole render). Settling best-first
          # instead means a hex's best/predecessor is finalized the
          # instant it's settled -- nothing relaxes it again afterward --
          # so `predecessor` is always a genuine acyclic tree rooted at
          # `start`, with no need to detect or drop anything afterward.
          def refuel_shortcut_paths(entity, train)
            start = @trace.last
            full_mp = @game.ship_distance(entity, train)
            best = { start.id => mp_left(entity, train) }
            predecessor = {}
            settled = {}
            frontier = [start]

            until frontier.empty?
              hex = frontier.max_by { |h| best[h.id] }
              frontier.delete(hex)
              next if settled[hex.id]

              settled[hex.id] = true
              remaining = best[hex.id]

              hex.neighbors.each_value do |neighbor|
                next if neighbor.empty || settled[neighbor.id]

                next_remaining = remaining - 1
                next if next_remaining.negative?

                if @game.refueling_station_owner(neighbor.id) == entity && !@refueled_hexes.include?(neighbor.id)
                  next_remaining = [next_remaining + 3, full_mp].min
                end
                next if best[neighbor.id] && best[neighbor.id] >= next_remaining

                best[neighbor.id] = next_remaining
                predecessor[neighbor.id] = hex
                frontier << neighbor unless frontier.include?(neighbor)
              end
            end

            best.each_key.reject { |id| id == start.id }.to_h do |id|
              path = []
              hex = @game.hex_by_id(id)
              while hex && hex.id != start.id
                path.unshift(hex)
                hex = predecessor[hex.id]
              end
              [id, { path: path, remaining: best[id] }]
            end
          end

          # Replays a shortcut path hop by hop via the normal move_to.
          # Every hop but the last is always explore: false -- every
          # pass-through hex is a flyover regardless of whether it's been
          # explored, exactly like a hand-clicked FLYOVER move, so
          # refueling/transshipment pickup along the way behave exactly as
          # they would for a hand-clicked move and any unexplored hex
          # passed through stays hidden. The final hex honors
          # `explore_destination` (see shortcut_choices/process_choose's
          # SHORTCUT_EXPLORE branch) -- same explore-on-arrival choice a
          # direct neighbor move gets, just reached via the shortcut.
          # Ore pickups are the one thing skipped at intermediate hops:
          # picking up is a real decision, and the whole point of the
          # shortcut is not stopping for one at every hex passed through --
          # only the final hex (where control returns to the player)
          # offers a pickup choice, same as any normal move ending there.
          def fly_shortcut_to!(entity, hex_id, explore_destination: false)
            entry = shortcut_paths(entity, current_train(entity))[hex_id]
            raise GameError, "No shortcut route to #{hex_id}" unless entry

            path = entry[:path]
            @log << "#{entity.name} flies the shortcut route to #{hex_id} (#{path.size} hexes, "\
                    "no pickups along the way#{explore_destination ? ', exploring on arrival' : ''})"
            path.each_with_index { |hex, i| move_to(entity, hex.id, explore: explore_destination && i == path.size - 1) }
          end

          # The two choices offered while Ice Finder/Drill Hound/Lucky's
          # second-draw power is being resolved -- see move_to and
          # resolve_redraw!. Presented via entity_choices (bottom panel)
          # since there's no single map hex to click for this.
          # The real choice keys/labels for Lucky's tile redraw (used by
          # process_choose's validity check either way). The bare-hex-id
          # alias exists only so hex.rb's dispatch gate
          # (`choices.include?(@hex.id)`) finds a key to look for a popup
          # at all -- never dispatched directly, since hex_choice_popup
          # always returns non-nil here (redraw_tile_popup, the real
          # tile-image UI; these text labels no longer render anywhere).
          def redraw_choices
            r = @pending_redraw
            result = {
              "#{REDRAW}first" => "Place #{tile_label(r[:first_name])} (found first)",
              "#{REDRAW}second" => "Place #{tile_label(r[:second_name])} (found second)",
            }
            result[r[:hex_id]] ||= result.values.first
            result
          end

          def tile_label(tile_name)
            mines = @game.class::MINE_DATA.fetch(tile_name, [])
            return 'an empty tile (no mines)' if mines.empty?

            ores = mines.map { |m| ORE_NAMES[m[:ore]] }.join(' + ')
            "#{ores} #{mines.size == 1 ? 'mine' : 'mines'}"
          end

          # A mine is "visited" if ore was actually picked up there -- flying
          # over/through an explored mine hex without picking up doesn't
          # count (e.g. cargo was already full, or it was already claimed by
          # someone else and thus unavailable).
          def mines_visited(cargo)
            cargo.select { |c| c[:ore] }.map { |c| [c[:hex_id], c[:mine_idx]] }.uniq.size
          end

          # Short form for quick scanning in the ship-selector row: "explore
          # <hexes>/<bonus>, mines <visited>/<delivered>". The explore part
          # is dropped entirely for a route that never explored anything --
          # "explore 0/$0" conveys nothing a blank doesn't already, and
          # skipping it leaves more room for the mines/commodities that do
          # matter -- confirmed with the user.
          def route_summary(route)
            stats = @route_stats_by_train[route.train] || { explored: 0, mines: 0, cargo: [] }
            codes = (stats[:cargo] || []).filter_map { |c| ORE_NAMES[c[:ore]]&.[](0) }
            codes_str = codes.empty? ? '' : " (#{codes.join(', ')})"
            explore_str =
              if stats[:explored].positive?
                bonus = stats[:explored] * @game.class::EXPLORATION_BONUS
                "explore #{stats[:explored]}/#{@game.format_currency(bonus)}, "
              else
                ''
              end
            "#{explore_str}mines #{stats[:mines]}/#{@game.format_currency(route.revenue)}#{codes_str}"
          end

          # One line describing a pending (not-yet-accepted) suggestion --
          # shared by pending_suggestion_summary (the button-area display)
          # and ship_rows (the per-ship-tab display).
          def suggestion_summary(suggestion)
            loads = suggestion[:cargo].map { |c| c[:ore] ? ORE_NAMES[c[:ore]] : 'Transshipment credit' }.join(', ')
            label = suggestion[:source] == :replay ? 'Previous route' : 'Suggested'
            base = "#{label}: #{@game.format_currency(suggestion[:revenue])}"
            base += " (#{loads})" unless loads.empty?
            # elapsed is only set for a freshly-searched suggestion (nil for
            # a Previous Route replay, which does no search) -- surfaced
            # here, not just in the log, since an unaccepted suggestion
            # otherwise leaves no trace of how long the search actually
            # took. TEMPORARY alongside DEFAULT_TIMEOUT's 300s test value.
            base += " -- search took #{suggestion[:elapsed]}s" if suggestion[:elapsed]
            base
          end

          def needs_exploration?(hex)
            hex.tile.color == :blue && !@game.mine_state[hex.id]
          end

          def start_choices(entity, train)
            entity.tokens.filter_map { |t| t.city&.hex }.uniq.to_h do |hex|
              [hex.id, "Launch #{ship_label(train)} from #{hex.id}"]
            end
          end

          # Lets the player click the last hex of a pending suggestion to
          # drop it (and whatever it picked up there), same "click the
          # endpoint to shorten the route" idiom the standard track-based
          # RouteSelector uses (Engine::Route#touch_node) -- rerouting a
          # middle leg isn't offered (confirmed with the user it's not
          # needed here), only trimming from the very end, repeatedly.
          # Never offered once only the launch hex itself would be left --
          # nothing to trim down to.
          def trim_suggestion_choice(entity)
            return {} unless suggestion_pending?(entity)

            hexes = @pending_suggestion[:hexes]
            return {} if hexes.size <= 1

            { hexes.last.id => "Remove #{hexes.last.id} from suggested route" }
          end

          # Every real spaceship's name already encodes its stats (e.g.
          # '3/2' = 3 MP, 2 cargo holds); the Probe doesn't follow that
          # convention, so spell its stats out alongside its name instead.
          # Once a Growth Corp pilot is assigned to this specific ship, its
          # two-letter source code is appended too, so any ship label
          # anywhere (ship selector, route summaries, log lines) shows at a
          # glance which pilot (if any) is riding along.
          def ship_label(train)
            base = train.name == 'Probe' ? "#{train.name} (#{train.distance}/#{@game.cargo_holds_for_train(train)})" : train.name
            source = @pilot_assignments.key(train)
            source ? "#{base} (#{source})" : base
          end

          def pickup_choices(entity, train, result)
            return if @cargo.size >= @game.cargo_holds_for_train(train)

            state = @game.mine_state[@trace.last.id]
            return unless state

            state[:mines].each_with_index do |mine, idx|
              next if mine[:used]
              next if mine[:owner] && mine[:owner] != entity.id

              value = @game.pickup_value(entity, @trace.last.id, idx)
              result["#{PICKUP}#{idx}"] =
                "Pick up #{ORE_NAMES[mine[:ore]]} ore (#{@game.format_currency(value)})"
            end
          end

          # Never automatic (see pick_up_transshipment! above) -- offered as
          # a click choice on the current hex, same shape as pickup_choices,
          # so mines and transshipment points behave identically from the
          # player's perspective (click the hex you're already on to
          # collect).
          def transshipment_choice(entity, train, result)
            return unless @game.transshipment_hex?(@trace.last.id)
            return if @cargo.size >= @game.cargo_holds_for_train(train)

            value = @game.transshipment_value(@trace.last, train)
            result[TRANSSHIP] = "Pick up transshipment credit (#{@game.format_currency(value)})"
          end

          # The current hex is never one of its own neighbors, so it never
          # gets a plain hex-id key from the loop above -- but hex.rb's
          # generic click dispatch only ever looks for a popup (or a direct
          # bare-hex-id action) when `choices.include?(@hex.id)` is already
          # true. Alias it here so clicking the ship's own hex can trigger a
          # pickup, same trick BuyInfrastructure uses for its claim hexes.
          # With exactly one pickup available this value is what actually
          # gets dispatched; with 2+ it's a placeholder `hex_choice_popup`
          # always intercepts ahead of. A mine hex and a transshipment point
          # are mutually exclusive, so PICKUP/TRANSSHIP never both match at
          # once in practice, but treating them as one combined pool here
          # keeps the "exactly one -> alias it" rule uniform either way.
          def alias_current_hex_pickup!(result)
            result[UNDO_HEX] = undo_hex_label if undo_last_hex_available?(current_entity)

            matches = result.select { |key, _label| key.start_with?(PICKUP) || key == TRANSSHIP || key == UNDO_HEX }
            return if matches.empty?

            result[@trace.last.id] ||= matches.values.first
          end

          # Launching costs no MP -- the ship starts at its base, full tank.
          def launch_at(entity, hex_id)
            # Discards any stale preview for this ship -- reached both by a
            # manual launch (abandoning an unaccepted suggestion) and by
            # accept_suggested_route! itself (which already nils this out
            # beforehand, so this is a harmless no-op in that path).
            @pending_suggestion = nil
            @hexes_explored_this_trip = 0
            # Refueling stations already used this specific flight (§7.11:
            # a station only tops off a ship once per flight, not once per
            # visit) -- reset per trip, not per OR, so a second ship (or a
            # re-trace after cancelling) gets its own full set of stations
            # again.
            @refueled_hexes = []
            hex = @game.hex_by_id(hex_id)
            @trace << hex
            @hexes_entered += 1
            update_trace_highlight
          end

          def move_to(entity, hex_id, explore:)
            hex = @game.hex_by_id(hex_id)
            do_explore = explore && needs_exploration?(hex)
            @mp_spent += do_explore ? 2 : 1
            @trace << hex
            @hexes_entered += 1

            if do_explore
              # Peeking at what's there is itself a reveal, whether or not
              # a second-draw power ends up mattering here.
              @explored_in_trace = true

              train = current_train(entity)
              first_name, first_mines = @game.peek_tile(hex_id)
              if @game.needs_second_draw?(entity, train, first_mines)
                # Lucky picks which of the two to place; Ice Finder/Drill
                # Hound have no choice -- needs_second_draw? is only true
                # for them because the first tile already failed their ore
                # requirement, so the second (borrowed) tile is always the
                # one used. A Growth Corp checks THIS train's specific
                # assigned pilot source (Phase 8) instead of its own id.
                pilot_source = entity.minor? ? entity.id : pilot_source_for_train(entity, train)
                if pilot_source == 'LY'
                  start_redraw!(hex_id, first_name)
                else
                  auto_redraw!(entity, hex_id, first_name, pilot_source)
                end
              else
                explore_hex_tracked!(hex_id, entity)
                @hexes_explored_this_trip += 1
              end
            end

            refuel!(entity, hex) if @game.refueling_station_owner(hex.id) == entity && !@refueled_hexes.include?(hex.id)
            update_trace_highlight
            maybe_auto_finish!(entity, current_train(entity))
          end

          # Once MP is exhausted, there's nothing left to decide once any
          # pickup still available at the current hex is gone too --
          # auto-finish instead of making the player click "End route" for
          # a foregone conclusion, the same "no click for a choice that
          # isn't really one" principle already applied elsewhere (the SR
          # Done-button fix, ships auto-passing between each other). Skipped
          # while a tile-redraw choice is still pending (Lucky) -- that's a
          # real decision to resolve first, not a foregone conclusion; safe
          # to call repeatedly mid-shortcut-flight too, since MP only ever
          # reaches 0 at the true final hop of any reachable path (see
          # shortcut_paths).
          def maybe_auto_finish!(entity, train)
            return if @pending_redraw
            return unless @trace.size > 1
            return if train.nil? || mp_left(entity, train).positive?

            remaining_pickups = {}
            pickup_choices(entity, train, remaining_pickups)
            transshipment_choice(entity, train, remaining_pickups)
            return unless remaining_pickups.empty?

            finish_route(entity)
          end

          # A transshipment point's printed value works like a mine with
          # unlimited availability (no "used" marker, any ship any number of
          # times), but -- unlike an ore pickup -- it's never automatic: the
          # rules permit a ship to end its flight at a transshipment point
          # without collecting there, so picking it up requires an explicit
          # click on the hex, same as any other mine (see
          # transshipment_choice/alias_current_hex_pickup!/process_choose's
          # TRANSSHIP branch below). Confirmed with the user that choosing
          # to collect also ends the ship's flight immediately -- unlike an
          # ore pickup, which lets the ship keep flying.
          def pick_up_transshipment!(entity, hex)
            return unless @game.transshipment_hex?(hex.id)

            train = current_train(entity)
            return if !train || @cargo.size >= @game.cargo_holds_for_train(train)

            value = @game.transshipment_value(hex, train)
            @cargo << { hex_id: hex.id, mine_idx: nil, ore: nil, value: value }
            @log << "#{entity.name} collects #{@game.format_currency(value)} at transshipment point #{hex.id}"
          end

          # Ice Finder/Drill Hound: the second (borrowed) tile is placed
          # automatically -- no player choice, since it was only drawn
          # because the first tile lacked their favored ore. The unused
          # first tile goes back to wherever the second was borrowed from
          # (Decision D). Logged explicitly so a run of bad luck (missing
          # the favored ore on both draws) reads as expected behavior
          # rather than a suspected bug.
          def auto_redraw!(entity, hex_id, first_name, pilot_source)
            ore = @game.class::INDEPENDENT_ORE_BONUS[pilot_source]
            @log << "#{entity.name}'s first draw lacked #{ORE_NAMES[ore]}; drawing second tile"

            borrowed_hex_id, second_name = @game.borrow_second_tile(hex_id) || []
            unless borrowed_hex_id
              explore_hex_tracked!(hex_id, entity)
              @hexes_explored_this_trip += 1
              return
            end

            resolve_second_draw_tracked!(hex_id, second_name, borrowed_hex_id, first_name)
            explore_hex_tracked!(hex_id, entity)
            @hexes_explored_this_trip += 1
          end

          # Lucky's power: borrow a second tile from a random still-
          # unexplored hex and let the player pick which of the two to
          # actually place here (Decision D). If there's simply nothing
          # left to borrow from (end of the tile pool), fall back to
          # placing the one tile already drawn.
          def start_redraw!(hex_id, first_name)
            borrowed_hex_id, second_name = @game.borrow_second_tile(hex_id) || []
            unless borrowed_hex_id
              explore_hex_tracked!(hex_id, current_entity)
              @hexes_explored_this_trip += 1
              return
            end

            @pending_redraw = {
              hex_id: hex_id,
              first_name: first_name,
              borrowed_hex_id: borrowed_hex_id,
              second_name: second_name,
            }
          end

          def resolve_redraw!(entity, choice)
            r = @pending_redraw
            chosen, other = choice == "#{REDRAW}first" ? [r[:first_name], r[:second_name]] : [r[:second_name], r[:first_name]]

            resolve_second_draw_tracked!(r[:hex_id], chosen, r[:borrowed_hex_id], other)
            @pending_redraw = nil
            explore_hex_tracked!(r[:hex_id], entity)
            @hexes_explored_this_trip += 1
            maybe_auto_finish!(entity, current_train(entity))
          end

          # +3 MP, capped at the ship's own movement allowance (§7.11/7.12).
          # Once per flight per station -- @refueled_hexes (reset per trip in
          # launch_at) is what stops a route that loops back through the
          # same station from refueling over and over.
          def refuel!(entity, hex)
            train = current_train(entity)
            gained = [@mp_spent, 3].min
            @mp_spent -= gained
            @refueled_hexes << hex.id
            @log << "#{entity.name}'s #{train.name} refuels at #{hex.id} (+#{gained} MP)"
          end

          def pick_up(entity, mine_idx)
            hex = @trace.last
            mine = @game.mine_state.dig(hex.id, :mines, mine_idx)
            value = @game.pickup_value(entity, hex.id, mine_idx)
            @cargo << { hex_id: hex.id, mine_idx: mine_idx, ore: mine[:ore], value: value }
            @game.mark_mine_used!(hex.id, mine_idx)
            @rollback[:pickups] << [hex.id, mine_idx] if @rollback
            @log << "#{entity.name} picks up #{ORE_NAMES[mine[:ore]]} ore at #{hex.id} "\
                    "(#{@game.format_currency(value)})"
            maybe_auto_finish!(entity, current_train(entity))
          end

          def finish_route(entity)
            train = current_train(entity)
            trace = @trace.dup
            revenue = @game.trace_revenue(entity, train, trace, @cargo)

            if revenue.zero? && !@cargo.empty?
              @log << "#{entity.name}'s #{@cargo.size} #{@cargo.size == 1 ? 'load is' : 'loads are'} "\
                      'not delivered and lost'
            end

            if @rollback
              @rollback[:finished] = true
              @rollback[:finished_train] = train
              @rollback[:last_route_snapshot] = @game.last_route(train)
            end

            route = Engine::Route.new(@game, @game.phase, train, hexes: trace, revenue: revenue)
            @round.routes << route
            @game.record_last_route!(train, trace, @cargo) if trace.size > 1

            mines = mines_visited(@cargo)
            @log << "#{entity.name} runs #{ship_label(train)} for #{@game.format_currency(revenue)} "\
                    "(#{mines} #{mines == 1 ? 'mine' : 'mines'} visited, "\
                    "#{@mp_spent}/#{@game.ship_distance(entity, train)} MP): #{trace.map(&:id).join(' - ')}"

            @route_stats_by_train[train] = { explored: @hexes_explored_this_trip, mines: mines, cargo: @cargo.dup }
            @ran_trains << train
            @trace = []
            @cargo = []
            @explored_in_trace = false
            @mp_spent = 0
            @selected_train_id = nil
            update_trace_highlight
            # No auto-pass here anymore, even once every ship has flown --
            # confirmed with the user: with routes built entirely client-
            # side, the corp's turn should never silently jump to Dividend
            # on its own. Ending the turn is always an explicit click on
            # "Submit All Routes" now (see pass_description/actions,
            # which -- also per that change -- no longer goes empty just
            # because available_trains/cancellable_trains are).
          end

          def cancel_route
            # Only reachable when nothing was explored this trace (choices/pass
            # both guard). Return picked-up ore loads: un-mark their mines so
            # another ship (or a re-trace) can use them this OR. Transshipment
            # credits (mine_idx: nil) have no mine state to un-mark -- they're
            # not a limited resource, so there's nothing to give back.
            @cargo.each { |c| @game.mark_mine_used!(c[:hex_id], c[:mine_idx], false) if c[:mine_idx] }
            @cargo = []
            @trace = []
            @explored_in_trace = false
            @mp_spent = 0
            @selected_train_id = nil
            update_trace_highlight
          end

          # Undoes an already-finished route (see cancellable_trains for the
          # eligibility rule): drops it from this OR's route list before
          # Dividend ever sees it (nothing has been paid out for plain
          # revenue yet -- only the flat exploration bonus pays immediately,
          # which is exactly why an explored route is never eligible here),
          # frees the ship to fly again this turn, and gives back any
          # picked-up ore the same way cancel_route does for an in-progress
          # trace.
          def cancel_completed_route(entity, train_id)
            train = @ran_trains.find { |t| t.id == train_id }
            return unless train

            stats = @route_stats_by_train[train]
            route = @round.routes.find { |r| r.train == train }
            @round.routes.delete(route)
            stats[:cargo].each { |c| @game.mark_mine_used!(c[:hex_id], c[:mine_idx], false) if c[:mine_idx] }
            @route_stats_by_train.delete(train)
            @ran_trains.delete(train)
            @log << "#{entity.name} cancels #{ship_label(train)}'s completed route"
          end

          # Starting point for a fresh @rollback -- see local_choose!.
          # rand is a single LCG integer (Game::Base#rand/#initialize_seed),
          # so snapshotting it here and restoring it verbatim in
          # rollback_local_flight! is enough to make a later real replay
          # draw identically to whatever the discarded local preview
          # already showed (tile rotation, Lucky's second-draw borrow) --
          # no need to separately track which random calls happened.
          def capture_rollback!
            {
              log_size: @log.size,
              rand: @game.rand_state,
              laid_hexes: [],
              mine_state_added: [],
              hex_assignment_originals: {},
              pickups: [],
              pilots_assigned: [],
              finished: false,
              finished_train: nil,
              last_route_snapshot: nil,
              hex_marks: [],
            }
          end

          # Precisely undoes everything local_choose! has mutated for real
          # since the last submit/discard -- explored hexes/mine reveals,
          # Lucky/Ice Finder/Drill Hound's borrowed tile assignments,
          # pickups, pilot assignments, the log tail, and (if the flight
          # had already finished locally) the route/ran-trains/last-route
          # bookkeeping finish_route recorded. A no-op when nothing's
          # pending (@rollback nil) -- true both when the player never
          # started a local flight and, deliberately, at the top of every
          # real replay (see replay_submitted_flight!), so a fresh reload
          # with no local state to undo behaves identically to the live
          # browser that just submitted.
          def rollback_local_flight!
            r = @rollback
            return unless r

            if r[:finished]
              train = r[:finished_train]
              @round.routes.pop
              @ran_trains.delete(train)
              @route_stats_by_train.delete(train)
              @game.restore_last_route!(train, r[:last_route_snapshot])
            end

            r[:laid_hexes].reverse_each do |e|
              hex = @game.hex_by_id(e[:hex_id])
              # Puts the revealed mine tile back in the Tile Manifest's
              # pool -- explore_hex! removed it on the way in (see its own
              # comment); discarding this preview means it was never
              # really revealed at all.
              @game.tiles << hex.tile
              hex.lay(e[:original_tile])
            end
            r[:mine_state_added].each { |hex_id| @game.mine_state.delete(hex_id) }
            r[:hex_assignment_originals].each { |hex_id, name| @game.hex_assignments[hex_id] = name }
            r[:pickups].each { |hex_id, idx| @game.mark_mine_used!(hex_id, idx, false) }
            r[:pilots_assigned].each { |source| @pilot_assignments.delete(source) }

            @game.rand_state = r[:rand]
            @log.slice!(r[:log_size]..-1) if @log.size > r[:log_size]

            @trace = []
            @cargo = []
            @explored_in_trace = false
            @mp_spent = 0
            @selected_train_id = nil
            @pending_redraw = nil
            @local_flight_log = []
            @hexes_entered = 0
            @rollback = nil
            @choices_memo = nil
            update_trace_highlight
          end

          # Wraps Game#explore_hex! so a local, unsubmitted flight can be
          # rolled back precisely (see rollback_local_flight!) -- records
          # the hex's pre-explore tile so it can be re-laid, and that
          # @mine_state gained a fresh entry so it can be dropped. A no-op
          # tracking-wise during a real replay (@rollback is nil there --
          # see rollback_local_flight!'s comment): nothing will ever need
          # to undo a real, committed explore. `pay:` is deferred to
          # @committing -- see Game#explore_hex!'s own comment.
          def explore_hex_tracked!(hex_id, entity)
            if @rollback
              hex = @game.hex_by_id(hex_id)
              @rollback[:laid_hexes] << { hex_id: hex_id, original_tile: hex.tile }
              @rollback[:mine_state_added] << hex_id
            end
            @game.explore_hex!(hex_id, entity, pay: @committing)
          end

          # Wraps Game#resolve_second_draw! the same way explore_hex_tracked!
          # wraps explore_hex! -- records each hex's original tile
          # assignment the first time it's touched (a flight may redraw
          # more than once, and each redraw touches two hexes: the one
          # being explored and whichever unexplored hex it borrowed from),
          # so rollback_local_flight! can restore the exact pre-draw state
          # regardless of how many redraws happened.
          def resolve_second_draw_tracked!(hex_id, chosen_name, borrowed_hex_id, other_name)
            if @rollback
              originals = @rollback[:hex_assignment_originals]
              originals[hex_id] = @game.hex_assignments[hex_id] unless originals.key?(hex_id)
              originals[borrowed_hex_id] = @game.hex_assignments[borrowed_hex_id] unless originals.key?(borrowed_hex_id)
            end
            @game.resolve_second_draw!(hex_id, chosen_name, borrowed_hex_id, other_name)
          end

          # The real, recorded handler for SUBMIT_FLIGHT -- rolls back
          # whatever local preview already happened (a no-op on a fresh
          # reload, which never ran one), then replays the submitted
          # choice sequence hop by hop through the exact same
          # dispatch_choice! table local_choose! used, with @committing
          # true so the exploration bonus actually gets paid and
          # finish_route's auto-pass can actually end the turn. Rolling
          # back first (rather than trusting the live browser's
          # already-correct local state) means the browser that submitted
          # and a browser that later reloads from raw_actions run through
          # an identical code path -- no separate "already did this"
          # special case to keep in sync.
          def replay_submitted_flight!(entity, choice)
            _prefix, rest = choice.split(':', 2)
            sequence = rest.to_s.split(FLIGHT_SEP)
            raise GameError, 'Empty submitted flight' if sequence.empty?

            rollback_local_flight!
            @committing = true
            sequence.each { |c| dispatch_choice!(entity, c) }
          ensure
            @committing = false
          end

          def update_trace_highlight
            @round.laid_hexes = @trace.dup
          end

          # public/icons/g_2038/ship_marker_0.svg .. _10.svg -- covers every
          # ship's distance (max printed is 9, +1 for Torch).
          SHIP_MARKER_MAX_MP = 10

          # public/icons/g_2038/ship_marker_<key>_<mp>.svg -- real per-ship
          # illustrations, added incrementally as each ship type's art is
          # extracted/generated (see ROADMAP.md Phase 12). Any train name
          # not listed here still falls back to the plain generic marker
          # set above. `max_mp` caps the badge value at this specific
          # ship's own real ceiling (base distance + Torch's +1), narrower
          # than the generic set's 0..10 range, since a real per-ship-type
          # marker can never need a value its own ship could never reach.
          SHIP_MARKER_ART = {
            'Probe' => { key: 'probe', max_mp: 4 },
            '3/2' => { key: '3_2', max_mp: 4 },
            '5/1' => { key: '5_1', max_mp: 6 },
            '4/3' => { key: '4_3', max_mp: 5 },
            '6/2' => { key: '6_2', max_mp: 7 },
            '5/4' => { key: '5_4', max_mp: 6 },
            '7/3' => { key: '7_3', max_mp: 8 },
            '6/5' => { key: '6_5', max_mp: 7 },
            '8/4' => { key: '8_4', max_mp: 9 },
            '7/6' => { key: '7_6', max_mp: 8 },
            '9/5' => { key: '9_5', max_mp: 10 },
            '9/7' => { key: '9_7', max_mp: 10 },
          }.freeze

          def ship_marker_icon_name(train, mp)
            art = train && SHIP_MARKER_ART[train.name]
            return "g_2038/ship_marker_#{mp}" unless art

            "g_2038/ship_marker_#{art[:key]}_#{[mp, art[:max_mp]].min}"
          end

          def double_mine_hex?(hex)
            @game.mine_state[hex.id]&.dig(:mines)&.size == 2
          end
        end
      end
    end
  end
end
