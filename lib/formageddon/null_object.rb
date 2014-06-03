require 'naught'

NullObject = Naught.build do |config|
  config.black_hole
  config.define_explicit_conversions
  config.singleton

  def nil?
    true
  end
end