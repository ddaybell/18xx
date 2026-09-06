require './lib/engine'
g = Engine::Game::G2038::Game.new(['P1', 'P2', 'P3'])
p g.show_map_legend?
p g.map_legends
