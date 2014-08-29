module Formageddon
  module ActsAsFormageddonRecipient

    ## Define ModelMethods
    module Base
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def acts_as_formageddon_recipient
          has_many :formageddon_contact_steps, -> { order('formageddon_contact_steps.step_number ASC') },
                   :class_name => 'Formageddon::FormageddonContactStep', :as => :formageddon_recipient, :dependent => :destroy
          has_many :formageddon_threads, -> { order('formageddon_threads.created_at DESC') },
                   :class_name => 'Formageddon::FormageddonThread', :as => :formageddon_recipient

          include Formageddon::ActsAsFormageddonRecipient::Base::InstanceMethods
        end
      end

      module InstanceMethods
        def execute_contact_steps(browser, letter, start_step = 1)
          remaining_steps = formageddon_contact_steps.where(['formageddon_contact_steps.step_number >= ?', start_step])

          # create a new delivery attempt
          delivery_attempt = letter.formageddon_delivery_attempts.create
          captcha_state = letter.instance_variable_get('@captcha_browser_state') rescue nil
          delivery_attempt.captcha_browser_state = captcha_state if captcha_state

          remaining_steps.each do |s|
            return unless s.execute(browser, { :letter => letter, :delivery_attempt => delivery_attempt })
          end
        end

        def formageddon_display_address
          ""
        end

        def formageddon_configured?
          not formageddon_contact_steps.empty?
        end
      end # InstanceMethods
    end

  end
end
