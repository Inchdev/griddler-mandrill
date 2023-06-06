module Griddler
  module Mandrill
    class Adapter
      def initialize(params)
        @params = params
      end

      def self.normalize_params(params)
        adapter = new(params)
        adapter.normalize_params
      end

      def normalize_params
        # reject event on confirmed SPF error
        # or reject invalid DKIM signatures
        #
        # accept by default in case of payload regression
        # https://mailchimp.com/developer/transactional/docs/webhooks/#detailed-webhook-format-responses
        events.reject do |event|
          # event[:spf] or event[:spf][:result] might be nil
          # if an error occurred while checking SPF for the message
          (
            event[:spf].present? && (
              # possible values for result are
              # pass, neutral, fail, softfail, temperror, permerror, none
              event[:spf][:result] == 'fail' ||
              event[:spf][:result] == 'temperror' ||
              event[:spf][:result] == 'permerror'
            )
          )
          # Orange and Wanadoo senders might fail to send a valid DKIM signature
          # || (
          #   event[:dkim].present? &&
          #   event[:dkim][:signed] == true &&
          #   event[:dkim][:valid] == false
          # )
        end.map do |event|
          {
            to: recipients(:to, event),
            cc: recipients(:cc, event),
            bcc: resolve_bcc(event),
            headers: event[:headers],
            from: full_email([ event[:from_email], event[:from_name] ]),
            subject: event[:subject],
            text: event[:text] || '',
            html: event[:html] || '',
            raw_body: event[:raw_msg],
            attachments: attachment_files(event),
            email: event[:email], # the email address where Mandrill received the message
            spam_report: event[:spam_report]
          }
        end
      end

      private

      attr_reader :params

      def events
        @events ||= ActiveSupport::JSON.decode(params[:mandrill_events]).map { |event|
          event['msg'].with_indifferent_access if event['event'] == 'inbound'
        }.compact
      end

      def recipients(field, event)
        Array.wrap(event[field]).map { |recipient| full_email(recipient) }
      end

      def resolve_bcc(event)
        email = event[:email]
        to_and_cc = (event[:to].to_a + event[:cc].to_a).compact.map(&:first)
        to_and_cc.include?(email) ? [] : [full_email([email, email.split("@")[0]])]
      end

      def full_email(contact_info)
        email = contact_info[0]
        if contact_info[1]
          "#{contact_info[1]} <#{email}>"
        else
          email
        end
      end

      def attachment_files(event)
        files(event, :attachments) + files(event, :images)
      end

      def files(event, key)
        files = event[key] || Hash.new

        files.map do |key, file|
          file[:base64] = true if !file.has_key?(:base64)

          ActionDispatch::Http::UploadedFile.new({
            filename: file[:name],
            type: file[:type],
            tempfile: create_tempfile(file)
          })
        end
      end

      def create_tempfile(attachment)
        filename = attachment[:name].gsub(/\/|\\/, '_')
        tempfile = Tempfile.new(filename, Dir::tmpdir, encoding: 'ascii-8bit')
        content = attachment[:content]
        content = Base64.decode64(content) if attachment[:base64]
        tempfile.write(content)
        tempfile.rewind
        tempfile
      end
    end
  end
end
