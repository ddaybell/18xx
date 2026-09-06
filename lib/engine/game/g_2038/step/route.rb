# frozen_string_literal: true

require_relative '../../../step/base'
require_relative 'auto_route_all'
require_relative 'ship_display'

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
          include AutoRouteAll
          include ShipDisplay

          ACTIONS = %w[choose pass].freeze

          FINISH = 'finish'
          CANCEL = 'cancel'
          CANCEL_COMPLETED = 'cancel_completed_'
          PICKUP = 'pickup_'
          TRANSSHIP = 'transship'
          # Refueling (§7.12) is a "may," not a "must" -- entering an
          # eligible station hex offers this, same optional-click shape as
          # TRANSSHIP, but taking it never ends the flight the way
          # collecting a transshipment does.
          REFUEL = 'refuel'
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
            @ran_ships = []
            @explored_in_trace = false
            @mp_spent = 0
            @selected_ship_id = nil
            # Which already-submitted, still-cancellable route the single
            # "Clear Ship" control targets -- see select_completed_ship!/
            # selected_completed_ship.
            @selected_completed_ship_id = nil
            # Ships the player has explicitly backed away from an
            # auto-filled (or any already-submitted) route for this turn
            # -- see cancel_completed_route/auto_actions' own comment.
            # Reset fresh each turn, same as everything else here.
            @auto_fill_declined = []
            # This OR's Growth Corp pilot assignments (Phase 8): pilot
            # source string ('LY'/'TH'/etc) => the Ship it's assigned to.
            # Each inherited pilot gets its OWN ship -- never shared, never
            # doubled up on one ship -- explicitly chosen (or auto-assigned
            # when there's only one real pairing left), and always reset
            # here each OR since a fresh step instance is built every
            # round, mirroring 1822's Pullman-to-ship assignment.
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
            # Per-ship {explored:, mines:} snapshot, taken at `finish_route`
            # -- `route_summary` runs later (once this ship is done and a
            # different one may already be flying), by which point @cargo/
            # @hexes_explored_this_trip have moved on to the next trip, and
            # every hex in a finished route already looks explored regardless
            # of who explored it. Neither figure can be recomputed post-hoc
            # from the stored Engine::Route alone.
            @route_stats_by_ship = {}
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
            # intended. 
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
          # removed auto-pass).
          def actions(entity)
            return [] unless entity == current_entity
            return [] unless entity.operator?
            # A company that owns no ships at all has nothing to confirm 
            # here; skip straight past this step (and, since it'll earn 
            # exactly $0, Dividend's own actions already auto-skips on 
            # total_revenue.zero? too) rather than making the player 
            # click Submit All Routes for a turn that could never have 
            # had anything in it.
            return [] if @game.route_trains(entity).empty?

            ACTIONS
          end

          # nil -- suppresses the generic Choose panel's "X:" header
          # entirely (see assets/app/view/game/choose.rb, which already
          # treats a falsy choice_name as "no header"). 
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

          # Dims everything that isn't a company base (i.e. a legal starting
          # location) before launch, when it's actually useful to see which 
          # of this entity's bases are valid to fly from.
          def available_hex(entity, hex)
            return false unless entity == current_entity
            return true unless @trace.empty?
            return true unless current_ship(entity)
            choices.key?(hex.id)
          end

          # Opt-in hook the generic Choose view prefers over `choices` for
          # its bottom-panel button list (see assets/app/view/game/choose.rb).
          # Hex-based choices (launch/move/explore/flyover/pickup/Lucky's
          # tile redraw) are fully redundant with clicking the relevant hex
          # directly on the map (`available_hex` above, and
          # `hex_choice_popup` below for the explore/flyover/multi-pickup/
          # tile-redraw disambiguation). FINISH is deliberately left out
          # too, even though it has no map-click equivalent of its own.
          # ShipSelector's Submit button now covers it (see submit_ready?/
          # finish_and_submit_choice), so a route that could end here with
          # MP still left shows the same "Submit ($X)" button a route
          # that already auto-finished from running out of MP does. `choices` 
          # itself is unchanged: it's still the source of truth for hex-click 
          # validation and `process_choose`.
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
          # only being safe pre-payout). Exploring a hex draws real, 
          # order-dependent randomness from the engine's single seeded RNG 
          # stream.  Every tile reveal's rotation (Game#explore_hex!) and 
          # every Lucky/Ice Finder/Drill Hound "second draw" (Game#
          # borrow_second_tile, whose *candidate pool* is literally
          # "whichever hexes are still unexplored right now") both draw
          # from it. If an earlier, non-exploring route were reopened and
          # reflown differently, and the new attempt explored a hex the
          # original never touched, that inserts an extra draw ahead of
          # whatever a later route already explored. On reload, replay
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
          def cancellable_ships
            return [] unless @trace.empty?

            not_yet_locked_ships
          end

          # The same backward walk cancellable_ships does, minus its own
          # `@trace.empty?` gate.  That gate is right for cancellable_
          # ships' own purpose (you can't target an already-submitted
          # route for cancellation while mid-flight elsewhere), but wrong
          # for explore_would_lock_other_routes? below, which specifically
          # needs to ask this question *while* mid-flight (exploring only
          # ever happens mid-flight).  Cancellable_ships alone always
          # answered "[]" there, silently never warning at all.
          def not_yet_locked_ships
            blocked = false
            result = []
            @ran_ships.reverse_each do |ship|
              # The currently pending (local, not-yet-submitted) flight
              # has its own undo path (Discard, via local_pass!) and
              # isn't real yet, so it neither belongs in this list nor
              # should its own explored-ness block earlier, genuinely
              # already-submitted routes from being reachable here.
              next if @rollback&.dig(:finished_ship) == ship

              if @route_stats_by_ship[ship][:explored].positive?
                blocked = true
                next
              end
              result << ship unless blocked
            end
            result
          end

          def cancel_completed_choices
            cancellable_ships.to_h { |t| ["#{CANCEL_COMPLETED}#{t.id}", "Cancel completed route for #{ship_label(t)}"] }
          end

          # Public: for a ship that's LOCKED (excluded from
          # not_yet_locked_ships, i.e. can no longer be cancelled), which
          # ship's exploration is actually responsible -- so the UI can
          # name (and color-match) that specific row instead of a vague
          # "something exploded" message.
          #
          # Why this search works: not_yet_locked_ships walks @ran_ships
          # BACKWARD (latest-flown first) and locks a ship the instant it
          # reaches one that explored -- from that point on, every EARLIER
          # ship is locked too, regardless of whether it explored itself.
          # So the real culprit for any locked ship is always the
          # EARLIEST explorer at or after it in flown order, never an
          # earlier one. This method finds exactly that: walk @ran_ships
          # FORWARD starting at `ship` itself, and take the first one
          # whose route explored anything -- `ship` itself if it's the
          # explorer, or whichever later ship actually was.
          def locking_ship_for(ship)
            index = @ran_ships.index(ship)
            return nil unless index

            @ran_ships[index..].find { |t| @route_stats_by_ship[t][:explored].positive? }
          end

          # Public: which already-submitted, still-cancellable route the
          # single "Clear Ship" control (ShipSelector's global button --
          # distinct from the per-row Cancel used for whichever ship is
          # actively mid-flight/pending-submit) currently targets. Pure UI
          # state, never a recorded action by itself -- only the resulting
          # button click is. nil once nothing's been clicked yet, or the
          # previously-selected one stopped being eligible (e.g. an
          # earlier ship's route got explored, locking the chain in front
          # of it -- see cancellable_ships).
          def selected_completed_ship(entity)
            return nil unless @selected_completed_ship_id

            cancellable_ships.find { |t| t.id == @selected_completed_ship_id }
          end

          # Public: click handler for an already-submitted ship's row --
          # purely local UI selection, not a real action. Also drops
          # whichever *unrun* ship was the current build target (its own
          # selected-row highlight/Route:/Reset controls).
          def select_completed_ship!(ship)
            @selected_completed_ship_id = ship.id
            @selected_ship_id = nil
            @round.laid_hexes = []
          end

          # Public: the real, recorded choice string ShipSelector's single
          # "Clear Ship" button submits for a targeted already-submitted
          # route -- keeps CANCEL_COMPLETED's exact format a route.rb-only
          # concern rather than something the view needs to know how to
          # build.
          def cancel_completed_choice(ship)
            "#{CANCEL_COMPLETED}#{ship.id}"
          end

          # Growth Corp pilot assignment (Phase 8), mirroring 1822's
          # Pullman-to-ship attachment: only offered pre-launch, only when
          # this corp has an unresolved pilot-ship pairing. Each inherited
          # pilot gets its own ship -- never shared, never doubled up --
          # and a choice is only ever shown when there's real ambiguity:
          # one pilot contending for 2+ un-run ships, or (the mirror image,
          # e.g. the AL running 2+ pilots) 2+ pilots contending for the one
          # ship left. With exactly one pilot and one ship, there's nothing
          # to pick -- `pilot_source_for_ship`/`resolve_unambiguous_pilots!`
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

            ships = available_ships(entity) - @pilot_assignments.values
            return {} if ships.empty?

            if ships.one? && sources.size > 1
              ship = ships.first
              return sources.to_h { |s| ["#{PILOT}#{s}_#{ship.id}", "Assign #{@game.class::PILOT_NAMES[s]}'s pilot to #{ship_label(ship)}"] }
                             .merge(sources.to_h { |s| ["#{PILOT_SKIP}#{s}", "Skip #{@game.class::PILOT_NAMES[s]}'s pilot"] })
            end
            return {} if ships.size <= 1

            source = sources.first
            ships.to_h { |t| ["#{PILOT}#{source}_#{t.id}", "Assign #{@game.class::PILOT_NAMES[source]}'s pilot to #{ship_label(t)}"] }
                  .merge(PILOT_SKIP + source => "Skip #{@game.class::PILOT_NAMES[source]}'s pilot")
          end

          # Public: called from Game#pilot_source_for_ship for the actual
          # bonus checks (company_ore_bonus/ship_distance/
          # needs_second_draw?) -- returns which pilot source (if any) is
          # assigned to this specific ship. Auto-assigns (and announces,
          # once, via assign_pilot!) the sole remaining (source, ship)
          # pairing once there's no real choice left, same idiom
          # current_ship already uses for ship selection itself.
          #
          # Excludes @pilots_skipped the same way pilot_choices already
          # does -- without this, a pilot the player explicitly declined
          # (PILOT_SKIP) earlier this OR would silently come back once the
          # remaining ships narrowed to exactly one, overriding that
          # decision instead of honoring it for the rest of the turn
          # (found live in browser: skip Ore Crusher's pilot, hand-fly two
          # of three ships, and the third still got assigned it anyway).
          def pilot_source_for_ship(entity, ship)
            sources = @game.growth_corp_pilots(entity) - @pilots_skipped
            return nil if sources.empty?

            assigned_source = @pilot_assignments.key(ship)
            return assigned_source if assigned_source

            unassigned_sources = sources - @pilot_assignments.keys
            return nil unless unassigned_sources.one?

            assignable_ships = available_ships(entity) - @pilot_assignments.values
            return nil unless assignable_ships.one? && assignable_ships.first == ship

            source = unassigned_sources.first
            assign_pilot!(entity, source, ship)
            source
          end

          # Records a pilot-ship pairing and announces it in the log --
          # shared by the auto-assign paths above (unambiguous from the
          # start of the turn, or becoming unambiguous mid-turn as ships
          # finish flying) and the explicit PILOT choice in process_choose,
          # so every pairing is announced exactly once regardless of how
          # it was resolved.
          def assign_pilot!(entity, source, ship)
            @pilot_assignments[source] = ship
            @log << "#{entity.name}: Pilot #{@game.class::PILOT_NAMES[source]} (#{source}) assigned to #{ship_label(ship)}"
          end

          # Called from `setup`, before a single ship has flown this turn:
          # announces the one truly unambiguous case (exactly one pilot,
          # exactly one ship) right at the start of the Route phase rather
          # than waiting for the first bonus check to trigger it lazily.
          def resolve_unambiguous_pilots!
            entity = current_entity
            return unless entity

            # Excludes @pilots_skipped for consistency with
            # pilot_source_for_ship -- harmless today since this only
            # ever runs once per fresh setup (before any skip could exist
            # this OR), but keeps both auto-assign paths honoring the
            # same skip decision if this is ever called again mid-turn.
            sources = @game.growth_corp_pilots(entity) - @pilots_skipped
            return unless sources.one?

            ships = available_ships(entity)
            return unless ships.one?

            assign_pilot!(entity, sources.first, ships.first)
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
          # those routes for the rest of the turn (see cancellable_ships'
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
            # Not cancellable_ships -- that returns [] outright the
            # moment @trace isn't empty (mid-flight), which is exactly
            # when this question is actually being asked (see
            # not_yet_locked_ships' own comment).
            return false if not_yet_locked_ships.empty?

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
            matches = choices.select { |key, _label| key.start_with?(PICKUP) || key == TRANSSHIP || key == REFUEL }
            return matches unless undo_last_hex_available?(current_entity)

            matches.merge(UNDO_HEX => undo_hex_label)
          end

          # Opt-in hook for assets/app/view/game/hex_choice_popup.rb: chain
          # straight into a follow-up popup ONLY for an independent whose
          # own explore-time choice is guaranteed to open a second popup
          # (the tile-redraw choice) right after, with nothing left for
          # the player to decide in between -- entities.rb's
          # chain_explore_popup field (Game#chain_explore_popup_sources)
          # says which ones, Lucky today. Every other transition (a plain
          # explore/flyover with no redraw power, IF/DH whose redraw is
          # automatic and silent, or picking a tile/ore) requires a fresh
          # hex click for its own popup -- in particular, explore must NOT
          # chain into a pickup popup, since choosing to explore is not
          # the same decision as choosing to pick up ore.
          # Checks the pilot actually assigned to the ship in flight (not
          # just entity.id), so a Growth Corp flying a ship with an
          # inherited chain_explore_popup pilot gets the same immediate
          # chain a bare independent does -- entity.id alone would only
          # ever match the independent itself.
          def chain_hex_choice_popup?(entity, hex, choice)
            return false unless choice == hex.id && needs_exploration?(hex)

            ship = current_ship(entity)
            pilot_source = entity.minor? ? entity.id : pilot_source_for_ship(entity, ship)
            @game.chain_explore_popup_sources.include?(pilot_source)
          end

          # For the tile choice popup (e.g. Lucky's tile choice), shown 
          # as real tile art (see assets/app/view/game/hex_choice_popup.rb, 
          # which renders an Engine::Tile value as a clickable preview instead 
          # of a text button) rather than the plain-text redraw_choices used 
          # as this hex's bare-id alias (see compute_choices) -- that alias only
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

          # "Submit All Routes ($X)" whenever nothing's locally pending. 
          # With every route built client-side, ending the
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
              available_ships(current_entity).each do |ship|
                next if @auto_fill_declined.include?(ship)

                preview = preview_last_route(current_entity, ship)
                total += preview[:revenue] if preview
              end
              return "Submit All Routes (#{@game.format_currency(total)})"
            end

            return 'Cancel (⚠️ un-reveals tile)' if @rollback && !@rollback[:laid_hexes].empty?

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
          # 
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
              # later choice worth keeping alongside the first. 
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
          # nothing worth offering to cancel.
          #
          # Deliberately does NOT treat a just-made pilot assignment as
          # "local, discardable" state -- PILOT is excluded from 
          # local_choose? precisely because it's always its own separately-
          # recorded real action, never a preview (see assign_pilot!'s own 
          # comment on the bug that came from treating it as local anyway: 
          # the real Undo button/ctrl+z defers to local_undo?, which mirrors 
          # this method, so a pilot pick being reported as "local" made Undo 
          # silently discard it client-side instead of issuing a real 
          # Action::Undo against the recorded action -- reloading the game 
          # then replayed the *original*, never-actually-undone pairing and 
          # rejected whatever the player picked next as invalid). Reconsidering 
          # a pilot pick now goes through the same real Undo as undoing anything 
          # else already committed, which correctly rewrites the action log
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

          # Opt-in hook for assets/app/view/game/pass.rb: unconditionally
          # suppressed -- ShipSelector now renders its own equivalent
          # unconditionally (Clear Ship via local_pass!/
          # cancel_flight_button while something's pending, the real
          # Submit-All-Routes PassButton once nothing is), grouped with
          # the rest of the ship controls instead of appearing as a
          # separate standalone button elsewhere on the page. No `entity`
          # comparison needed: pass.rb only ever calls this when this step
          # is the round's own active_step, at which point its
          # `current_entity` and the round's are the same value by
          # construction (Route doesn't override active_entities/entities/
          # entity_index), so the comparison could never actually be
          # false.
          def suppress_standalone_pass?(_entity)
            true
          end

          # Public: the self-contained choice this ship's just-finished,
          # not-yet-submitted flight would submit.  This is nil until finish_route
          # has actually run locally (see FLIGHT_SEP/replay_submitted_flight!).
          def submit_flight_choice(entity)
            return nil unless entity == current_entity
            return nil unless @rollback&.dig(:finished)
            return nil if @local_flight_log.empty?

            "#{SUBMIT_FLIGHT}:#{@local_flight_log.join(FLIGHT_SEP)}"
          end

          # Public: whether ShipSelector's Submit button should be showing
          # right now.  Either the flight has already finished (running
          # out of MP auto-finishes it; so does a previous click of this
          # same button), or it's simply sitting on a hex where finishing
          # is currently a legal move.  Read-only -- safe to call on every 
          # render, unlike finish_and_submit_choice below.
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

          # Public: undoes the most recently entered hex, leaving the 
          # ship back at the hex before it, free to fly a different 
          # direction from there. Implemented as a full rollback (the 
          # exact same one Cancel/local_pass! uses) followed by replaying 
          # every local choice up to (not including) the discarded hex's 
          # own move -- see local_choose!'s hex_marks comment. Deliberately 
          # not a second, narrower undo path: reusing rollback_local_flight! 
          # wholesale means this can never drift out of sync with what a full
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

            ship = @rollback[:finished_ship]
            @round.routes.find { |r| r.train == ship }&.hexes&.last
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
          # preview of what finishing right now would earn otherwise. 
          # Ending a route with MP still available looks identical to 
          # running out of MP: same button, same label, same code, 
          # regardless of which way the flight actually ends. Read-only.
          def submit_button_label(entity)
            revenue =
              if @rollback&.dig(:finished)
                ship = @rollback[:finished_ship]
                @round.routes.find { |r| r.train == ship }&.revenue
              elsif @trace.size > 1 && (ship = current_ship(entity))
                @game.trace_revenue(entity, ship, @trace, @cargo)
              end
            revenue ? "Submit (#{@game.format_currency(revenue)})" : 'Submit'
          end

          # Public: the idle-controls Submit button's own label -- reads
          # straight off the selected ship's own passive preview (see
          # preview_last_route/ship_rows), since nothing's actually been
          # built yet at this point (that only happens once Submit or
          # Modify is clicked -- see render_idle_controls).
          def previous_route_submit_label(entity)
            ship = current_ship(entity)
            preview = ship && preview_last_route(entity, ship)
            preview ? "Submit (#{@game.format_currency(preview[:revenue])})" : 'Submit'
          end

          # Public: the Submit button's actual click handler. Finishes the
          # flight locally first if it hasn't already and then returns the 
          # self-contained choice to submit for real -- so ending a route 
          # with MP still left takes the exact same one-click as a route 
          # that already auto-finished from running out of MP, instead of 
          # a separate Finish click before Submit even appears. Mutating -- 
          # only call from a click handler, never from render (see submit_ready?/
          # submit_button_label for the read-only render-time checks).
          def finish_and_submit_choice(entity)
            local_choose!(entity, FINISH) if @trace.size > 1 && !@rollback&.dig(:finished)
            submit_flight_choice(entity)
          end

          # Public: how many still-unfilled, non-Probe ships a joint "Auto"
          # click would have to jointly order -- ship_selector.rb uses this
          # to warn before a 4-ship click, the one case (AL only, Phases
          # IV-V) where the ranking phase's ordering count (4! = 24, even
          # after start_auto_route_all!'s own dedup/pruning) can still make
          # a single click slow. Rather than engineer around a rare worst case, 
          # just suggest flying one ship by hand first.
          def unfilled_ship_count(entity)
            available_ships(entity).count { |t| t.name != 'Probe' }
          end

          # Public: hexes/cargo/revenue computed by re-walking `ship`'s
          # last-recorded route, applying real MP/refuel rules fresh and
          # only re-collecting a pickup if that specific mine is still
          # available to this entity. Works for any ship, not just the
          # currently selected one, so it doubles as: the read-only
          # source for ship_rows' passive per-ship previews (nothing here
          # mutates anything -- every unrun ship's history shows at once,
          # not just whichever one was last Reset/Cleared), and what
          # Modify/Submit (via apply_previous_route!) actually load and
          # hand to apply_pending_suggestion!. Returns nil if there's no
          # route on record or it's no longer viable.
          def preview_last_route(entity, ship)
            stored = @game.last_route(ship)
            return nil unless stored

            path, refueled_hex_ids = replay_path(entity, ship, stored[:hexes], stored[:refueled_hex_ids])
            cargo = replay_cargo(entity, ship, path, stored[:cargo])
            revenue = @game.trace_revenue(entity, ship, path, cargo)

            no_longer_viable = path.size < 2 || (revenue.zero? && ship.name != 'Probe')
            return nil if no_longer_viable

            { hexes: path, cargo: cargo, revenue: revenue, refueled_hex_ids: refueled_hex_ids }
          end

          # Re-walks a stored hex-id path with today's MP rules, stopping
          # early (rather than raising) the moment MP would go negative --
          # e.g. eager resimulation of refuel timing could otherwise
          # diverge from what a flight actually did (see Game#last_route's
          # own comment for the worked example: eager resimulation can
          # strand a path short of where a real, deferred-choice flight
          # got to). Refueling stations themselves can't be the cause --
          # confirmed by reading the code, not assumed: @refueling_stations
          # is only ever written once, in place_station!, itself gated on
          # can_place_station?'s `!refueling_station_owner(hex.id)` check,
          # so a station's owner never changes once placed. Refuel TIMING,
          # unlike MP itself, is a recorded decision -- `stored_
          # refueled_hex_ids` (always present; no back-compat fallback
          # needed while still in development) says exactly which hexes
          # the original flight actually chose to refuel at, so the bump
          # is only ever applied there, not at every eligible one. Returns
          # [path, refueled_hex_ids] -- the latter trimmed to whichever of
          # those hexes actually got the bump applied within the
          # (possibly truncated) returned path, for callers to replay the
          # same choices as real actions (see apply_pending_suggestion!).
          def replay_path(entity, ship, hex_ids, stored_refueled_hex_ids)
            hexes = hex_ids.map { |id| @game.hex_by_id(id) }
            return [[], []] if hexes.empty?

            full_mp = @game.ship_distance(entity, ship)
            mp_left = full_mp
            refueled = []
            path = [hexes.first]

            hexes.each_cons(2) do |_prev, nxt|
              mp_left -= 1
              break if mp_left.negative?

              if stored_refueled_hex_ids.include?(nxt.id) && @game.refueling_station_owner(nxt.id) == entity &&
                 !refueled.include?(nxt.id)
                mp_left = [mp_left + 3, full_mp].min
                refueled << nxt.id
              end
              path << nxt
            end

            [path, refueled]
          end

          # Re-collects only the stored pickups that fall within the
          # (possibly truncated) replayed path and are still actually
          # available to this entity -- claimed by someone else since, or
          # already used elsewhere this OR, and that one load is simply
          # skipped rather than blocking the rest of the replay.
          def replay_cargo(entity, ship, path, stored_cargo)
            holds = @game.cargo_holds_for_ship(ship)
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
                           value: @game.transshipment_value(hex, ship) }
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
            elsif choice == REFUEL
              refuel!(entity, @trace.last)
            elsif choice.start_with?(SHIP)
              new_ship_id = choice.delete_prefix(SHIP)
              @selected_ship_id = new_ship_id
              # Exactly one thing selected at a time (see
              # select_completed_ship!'s own comment) -- picking a ship
              # to build/review drops whatever already-submitted route
              # was targeted for "Clear Selected Route", the same way
              # targeting one of those drops this.
              @selected_completed_ship_id = nil
            elsif choice.start_with?(PILOT_SKIP)
              source = choice.delete_prefix(PILOT_SKIP)
              @pilots_skipped << source
              @log << "#{entity.name}: #{@game.class::PILOT_NAMES[source]}'s pilot goes unplaced this turn"
            elsif choice.start_with?(PILOT)
              source, _sep, ship_id = choice.delete_prefix(PILOT).rpartition('_')
              ship = available_ships(entity).find { |t| t.id == ship_id }
              assign_pilot!(entity, source, ship) if ship
            elsif choice.start_with?(FLYOVER)
              move_to(entity, choice.delete_prefix(FLYOVER), explore: false)
            elsif choice.start_with?(SHORTCUT_EXPLORE)
              fly_shortcut_to!(entity, choice.delete_prefix(SHORTCUT_EXPLORE), explore_destination: true)
            elsif @trace.empty?
              launch_at(entity, choice)
            elsif choice == @trace.last.id
              resolve_current_hex_choice!(entity, choice)
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
            # a legitimate launch point.  Resetting here, unconditionally, 
            # after every branch has run, guarantees the next `choices` 
            # call is always freshly computed regardless of how many times 
            # something upstream recomputed and cached it mid-dispatch.
            @choices_memo = nil
          end

          # Disambiguates a direct click on the flight's own current hex
          # (dispatch_choice!'s `choice == @trace.last.id` branch) --
          # transshipment pickup, an un-reveal (Undo), or an ordinary
          # mine pickup, whichever the popup actually offered there.
          def resolve_current_hex_choice!(entity, choice)
            matches = current_hex_action_choices
            raise GameError, "Ambiguous pickup at #{choice}" if matches.size != 1

            match = matches.keys.first
            if match == TRANSSHIP
              pick_up_transshipment!(entity, @trace.last)
              finish_route(entity)
            elsif match == REFUEL
              refuel!(entity, @trace.last)
            elsif match == UNDO_HEX
              undo_last_hex!(entity)
            else
              pick_up(entity, match.delete_prefix(PICKUP).to_i)
            end
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

            ship = current_ship(entity)
            return {} unless ship

            return start_choices(entity, ship) if @trace.empty?

            result = neighbor_move_choices(entity, ship)
            result.merge!(shortcut_choices(entity, ship))
            pickup_choices(entity, ship, result)
            transshipment_choice(entity, ship, result)
            refuel_choice(entity, result)
            alias_current_hex_pickup!(result)
            if @trace.size > 1
              revenue = @game.trace_revenue(entity, ship, @trace, @cargo)
              result[FINISH] = "End route (#{@game.format_currency(revenue)})"
            end
            # Exploration reveals hidden information, so a route that has
            # explored is committed — it can be finished but not taken back.
            result[CANCEL] = 'Cancel route' unless @explored_in_trace
            result
          end

          def available_ships(entity)
            @game.route_trains(entity).reject { |t| @ran_ships.include?(t) }
          end

          # Before launch, the player may own several unrun ships; let them
          # pick (and switch) which one flies before committing to a base.
          # With only one available ship there's nothing to pick, so skip
          # straight to base selection.
          #
          # A flight that finished locally but hasn't been submitted yet
          # always wins over that fallback, regardless of how many (or
          # how few) other ships remain unrun -- @rollback[:finished_ship]
          # is already in @ran_ships at this point (finish_route put it
          # there), so once it was the *last* unrun ship, available_ships
          # would otherwise narrow to size 1 and silently hand focus to
          # whatever ship comes next, even though the pending flight is
          # still what the player's looking at (its Submit/Cancel bar,
          # its route on the map). 
          def current_ship(entity)
            return @rollback[:finished_ship] if @rollback&.dig(:finished_ship)

            ships = available_ships(entity)
            return nil if ships.empty?
            return ships.first if ships.size == 1

            ships.find { |t| t.id == @selected_ship_id }
          end

          def mp_left(entity, ship)
            @game.ship_distance(entity, ship) - @mp_spent
          end

          # Plain one-hop choices: every direct neighbor of the current
          # hex, either a Move (already explored) or an Explore/Skip pair
          # (not yet explored) -- pulled out of compute_choices so it
          # reads as its own named concern, the same way shortcut/pickup/
          # transshipment/refuel choices already are, rather than being
          # the one inline loop left sitting directly in the dispatch
          # method.
          def neighbor_move_choices(entity, ship)
            result = {}
            @trace.last.neighbors.each_value do |hex|
              next if hex.empty

              if needs_exploration?(hex)
                if mp_left(entity, ship) >= 2
                  result[hex.id] = "Explore #{hex.id} (2 MP: 1 fly + 1 explore; #{mp_left(entity, ship) - 2} left)"
                end
                if mp_left(entity, ship) >= 1
                  result["#{FLYOVER}#{hex.id}"] =
                    "Skip #{hex.id} (1 MP; #{mp_left(entity, ship) - 1} left)"
                end
              elsif mp_left(entity, ship) >= 1
                result[hex.id] = "Move to #{hex.id} (1 MP; #{mp_left(entity, ship) - 1} left)"
              end
            end
            result
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
          def shortcut_choices(entity, ship)
            neighbor_ids = @trace.last.neighbors.values.map(&:id)
            shortcut_paths(entity, ship).each_with_object({}) do |(hex_id, entry), result|
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
          # Deliberately refuel-ignorant: a shortcut never assumes a
          # mid-path refuel happened, even at a station it passes right
          # through, so a hex only reachable BY counting on one simply
          # isn't offered as a shortcut at all -- the player flies there
          # by hand instead, one hex at a time, and gets the real §7.12
          # choice at each station entry along the way (see refuel_choice).
          # This was a real correctness question, not just a simplicity
          # choice: a station passed through mid-shortcut can genuinely be
          # revisited later via a separate, later move, and whether
          # refueling on THIS pass or a LATER one is better depends on
          # MP spent at each visit (gain is capped at mp_spent, not
          # remaining capacity) -- something no single shortcut call can
          # see ahead of time. 
          def shortcut_paths(entity, ship)
            start = @trace.last
            mp = mp_left(entity, ship)
            plain = plain_shortest_paths(start)

            plain.each_with_object({}) do |(hex_id, path), result|
              next if path.size > mp

              result[hex_id] = { path: path, remaining: mp - path.size }
            end
          end

          # Plain BFS shortest-hop-path tree from `start`, completely
          # ignoring refueling stations -- 1 MP per hop, unconstrained by
          # how much MP is actually available (shortcut_paths compares
          # against that separately). Built from Game#hex_bfs, a per-game
          # memoized cache of this exact walk (the hex-adjacency graph
          # never changes over a game) shared with Autorouter's own
          # identical need for it. Returns {hex_id => [hex, hex, ...]}, the
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

          # Replays a shortcut path hop by hop via the normal move_to.
          # Every hop but the last is always explore: false -- every
          # pass-through hex is a flyover regardless of whether it's been
          # explored, exactly like a hand-clicked FLYOVER move, so any
          # unexplored hex passed through stays hidden. The final hex
          # honors `explore_destination` (see shortcut_choices/
          # process_choose's SHORTCUT_EXPLORE branch) -- same
          # explore-on-arrival choice a direct neighbor move gets, just
          # reached via the shortcut.
          # Ore pickups and refueling are the things skipped at
          # intermediate hops: both are real decisions (a pass-through
          # station's refuel choice is simply never offered for that
          # visit, not silently declined -- it stays available if the hex
          # is ever reached again later, same as it would for any other
          # untaken visit), and the whole point of the shortcut is not
          # stopping for one at every hex passed through -- only the final
          # hex (where control returns to the player) offers a pickup or
          # refuel choice, same as any normal move ending there.
          def fly_shortcut_to!(entity, hex_id, explore_destination: false)
            entry = shortcut_paths(entity, current_ship(entity))[hex_id]
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
          # comes from (a finished route's stored @route_stats_by_ship
          # entry, the live in-progress ship's @hexes_explored_this_trip/
          # @cargo, or a pending suggestion/replay preview's own hexes/
          # cargo) -- see ship_rows' three call sites.
          def route_stats(explored, cargo)
            { explored: explored, mines: mines_visited(cargo), codes: mine_codes(cargo) }
          end

          # Comma-joined letter-code list (e.g. "N, I, TP"), empty when
          # nothing's been picked up (or planned) yet. "TP" for a
          # transshipment credit -- the one cargo entry with no `:ore`
          # (see pick_up_transshipment!). A transshipment point is a mine for
          # tracking purposes.
          def mine_codes(cargo)
            (cargo || []).map { |c| c[:ore] ? ORE_NAMES[c[:ore]][0] : 'TP' }.join(', ')
          end

          def needs_exploration?(hex)
            hex.tile.color == :blue && !@game.mine_state[hex.id]
          end

          def start_choices(entity, ship)
            entity.tokens.filter_map { |t| t.city&.hex }.uniq.to_h do |hex|
              [hex.id, "Launch #{ship_label(ship)} from #{hex.id}"]
            end
          end

          # Every real spaceship's name already encodes its stats (e.g.
          # '3/2' = 3 MP, 2 cargo holds); the Probe doesn't follow that
          # convention, so spell its stats out alongside its name instead.
          # Once a Growth Corp pilot is assigned to this specific ship, its
          # two-letter source code is appended too, so any ship label
          # anywhere (ship selector, route summaries, log lines) shows at a
          # glance which pilot (if any) is riding along.
          def ship_label(ship)
            # Just "4/0", matching every other ship's plain movement/
            # cargo naming (see the class comment's naming convention) --
            # the leading "Probe" name made this one row visibly wider
            # than every other ship-selector row for no informational
            # gain, throwing off the row grid's column alignment.
            base = ship.name == 'Probe' ? "#{ship.distance}/#{@game.cargo_holds_for_ship(ship)}" : ship.name
            source = @pilot_assignments.key(ship)
            source ? "#{base} (#{source})" : base
          end

          def pickup_choices(entity, ship, result)
            return if cargo_full?(ship)

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
          def transshipment_choice(entity, ship, result)
            return unless @game.transshipment_hex?(@trace.last.id)
            return if cargo_full?(ship)

            value = @game.transshipment_value(@trace.last, ship)
            result[TRANSSHIP] = "Transshipment (#{@game.format_currency(value)})"
          end

          # Shared by pickup_choices/transshipment_choice -- was a
          # verbatim-duplicated `@cargo.size >= @game.cargo_holds_for_
          # ship(ship)` check in both; a future change to hold-capacity
          # rules (e.g. exempting transshipment from hold limits, or a
          # third pickup-like choice) is an easy place to update one copy
          # and miss the other, silently reintroducing the exact bug this
          # guard exists to prevent.
          def cargo_full?(ship)
            @cargo.size >= @game.cargo_holds_for_ship(ship)
          end

          # §7.12: entering a station hex only ever offers the chance to
          # refuel -- never automatic. Offered again on every later visit
          # to this same hex this flight, for as long as it stays
          # unclaimed (@refueled_hexes, reset per flight in launch_at) --
          # since the gain is capped at @mp_spent, not remaining capacity,
          # declining now to take a bigger gain on a later visit is a real
          # decision, not a no-op.
          def refuel_choice(entity, result)
            return unless @game.refueling_station_owner(@trace.last.id) == entity
            return if @refueled_hexes.include?(@trace.last.id)

            gain = [@mp_spent, 3].min
            result[REFUEL] = "Refuel here (+#{gain} MP)"
          end

          # The current hex is never one of its own neighbors, so it never
          # gets a plain hex-id key from the loop above -- but hex.rb's
          # generic click dispatch only ever looks for a popup (or a direct
          # bare-hex-id action) when `choices.include?(@hex.id)` is already
          # true. Alias it here so clicking the ship's own hex can trigger a
          # pickup, same trick BuyInfrastructure uses for its claim hexes.
          # With exactly one action available this value is what actually
          # gets dispatched; with 2+ it's a placeholder `hex_choice_popup`
          # always intercepts ahead of -- a mine/transshipment hex that's
          # ALSO a station (REFUEL) is exactly the 2+ case this popup
          # already handles, not a new one.
          def alias_current_hex_pickup!(result)
            result[UNDO_HEX] = undo_hex_label if undo_last_hex_available?(current_entity)

            matches = result.select do |key, _label|
              key.start_with?(PICKUP) || key == TRANSSHIP || key == REFUEL || key == UNDO_HEX
            end
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

              ship = current_ship(entity)
              first_name, first_mines = @game.peek_tile(hex_id)
              if @game.needs_second_draw?(entity, ship, first_mines)
                # Whoever's redraw rule is entities.rb's chooses_own_redraw
                # (Lucky today) picks which of the two to place; everyone
                # else's second draw (Ice Finder/Drill Hound) is no real
                # choice -- needs_second_draw? is only true for them
                # because the first tile already failed their ore
                # requirement, so the second (borrowed) tile is always the
                # one used. A Growth Corp checks THIS ship's specific
                # assigned pilot source (Phase 8) instead of its own id.
                pilot_source = entity.minor? ? entity.id : pilot_source_for_ship(entity, ship)
                if @game.chooses_own_redraw_sources.include?(pilot_source)
                  start_redraw!(hex_id, first_name)
                else
                  auto_redraw!(entity, hex_id, first_name, pilot_source)
                end
              else
                explore_hex_tracked!(hex_id, entity)
                @hexes_explored_this_trip += 1
              end
            end

            update_trace_highlight
            maybe_auto_finish!(entity, current_ship(entity))
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
          # shortcut_paths). A pending refuel choice ALSO blocks this --
          # unlike a pickup, taking it doesn't end the flight, so stranding
          # the ship at 0 MP without offering it first would defeat the
          # entire point of letting refueling be deferred (§7.12).
          def maybe_auto_finish!(entity, ship)
            return if @pending_redraw
            return unless @trace.size > 1
            return if ship.nil? || mp_left(entity, ship).positive?

            remaining_pickups = {}
            pickup_choices(entity, ship, remaining_pickups)
            transshipment_choice(entity, ship, remaining_pickups)
            refuel_choice(entity, remaining_pickups)
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
          # TRANSSHIP branch below). Choosing to collect also ends the ship's 
          # flight immediately -- unlike an ore pickup, which lets the ship 
          # keep flying.
          def pick_up_transshipment!(entity, hex)
            return unless @game.transshipment_hex?(hex.id)

            ship = current_ship(entity)
            return if !ship || @cargo.size >= @game.cargo_holds_for_ship(ship)

            value = @game.transshipment_value(hex, ship)
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
            ore, = @game.company_ore_bonuses[pilot_source]
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
          # placing the one tile already drawn.  Note that this should 
          # never happen, since there are 106 tiles in the draw and only
          # 100 hexes on the map.
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
            maybe_auto_finish!(entity, current_ship(entity))
          end

          # +3 MP, capped at the ship's own movement allowance (§7.11/7.12).
          # Once per flight per station -- @refueled_hexes (reset per trip in
          # launch_at) is what stops a route that loops back through the
          # same station from refueling over and over.
          def refuel!(entity, hex)
            ship = current_ship(entity)
            gained = [@mp_spent, 3].min
            @mp_spent -= gained
            @refueled_hexes << hex.id
            @log << "#{entity.name}'s #{ship.name} refuels at #{hex.id} (+#{gained} MP)"
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
            maybe_auto_finish!(entity, current_ship(entity))
          end

          def finish_route(entity)
            ship = current_ship(entity)
            trace = @trace.dup
            revenue = @game.trace_revenue(entity, ship, trace, @cargo)

            if revenue.zero? && !@cargo.empty?
              @log << "#{entity.name}'s #{@cargo.size} #{@cargo.size == 1 ? 'load is' : 'loads are'} "\
                      'not delivered and lost'
            end

            if @rollback
              @rollback[:finished] = true
              @rollback[:finished_ship] = ship
              @rollback[:last_route_snapshot] = @game.last_route(ship)
            end

            route = Engine::Route.new(@game, @game.phase, ship, hexes: trace, revenue: revenue)
            @round.routes << route
            # The Probe never gets a recorded "last route" at all --
            # It's a pure explorer, its route is a fresh player call every 
            # time, never worth repeating. Every "Reset" path 
            # (previous_route_available?/apply_previous_route!) already 
            # gates on @game.last_route(t) being present before offering 
            # anything, so simply never recording one here is enough to 
            # exclude the Probe from all of them at once, the same single-
            # point fix suggestable? already applies for the Auto/Suggest button.
            if trace.size > 1 && ship.name != 'Probe'
              @game.record_last_route!(ship, trace, @cargo, @refueled_hexes)
            end

            mines = mines_visited(@cargo)
            @log << "#{entity.name} runs #{ship_label(ship)} for #{@game.format_currency(revenue)} "\
                    "(#{mines} #{mines == 1 ? 'mine' : 'mines'} visited, "\
                    "#{@mp_spent}/#{@game.ship_distance(entity, ship)} MP): #{trace.map(&:id).join(' - ')}"

            @route_stats_by_ship[ship] = { explored: @hexes_explored_this_trip, mines: mines, cargo: @cargo.dup }
            @ran_ships << ship
            @trace = []
            @cargo = []
            @explored_in_trace = false
            @mp_spent = 0
            @selected_ship_id = nil
            update_trace_highlight
            
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
            @selected_ship_id = nil
            update_trace_highlight
          end

          # Undoes an already-finished route (see cancellable_ships for the
          # eligibility rule): drops it from this OR's route list before
          # Dividend ever sees it (nothing has been paid out for plain
          # revenue yet -- only the flat exploration bonus pays immediately,
          # which is exactly why an explored route is never eligible here),
          # frees the ship to fly again this turn, and gives back any
          # picked-up ore the same way cancel_route does for an in-progress
          # trace.
          def cancel_completed_route(entity, ship_id)
            ship = @ran_ships.find { |t| t.id == ship_id }
            return unless ship

            stats = @route_stats_by_ship[ship]
            route = @round.routes.find { |r| r.train == ship }
            @round.routes.delete(route)
            stats[:cargo].each { |c| @game.mark_mine_used!(c[:hex_id], c[:mine_idx], false) if c[:mine_idx] }
            @route_stats_by_ship.delete(ship)
            @ran_ships.delete(ship)
            # A deliberate cancel is the one explicit signal the player
            # doesn't want this ship's on-record route re-applied --
            # without this, auto_actions (re-triggered by this very
            # cancel, since it's itself a real action) would just refill
            # it straight back to the same route the player just backed
            # away from.
            @auto_fill_declined << ship
            @log << "#{entity.name} cancels #{ship_label(ship)}'s completed route"
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
              finished_ship: nil,
              last_route_snapshot: nil,
              hex_marks: [],
            }
          end

          # Precisely undoes everything local_choose! has mutated for real
          # since the last submit/discard -- explored hexes/mine reveals,
          # Lucky/Ice Finder/Drill Hound's borrowed tile assignments,
          # pickups, the log tail, and (if the flight had already finished
          # locally) the route/ran-ships/last-route bookkeeping
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
              ship = r[:finished_ship]
              @round.routes.pop
              @ran_ships.delete(ship)
              @route_stats_by_ship.delete(ship)
              @game.restore_last_route!(ship, r[:last_route_snapshot])
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
            @selected_ship_id = nil
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
        end
      end
    end
  end
end
