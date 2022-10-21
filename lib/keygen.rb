# frozen_string_literal: true

require_relative 'keygen/ee'
require_relative 'keygen/error'
require_relative 'keygen/jsonapi'
require_relative 'keygen/logger'
require_relative 'keygen/middleware'

module Keygen
  PUBLIC_KEY = %(\xB8\xF3\xEBL\xD2`\x13_g\xA5\tn\x8D\xC1\xC9\xB9\xDC\xB8\x1E\xE9\xFEP\xD1,\xDC\xD9A\xF6`z\x901).freeze

  class << self
    def console? = Rails.const_defined?(:Console)

    def ce? = !lic? && !key?
    def ee? = !ce? && EE.license.valid?

    def ee(&)
      yield EE.license if ee?
    end

    private

    def lic? = ENV.key?('KEYGEN_LICENSE_FILE_PATH') || ENV.key?('KEYGEN_LICENSE_FILE')
    def key? = ENV.key?('KEYGEN_LICENSE_KEY')
  end
end
