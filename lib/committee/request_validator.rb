module Committee
  class RequestValidator
    def initialize(link, options = {})
      @link = link
      @logger = options[:logger]
      @check_content_type = options.fetch(:check_content_type, true)
    end

    def call(request, data)
      check_content_type!(request, data) if @check_content_type
      if @link.schema
        valid, errors = @link.schema.validate(data)
        if !valid
          errors = JsonSchema::SchemaError.aggregate(errors).join("\n")
          if @logger
            @logger.call.warn "Invalid request.\n\n#{errors}"
          else
            raise InvalidRequest, "Invalid request.\n\n#{errors}"
          end
        end
      end
    end

    private

    def request_media_type(request)
      request.content_type.to_s.split(";").first.to_s
    end

    def check_content_type!(request, data)
      content_type = request_media_type(request)
      if content_type && @link.enc_type && !empty_request?(request)
        unless Rack::Mime.match?(content_type, @link.enc_type)
          if @logger
            @logger.call.warn %{"Content-Type" request header must be set to "#{@link.enc_type}".}
          else
            raise Committee::InvalidRequest,
                  %{"Content-Type" request header must be set to "#{@link.enc_type}".}
          end
        end
      end
    end

    def empty_request?(request)
      # small optimization: assume GET and DELETE don't have bodies
      return true if request.get? || request.delete? || !request.body

      data = request.body.read
      request.body.rewind
      data.empty?
    end
  end
end
