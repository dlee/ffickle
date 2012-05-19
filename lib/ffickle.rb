require 'active_support/core_ext'
require 'open3'
require 'cast'

module FFIckle
  NAMED_TYPES = [C::Struct, C::Union, C::Enum]
  CONTAINER_TYPES = [C::Struct, C::Union]

  module Helper
    attr_reader :typedef_map, :required_containers, :required_enums

    def filepath_to_module_name(filepath)
      File.basename(filepath, '.*').underscore.camelize.gsub('.', '_')
    end

    # Returns Ruby literal that can be injected as return type or param in Ruby
    # FFI code.
    #
    # If +type+ is a string, it'll look into @library.typedef_map to find what
    # the type name is mapped to.
    #
    # +func_name+ is the name of the function that uses this type in either the
    # return value or the parameters.
    #
    # Also calls +require_type+ on +type+ if the type is a pointer or a named
    # type.
    def ffi_type_literal(type, func_name = nil)
      case type
      when C::CustomType
        return ":varargs" if type.name == "__builtin_va_list"
        ffi_type_literal @typedef_map[type.name], func_name
      when C::Pointer
        if type =~ 'const char *'
          ":string"
        else
          require_type type, func_name
          ":pointer"
        end
      when *CONTAINER_TYPES
        require_type type, func_name
        "#{type.name.camelize}.by_value"
      when C::Enum
        require_type type, func_name
        "#{type.name.camelize}"
      when C::PrimitiveType
        name = type.to_s
        name.gsub!(/^(const )?(restrict )?(volatile )?/, ':')
        name.gsub!(/unsigned /, 'u')
        name.gsub!(/ int$/, '')
        name.gsub!(/ /, '_')
        name
      else
        raise "Unknown type: #{type.inspect}"
      end
    end

    # Populates keys of +@required_enums+ and +@required_containers+ with
    # top-level enums, structs, and unions that need to be defined (nested
    # structs and unions will be automatically defined when the top-level
    # struct/union is defined). The keys map to an array of function names that
    # refer to the types.
    #
    # Recursively calls +require_type+ on types that are used within structs
    # and unions. Note, this is only for custom type members of structs/unions,
    # not nested structs/unions.
    def require_type(type, func_name)
      case type
      when C::Pointer
        require_type type.type, func_name
      when C::CustomType
        require_type @typedef_map[type.name], func_name
      when *CONTAINER_TYPES
        require_nested_types type, func_name
        @required_containers[type] << func_name
      when C::Enum
        @required_enums[type] << func_name
      when C::PrimitiveType
        # noop
      else
        raise "Unknown type: #{type.inspect}"
      end
    end

    # Populates +@required_enums+ and +@required_containers+ with top-level
    # enums, structs, and unions that are referred by +type+.
    #
    # This is called recursively for nested structs/unions.
    def require_nested_types(type, func_name)
      if type.members
        type.members.each do |declaration|
          case declaration.type
          when C::CustomType
            require_type(declaration.type, func_name)
          when C::Struct, C::Union
            if declaration.type.members
              # nested struct/union
              require_nested_types(declaration.type, func_name)
            else
              # reference to top-level struct/union
              require_type(declaration.type, func_name)
            end
          end
        end
      end
    end
  end

  class ParseError < ::StandardError; end

  class Library
    include Helper

    attr_reader :files, :module_name

    def initialize(lib, files)
      @lib = lib
      @module_name = filepath_to_module_name lib
      @files = [files].flatten.map {|f| File.expand_path f}
      @parser = C::Parser.new
      @parser.type_names << '__builtin_va_list'
      @preprocessor = C::Preprocessor.new 

      # Remove GNU-specific keywords that we don't need
      @preprocessor.macros["__asm(arg)"] = ''
      @preprocessor.macros["__attribute__(arg)"] = ''
      @preprocessor.macros["__inline"] = "inline"
    end

    def to_ffi
      <<-FFI
require 'ffi'
#{headers.map(&:to_ffi).join("\n")}
module #{module_name}
  extend FFI::Library
  ffi_lib "#{@lib}"

#{ffi_enums_literal}

#{ffi_containers_literal}

  # load functions from modules
