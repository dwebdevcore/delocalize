require 'active_record'

require 'active_record/connection_adapters/abstract/schema_definitions'
begin
  require 'active_record/connection_adapters/column'
rescue LoadError
  # Not Rails 3.1, it seems
end

# let's hack into ActiveRecord a bit - everything at the lowest possible level, of course, so we minimalize side effects
ActiveRecord::ConnectionAdapters::Column.class_eval do
  def date?
    klass == Date
  end

  def time?
    klass == Time
  end
end

ActiveRecord::Base.class_eval do
  def write_attribute_with_localization(attr_name, original_value)
    new_value = original_value
    if column = column_for_attribute(attr_name.to_s)
      if column.date?
        new_value = delocalize_date_parser.parse(original_value) rescue original_value
      elsif column.time?
        new_value = delocalize_time_parser.parse(original_value) rescue original_value
      end
    end
    write_attribute_without_localization(attr_name, new_value)
  end
  alias_method_chain :write_attribute, :localization

  def convert_number_column_value_with_localization(value)
    value = convert_number_column_value_without_localization(value)
    value = delocalize_numeric_parser.parse(value) if I18n.delocalization_enabled?
    value
  end
  alias_method_chain :convert_number_column_value, :localization


  define_method( (Gem::Version.new(ActiveRecord::VERSION::STRING) < Gem::Version.new('3.2.9')) ? :field_changed? : :_field_changed? ) do |attr, old, value|
    if column = column_for_attribute(attr)
      if column.number? && column.null && (old.nil? || old == 0) && value.blank?
        # For nullable numeric columns, NULL gets stored in database for blank (i.e. '') values.
        # Hence we don't record it as a change if the value changes from nil to ''.
        # If an old value of 0 is set to '' we want this to get changed to nil as otherwise it'll
        # be typecast back to 0 (''.to_i => 0)
        value = nil
      elsif column.number?
        value = column.type_cast(convert_number_column_value_with_localization(value))
      else
        value = column.type_cast(value)
      end
    end
    old != value
  end

private

  def delocalize_numeric_parser
    @delocalize_numeric_parser ||= Delocalize::LocalizedNumericParser.new
  end

  def delocalize_date_parser
    @delocalize_date_parser ||= Delocalize::LocalizedDateTimeParser.new(Date)
  end

  def delocalize_time_parser
    @delocalize_time_parser ||= Delocalize::LocalizedDateTimeParser.new(Time)
  end

  def delocalize_time_with_zone_parser
    @delocalize_time_parser ||= Delocalize::LocalizedDateTimeParser.new(Time.zone)
  end

end

ActiveRecord::Base.instance_eval do
  def define_method_attribute=(attr_name)
    if create_time_zone_conversion_attribute?(attr_name, columns_hash[attr_name])
      method_body, line = <<-EOV, __LINE__ + 1
        def #{attr_name}=(original_time)
          time = original_time
          unless time.acts_like?(:time)
            time = time.is_a?(String) ? (I18n.delocalization_enabled? ? delocalize_time_with_zone_parser.parse(time) : Time.zone.parse(time)) : time.to_time rescue time
          end
          time = time.in_time_zone rescue nil if time
          write_attribute(:#{attr_name}, original_time)
          @attributes_cache["#{attr_name}"] = time
        end
      EOV
      generated_attribute_methods.module_eval(method_body, __FILE__, line)
    else
      super
    end
  end
end
