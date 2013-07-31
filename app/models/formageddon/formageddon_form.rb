module Formageddon
  class FormageddonForm < ActiveRecord::Base
    has_many :formageddon_form_fields, :dependent => :destroy, :order => 'field_number ASC NULLS LAST'
    has_one :formageddon_form_captcha_image, :dependent => :destroy
    belongs_to :formageddon_contact_step

    accepts_nested_attributes_for :formageddon_form_fields
    accepts_nested_attributes_for :formageddon_form_captcha_image, :reject_if => lambda { |a| a[:css_selector].blank? }, :allow_destroy => true

    def has_captcha?
      formageddon_form_fields.each { |f| return true if f.value == 'captcha_solution' }
      return false
    end
  end
end