#{headers.map {|h| "  include #{h.module_name}"}.join("\n")}
end
FFI
    end

    def to_module
      Object.class_eval to_ffi
    end

    def source
      @source ||=
        begin
          includer = @files.map {|f| "#include \"#{f}\""}.join("\n").force_encoding("ASCII-8BIT")
          @preprocessor.preprocess(includer, true)
      end
    end

    def asts
      @asts ||=
        begin
          @typedef_map = {}
          asts = Hash.new {|h,k| h[k] = []}
          # only look at lines that don't start with #
          source.scan(/(?:^# \d+ "(.+)".*$\n|\n)+(?m:([^#].*?))(?=^#)/) do |file,content|
            begin
              entities = @parser.parse(content).entities.to_a
              asts[file].concat entities
              entities.each do |entity|
                if entity.typedef?
                  entity.declarators.each do |decl|
                    type = entity.type
                    if !type.name && NAMED_TYPES.include?(type.class)
                      # consider first typedef as name for nameless structs/unions/enums
                      type.name = decl.name
                    end
                    @typedef_map[decl.name] = entity.type
                  end
                end
              end
            rescue => e
              raise ParseError, "Failed to parse #{file}: #{e.message}\nContent:\n#{content}", e.backtrace
            end
          end
          asts
      end
    end

    def headers
      @required_enums = Hash.new {|h,k| h[k] = []}
      @required_containers = Hash.new {|h,k| h[k] = []}
      files.map {|f| Header.new(f, self)}
    end

    private
    def ffi_containers_literal
      # TODO: make sure to put definitions of nested types before each container definition
      return @required_containers.map do |container, functions|
        referring_functions = functions.uniq.map do |func|
          "  # required by #{func}()"
        end.join("\n")

        # TODO: handle nested struct/unions
        if container.members
          layout = "    layout(\n" << container.members.map do |member|
            "      :#{member.declarators.first.name}, #{ffi_type_literal member.type, "parent #{container.class.to_s.demodulize}"}"
          end.join(",\n") << "\n    )"
        else
          layout = "    # empty struct"
        end

        "#{referring_functions}\n  class #{container.name.camelize} < FFI::#{container.class.to_s.demodulize}\n#{layout}\n  end"
      end.join("\n")
    end

    def ffi_enums_literal
      @required_enums.map do |enum, function_names|
        literal = enum.members.map do |member|
          if member.val
            "    :#{member.name}, #{member.val.val}"
          else
            "    :#{member.name}"
          end
        end.join(",\n")
        function_names.uniq.map do |function_name|
          "  # required by #{function_name}()"
        end.join("\n") + "\n  #{enum.name.camelize} = enum(\n#{literal}\n  )"
      end.join("\n")
    end
  end

  class Header
    include Helper

    RUBY_INDENT = 2
    attr_reader :module_name, :class_path, :declarations

    def initialize(header, library)
      @header = header
      @library = library
      @ast = library.asts[header]
      @module_name = filepath_to_module_name header

      # These are shared with @library and across all its headers
      @required_containers = library.required_containers
      @required_enums      = library.required_enums
      @typedef_map         = library.typedef_map
    end

    def indent(level)
      ' ' * level * RUBY_INDENT
    end

    def header
      <<-HEADER.strip_heredoc
        module #{@library.module_name}
          module #{module_name}
            # from #{@header}
            def self.included(base)
              base.module_eval do
      HEADER
    end

    def footer
      <<-FOOTER.strip_heredoc
              end
            end
          end
        end
      FOOTER
    end

    def to_ffi
      "#{header}#{declarations}#{footer}"
    end

    def declarations
      @functions = []
      @callbacks = []
      # gather functions
      @ast.each do |node|
        case node
        when C::Declaration
          node.declarators.each do |declarator|
            type = declarator.type
            case type
            when C::Function
              type.type = node.type # record return type of function inside the actual function node
              @functions << declarator
            when C::Pointer
              pointee = type.type
              if node.typedef? && pointee.is_a?(C::Function)
                pointee.type = node.type # record return type of function inside the actual function node
                @callbacks << declarator
              end
            end
          end
        when C::FunctionDef
          # TODO
        end
      end
      # gather callbacks, enums, structs, and typedefs the functions rely on
      "#{ffi_callbacks_literal}#{ffi_functions_literal}"
    end

    private
    def ffi_functions_literal
      @functions.map do |function|
        "        attach_function :#{function.name}, #{ffi_params_and_return_type function.name, function.type}"
      end.join
    end

    def ffi_callbacks_literal
      @callbacks.map do |callback|
        "        callback :#{callback.name}, #{ffi_params_and_return_type callback.name, callback.type.type}"
      end.join
    end

    # function_name is required only so that named types referred to by
    # function can know which function referred to them.
    def ffi_params_and_return_type(function_name, function_type)
      params = Array(function_type.params).map {|param| ffi_type_literal(param.type, function_name)}
      return_type = ffi_type_literal(function_type.type, function_name)
      "[#{params.join(', ')}], #{return_type}\n"
    end
  end
end
