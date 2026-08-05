# frozen_string_literal: true

require_relative 'base'
require_relative '../ownable'

module Engine
  module Part
    class Icon < Base
      include Ownable

      attr_accessor :preprinted, :image, :large, :loc, :radius
      attr_reader :name, :sticky

      # radius: opt-in override of the small-icon renderer's default fixed
      # size (Part::Icons::ICON_RADIUS) for this specific icon -- nil (the
      # default) keeps every existing icon rendering exactly as before;
      # only set this when one icon genuinely needs its own size (e.g.
      # g_2038's ship position marker).
      def initialize(image, name = nil, sticky = true, blocks_lay = nil, preprinted = true, large: false, owner: nil,
                     loc: nil, radius: nil)
        @image = image.start_with?('/icons') ? "#{image}.svg" : "/icons/#{image}.svg"
        @name = name || image.split('/')[-1]
        @sticky = !!sticky
        @preprinted = preprinted
        @blocks_lay = !!blocks_lay
        @large = !!large
        @owner = owner
        @loc = loc
        @radius = radius
      end

      def blocks_lay?
        @blocks_lay
      end

      def icon?
        true
      end
    end
  end
end
