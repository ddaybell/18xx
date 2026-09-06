# frozen_string_literal: true

require '../lib/settings'

module View
  module Game
    class MapLegend < Snabberb::Component
      include Actionable
      include Lib::Settings
      needs :game, store: true
      # Which of @game's methods to call for legend table data -- defaults
      # to @game.map_legends (the map's own legend section) so every
      # existing caller is unaffected; a caller elsewhere (e.g. the Tiles
      # tab's own legend section) can pass a different list of method
      # names instead.
      needs :legend_methods, default: nil

      def render
        h(:div, (@legend_methods || @game.map_legends).map { |method| render_legend(method) })
      end

      def render_legend(method)
        table_props, header, *chart = @game.send(
          method,
          color_for(:font),
          color_for(:yellow),
          color_for(:green),
          color_for(:brown),
          color_for(:gray),
          color_for(:red),
          action_processor: ->(a) { process_action(a) },
        )

        head = header.map do |cell|
          item = cell[:text] || h(:image, { attrs: { href: cell[:image] } })
          if cell[:props]
            h(:th, cell[:props], item)
          else
            h(:th, item)
          end
        end

        rows = chart.map do |r|
          columns = r.map do |cell|
            item = cell[:text] || [h(:img, { attrs: { src: cell[:image], height: cell[:image_height] } })]
            if cell[:props]
              h(:td, cell[:props], item)
            else
              h(:td, item)
            end
          end
          h(:tr, columns)
        end

        h(:table, table_props, [
          h(:thead, [
            h(:tr, head),
          ]),
          h(:tbody, rows),
        ])
      end
    end
  end
end
