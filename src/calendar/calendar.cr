require "connect-proxy"
require "json"
require "uri"

require "../auth/auth"
require "../auth/file_auth"
require "./event"
require "./events"
require "./g_time"
require "./list"
require "./availability"

module Google
  module RFC3339Converter
    def self.from_json(time : JSON::PullParser) : Time
      Time.parse_rfc3339(time.read_string)
    end

    def self.to_json(time : Time, json : JSON::Builder)
      time.to_json
    end
  end

  enum UpdateGuests
    All
    ExternalOnly
    None
  end

  enum Visibility
    Default
    Public
    Private
  end

  class Calendar
    def initialize(@auth : Google::Auth | Google::FileAuth, user_agent : String? = nil)
      @user_agent = user_agent || @auth.user_agent
    end

    @user_agent : String

    def calendar_list : Array(Calendar::ListEntry)
      response = ConnectProxy::HTTPClient.new(GOOGLE_URI) do |client|
        client.exec("GET", "/calendar/v3/users/me/calendarList", HTTP::Headers{
          "Authorization" => "Bearer #{get_token}",
          "User-Agent"    => @user_agent,
        })
      end

      raise "error fetching calendar list - #{response.status} (#{response.status_code})\n#{response.body}" unless response.success?
      results = Calendar::List.from_json response.body
      results.items
    end

    # example additional options: showDeleted
    def events(calendar_id = "primary", period_start : Time = Time.local.at_beginning_of_day, period_end : Time? = nil, updated_since : Time? = nil, **opts)
      other_options = opts.empty? ? nil : events_other_options(opts)
      updated = updated_since ? "&updatedMin=#{updated_since.to_rfc3339}" : nil
      pend = period_end ? "&timeMax=#{period_end.to_rfc3339}" : nil

      request_uri = "/calendar/v3/calendars/#{calendar_id}/events?maxResults=2500&singleEvents=true&timeMin=#{period_start.to_rfc3339}#{pend}#{updated}#{other_options}"

      response = ConnectProxy::HTTPClient.new(GOOGLE_URI) do |client|
        client.exec(
          "GET",
          request_uri,
          HTTP::Headers{
            "Authorization" => "Bearer #{get_token}",
            "User-Agent"    => @user_agent,
          }
        )
      end

      raise "error fetching events from #{calendar_id} - #{response.status} (#{response.status_code})\n#{response.body}" unless response.success?
      results = Calendar::Events.from_json response.body

      # Return all the pages, nextPageToken will be nil when there are no more
      next_page = results.next_page_token
      loop do
        break unless next_page

        response = ConnectProxy::HTTPClient.new(GOOGLE_URI) do |client|
          client.exec(
            "GET",
            "#{request_uri}&pageToken=#{next_page}",
            HTTP::Headers{
              "Authorization" => "Bearer #{get_token}",
              "User-Agent"    => @user_agent,
            }
          )
        end

        raise "error fetching events from #{calendar_id} - #{response.status} (#{response.status_code})\n#{response.body}" unless response.success?
        next_results = Calendar::Events.from_json response.body

        # Append the results
        results.items.concat(next_results.items)
        next_page = next_results.next_page_token
      end

      results
    end

    def event(event_id, calendar_id = "primary")
      response = ConnectProxy::HTTPClient.new(GOOGLE_URI) do |client|
        client.exec(
          "GET",
          "/calendar/v3/calendars/#{calendar_id}/events/#{event_id}",
          HTTP::Headers{
            "Authorization" => "Bearer #{get_token}",
            "User-Agent"    => @user_agent,
          }
        )
      end

      return nil if {HTTP::Status::GONE, HTTP::Status::NOT_FOUND}.includes?(response.status)
      raise "error fetching events from #{calendar_id} - #{response.status} (#{response.status_code})\n#{response.body}" unless response.success?
      Calendar::Event.from_json response.body
    end

    def delete(event_id, calendar_id = "primary", notify : UpdateGuests = UpdateGuests::None)
      # convert ExternalOnly to externalOnly
      send_notifications = notify.all?
      update_guests = notify.to_s.camelcase(lower: true)

      response = ConnectProxy::HTTPClient.new(GOOGLE_URI) do |client|
        client.exec("DELETE",
          "/calendar/v3/calendars/#{calendar_id}/events/#{event_id}?sendUpdates=#{update_guests}&sendNotifications=#{send_notifications}",
          HTTP::Headers{
            "Authorization" => "Bearer #{get_token}",
            "User-Agent"    => @user_agent,
          }
        )
      end

      # Not an error if the booking doesn't exist
      return true if {HTTP::Status::GONE, HTTP::Status::NOT_FOUND}.includes?(response.status)
      raise "error deleting event #{event_id} from #{calendar_id} - #{response.status} (#{response.status_code})\n#{response.body}" unless response.success?
      true
    end

    # Create an event
    # Supports: summary, description, location
    def create(
      event_start : Time,
      event_end : Time,
      calendar_id = "primary",
      attendees : (Array(String) | Tuple(String)) = [] of String,
      all_day = false,
      visibility : Visibility = Visibility::Default,
      extended_properties = nil,
      **opts
    )
      opts = extended_properties(opts, extended_properties) if extended_properties

      body = opts.merge({
        start:      GTime.new(event_start, all_day),
        "end":      GTime.new(event_end, all_day),
        visibility: visibility.to_s.downcase,
        attendees:  attendees.map { |email| {email: email} },
      }).to_json

      response = ConnectProxy::HTTPClient.new(GOOGLE_URI) do |client|
        client.exec(
          "POST",
          "/calendar/v3/calendars/#{calendar_id}/events?supportsAttachments=true&conferenceDataVersion=1",
          HTTP::Headers{
            "Authorization" => "Bearer #{get_token}",
            "Content-Type"  => "application/json",
            "User-Agent"    => @user_agent,
          },
          body
        )
      end

      raise "error creating booking on #{calendar_id} - #{response.status} (#{response.status_code})\nRequested: #{body}\n#{response.body}" unless response.success?
      Calendar::Event.from_json response.body
    end

    def update(
      event_id,
      calendar_id = "primary",
      event_start : Time? = nil,
      event_end : Time? = nil,
      attendees : (Array(String) | Tuple(String) | Nil) = nil,
      all_day = false,
      visibility : Visibility? = nil,
      extended_properties = nil,
      notify : UpdateGuests = UpdateGuests::None,
      raw_json : String? = nil,
      **opts
    )
      opts = opts.merge({start: GTime.new(event_start, all_day)}) if event_start
      opts = opts.merge({"end": GTime.new(event_end, all_day)}) if event_end
      opts = opts.merge({visibility: visibility.to_s.downcase}) if visibility
      opts = opts.merge({attendees: attendees.map { |email| {email: email} }}) if attendees
      opts = extended_properties(opts, extended_properties) if extended_properties

      body = raw_json || opts.to_json

      response = ConnectProxy::HTTPClient.new(GOOGLE_URI) do |client|
        client.exec(
          "PATCH",
          "/calendar/v3/calendars/#{calendar_id}/events/#{event_id}?supportsAttachments=true&sendUpdates=#{notify}",
          HTTP::Headers{
            "Authorization" => "Bearer #{get_token}",
            "Content-Type"  => "application/json",
            "User-Agent"    => @user_agent,
          },
          body
        )
      end

      raise "error updating booking on #{calendar_id} - #{response.status} (#{response.status_code})\nRequested: #{body}\n#{response.body}" unless response.success?
      Calendar::Event.from_json response.body
    end

    # Move an event to another calendar
    def move(
      event_id : String,
      calendar_id : String,
      destination_id : String,
      notify : UpdateGuests = UpdateGuests::None
    )
      response = ConnectProxy::HTTPClient.new(GOOGLE_URI) do |client|
        client.exec(
          "POST",
          "/calendar/v3/calendars/#{calendar_id}/events/#{event_id}/move?destination=#{destination_id}&sendUpdates=#{notify}",
          HTTP::Headers{
            "Authorization" => "Bearer #{get_token}",
            "User-Agent"    => @user_agent,
          }
        )
      end

      raise "error moving event #{event_id} from #{calendar_id} to #{destination_id}- #{response.status} (#{response.status_code})\n#{response.body}" unless response.success?

      Calendar::Event.from_json response.body
    end

    # Find availability (free/busy) for calendars
    def availability(mailboxes : Array(String), starts_at : Time, ends_at : Time)
      time_min = GTime.new(starts_at)
      items = mailboxes.map { |mailbox| {"id" => mailbox} }
      body = {
        "timeMin"  => time_min.date_time,
        "timeMax"  => GTime.new(ends_at).date_time,
        "timeZone" => time_min.time_zone,
        "items"    => items,
      }.to_json
      response = ConnectProxy::HTTPClient.new(GOOGLE_URI) do |client|
        client.exec(
          "POST",
          "/calendar/v3/freeBusy",
          HTTP::Headers{
            "Authorization" => "Bearer #{get_token}",
            "Content-Type"  => "application/json",
            "User-Agent"    => @user_agent,
          },
          body
        )
      end

      raise "error fetching free/busy information #{response.status} (#{response.status_code})\n#{response.body}" unless response.success?

      Calendar::Availability.parse_json(response.body).value
    end

    private def events_other_options(opts) : String
      opts_string = opts.map { |key, value| "#{key}=#{value}" }.join("&")
      "&#{opts_string}"
    end

    private def get_token
      @auth.get_token.access_token
    end

    protected def extended_properties(opts, extended_properties)
      extended_keys = {} of String => String?

      extended_properties.each do |key, value|
        extended_keys[key.to_s] = case value
                                  when Nil, String
                                    value
                                  else
                                    value.to_json
                                  end
      end

      opts = opts.merge({
        extendedProperties: {
          shared: extended_keys,
        },
      })

      opts
    end
  end
end
