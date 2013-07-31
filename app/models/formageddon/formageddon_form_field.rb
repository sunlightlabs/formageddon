module Formageddon
  class FormageddonFormField < ActiveRecord::Base
    belongs_to :formageddon_form

    after_save :ensure_index

    def not_changeable?
      self.value == 'submit_button' or self.value == 'leave_blank'
    end

    @@titles = ["Mr.", "Miss", "Mrs.", "Ms.", "Dr."]
    @@states = [
        "AL",
        "AK",
        "AS",
        "AZ",
        "AR",
        "CA",
        "CO",
        "CT",
        "DE",
        "DC",
        "FL",
        "GA",
        "GU",
        "HI",
        "ID",
        "IL",
        "IN",
        "IA",
        "KS",
        "KY",
        "LA",
        "ME",
        "MD",
        "MA",
        "MI",
        "MN",
        "MS",
        "MO",
        "MT",
        "NE",
        "NV",
        "NH",
        "NJ",
        "NM",
        "NY",
        "NC",
        "ND",
        "OH",
        "OK",
        "OR",
        "PA",
        "PR",
        "RI",
        "SC",
        "SD",
        "TN",
        "TX",
        "UT",
        "VI",
        "VT",
        "VA",
        "WA",
        "WV",
        "WI",
        "WY"
    ]

    def self.states
      @@states
    end

    def self.titles
      @@titles
    end

    def ensure_index
      unless field_number.present?
        self.update_attribute(:field_number, (formageddon_form.formageddon_form_fields.index(self) + 1)) rescue nil
      end
    end
  end
end
