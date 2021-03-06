use "../world"
use "../display"
use "../agents"
use "../input"
use "../datast"
use "collections"
use "term"

type GameMode is (
  SplashMode |
  LevelMode |
  InventoryMode |
  HelpMode |
  DroppingMode |
  PrepareFastMode |
  FastMode |
  LookMode |
  MapViewMode |
  VictoryMode |
  QuittingMode
)

// Splash screen
primitive SplashMode
// Standard game playing mode
primitive LevelMode
// Looking at inventory
primitive InventoryMode
// Help
primitive HelpMode
// Checking if you really want to drop an item
primitive DroppingMode
// Ready to receive direction for FastMode
primitive PrepareFastMode
// Automatically moving in one direction as far as you can
primitive FastMode
// Looking around map and inspecting with cursor
primitive LookMode
// Looking around map by jumping screens
primitive MapViewMode
primitive VictoryMode
primitive QuittingMode

actor Game
  var _mode: GameMode = LevelMode
  var _running: Bool = true
  let _env: Env
  let _seed: U64
  let _display_height: I32 = 27
  let _display_width: I32 = 61
  let _log_width: I32 = 27
  let _stats_height: I32 = 5
  let _starting_pos: Pos val
  let _self: Self
  let _looker: Looker tag
  let _map_viewer: MapViewer tag
  let _display: Display tag
  let _term: ANSITerm
  let _turn_manager: TurnManager
  var _world: World tag
  var _focus: Pos val
  var _saved_focus: Pos val
  var _looping: Bool = false
  var _loop_counter: USize = 0
  var _mid_turn: Bool = false

  //TODO: Once fast bug is fixed, fast should always be enabled and this
  //can be removed.
  let _enable_fast: Bool

  new create(env: Env, seed: U64, is_overworld: Bool = false,
    noscreen: Bool = false, see_input: Bool = false,
    is_simple_dungeon: Bool = false, enable_fast: Bool = false)
  =>
    let world_diameter: I32 = 50//if is_overworld then 3250 else 50 end
    _env = env
    _seed = seed
    _starting_pos = Pos((world_diameter / 2), (world_diameter / 2))
    _focus = _starting_pos
    _saved_focus = _focus
    _display = if noscreen then
        EmptyDisplay(env)
      else
        CursesDisplay(_display_height, _display_width, _log_width,
          _stats_height)
      end
    _turn_manager = TurnManager(this, _display)

    _self = Self(_turn_manager, _display, this)
    _world =
      if is_overworld then
        OverWorld(world_diameter, _turn_manager, _seed, _display)
      elseif is_simple_dungeon then
        SimpleDungeon(10, _turn_manager, _display where self = _self)
      else
        Dungeon(world_diameter, _turn_manager, _display where self = _self)
      end
    _looker = Looker(_world, _focus, _display_height, _display_width, _display)
    _map_viewer = MapViewer(_world, _focus, _display_height, _display_width,
      _display)

    // Setup input
    let term = ANSITerm(InputNotify(this), env.input)
    let notify = object iso
      let term: ANSITerm = term
      fun ref apply(data: Array[U8] iso) => term(consume data)
      fun ref dispose() => term.dispose()
    end
    _term = term
    env.input(consume notify)

    _enable_fast = enable_fast

  // Called after InputNotify checks that Terminal is a valid size
  be start() =>
    _display.log("")
    _log_initial_msgs()
    _world.enter(_self)
    display_world()
    display_stats()

  be apply(cmd: Cmd val) =>
    match cmd
    | QuitCmd =>
      _display.log("You sure you want to quit? y/n")
      _mode = QuittingMode
    | ResetCmd =>
      _display.log("Resetting turn and command queues.")
      stop_loop()
      exit_fast_mode()
      _self.clear_commands()
      _turn_manager.panic()
    // TODO: Always enable fast when bug with getting stuck at wall is fixed.
    | FastCmd =>
      if _enable_fast then
        if _mode is LevelMode then
          _display.log("Repeat which command?")
          _mode = PrepareFastMode
        elseif _mode is PrepareFastMode then
          _display.log("Cancelled")
          _mode = LevelMode
        end
      else
        _display.log("Unrecognized Cmd")
      end
    | EmptyCmd =>
      None
    else
      match (_mode, cmd)
      // LevelMode
      | (LevelMode, HelpCmd) =>
        _display.log("Displaying help...")
        _display.help()
        _mode = HelpMode
      | (LevelMode, InventoryModeCmd) =>
        _mode = InventoryMode
        _display.log("-------------------------")
        _display.log("INVENTORY COMMANDS")
        _display.log("-------------------------")
        _display.log("<arrows> - select item")
        _display.log("<enter>  - equip/use/drink")
        _display.log("d        - (d)rop item")
        _display.log("l        - (l)ook at item")
        _display.log("i/<esc>  - exit inventory")
        _display.log("-------------------------")
        _self.process_inventory_command(cmd, _display)
      | (LevelMode, LookCmd) =>
        _display.log("Look where?")
        _mode = LookMode
        _looker.init(_display_height, _display_width, _focus, _world)
      | (LevelMode, ViewCmd) =>
        _display.log("Move cursor to see map")
        _mode = MapViewMode
        _map_viewer.init(_focus, _world)
      | (LevelMode, _) =>
        if _running and not _mid_turn then
          _self.enqueue_command(cmd)
          _turn_manager.next_turn(_world, _focus)
          _mid_turn = true
        end
      // LookMode //
      | (LookMode, EscCmd) =>
        _mode = LevelMode
        _looker.close(_display_height, _display_width, _focus)
      | (LookMode, LookCmd) =>
        _mode = LevelMode
        _looker.close(_display_height, _display_width, _focus)
      | (LookMode, _) =>
        _looker(cmd)
      // MapViewMode //
      | (MapViewMode, EscCmd) =>
        _mode = LevelMode
        _map_viewer.close(_focus)
      | (MapViewMode, ViewCmd) =>
        _mode = LevelMode
        _map_viewer.close(_focus)
      | (MapViewMode, _) =>
        _map_viewer(cmd)
      // InventoryMode //
      | (InventoryMode, EscCmd) =>
        _mode = LevelMode
        _display.log("-------------------------")
        _self.exit_inventory_mode()
        display_world()
      | (InventoryMode, DropCmd) =>
        _display.log("You sure you want to drop? y/n")
        _mode = DroppingMode
      | (InventoryMode, InventoryModeCmd) =>
        _mode = LevelMode
        _display.log("-------------------------")
        _self.exit_inventory_mode()
        display_world()
      | (InventoryMode, _) =>
        _self.process_inventory_command(cmd, _display)
      // HelpMode
      | (HelpMode, _) =>
        _mode = LevelMode
        _display.log("Exiting help...")
        display_world()
      // DroppingMode //
      | (DroppingMode, YCmd) =>
        _mode = InventoryMode
        _self.process_inventory_command(DropCmd, _display)
      | (DroppingMode, _) =>
        _display.log("That was close!")
        _mode = InventoryMode
      // PrepareFastMode //
      | (PrepareFastMode, EscCmd) =>
        _display.log("Cancelled")
        _mode = LevelMode
      | (PrepareFastMode, _) =>
        _self.enter_fast_mode(cmd)
        _mode = FastMode
        _looping = true
        loop()
      // FastMode //
      | (FastMode, _) =>
        _exit_fast_mode()
        _mode = LevelMode
      // QuittingMode //
      | (QuittingMode, YCmd) =>
        _term.dispose()
        _end_game()
      | (QuittingMode, _) =>
        _display.log("Good choice!")
        _mode = LevelMode
      end
    end

  be loop() =>
    if _looping and _running then
      _turn_manager.loop_next_turn(_world, _focus)
    end

  be stop_loop() => _stop_loop()

  fun ref _stop_loop() =>
    _turn_manager.stop_loop(_self)
    _looping = false

  be exit_fast_mode() =>
    _exit_fast_mode()

  fun ref _exit_fast_mode() =>
    _stop_loop()
    _self.exit_fast_mode()
    _mode = LevelMode

  be next_turn() =>
    display_world()
    _mid_turn = false

  be update_world(w: World tag) =>
    _world = w
    update_seen()
    display_world()

  be update_focus(pos: Pos val) => _focus = pos

  be update_seen() => _world.update_seen(_display_height, _display_width,
    _focus)

  be display_world() =>
    _world.display_map(_display_height, _display_width, _focus, _display)

  be display_stats() => _self.display_stats()

  be log(s: String) => _display.log(s)

  be increment_turn() => _self.increment_turn()

  be fail_term_too_small() =>
    _display.close_with_message("\nTerminal must be at least 99x31! Please resize and start Acolyte again.\n")
    _term.dispose()

  be win() =>
    _display.log("You have won the game!")
    _mode = VictoryMode

  fun ref _end_game() =>
    _display.close()
    _term.dispose()
    _running = false

  fun _log_initial_msgs() =>
    _display.log("=-----------=")
    _display.log("|-=-=-=-=-=-|")
    _display.log("||--=-=-=--||")
    _display.log("|||acolyte|||")
    _display.log("||--=-=-=--||")
    _display.log("|-=-=-=-=-=-|")
    _display.log("=-----------=")
    _display.log("")
    _display.log("**************************")
    _display.log("*Resizing terminal window*")
    _display.log("*smaller than 99x31 will *")
    _display.log("*shut down game          *")
    _display.log("**************************")
    _display.log("")
    _display.log("Press h for command list.")
    _display.log("")
