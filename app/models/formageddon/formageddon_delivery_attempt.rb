module Formageddon
  class FormageddonDeliveryAttempt < ActiveRecord::Base
    belongs_to :formageddon_letter

    belongs_to :before_browser_state, :class_name => 'FormageddonBrowserState', :foreign_key => 'before_browser_state_id'
    belongs_to :after_browser_state, :class_name => 'FormageddonBrowserState', :foreign_key => 'after_browser_state_id'
    belongs_to :captcha_browser_state, :class_name => 'FormageddonBrowserState', :foreign_key => 'captcha_browser_state_id'

    def save_before_browser_state(browser)
      self.before_browser_state ||= create_before_browser_state
      save_state(before_browser_state, browser)
    end

    def save_after_browser_state(browser)
      self.after_browser_state ||= create_after_browser_state
      save_state(after_browser_state, browser)
    end

    def save_captcha_browser_state(browser)
      self.captcha_browser_state ||= create_captcha_browser_state
      save_state(captcha_browser_state, browser)
    end

    def save_state(state, browser)
      state.cookie_jar = YAML.dump(browser.cookie_jar)
      state.raw_html = browser.page.parser.to_s.encode('US-ASCII', :undef => :replace, :invalid => :replace)
      state.uri = browser.page.uri.to_s

      state.save
      save
    end

    def rebuild_browser(browser, state="before")
      state = send("#{state}_browser_state".to_sym) rescue nil
      return browser if state.nil?
      browser.rebuild_page(state.uri, state.cookie_jar, state.raw_html)
      browser
    end

    def to_s
      result
    end
  end
end