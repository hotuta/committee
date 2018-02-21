module Committee::Drivers
  class OpenAPI2 < Committee::Drivers::Driver
    # Whether parameters that were form-encoded will be coerced by default.
    def default_coerce_form_params
      true
    end

    # Whether parameters in a request's path will be considered and coerced by
    # default.
    def default_path_params
      true
    end

    # Whether parameters in a request's query string will be considered and
    # coerced by default.
    def default_query_params
      true
    end

    def name
      :open_api_2
    end

    # Parses an API schema and builds a set of route definitions for use with
    # Committee.
    #
    # The expected input format is a data hash with keys as strings (as opposed
    # to symbols) like the kind produced by JSON.parse or YAML.load.
    def parse(data)
      REQUIRED_FIELDS.each do |field|
        if !data[field]
          raise ArgumentError, "Committee: no #{field} section in spec data."
        end
      end

      if data['swagger'] != '2.0'
        raise ArgumentError, "Committee: driver requires OpenAPI 2.0."
      end

      schema = Schema.new
      schema.driver = self

      schema.base_path = data['basePath'] || ''

      # Arbitrarily choose the first media type found in these arrays. This
      # appraoch could probably stand to be improved, but at least users will
      # for now have the option of turning media type validation off if they so
      # choose.
      schema.consumes = data['consumes'].first
      schema.produces = data['produces'].first

      schema.definitions, store = parse_definitions!(data)
      schema.routes = parse_routes!(data, schema, store)

      schema
    end

    def schema_class
      Committee::Drivers::OpenAPI2::Schema
    end

    # Link abstracts an API link specifically for OpenAPI 2.
    class Link
      # The link's input media type. i.e. How requests should be encoded.
      attr_accessor :enc_type

      attr_accessor :href

      # The link's output media type. i.e. How responses should be encoded.
      attr_accessor :media_type

      attr_accessor :method

      # The link's input schema. i.e. How we validate an endpoint's incoming
      # parameters.
      attr_accessor :schema

      attr_accessor :status_success

      # The link's output schema. i.e. How we validate an endpoint's response
      # data.
      attr_accessor :target_schema

      def rel
        raise "Committee: rel not implemented for OpenAPI"
      end
    end

    # ParameterSchemaBuilder converts OpenAPI 2 link parameters, which are not
    # quite JSON schemas (but will be in OpenAPI 3) into synthetic schemas that
    # we can use to do some basic request validation.
    class ParameterSchemaBuilder
      def initialize(link_data)
        self.link_data = link_data
      end

      # Returns a tuple of (schema, schema_data) where only one of the two
      # values is present. This is either a full schema that's ready to go _or_
      # a hash of unparsed schema data.
      def call
        if link_data["parameters"]
          body_param = link_data["parameters"].detect { |p| p["in"] == "body" }
          if body_param
            check_required_fields!(body_param)

            if link_data["parameters"].detect { |p| p["in"] == "form" } != nil
              raise ArgumentError, "Committee: can't mix body parameter " \
                "with form parameters."
            end

            schema_data = body_param["schema"]
            [nil, schema_data]
          else
            link_schema = JsonSchema::Schema.new
            link_schema.properties = {}
            link_schema.required = []

            link_data["parameters"].each do |param_data|
              check_required_fields!(param_data)

              param_schema = JsonSchema::Schema.new

              # We could probably use more validation here, but the formats of
              # OpenAPI 2 are based off of what's available in JSON schema, and
              # therefore this should map over quite well.
              param_schema.type = [param_data["type"]]

              # And same idea: despite parameters not being schemas, the items
              # key (if preset) is actually a schema that defines each item of an
              # array type, so we can just reflect that directly onto our
              # artifical schema.
              if param_data["type"] == "array" && param_data["items"]
                param_schema.items = param_data["items"]
              end

              link_schema.properties[param_data["name"]] = param_schema
              if param_data["required"] == true
                link_schema.required << param_data["name"]
              end
            end

            [link_schema, nil]
          end
        end
      end

      private

      LINK_REQUIRED_FIELDS = [
        :name
      ].map(&:to_s).freeze

      attr_accessor :link_data

      def check_required_fields!(param_data)
        LINK_REQUIRED_FIELDS.each do |field|
          if !param_data[field]
            raise ArgumentError,
              "Committee: no #{field} section in link data."
          end
        end
      end
    end

    class Schema < Committee::Drivers::Schema
      attr_accessor :base_path
      attr_accessor :consumes

      # A link back to the derivative instace of Committee::Drivers::Driver
      # that create this schema.
      attr_accessor :driver

      attr_accessor :definitions
      attr_accessor :produces
      attr_accessor :routes
    end

    private

    DEFINITIONS_PSEUDO_URI = "http://json-schema.org/committee-definitions"

    # These are fields that the OpenAPI 2 spec considers mandatory to be
    # included in the document's top level.
    REQUIRED_FIELDS = [
      :consumes,
      :definitions,
      :paths,
      :produces,
      :swagger,
    ].map(&:to_s).freeze

    def find_best_fit_response(link_data)
      if response_data = link_data["responses"][200]
        [200, response_data]
      elsif response_data = link_data["responses"][201]
        [201, response_data]
      else
        # Sort responses so that we can try to prefer any 3-digit status code.
        # If there are none, we'll just take anything from the list.
        ordered_responses = link_data["responses"].
          select { |k, v| k =~ /[0-9]{3}/ }
        if first = ordered_responses.first
          [first[0].to_i, first[1]]
        else
          [nil, nil]
        end
      end
    end

    def href_to_regex(href)
      href.gsub(/\{(.*?)\}/, '(?<\1>[^/]+)')
    end

    def parse_definitions!(data)
      # The "definitions" section of an OpenAPI 2 spec is a valid JSON schema.
      # We extract it from the spec and parse it as a schema in isolation so
      # that all references to it will still have correct paths (i.e. we can
      # still find a resource at '#/definitions/resource' instead of
      # '#/resource').
      schema = JsonSchema.parse!({
        "definitions" => data['definitions'],
      })
      schema.expand_references!
      schema.uri = DEFINITIONS_PSEUDO_URI

      # So this is a little weird: an OpenAPI specification is _not_ a valid
      # JSON schema and yet it self-references like it is a valid JSON schema.
      # To work around this what we do is parse its "definitions" section as a
      # JSON schema and then build a document store here containing that. When
      # trying to resolve a reference from elsewhere in the spec, we build a
      # synthetic schema with a JSON reference to the document created from
      # "definitions" and then expand references against this store.
      store = JsonSchema::DocumentStore.new
      store.add_schema(schema)

      [schema, store]
    end

    def parse_routes!(data, schema, store)
      routes = {}

      # This is a performance optimization: instead of going through each link
      # and parsing out its JSON schema separately, instead we just aggregate
      # all schemas into one big hash and then parse it all at the end. After
      # we parse it, go through each link and assign a proper schema object. In
      # practice this comes out to somewhere on the order of 50x faster.
      schemas_data = { "properties" => {} }

      # Exactly the same idea, but for response schemas.
      target_schemas_data = { "properties" => {} }

      data['paths'].each do |path, methods|
        href = schema.base_path + path
        schemas_data["properties"][href] = { "properties" => {} }
        target_schemas_data["properties"][href] = { "properties" => {} }

        methods.each do |method, link_data|
          method = method.upcase

          link = Link.new
          link.enc_type = schema.consumes
          link.href = href
          link.media_type = schema.produces
          link.method = method

          # Convert the spec's parameter pseudo-schemas into JSON schemas that
          # we can use for some basic request validation.
          link.schema, schema_data = ParameterSchemaBuilder.new(link_data).call

          # If data came back instead of a schema (this occurs when a route has
          # a single `body` parameter instead of a collection of URL/query/form
          # parameters), store it for later parsing.
          if schema_data
            schemas_data["properties"][href]["properties"][method] = schema_data
          end

          # Arbitrarily pick one response for the time being. Prefers in order:
          # a 200, 201, any 3-digit numerical response, then anything at all.
          status, response_data = find_best_fit_response(link_data)
          if status
            link.status_success = status

            # A link need not necessarily specify a target schema.
            if response_data["schema"]
              target_schemas_data["properties"][href]["properties"][method] =
                response_data["schema"]
            end
          end

          rx = %r{^#{href_to_regex(link.href)}$}
          Committee.log_debug "Created route: #{link.method} #{link.href} (regex #{rx})"

          routes[method] ||= []
          routes[method] << [rx, link]
        end
      end

      # See the note on our DocumentStore's initialization in
      # #parse_definitions!, but what we're doing here is prefixing references
      # with a specialized internal URI so that they can reference definitions
      # from another document in the store.
      schemas =
        rewrite_references_and_parse(schemas_data, store)
      target_schemas =
        rewrite_references_and_parse(target_schemas_data, store)

      # As noted above, now that we've parsed our aggregate response schema, go
      # back through each link and them their response schema.
      routes.each do |method, method_routes|
        method_routes.each do |(_, link)|
          # request
          #
          # Differs slightly from responses in that the schema may already have
          # been set for endpoints with non-body parameters, so check for nil
          # before we set it.
          if schema = schemas.properties[link.href].properties[method]
            link.schema = schema
          end

          # response
          link.target_schema =
            target_schemas.properties[link.href].properties[method]
        end
      end

      routes
    end

    def rewrite_references_and_parse(schemas_data, store)
      schemas = rewrite_references(schemas_data)
      schemas = JsonSchema.parse!(schemas_data)
      schemas.expand_references!(:store => store)
      schemas
    end

    def rewrite_references(schema)
      if schema.is_a?(Hash)
        ref = schema["$ref"]
        if ref && ref.is_a?(String) && ref[0] == "#"
          schema["$ref"] = DEFINITIONS_PSEUDO_URI + ref
        else
          schema.each do |_, v|
            rewrite_references(v)
          end
        end
      end
      schema
    end
  end
end
