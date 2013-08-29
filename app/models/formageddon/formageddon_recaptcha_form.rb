module Formageddon
  class FormageddonRecaptchaForm < ActiveRecord::Base
    belongs_to :formageddon_form
  end
end