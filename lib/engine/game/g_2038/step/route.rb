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
          PILOT_SKIP = 'pilot_skip_'
          # The one real action a hand-flown route ever submits -- see
          # local_choose!/submit_flight_choice/replay_submitted_flight!.
          # A hand-flown flight can hit every choice type this step
          # supports (explore vs flyover, shortcuts, pickups, transship,
          # Lucky's redraw), so rather than deriving a separate replay
          # format, this just carries the literal sequence of `choice`
          # values the player clicked, replayed through the exact same
          # dispatch_choice! table that built it.
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

          # Suppresses Step::Base's generic "<entity> passes fly
          # spaceships" log line -- every real route decision this step
          # makes is already logged with specifics (route submitted,
          # ship declared no route, etc.), so the generic pass
          # announcement is just noise on top of that.
          def log_pass(_entity); end

          def help
            base = 'Click a base to launch, then click adjacent hexes to fly. '\
                   'While on a mine or transshipment point, click to pick up '\
                   'cargo. It cannot be jettisoned later. End route at a base '\
                   'or transshipment point to collect payment.'
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
            # Which already-submitted, still-cancellable route the single
            # "Clear Ship" control targets -- see select_completed_train!/
            # selected_completed_train.
            @selected_completed_train_id = nil
            # Trains the player has explicitly backed away from an
            # auto-filled (or any already-submitted) route for this turn
            # -- see cancel_completed_route/auto_actions' own comment.
            # Reset fresh each turn, same as everything else here.
            @auto_fill_declined = []
            # This OR's Growth Corp pilot assignments (Phase 8): pilot
            # source string ('LY'/'TH'/etc) => the Train it's assigned to.
            # Each inherited pilot gets its OWN ship -- never shared, never
            # doubled up on one ship -- explicitly chosen (or auto-assigned
            # when there's only one real pairing left), and always reset
            # here each OR since a fresh step instance is built every
            # round, mirroring 1822's Pullman-to-train assignment.
            @pilot_assignments = {}
            # Pilots the player has explicitly declined to place this OR --
            # see pilot_choices/PILOT_SKIP. Distinct from @pilot_assignments
            # (declining isn't a pairing), so a skipped pilot still counts
            # against nothing and simply drops out of the remaining
            # ambiguity for the rest of this OR. Reset here each OR, same
            # as @pilot_assignments -- a skip is a this-OR-only choice, not
            # permanent (there's nothing to persist: an unplaced pilot's
            # ship just goes unassigned, no different from any other OR
            # where a still-independent's ship pool doesn't stretch to
            # cover every inherited pilot).
            @pilots_skipped = []
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
            # Once every ship this entity owns has been flown/submitted
            # for the turn, compute_choices returns {} (current_train
            # is nil -- nothing left to launch), which made choices.key?
            # false for literally every hex, greying out the entire map
            # even though there was nothing left to click there -- the
            # only remaining action is the Submit All Routes button.
            # Found live in browser: the map stayed fully greyed out
            # after the last route of the turn was submitted.
            return true unless current_train(entity)

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
            # other.
            return {} if @rollback&.dig(:finished)

            pilot_choices(entity)
          end

          # A completed route may be undone -- but only the most recent ones
          # in an unbroken run of never-explored routes (walking backward
          # from the last ship flown this turn). The moment we hit an
          # explored route, it and everything before it are locked in for
          # good -- this is the reason ShipSelector's "Clear Selected
          # Route" stops offering those rows at all (see ship_rows'
          # `locked` flag/its own comment).
          #
          # This isn't just "exploration reveals hidden info" as a vague
          # principle (though the $10 bonus being paid immediately, not
          # deferred to Dividend, is one real reason on its own -- Cancel
          # only being safe pre-payout). Confirmed via a worked example
          # with the user: exploring a hex draws real, order-dependent
          # randomness from the engine's single seeded RNG stream --
          # every tile reveal's rotation (Game#explore_hex!) and every
          # Lucky/Ice Finder/Drill Hound "second draw" (Game#
          # borrow_second_tile, whose *candidate pool* is literally
          # "whichever hexes are still unexplored right now") both draw
          # from it. If an earlier, non-exploring route were reopened and
          # reflown differently, and the new attempt explored a hex the
          # original never touched, that inserts an extra draw ahead of
          # whatever a later route already explored -- on reload, replay
          # re-dispatches every action in order and draws from the same
          # stream again, so that already-locked-in later exploration
          # (or redraw) could reveal something else entirely. For a plain
          # rotation that's merely cosmetic drift, but for a redraw it can
          # hand a completely different mine to a completely different
          # hex -- and worse, a previously-recorded claim/pickup on a
          # tile that used to have two mines but redrew as a single-mine
          # tile crashes outright (Game#place_claim!/#pick_up index into
          # an array that's now one element short, raising instead of
          # failing safely). The only thing that removes the exploring
          # action from the log entirely -- taking its RNG draw out with
          # it, rather than trying to replay around it -- is the real
          # Undo button, which is why that one stays available regardless
          # of this lock; this in-turn Cancel is a narrower, partial
          # rewrite that can't offer the same guarantee.
          def cancellable_trains
            return [] unless @trace.empty?

            not_yet_locked_trains
          end

          # The same backward walk cancellable_trains does, minus its own
          # `@trace.empty?` gate -- that gate is right for cancellable_
          # trains' own purpose (you can't target an already-submitted
          # route for cancellation while mid-flight elsewhere), but wrong
          # for explore_would_lock_other_routes? below, which specifically
          # needs to ask this question *while* mid-flight (exploring only
          # ever happens mid-flight) -- cancellable_trains alone always
          # answered "[]" there, silently never warning at all. Found live
          # in browser: submitted one 3/2's route clean, then explored
          # with a second ship and got no popup at all.
          def not_yet_locked_trains
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

          # Public: for a train `cancellable_trains` has already locked
          # out, which train's own exploration is the reason -- walks
          # forward from `train` (the same @ran_trains order
          # not_yet_locked_trains itself walks backward through) to the
          # first one that actually explored, so a locked row's own
          # message can name (and color-match) the real cause instead of
          # a generic "something exploded" -- itself, if this train is
          # the one that explored, or a later one otherwise.
          def locking_train_for(train)
            index = @ran_trains.index(train)
            return nil unless index

            @ran_trains[index..].find { |t| @route_stats_by_train[t][:explored].positive? }
          end

          # Public: which already-submitted, still-cancellable route the
          # single "Clear Ship" control (ShipSelector's global button --
          # distinct from the per-row Cancel used for whichever ship is
          # actively mid-flight/pending-submit) currently targets. Pure UI
          # state, never a recorded action by itself -- only the resulting
          # button click is. nil once nothing's been clicked yet, or the
          # previously-selected one stopped being eligible (e.g. an
          # earlier ship's route got explored, locking the chain in front
          # of it -- see cancellable_trains).
          def selected_completed_train(entity)
            return nil unless @selected_completed_train_id

            cancellable_trains.find { |t| t.id == @selected_completed_train_id }
          end

          # Public: click handler for an already-submitted ship's row --
          # purely local UI selection, not a real action. Also drops
          # whichever *unrun* ship was the current build target (its own
          # selected-row highlight/Route:/Reset controls) -- confirmed
          # with the user: exactly one thing should ever be selected at a
          # time, not "the ship I'm building" and "the route I'm
          # targeting for cancel" simultaneously, each with its own
          # identically-styled black border, reading as two conflicting
          # selections at once.
          def select_completed_train!(train)
            @selected_completed_train_id = train.id
            @selected_train_id = nil
            @round.laid_hexes = []
          end

          # Public: the real, recorded choice string ShipSelector's single
          # "Clear Ship" button submits for a targeted already-submitted
          # route -- keeps CANCEL_COMPLETED's exact format a route.rb-only
          # concern rather than something the view needs to know how to
          # build.
          def cancel_completed_choice(train)
            "#{CANCEL_COMPLETED}#{train.id}"
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
          #
          # Whenever more pilots remain than ships could ever soak up --
          # exactly the "5 pilots, 3 ships" case the user hit -- some
          # pilots are always going to end up unplaced. Without a way to
          # decline one, the player has no say in *which* -- whichever
          # pilot happens to sort first always eats a ship, forced, before
          # the next one even gets offered. PILOT_SKIP (see dispatch_
          # choice!) lets them explicitly pass on the pilot currently
          # being offered instead, same one-axis-at-a-time flow, just with
          # an opt-out.
          def pilot_choices(entity)
            return {} unless @trace.empty?

            sources = @game.growth_corp_pilots(entity) - @pilot_assignments.keys - @pilots_skipped
            return {} if sources.empty?

            trains = available_trains(entity) - @pilot_assignments.values
            return {} if trains.empty?

            if trains.one? && sources.size > 1
              train = trains.first
              return sources.to_h { |s| ["#{PILOT}#{s}_#{train.id}", "Assign #{@game.class::PILOT_NAMES[s]}'s pilot to #{ship_label(train)}"] }
                             .merge(sources.to_h { |s| ["#{PILOT_SKIP}#{s}", "Skip #{@game.class::PILOT_NAMES[s]}'s pilot"] })
            end
            return {} if trains.size <= 1

            source = sources.first
            trains.to_h { |t| ["#{PILOT}#{source}_#{t.id}", "Assign #{@game.class::PILOT_NAMES[source]}'s pilot to #{ship_label(t)}"] }
                  .merge(PILOT_SKIP + source => "Skip #{@game.class::PILOT_NAMES[source]}'s pilot")
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
            # No @rollback bookkeeping here, deliberately -- a PILOT choice
            # is always its own separately-recorded real action (see
            # local_choose?'s own comment: PILOT is excluded from local
            # batching precisely so it never rides along inside a
            # *different* ship's still-local, discardable flight). An
            # earlier version of this method DID tuck the pairing into
            # @rollback[:pilots_assigned], meaning to protect it from a
            # different ship's Cancel -- but @rollback being non-nil here
            # only ever means *some* other flight happens to be mid-build
            # right now, not that this pairing is itself provisional.
            # rollback_local_flight! (see its own comment) would still
            # delete the pairing whenever that other flight's Cancel
            # happened to target the very ship this pilot was just
            # assigned to -- reversing an already-real, already-logged
            # action purely in this browser's own memory, with nothing in
            # the action log to say so. Found live: the player used
            # Cancel expecting to undo a pilot pick, got a fresh choice to
            # reassign it, and reloading the game (a full replay from the
            # real action log, which still had the *original* pairing)
            # rejected the reassignment as invalid -- the local-only
            # "undo" and the permanent action history had silently
            # diverged. Changing a pilot's mind now has to go through a
            # real Undo action instead, the same as undoing anything else
            # already committed.
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
            popup[explore_key] = 'Explore' if choices.key?(explore_key)
            popup[flyover_key] = 'Skip' if choices.key?(flyover_key)
            popup.size > 1 ? popup : nil
          end

          # Opt-in hook for assets/app/view/game/hex_choice_popup.rb: does
          # choosing `choice` right now actually explore `hex` (rather
          # than Skip/Flyover, which leaves it unrevealed), while at
          # least one *other*, already-submitted route from earlier this
          # turn is still eligible for "Clear Selected Route"? If so,
          # exploring here is about to permanently lock every one of
          # those routes for the rest of the turn (see cancellable_trains'
          # own comment on why an explored route can't be safely reopened
          # around) -- worth a confirmation before it happens, rather than
          # the player only discovering it afterward via ship_rows' own
          # greyed-out `locked` rows. Reuses hex_choice_popup's own
          # Explore/Skip labeling rather than re-deriving the explore-key/
          # flyover-key prefix logic (SHORTCUT_EXPLORE swaps which of the
          # two is the bare hex-id alias depending on whether the hex is a
          # direct neighbor or a shortcut destination) a second time.
          def explore_would_lock_other_routes?(entity, hex, choice)
            return false unless entity == current_entity
            # Not cancellable_trains -- that returns [] outright the
            # moment @trace isn't empty (mid-flight), which is exactly
            # when this question is actually being asked (see
            # not_yet_locked_trains' own comment).
            return false unless not_yet_locked_trains.any?

            hex_choice_popup(entity, hex)&.[](choice) == 'Explore'
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
          # "Submit All Routes ($X)" whenever nothing's locally pending --
          # replaces the old "Skip Remaining Ships"/"Done Flying" wording
          # (and their auto-pass-on-last-ship behavior, now removed from
          # finish_route): with every route built client-side, ending the
          # corp's turn is now always an explicit confirmation, regardless
          # of whether every ship has flown or the player is choosing to
          # leave some unflown. The $ total is every route already
          # submitted this turn, plus a still-pending preview for the ship
          # currently on screen (folded in because process_pass now
          # accepts that preview rather than discarding it -- see there),
          # so the button always reports what will actually be submitted
          # if clicked right now.
          def pass_description
            if @trace.empty? && @rollback&.dig(:finished) != true
              total = current_turn_routes(current_entity).sum(&:revenue)
              # Every still-unrun ship with a viable prior route on file
              # (see preview_last_route/ship_rows -- these show up
              # passively in the row list) gets folded into the total
              # too, since submit_all_routes! (ship_selector.rb) actually
              # submits them all, not just whichever ship is selected.
              available_trains(current_entity).each do |train|
                next if @auto_fill_declined.include?(train)

                preview = preview_last_route(current_entity, train)
                total += preview[:revenue] if preview
              end
              return "Submit All Routes (#{@game.format_currency(total)})"
            end

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
          # is real state other clients need to see change); and PILOT
          # (assigning a Growth Corp's inherited pilot to a specific
          # ship) -- that's meant to survive a *different* ship's local
          # route being discarded or submitted (see assign_pilot!'s own
          # comment), which local batching can't actually guarantee.
          # Found live in browser via the user's real game JSON: pilot
          # assigned to ship A, then ship B auto-run and submitted without
          # first submitting/clearing A's pick, bundled the pilot choice
          # into B's own @local_flight_log. rollback_local_flight! (run at
          # the top of every replay) correctly preserves a pilot pick
          # scoped to a *different* train than the one just finished --
          # but that leaves it already present in @pilot_assignments by
          # the time replay tries to re-dispatch it as if it were still an
          # open choice, and pilot_choices no longer offers an already-
          # assigned pilot, so replay failed with "Invalid route choice:
          # pilot_LY_...". Dispatching it for real immediately, the same
          # as CANCEL_COMPLETED, sidesteps the whole local/replay
          # divergence outright.
          def local_choose?(entity, choice)
            choice = choice.to_s
            entity == current_entity &&
              !choice.start_with?("#{SUBMIT_FLIGHT}:") &&
              !choice.start_with?(CANCEL_COMPLETED) &&
              !choice.start_with?(PILOT)
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
            if choice.to_s.start_with?(SHIP)
              # A ship pick is only ever meaningful as *the* current
              # selection, not a growing history of every one clicked
              # along the way -- SHIP can only be dispatched pre-launch
              # (ship_choices returns {} once @trace is non-empty), so
              # picking a different ship before actually launching always
              # means "never mind, fly this one instead," never a second,
              # later choice worth keeping alongside the first. Without
              # this, clicking through two or three ships before settling
              # on one stacked every one of those clicks into the
              # eventual flight log, and submitting re-dispatched each
              # stale SHIP token in turn along with the real route --
              # found live in browser via the user's own game JSON: a
              # submitted flight whose own log read "ship_3/2-7~
              # ship_3/2-6~ship_3/2-6~K9~..." for a route that was only
              # ever actually 3/2-6's, leaving both ships' rows looking
              # selected and a later click on either raising "Invalid
              # route choice."
              @local_flight_log.reject! { |c| c.start_with?(SHIP) }
            end
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
          # *any* local click (see local_choose!), including a bare
          # ship-tab selection that hasn't launched anything yet and has
          # nothing worth offering to cancel -- found live in browser: a
          # freshly-selected, never-launched ship's row showed a Cancel
          # button with nothing behind it to cancel.
          #
          # Deliberately does NOT treat a just-made pilot assignment as
          # "local, discardable" state (an earlier version did) -- PILOT
          # is excluded from local_choose? precisely because it's always
          # its own separately-recorded real action, never a preview (see
          # assign_pilot!'s own comment on the bug that came from treating
          # it as local anyway: the real Undo button/ctrl+z defers to
          # local_undo?, which mirrors this method, so a pilot pick being
          # reported as "local" made Undo silently discard it client-side
          # instead of issuing a real Action::Undo against the recorded
          # action -- reloading the game then replayed the *original*,
          # never-actually-undone pairing and rejected whatever the
          # player picked next as invalid). Reconsidering a pilot pick now
          # goes through the same real Undo as undoing anything else
          # already committed, which correctly rewrites the action log
          # instead of only this browser's own memory.
          def local_pass?(entity)
            entity == current_entity &&
              (!@trace.empty? || @rollback&.dig(:finished) == true)
          end

          def local_pass!(entity)
            rollback_local_flight!(entity)
          end

          # Opt-in hook for assets/app/view/game/actionable.rb: same
          # pending-local-state test as local_pass? (a hand-built route
          # has nothing real to undo until Submit -- see local_choose!'s
          # own comment) -- whenever it's true, the real Undo button/
          # ctrl+z targets this local state instead of reaching into the
          # real action log for the previous entity's last action.
          def local_undo?(entity)
            local_pass?(entity)
          end

          # One step back: the same single-hex rollback the in-place
          # "Undo (hex)" control already offers once at least one hex has
          # actually been flown (@rollback[:hex_marks].size > 1 -- the
          # first mark is always the launch hex itself, see
          # capture_rollback!/undo_last_hex!'s own comment). Before that
          # -- nothing flown yet, only a bare pilot assignment or a
          # freshly-selected ship tab -- there's no hex to step back from,
          # so this discards the local state outright instead (which,
          # with nothing flown, only ever means undoing that pilot
          # assignment).
          def local_undo!(entity)
            return unless @rollback

            if @rollback[:hex_marks].size > 1
              undo_last_hex!(entity)
            else
              rollback_local_flight!(entity)
            end
          end

          # Opt-in hook for assets/app/view/game/pass.rb: always suppressed
          # for this entity's own turn -- ShipSelector now renders its own
          # equivalent unconditionally (Clear Ship via local_pass!/
          # cancel_flight_button while something's pending, the real
          # Submit-All-Routes PassButton once nothing is), grouped with
          # the rest of the ship controls instead of appearing as a
          # separate standalone button elsewhere on the page. Previously
          # only suppressed while local_pass?(entity) was true (avoiding
          # showing "Cancel" in two places at once); now that
          # ShipSelector covers the not-pending case too, there's no
          # state left where the standalone button should show through.
          def suppress_standalone_pass?(entity)
            entity == current_entity
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

            rollback_local_flight!(entity)
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
            undoing_last_hex_reveals_tile? ? 'Undo (⚠️)' : 'Undo'
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

          # Public: the idle-controls Submit button's own label -- reads
          # straight off the selected ship's own passive preview (see
          # preview_last_route/ship_rows), since nothing's actually been
          # built yet at this point (that only happens once Submit or
          # Modify is clicked -- see render_idle_controls).
          def previous_route_submit_label(entity)
            train = current_train(entity)
            preview = train && preview_last_route(entity, train)
            preview ? "Submit (#{@game.format_currency(preview[:revenue])})" : 'Submit'
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
          # this OR (with their Explore/Mines column stats), so a
          # multi-ship entity doesn't lose sight of what each ship did once
          # it moves on to the next. Empty when there was never a real ship
          # choice to make (this entity has 1 or 0 trains total).
          #
          # `blocked` distinguishes "not clickable because mid-flight" (the
          # view should still respond to a click, with an explanatory flash
          # message) from "not clickable because this ship already finished
          # this OR" (a genuine dead end -- no message needed). `select_train`
          # is set only for an already-submitted route still eligible for
          # the single "Clear Ship" control (see select_completed_train!) --
          # distinct from `choice`, which would actually re-launch a ship,
          # not just target it for cancellation.
          def ship_rows(entity)
            # The Probe always leads, then slowest-ship-first for
            # everything else -- matches the same order the "start of
            # turn" auto-search uses for non-Probe ships (see
            # start_slowest_ship_search!/slowest_undeclined_train, which
            # excludes the Probe outright), so the ship the player would
            # want routed first also shows first. Per the user: the Probe
            # is a pure explorer, always dealt with before the fleet's
            # own routing order even matters. A display-only sort, local
            # to this method -- it never touches entity.trains' own
            # stored (acquisition) order, which other, unrelated shared
            # display code (e.g. the Spreadsheet tab's Trains column)
            # still expects to reflect when each ship was actually bought.
            trains = slowest_first(entity, @game.route_trains(entity))
            return [] if trains.empty?

            selected = current_ship_choice(entity)
            # Blocks switching ships both while actively flying and while
            # a just-finished flight is still awaiting Submit/Discard --
            # see compute_choices' matching guard.
            mid_flight = !@trace.empty? || @rollback&.dig(:finished)
            pending_train = @rollback&.dig(:finished_train)
            cancellable = cancellable_trains
            rows = trains.map do |train|
              if @ran_trains.include?(train)
                stats = @route_stats_by_train[train]
                route = @round.routes.find { |r| r.train == train }
                can_cancel = cancellable.include?(train)
                # Not unconditionally false -- a locally-finished,
                # not-yet-submitted flight (train == pending_train) is
                # still the one the player's action bar belongs to, same
                # as an unrun ship mid-flight below; only a genuinely
                # already-*submitted* route (any other @ran_trains entry)
                # is a settled fact, selected only if it's the one the
                # "Clear Ship" control currently targets.
                is_pending = train == pending_train
                is_selected = is_pending || (can_cancel && train.id == @selected_completed_train_id)
                # Locked: a later route this turn already explored a hex,
                # so this one's own submission can never be safely
                # reopened (see cancellable_trains' own comment -- a
                # replayed reopen risks the game drawing a different
                # tile/rotation than it actually did live). Never true
                # for the currently-pending flight, which is still fully
                # live via its own Submit/Clear bar, not settled history.
                # Flagged separately from `blocked` (an unrun ship
                # mid-flight, below) so ShipSelector can grey this row
                # out and explain *why* on click, instead of a locked
                # route looking identical to a still-cancellable one and
                # silently doing nothing when clicked. Confirmed with the
                # user: previously non-cancellable rows had no click
                # handler and no visual distinction at all, which read as
                # "this button is broken" rather than "this is settled."
                locked = !can_cancel && !is_pending
                locking_train = locking_train_for(train) if locked
                { choice: nil, blocked: false, locked: locked, select_train: (can_cancel ? train : nil),
                  label: ship_label(train), selected: is_selected, train_id: train.id,
                  stats: stats && route_stats(stats[:explored], stats[:cargo]),
                  revenue: route && @game.format_currency(route.revenue),
                  color_index: route_color_index(entity, train),
                  locked_by_label: locking_train && ship_label(locking_train),
                  locked_by_color_index: locking_train && route_color_index(entity, locking_train),
                  found_at: @auto_all_found_at&.dig(train.id) }
              else
                ship_choice = "#{SHIP}#{train.id}"
                is_selected = ship_choice == selected
                live_stats = nil
                live_revenue = nil
                is_preview = false
                if mid_flight && is_selected
                  live_stats = route_stats(@hexes_explored_this_trip, @cargo)
                  live_revenue = @game.format_currency(@game.trace_revenue(entity, train, @trace, @cargo))
                elsif (preview = preview_last_route(entity, train))
                  # Not gated on !mid_flight -- a *different* ship's own
                  # already-hand-flown-elsewhere-blocked row still has a
                  # perfectly good preview to show; the player's just not
                  # allowed to act on it right now (see `blocked` below),
                  # not that it stopped existing. Confirmed with the
                  # user: blanking it while mid-flight elsewhere read as
                  # data loss, not a temporary lock.
                  is_preview = true
                  explored = preview[:hexes].count { |h| needs_exploration?(h) }
                  live_stats = route_stats(explored, preview[:cargo])
                  live_revenue = @game.format_currency(preview[:revenue])
                end
                { choice: mid_flight ? nil : ship_choice, blocked: mid_flight && !is_selected,
                  select_train: nil, label: ship_label(train), selected: is_selected, train_id: train.id,
                  stats: live_stats, revenue: live_revenue, color_index: route_color_index(entity, train),
                  preview: is_preview }
              end
            end
          end

          # Public: {train => hexes} for every still-unrun ship's own
          # passively-previewed prior route (see preview_last_route/
          # ship_rows) -- lets the map draw all of them simultaneously
          # instead of just the one ship on screen, matching ship_rows'
          # own "show every ship's history at once" change. A Hash (not
          # just the hexes) so View::Game::Map#render_route_lines can look
          # each train's own route_color_index up directly, rather than
          # assuming draw order lines up with row color -- it doesn't,
          # the moment a submitted route or the live ship join the same
          # pass and shift how many entries are even being drawn. The
          # @trace.empty?
          # gate alone is enough to exclude whichever ship is actually
          # mid-flight (only one ship's trace is ever live at a time) --
          # Modify/Submit/Auto all apply-then-consume a route within a
          # single click, so there's no separate "actively selected but
          # not yet built" ship to exclude anymore.
          def previewed_ship_routes(entity)
            return {} unless entity == current_entity
            return {} unless @trace.empty?

            slowest_first(entity, available_trains(entity)).each_with_object({}) do |train, h|
              route = preview_last_route(entity, train)
              h[train] = route[:hexes] if route
            end
          end

          # Public: the ship currently being searched by a live Auto-all
          # run, plus its current best hexes so far -- nil (either) unless
          # there's something real to show. Deliberately separate from
          # previewed_ship_routes above: that one shows a NOT-yet-run
          # ship's own last-recorded (settled) route; this shows the
          # CURRENTLY-searching ship's still-changing, unsettled best,
          # drawn with a dashed line on the map (see map.rb's
          # render_route_lines) so it reads as "still under test," never
          # confusable with a real, finished route.
          def auto_route_all_preview_hexes(entity)
            return [nil, nil] unless auto_route_all_active?(entity) && @auto_all_final_train

            hexes = @game.optimal_autorouter.best_hexes
            return [nil, nil] unless hexes

            [@auto_all_final_train, hexes]
          end

          # Public: this train's own fixed color slot, same convention
          # the standard RouteSelector already uses (route_selector.rb:
          # `route_prop(@routes.index(route), :color)` -- @routes built
          # once per turn, in a stable order, never reshuffled by what's
          # submitted/active/previewed) -- a ship's color is tied to its
          # position in the fleet, not to what state it's currently in.
          # Previously recomputed per-role (submitted, then the one live
          # slot, then every preview after that), which meant a ship's
          # color visibly changed the moment it went from previewed to
          # active, or from active to submitted -- confirmed with the
          # user this read as a bug, not a feature, once seen live.
          # nil for a ship with no route currently drawn at all (not yet
          # run, not selected, no pending suggestion, no viable prior
          # route to preview) -- same as the standard selector only
          # coloring a row once it actually has a route object to draw.
          def route_color_index(entity, train)
            has_route = current_turn_routes(entity).any? { |r| r.train == train } ||
              (train == current_train(entity) && !live_route_hexes(entity).empty?) ||
              previewed_ship_routes(entity).key?(train)
            return nil unless has_route

            slowest_first(entity, @game.route_trains(entity)).index(train)
          end

          # Public: whether "Suggest Route" is meaningful right now -- a
          # ship must be selected (single-ship case auto-resolves this; a
          # multi-ship entity needs its tab clicked first, same as
          # launching by hand) and not already mid-flight, since the
          # autorouter always plans a fresh flight from a base, never a
          # continuation of one already underway. Whether the autorouter
          # is available *at all* for this game instance (the site's own
          # per-instance auto_routing setting) is a view-level concern --
          # see ship_selector.rb#autorouting_allowed? -- not something
          # the engine checks; every other game's own AutoRouter-backed
          # Auto button is gated the same way, entirely outside the step.
          # The Probe (TSI's pre-float ship) is excluded outright, not
          # just left to find nothing worth suggesting -- confirmed with
          # the user: its whole "route" is exploration, and which hex to
          # explore next is a player call the autorouter has no business
          # optimizing (it always earns $0 by design, so "best revenue"
          # is meaningless for it anyway).
          def suggestable?(entity)
            return false if @rollback&.dig(:finished)
            return false if current_train(entity)&.name == 'Probe'

            @trace.empty? && !current_train(entity).nil?
          end

          # Public: whether this ship finished a run in some earlier OR
          # that "Modify"/"Submit" (see render_idle_controls) could try to
          # replay -- cheap to check (just a hash lookup), independent of
          # whether that route is still fully flyable today;
          # preview_last_route is the one that actually re-validates it
          # hop by hop against current state.
          def previous_route_available?(entity)
            return false unless suggestable?(entity)

            !@game.last_route(current_train(entity)).nil?
          end

          # Public: builds `train`'s last-recorded route as a local,
          # finished-but-not-yet-submitted flight -- preview_last_route's
          # own replay logic, applied for real (see apply_pending_
          # suggestion!) rather than just displayed. Selects the ship
          # first (mirroring the row-click a player would do by hand) so
          # it works for any unrun ship, not only whichever one already
          # happens to be selected. Used by "Submit All Routes" to rebuild
          # every still-unrun, non-declined ship from its last-OR route in
          # one click. Returns true if a route was actually built (ready
          # for finish_and_submit_choice), false if there's nothing on
          # record, it's no longer viable, or the ship was explicitly
          # declined (Clear Ship) this turn -- an explicit decline
          # shouldn't get silently resubmitted anyway just because
          # "Submit All Routes" swept it up, any more than ship_rows' own
          # passive preview still shows it. The caller should just move
          # on to the next ship either way.
          def apply_previous_route!(entity, train)
            return false if @auto_fill_declined.include?(train)

            suggestion = preview_last_route(entity, train)
            return false unless suggestion

            local_choose!(entity, "#{SHIP}#{train.id}") if available_trains(entity).size > 1
            apply_pending_suggestion!(entity, suggestion)
            true
          end

          # Public: hands a computed suggestion (see preview_last_route,
          # for Modify/Submit, or suggestion_from_result, for Auto) off
          # to hand-flying -- every caller lands in the exact same place:
          # a fully local, not-yet-submitted flight the player can either
          # Submit as-is or back out of the tail end (clicking the
          # route's own endpoint, repeatedly, to taste) and fly on from
          # wherever they backed up to.
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
          def apply_pending_suggestion!(entity, suggestion)
            return unless suggestion

            @round.laid_hexes = []

            hexes = suggestion[:hexes]
            cargo_by_hex = suggestion[:cargo].group_by { |c| c[:hex_id] }

            local_choose!(entity, hexes.first.id)

            hexes.each_cons(2) do |from, to|
              break if @trace.empty? # maybe_auto_finish! already closed it out

              # A suggestion never *explores* a hex it doesn't need to
              # (the autorouter never reveals a tile speculatively), but
              # it does fly straight
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

          # Shared Probe-then-slowest-first ordering -- see ship_rows'
          # own comment for the full reasoning. Pulled out so other
          # per-ship walks (previewed_ship_routes, best_ship_order) offer
          # ships in the same order they're displayed in, rather than
          # entity.trains' raw acquisition order.
          def slowest_first(entity, trains)
            trains.sort_by { |t| [t.name == 'Probe' ? 0 : 1, @game.ship_distance(entity, t)] }
          end

          # Public: whether the joint "Auto" (autoroute every still-
          # unfilled ship -- see best_ship_order/build_ship_route!) has
          # anything to work with right now. Deliberately not scoped to
          # any one selected ship (unlike suggestable?, which previous_
          # route_available? and the per-ship "Last" flow still use) --
          # per the user, this button's whole point is routing everything
          # still unfilled in one click, so it only needs *some* unrun,
          # non-Probe ship to exist, not a specific one picked first.
          def any_suggestable?(entity)
            return false if @rollback&.dig(:finished)
            return false unless @trace.empty?

            available_trains(entity).any? { |t| t.name != 'Probe' }
          end

          # Public: how many still-unfilled, non-Probe ships a joint "Auto"
          # click would have to jointly order -- ship_selector.rb uses this
          # to warn before a 4-ship click, the one case (AL only, Phases
          # IV-V) where the ranking phase's ordering count (4! = 24, even
          # after start_auto_route_all!'s own dedup/pruning) can still make
          # a single click slow. Per the user: rather than engineer around
          # a rare worst case, just suggest flying one ship by hand first
          # -- available_trains already only returns still-unfilled ships,
          # so that alone drops this back to the cheap 3-ship case with no
          # engine changes needed.
          def unfilled_ship_count(entity)
            available_trains(entity).count { |t| t.name != 'Probe' }
          end

          # Public: searches for and locally builds (finish_route, not
          # yet submitted) `train`'s best route -- callable for any
          # specific train, not just current_train. Selects the ship
          # first if more than one remains unrun (must go through
          # local_choose! rather than a bare @selected_train_id
          # assignment, so the rest of this entity's state stays
          # consistent with whichever ship is actually being built).
          # Returns the Autorouter::Result if a route was found and
          # applied, nil (having already logged "No profitable route
          # found") if not -- shared by both best_ship_order's own
          # discarded trial orderings and the real, final application of
          # whichever ordering wins (see ship_selector.rb's
          # auto_route_all_button).
          # Ranking trials used to run the old heuristic Autorouter here,
          # capped at the same `timeout` (TRIAL_TIMEOUT). Measured
          # side-by-side under that exact cap on a real board: the new
          # OptimalAutorouter's ceiling-descending combo order means its
          # "best so far" at 4s already matched or beat what a full,
          # uncapped proof search later confirmed as optimal, while the
          # old engine's 4s answer was $60-100 short every time on the
          # same ships. Since ranking only needs a good revenue ESTIMATE
          # per ordering (the real, final build for whichever ordering
          # wins already goes through the full uncapped new engine via
          # auto_route_all_tick! below), swapping this trial call to the
          # new engine's own chunked interface -- bounded externally by
          # `timeout` exactly like a single old-engine call was -- gives
          # strictly better ranking data for the same time spent.
          #
          # result.proven_optimal is force-corrected to `done` below --
          # NOT a no-op. finish_chunk!'s own proven_optimal only tracks
          # whether OptimalAutorouter's internal tolerance-stop mechanism
          # fired (@stopped_at_tolerance); it has no idea this method's
          # OWN external `deadline` cut the search short first. Left
          # alone, EVERY capped trial call came back claiming
          # proven_optimal: true regardless of whether it actually
          # finished -- harmless back when only .revenue/.hexes/.cargo
          # were ever read here, but became a real, silent correctness
          # bug once try_ordering!'s cached[] (and, through it,
          # auto_route_all_tick!'s final-build reuse) started trusting
          # proven_optimal to mean "this is genuinely the full answer,
          # safe to apply verbatim instead of re-searching." Found live:
          # ship 1's own solo search (no other ship's claims to react to,
          # so fully deterministic) proved $460 fresh, but a real 3-ship
          # Auto run submitted only $420 for it -- a capped, 4s ranking-
          # trial guess that never got a real uncapped search at all
          # because it was wrongly cached as already-proven.
          def build_ship_route!(entity, train, timeout: Autorouter::DEFAULT_TIMEOUT)
            router = @game.optimal_autorouter
            router.start_chunk!(entity, train, tolerance_pct: 0)
            deadline = Time.now + timeout
            done = false
            loop do
              done = router.run_one_chunk!
              break if done || Time.now > deadline
            end
            result = router.finish_chunk!
            result.proven_optimal = done if result
            apply_ship_result!(entity, train, result)
          end

          # Shared by build_ship_route! above (the synchronous path, still
          # used by try_ordering!'s ranking trials) and the chunked final-
          # build loop in auto_route_all_tick! below, so there's only one
          # place a found Result actually gets turned into a local route.
          def apply_ship_result!(entity, train, result)
            suggestion = suggestion_from_result(train, result)
            return nil unless suggestion

            local_choose!(entity, "#{SHIP}#{train.id}") if available_trains(entity).size > 1
            apply_pending_suggestion!(entity, suggestion)
            result
          end

          # The joint "autoroute everything still unfilled" search (the
          # global "Auto" button -- see ship_selector.rb's auto_route_
          # all_button) -- per the user, two ships autorouted individually
          # one after another can total less revenue than routing them
          # together in a different order (whichever goes first gets
          # first pick of every mine), so the single-ship search alone
          # can't be trusted once more than one ship is involved. With at
          # most 4 ships this game ever hands any one entity, exhaustively
          # trying every ordering (<=4! = 24) and keeping the best-
          # scoring one is cheap enough to just do outright rather than
          # reach for a heuristic. Driven from start_auto_route_all!/
          # auto_route_all_tick! below, one ordering (via try_ordering!,
          # just below) or one real ship build per call.
          #
          # TRIAL_TIMEOUT, not the caller's own `timeout:`, bounds each
          # ordering trial -- the "<=24 orderings, cheap enough to just do
          # outright" reasoning above only counts *orderings*, not
          # searches: each ordering runs build_ship_route! once per ship
          # in it, so the real total is up to N x N! individual Autorouter
          # searches (96 for 4 ships), not 24. Each one already respects
          # its own per-call timeout -- nothing here was ever unbounded --
          # but with nothing capping how many of them run, passing the
          # user's full route_timeout (a Tools-tab setting, sometimes set
          # generously high) through to all 96 turned "click Auto" into an
          # up to N x N! x route_timeout wall-clock hang, indistinguishable
          # from the timeout being ignored entirely. Found live in
          # browser. Every trial is rolled back regardless of outcome (see
          # try_ordering!) and exists only to *rank* orderings against
          # each other -- unlike the final per-ship pass (which actually
          # keeps its results and rightly uses the user's real timeout),
          # it was never the source of an applied result and doesn't need
          # that same budget.
          TRIAL_TIMEOUT = 4.0

          # One ordering's worth of the search above -- shared by both
          # start_auto_route_all!/auto_route_all_tick! below (the only
          # caller now; this used to also back a synchronous best_ship_
          # order, since replaced by the chunked flow) so there's only one
          # place this build-then-roll-back logic can drift. Every ship in
          # `order` is actually built (so later ships in the ordering see
          # the earlier ones' mines/stations already claimed, the whole
          # reason ordering matters at all) then fully unwound in reverse
          # before returning.
          #
          # `current_best_total` (the best confirmed total from orderings
          # already tried) lets this bail out of `order` early once it's
          # provably unable to win: before building each remaining ship,
          # `ceiling_remaining` is the sum of Autorouter#solo_ceiling for
          # every not-yet-built ship in this order -- an admissible (never
          # too low) upper bound on what they could contribute even with
          # the whole board to themselves, ignoring MP cost and ignoring
          # that an earlier ship here may have already claimed the best of
          # it. If what's already been earned plus that generous ceiling
          # still can't beat current_best_total, no real search of the
          # remaining ships can possibly change the outcome -- so this
          # order is abandoned (whatever wasn't built simply doesn't add
          # to `total`, correctly scoring this order as a loss) without
          # spending real search time proving it more precisely. Confirmed
          # safe by the user: an over-estimate can only ever fail to prune
          # a hopeless order early, never wrongly discard a genuinely-
          # better one.
          def try_ordering!(entity, order, timeout, current_best_total)
            ceiling_remaining = order.sum { |t| @game.autorouter.solo_ceiling(entity, t) }
            rollbacks = []
            total = 0
            # A ship's trial result is only safe to reuse verbatim in the
            # final-build phase (see auto_route_all_tick!) if its own
            # precondition -- everything earlier ships in THIS ordering
            # left behind -- is guaranteed to be identical there too.
            # That only holds for a PREFIX of ships whose own trial
            # results were each proven_optimal (not merely the best found
            # within `timeout`): a capped, unproven result could differ
            # from what an uncapped final search finds for that same
            # ship, which would change what's left for every ship after
            # it. The first non-proven (or unbuilt, pruned-away) ship
            # ends the reusable prefix; cached stops growing from there,
            # even if trailing ships happened to also prove optimal.
            cached = {}
            chain_valid = true
            # Different orderings sharing the same leading ships (any
            # ordering starting with the same first ship, say, or the
            # same first two, etc.) face an IDENTICAL board at that
            # point, so build_ship_route! -- deterministic given the same
            # starting state and the same TRIAL_TIMEOUT cap -- would
            # search and find the exact same thing again. Found live in
            # browser console: two separate trials' heartbeat lines were
            # byte-for-byte identical (same combos/elapsed/bound/search
            # counts) because both orderings happened to share a first
            # ship. @auto_all_prefix_cache (reset per Auto click, see
            # start_auto_route_all!) is keyed by the ship-id sequence
            # seen so far THIS trial, shared across every trial in the
            # whole ranking phase -- a repeat prefix skips straight to
            # re-applying the previously found result (still needed, to
            # consume the same mines for whatever ship comes next in
            # THIS trial) instead of re-searching. Safe regardless of
            # proven_optimal: every trial in the ranking phase runs under
            # the identical TRIAL_TIMEOUT cap, so reusing a capped result
            # is exactly as valid as reusing a proven one here (unlike
            # the final-build cache below, which mixes a capped trial
            # against an uncapped real build and so requires proof).
            @auto_all_prefix_cache ||= {}
            prefix_ids = []

            order.each do |train|
              break if total + ceiling_remaining <= current_best_total

              ceiling_remaining -= @game.autorouter.solo_ceiling(entity, train)
              prefix_ids << train.id
              prefix_key = prefix_ids.join(',')

              @rollback = capture_rollback!
              memo = @auto_all_prefix_cache[prefix_key]
              result = memo ? apply_ship_result!(entity, train, memo) : build_ship_route!(entity, train, timeout: timeout)
              @auto_all_prefix_cache[prefix_key] ||= result if result
              total += result.revenue if result
              rollbacks << @rollback

              if chain_valid && result&.proven_optimal
                cached[train.id] = result
              else
                chain_valid = false
              end
            end

            rollbacks.reverse_each do |r|
              @rollback = r
              rollback_local_flight!(entity)
            end

            { total: total, cached: cached }
          end

          # Chunked equivalent of "compute best_ship_order, then actually
          # build+submit each ship in that order" -- ship_selector.rb's
          # auto_route_all_button used to do this as one giant synchronous
          # call (up to a couple of minutes even with TRIAL_TIMEOUT
          # already capping the worst case -- found live in browser: a
          # "semi-responsive" tab, scroll working but tab-switch not, for
          # the entire multi-minute duration of a 3-ship Auto click).
          # Restructured onto the same one-bounded-unit-of-work-per-tick
          # idea Autorouter#resume_async! already uses for a single ship's
          # own search -- one *ordering trial* per tick during ranking,
          # then one *ship build* per tick during the real final pass --
          # so the caller can yield (a real setTimeout, same as
          # Autorouter's own) between ticks instead of blocking the
          # browser for the whole operation. State lives entirely on this
          # step instance (long-lived on @game.round.steps for the whole
          # round, unlike a view component that a store(:game, ...) call
          # mid-flow could tear down and rebuild) so the view-layer caller
          # can safely resume across ticks purely by calling
          # auto_route_all_tick! again -- it never needs to hold any
          # state of its own besides "keep calling until :done".
          #
          # Deliberately does NOT submit the built route itself
          # (Action::Choose/process_action are Actionable/view-layer
          # concerns, not this step's) -- returns :built so the caller
          # knows a route was just built and it's their turn to submit it
          # before the next tick, :ranking for a trial tick with nothing
          # to submit, or :done once there's nothing left to do at all.
          # Orderings are deduplicated by ship *name*, not object identity --
          # two same-named ships (a twin pair, say two 6/5s) are fully
          # interchangeable as far as the search is concerned (only
          # distance/cargo_holds ever matter, never which physical ship
          # object), so swapping their positions in an ordering can never
          # change the outcome. trains.permutation.to_a treats them as
          # distinct anyway, so without this a twin pair doubles the real
          # work for no possible gain (a triplet multiplies it by 6).
          #
          # The surviving orderings are then resorted so whichever one
          # matches "longest range first" (ships sorted by ship_distance,
          # descending) is tried first, not wherever permutation happened
          # to place it -- the ship with the most to lose from going last
          # is a reasonable guess at the best order, and trying it first
          # means try_ordering!'s own cross-ordering pruning (see its own
          # comment) has a real, high bar to prune every later ordering
          # against from the very start, instead of ratcheting up slowly.
          # This never risks correctness -- every ordering the dedup above
          # kept is still fully tried, just not necessarily in permutation
          # order.
          def start_auto_route_all!(entity, timeout:)
            @auto_all_entity = entity
            @auto_all_trial_timeout = [timeout, TRIAL_TIMEOUT].min
            @auto_all_final_timeout = timeout
            trains = available_trains(entity).reject { |t| t.name == 'Probe' }
            orderings = trains.size <= 1 ? [] : trains.permutation.to_a.uniq { |order| order.map(&:name) }
            # A SINGLE surviving ordering has nothing to be ranked
            # against, so trialing it is pure waste -- found live in
            # browser with twin 6/5s (whose two permutations dedup to
            # one): 6 of the run's 8 total seconds went to "ranking" the
            # only possible order before building it for real.
            orderings = [] if orderings.size == 1
            unless orderings.empty?
              heuristic_first = trains.sort_by { |t| -@game.ship_distance(entity, t) }
              orderings = [heuristic_first, *(orderings - [heuristic_first])] if orderings.include?(heuristic_first)
            end
            @auto_all_orderings = orderings
            @auto_all_best_order = trains
            @auto_all_best_total = -1
            @auto_all_cached_results = nil
            @auto_all_prefix_cache = {}
            # Per-ship snapshot of found_at_ratio, captured the instant
            # each ship's own final search completes (see the final-build
            # loop below) -- unlike @game.optimal_autorouter's own live
            # value, this survives past that ship's own turn so its row
            # can keep showing "how early was this found" after the fact,
            # not just while it's the currently active ship. Never
            # populated for a ship served from the ranking-trial cache
            # (@auto_all_cached_results) -- that reuses a result from a
            # trial's own, already-discarded router instance, with no
            # found_at history of its own to carry over.
            @auto_all_found_at = {}
            @auto_all_trial_index = 0
            @auto_all_final_index = 0
            @auto_all_final_train = nil
            @auto_all_started_at = Time.now
            @auto_all_finished_at = nil
            # Hard backstop, independent of every lower-level timeout --
            # found live in browser: a single-ship run kept climbing well
            # past 2000s, far beyond any timeout actually configured, for
            # reasons never fully pinned down (most likely two overlapping
            # tick-chains, e.g. a fast double-click before the Auto button
            # had a chance to re-render as hidden, each independently
            # driving the same shared step/Autorouter state). Rather than
            # only trusting Autorouter's own internal per-search deadline
            # to always fire correctly, this caps the *entire* multi-ship
            # operation at a generous but genuinely finite multiple of its
            # own worst-case legitimate cost, so a bug anywhere in the
            # chain still can't run forever -- see the check at the top of
            # auto_route_all_tick!.
            # The final phase now runs OptimalAutorouter (uncapped -- it
            # runs to proof, no route_timeout involved), so its slice of
            # the backstop can't be derived from a configured timeout any
            # more; a generous flat per-ship allowance replaces it (an
            # hour per ship -- far past anything observed even on the
            # worst real board tested, ~168s in-browser, while still
            # genuinely finite).
            worst_case_trials = orderings.size * @auto_all_trial_timeout * [trains.size, 1].max
            worst_case_final = 3600 * [trains.size, 1].max
            @auto_all_deadline = @auto_all_started_at + worst_case_trials + worst_case_final + 30
            @auto_all_active = true
          end

          def auto_route_all_tick!(entity)
            if @auto_all_deadline && Time.now > @auto_all_deadline
              @game.log << "#{entity.name}'s Auto route search was stopped after exceeding its own worst-case " \
                           'time budget -- this should never happen; please report it.'
              @auto_all_active = false
              @auto_all_final_train = nil
              @auto_all_finished_at = Time.now
              return :done
            end

            if @auto_all_trial_index < @auto_all_orderings.size
              order = @auto_all_orderings[@auto_all_trial_index]
              result = try_ordering!(entity, order, @auto_all_trial_timeout, @auto_all_best_total)
              if result[:total] > @auto_all_best_total
                @auto_all_best_total = result[:total]
                @auto_all_best_order = order
                @auto_all_cached_results = result[:cached]
              end
              @auto_all_trial_index += 1
              return :ranking
            end

            # Chunked (start_chunk!/run_one_chunk!/finish_chunk!), not a
            # single blocking call, so the live clock keeps updating and
            # the tab stays responsive throughout each ship's search.
            #
            # The final builds run OptimalAutorouter (the "optimal set"
            # engine -- see optimal_autorouter.rb), not the original
            # Autorouter: per the user, after side-by-side Compare runs
            # showed it consistently matching the old engine's answers
            # while proving optimality in a fraction of the time (168s vs
            # 763s in-browser on the worst real board tested), it takes
            # the primary slot. The RANKING TRIALS above (build_ship_
            # route!, called from try_ordering!) also run OptimalAutorouter
            # now, via its own chunked interface bounded externally by
            # TRIAL_TIMEOUT rather than run to proof -- measured
            # side-by-side against the old engine under that same short
            # cap, it landed on the true optimal revenue (later confirmed
            # by an uncapped run) while the old engine's 4s answer was
            # $60-100 short on every ship tried. The original Autorouter
            # class stays in the codebase only for Autorouter#solo_ceiling
            # (try_ordering!'s own cross-ordering pruning bound, unrelated
            # to which engine actually searches for a route).
            #
            # @auto_all_cached_results (set alongside @auto_all_best_order
            # in the ranking branch above -- see try_ordering!'s own
            # comment on the prefix-validity reasoning) lets a ship whose
            # ranking trial already reached proven_optimal within
            # TRIAL_TIMEOUT skip a second, identical search here entirely:
            # on a simple board the ranking phase can fully solve a ship
            # in well under 4s, and re-running that same deterministic
            # search a second time (once per ordering trial already,
            # trials can number up to N!, and then again here) would
            # waste real time proving the same already-proven answer
            # again for nothing. Both the ranking trial and this final
            # build always run to full proof (tolerance_pct: 0, the only
            # mode now that the user's own accuracy dial is gone -- see
            # try_ordering!/build_ship_route!) -- since both stages run
            # the identical deterministic search under identical
            # conditions, a cached ship's route is guaranteed to be
            # exactly what a real (re-)search would produce anyway. A
            # user manually cutting a ship's OWN final build short via
            # "Accept & next ship" doesn't affect this: that only ever
            # touches the ship being built live, never a ranking trial,
            # so it can't poison what gets cached for a later ship.
            while @auto_all_final_index < @auto_all_best_order.size
              train = @auto_all_best_order[@auto_all_final_index]
              unless available_trains(entity).include?(train)
                @auto_all_final_index += 1
                next
              end

              if @auto_all_final_train.nil? && (cached = @auto_all_cached_results&.dig(train.id))
                @auto_all_final_index += 1
                next unless apply_ship_result!(entity, train, cached)

                return :built
              end

              router = @game.optimal_autorouter
              router.start_chunk!(entity, train, timeout: @auto_all_final_timeout) if @auto_all_final_train != train
              @auto_all_final_train = train

              return :searching unless router.run_one_chunk!

              @auto_all_final_train = nil
              @auto_all_final_index += 1
              result = router.finish_chunk!
              # Captured before apply_ship_result! moves on to the next
              # ship's own start_chunk! (which would reset the router's
              # internal found_at bookkeeping) -- see ship_rows' own use
              # of this, and ship_selector.rb's per-user request to keep
              # showing "how early was this found" on a ship's row after
              # it finishes, not just while it's the live one.
              @auto_all_found_at[train.id] = router.found_at_ratio
              next unless apply_ship_result!(entity, train, result)

              return :built
            end

            @auto_all_active = false
            @auto_all_final_train = nil
            @auto_all_finished_at = Time.now
            :done
          end

          # Live progress, read directly off this (long-lived, one-per-
          # round -- NOT one-per-entity) step instance rather than through
          # Snabberb's own store mechanism -- found live in browser: a
          # `needs ...store: true` key on the view component alone did NOT
          # survive the repeated store(:game, ...) re-renders the tick-
          # chain and live-clock both trigger, staying permanently nil
          # even though the search itself completed and submitted real
          # routes correctly. This step object's own @auto_all_* ivars, by
          # contrast, are already proven to survive that exact same
          # repeated-re-render sequence (that's how the tick-chain itself
          # keeps working across ticks) -- so the view just reads them
          # fresh each render instead of trying to mirror them into a
          # second, less reliable place.
          #
          # `entity` here guards against a second bug this same sharing
          # caused: since this ONE step instance's @auto_all_* ivars are
          # shared across every corp's turn all round, they kept showing
          # whichever corp's run happened most recently even while looking
          # at a totally different corp that never had Auto clicked at
          # all -- found live in browser: AL's own panel showing "210.1s"
          # left over from an earlier corp's finished run. Only report
          # anything when the caller's current entity matches whichever
          # entity start_auto_route_all! was actually invoked for.
          def auto_route_all_active?(entity)
            @auto_all_active && entity == @auto_all_entity
          end

          # Public: user-initiated "accept this ship's current best and
          # move on" (see ship_selector.rb's skip button). Only
          # meaningful during the final phase while the engine actually
          # holds a best (the engine's stop_early! no-ops otherwise);
          # the tick chain then completes the ship on its next tick,
          # submits it, and proceeds to the next ship exactly as if the
          # proof had finished naturally.
          def skip_current_ship_search!(entity)
            return unless auto_route_all_active?(entity)
            return unless @auto_all_final_train

            @game.optimal_autorouter.stop_early!
          end

          # Public: the train id of whichever ship the final phase's
          # chunked search is CURRENTLY building for this entity, or nil
          # (during trials, or once the run's finished) -- lets
          # ShipSelector attach the live counter to that ship's own row
          # instead of showing it detached below the whole list. Only
          # meaningful during the final phase; the ranking trials run
          # each ordering's own throwaway searches without ever settling
          # on "the ship currently being routed" in a way worth
          # displaying against a row.
          # Read-only peek, never mutates search state (unlike
          # @auto_all_final_train itself, whose nil/non-nil is load-
          # bearing for start_chunk!'s own "have I already begun this
          # ship's search" check in the tick loop -- setting it eagerly
          # here would skip that call entirely for the next ship).
          #
          # Needed because @auto_all_final_train is deliberately nil for
          # exactly one tick boundary: the tick that finishes a ship
          # clears it to nil (see the final-phase loop) BEFORE returning
          # :built, and it's only reassigned to the NEXT ship on some
          # later tick -- but :built is also the one moment that
          # actually triggers a real re-render (ship_selector.rb's
          # run_auto_route_all_tick!). Found live in browser: a 3-ship
          # run correctly attached the counter to ship 1's row, then
          # fell back to the detached bottom placement for the rest of
          # the run, because that's exactly the state this method saw at
          # every later re-render (each one happening right at a ship
          # boundary, where @auto_all_final_train was momentarily nil).
          # Peeking ahead to "whichever still-unfilled ship comes next"
          # during that gap keeps the display honest without touching
          # the real search state at all.
          def auto_route_all_current_train_id(entity)
            return nil unless auto_route_all_active?(entity)
            return @auto_all_final_train.id if @auto_all_final_train
            return nil if @auto_all_trial_index < @auto_all_orderings.size

            next_train = @auto_all_best_order[@auto_all_final_index..]&.find { |t| available_trains(entity).include?(t) }
            next_train&.id
          end

          # Frozen at whatever it read at completion (@auto_all_finished_at),
          # not live Time.now, once the run is done -- otherwise this kept
          # recomputing against the current time on every *later* re-render
          # this same step/game triggers for completely unrelated reasons
          # (another player's action, anything else that calls
          # store(:game, ...)), so a "Finished: 12s" label would silently
          # keep climbing indefinitely long after the search itself had
          # actually stopped. Found live in browser: a single-ship run
          # reported "2315s and climbing" well after finishing -- the
          # search itself wasn't still running, only this label was.
          def auto_route_all_elapsed(entity)
            return nil unless @auto_all_started_at && entity == @auto_all_entity

            ((@auto_all_finished_at || Time.now) - @auto_all_started_at).round
          end

          # Entity-agnostic, unlike auto_route_all_active? above -- this
          # is only ever used to decide whether the view's own live-clock
          # setInterval (ship_selector.rb's start_auto_route_clock!) should
          # keep ticking at all. That has to stay true for as long as the
          # search itself is running, even if the player has since
          # switched to looking at a different corp's own (unrelated,
          # correctly nil) panel -- if this were entity-scoped too, the
          # clock would clear itself the instant the player looked away,
          # and the counter would freeze instead of catching back up once
          # they looked back.
          def auto_route_all_running?
            @auto_all_active
          end

          # Public: train/hexes/cargo/revenue computed from an
          # Autorouter::Result, ready for apply_pending_suggestion! --
          # or nil (having already logged "No profitable route found")
          # if the search came up empty. Pure computation; nothing here
          # touches real game state.
          def suggestion_from_result(train, result)
            unless result
              @log << "No profitable route found for #{ship_label(train)}"
              return nil
            end

            { train: train, hexes: result.hexes, cargo: result.cargo, revenue: result.revenue }
          end

          # Public: hexes/cargo/revenue computed by re-walking `train`'s
          # last-recorded route, applying real MP/refuel rules fresh (a
          # station's owner can change since the recorded flight) and
          # only re-collecting a pickup if that specific mine is still
          # available to this entity. Works for any train, not just the
          # currently selected one, so it doubles as: the read-only
          # source for ship_rows' passive per-ship previews (nothing here
          # mutates anything -- every unrun ship's history shows at once,
          # not just whichever one was last Reset/Cleared), and what
          # Modify/Submit (via apply_previous_route!) actually load and
          # hand to apply_pending_suggestion!. Returns nil if there's no
          # route on record or it's no longer viable.
          def preview_last_route(entity, train)
            stored = @game.last_route(train)
            return nil unless stored

            path = replay_path(entity, train, stored[:hexes])
            cargo = replay_cargo(entity, train, path, stored[:cargo])
            revenue = @game.trace_revenue(entity, train, path, cargo)

            no_longer_viable = path.size < 2 || (revenue.zero? && train.name != 'Probe')
            return nil if no_longer_viable

            { hexes: path, cargo: cargo, revenue: revenue }
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
              cancel_completed_choices.key?(choice)
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
              new_train_id = choice.delete_prefix(SHIP)
              @selected_train_id = new_train_id
              # Exactly one thing selected at a time (see
              # select_completed_train!'s own comment) -- picking a ship
              # to build/review drops whatever already-submitted route
              # was targeted for "Clear Selected Route", the same way
              # targeting one of those drops this.
              @selected_completed_train_id = nil
            elsif choice.start_with?(PILOT_SKIP)
              source = choice.delete_prefix(PILOT_SKIP)
              @pilots_skipped << source
              @log << "#{entity.name}: #{@game.class::PILOT_NAMES[source]}'s pilot goes unplaced this turn"
            elsif choice.start_with?(PILOT)
              source, _sep, train_id = choice.delete_prefix(PILOT).rpartition('_')
              train = available_trains(entity).find { |t| t.id == train_id }
              assign_pilot!(entity, source, train) if train
            elsif choice.start_with?(FLYOVER)
              move_to(entity, choice.delete_prefix(FLYOVER), explore: false)
            elsif choice.start_with?(SHORTCUT_EXPLORE)
              fly_shortcut_to!(entity, choice.delete_prefix(SHORTCUT_EXPLORE), explore_destination: true)
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

          # A bare Pass always means "end the turn" now -- Submit All
          # Routes (ship_selector.rb's submit_all_routes!) already drains
          # every ship (whatever's on screen, plus every other still-
          # unrun one with a viable prior route) into real, separately
          # recorded submit_flight actions of its own before it ever
          # sends this Pass, so there's nothing left standing that a bare
          # Pass could accidentally discard or need to fold in.
          def process_pass(action)
            @choices_memo = nil

            if @trace.empty?
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

            return start_choices(entity, train) if @trace.empty?

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
          # against that separately). Built from Game#hex_bfs, a per-game
          # memoized cache of this exact walk (the hex-adjacency graph
          # never changes over a game) shared with Autorouter's own
          # identical need for it -- this used to be a second, independent
          # copy of the same BFS. Returns {hex_id => [hex, hex, ...]}, the
          # hops after `start`, for every hex on the (fully connected,
          # minus empty hexes) board.
          def plain_shortest_paths(start)
            _dist, predecessor = @game.hex_bfs(start)

            predecessor.each_key.to_h do |id|
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

          # A mine (or transshipment point, tracked the same way here) is
          # "visited" if something was actually picked up there -- flying
          # over/through an explored mine hex without picking up doesn't
          # count (e.g. cargo was already full, or it was already claimed
          # by someone else and thus unavailable). Every @cargo entry is
          # already exactly one of those two real pickups (see pick_up/
          # pick_up_transshipment!), so counting the whole array (deduped
          # by hex+mine slot, defensively) already covers both.
          def mines_visited(cargo)
            cargo.map { |c| [c[:hex_id], c[:mine_idx]] }.uniq.size
          end

          # Public: the ship-selector row's Explore/Mines column values,
          # built the same way regardless of where the underlying data
          # comes from (a finished route's stored @route_stats_by_train
          # entry, the live in-progress ship's @hexes_explored_this_trip/
          # @cargo, or a pending suggestion/replay preview's own hexes/
          # cargo) -- see ship_rows' three call sites.
          def route_stats(explored, cargo)
            { explored: explored, mines: mines_visited(cargo), codes: mine_codes(cargo) }
          end

          # Comma-joined letter-code list (e.g. "N, I, TP"), empty when
          # nothing's been picked up (or planned) yet. "TP" for a
          # transshipment credit -- the one cargo entry with no `:ore`
          # (see pick_up_transshipment!) -- counted here the same as any
          # ore mine, per the user: a transshipment point is a mine for
          # tracking purposes.
          def mine_codes(cargo)
            (cargo || []).map { |c| c[:ore] ? ORE_NAMES[c[:ore]][0] : 'TP' }.join(', ')
          end

          def needs_exploration?(hex)
            hex.tile.color == :blue && !@game.mine_state[hex.id]
          end

          def start_choices(entity, train)
            entity.tokens.filter_map { |t| t.city&.hex }.uniq.to_h do |hex|
              [hex.id, "Launch #{ship_label(train)} from #{hex.id}"]
            end
          end

          # Every real spaceship's name already encodes its stats (e.g.
          # '3/2' = 3 MP, 2 cargo holds); the Probe doesn't follow that
          # convention, so spell its stats out alongside its name instead.
          # Once a Growth Corp pilot is assigned to this specific ship, its
          # two-letter source code is appended too, so any ship label
          # anywhere (ship selector, route summaries, log lines) shows at a
          # glance which pilot (if any) is riding along.
          def ship_label(train)
            # Just "4/0", matching every other ship's plain movement/
            # cargo naming (see the class comment's naming convention) --
            # the leading "Probe" name made this one row visibly wider
            # than every other ship-selector row for no informational
            # gain, throwing off the row grid's column alignment.
            base = train.name == 'Probe' ? "#{train.distance}/#{@game.cargo_holds_for_train(train)}" : train.name
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
              # A structured {ore:, value:} label rather than text -- this
              # only ever becomes visible in the double-mine hex-choice
              # popup (a single available pickup is aliased and dispatched
              # directly with no button shown at all, see
              # alias_current_hex_pickup!'s comment). HexChoicePopup
              # renders this as the same ore-colored icon used for
              # claiming a mine (Step::BuyInfrastructure#claim_choices),
              # so the two double-mine popups look consistent instead of
              # this one being plain text.
              result["#{PICKUP}#{idx}"] = { ore: mine[:ore], value: value }
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
            result[TRANSSHIP] = "Transshipment (#{@game.format_currency(value)})"
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
            @log << "#{entity.name} picks up #{ORE_NAMES[mine[:ore]]} at #{hex.id} "\
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
            # The Probe never gets a recorded "last route" at all --
            # confirmed with the user: it's a pure explorer, its route is
            # a fresh player call every time, never worth repeating. Every
            # "Reset" path (previous_route_available?/apply_previous_
            # route!) already gates on @game.last_route(t) being present
            # before offering anything, so simply never recording one
            # here is enough to exclude the Probe from all of them at
            # once, the same single-point fix suggestable? already
            # applies for the Auto/Suggest button.
            @game.record_last_route!(train, trace, @cargo) if trace.size > 1 && train.name != 'Probe'

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
            # A deliberate cancel is the one explicit signal the player
            # doesn't want this ship's on-record route re-applied --
            # without this, auto_actions (re-triggered by this very
            # cancel, since it's itself a real action) would just refill
            # it straight back to the same route the player just backed
            # away from.
            @auto_fill_declined << train
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
              finished: false,
              finished_train: nil,
              last_route_snapshot: nil,
              hex_marks: [],
            }
          end

          # Precisely undoes everything local_choose! has mutated for real
          # since the last submit/discard -- explored hexes/mine reveals,
          # Lucky/Ice Finder/Drill Hound's borrowed tile assignments,
          # pickups, the log tail, and (if the flight had already finished
          # locally) the route/ran-trains/last-route bookkeeping
          # finish_route recorded. A no-op when nothing's pending
          # (@rollback nil) -- true both when the player never started a
          # local flight and, deliberately, at the top of every real
          # replay (see replay_submitted_flight!), so a fresh reload with
          # no local state to undo behaves identically to the live
          # browser that just submitted.
          #
          # Deliberately never touches @pilot_assignments -- see
          # assign_pilot!'s own comment on why a pilot pick is always
          # already-real, committed state by the time this could run, not
          # local preview state this method's job is to discard.
          def rollback_local_flight!(entity = nil)
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

            rollback_local_flight!(entity)
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
