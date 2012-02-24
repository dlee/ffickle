require 'active_support/core_ext'
require 'open3'
require 'cast'

module FFIckle
  NAMED_TYPES = [C::Struct, C::Union, C::Enum]

  class ParseError < ::StandardError; end

  class Library
    attr_reader :files, :typedef_map

    def initialize(*files)
      @files = files.flatten.map {|f| File.expand_path f}
      @parser = C::Parser.new
      @parser.type_names << '__builtin_va_list'
      @preprocessor = C::Preprocessor.new 

      # Remove GNU-specific keywords that we don't need
      @preprocessor.macros["__asm(arg)"] = ''
      @preprocessor.macros["__attribute__(arg)"] = ''
      @preprocessor.macros["__inline"] = "inline"
    end

    def to_ffi
      asts.to_ffi
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
          @typedef_map = {"__builtin_va_list" => ":varargs"}
          asts = Hash.new {|h,k| h[k] = []}
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

    def rubies
      files.map {|f| Ruby.new(f, self)}
    end
  end

  class Ruby
    RUBY_INDENT = 2
    attr_reader :ruby_name, :class_path, :declarations

    def initialize(header, library)
      @header = header
      @library = library
      @ast = library.asts[header]
      @ruby_name = @header.sub(/^(?:\/(?:usr|local|lib|include|Library|opt))*\//, '').gsub(/\.\w+$/, '').underscore.camelize
      @class_path = @ruby_name.split("::")
      @depth = @class_path.size
      @inner_indent = indent(@depth)
    end

    def indent(level)
      ' ' * level * RUBY_INDENT
    end

    def header
      @class_path.map.with_index {|n,i| "#{indent(i)}#{(i + 1 == @class_path.length) ? 'class' : 'module'} #{n}\n" }.join
    end

    def footer
      @class_path.map.with_index {|n,i| "#{indent(@depth - i - 1)}end\n"}.join
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
            indirect_type = declarator.indirect_type
            case indirect_type
            when C::Function
              indirect_type.type = node.type unless indirect_type.type # record return type of function
              @functions << declarator
            when C::Pointer
              if indirect_type.type.is_a? C::Function
                @callbacks << indirect_type.type
              end
            end
          end
        end
      end
      # gather callbacks, enums, structs, and typedefs the functions rely on
      @required_callbacks = []
      @required_enums = []
      @required_structs = []
      @required_unions = []
      @functions.map do |func|
        name = func.name
        params = Array(func.type.params).map {|param| ultimate_type(param.type)}
        return_type = ultimate_type(func.type.type)
        "#{@inner_indent}attach_function :#{name}, [#{params.join(', ')}], #{return_type}\n"
      end.join
    end

    private
    def ultimate_type(type)
      case type
      when C::Pointer
        # TODO: mark type.type for definition?
        if type =~ 'const char *'
          ":string"
        else
          ":pointer"
        end
      when C::CustomType
        ultimate_type @library.typedef_map[type.name]
      when *NAMED_TYPES
        "#{type.name.camelize}.by_value"
      when C::PrimitiveType
        name = type.to_s
        name.gsub!(/^(const )?(restrict )?(volatile )?/, ':')
        name.gsub!(/unsigned /, 'u')
        name.gsub!(/ int$/, '')
        name.gsub!(/ /, '_')
        name
      else
        type
      end
    end
  end
end
