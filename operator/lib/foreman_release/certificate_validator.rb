# frozen_string_literal: true

require 'base64'
require 'openssl'
require 'time'
require_relative 'release_inputs'

module ForemanRelease
  class CertificateValidator
    DEFAULT_MINIMUM_VALIDITY_SECONDS = 86_400
    CERTIFICATE_KEY = /(?:\.crt|\.cer|_cert\.pem)\z/i
    CA_BUNDLE_KEY = /\A(?:ca|.+[-_]ca)\.crt\z/i
    KEY_PAIRS = [
      %w[tls.crt tls.key],
      %w[client_cert.pem client_key.pem],
      %w[tomcat.crt tomcat.key],
      %w[candlepin-ca.crt candlepin-ca.key]
    ].freeze
    TRUST_PAIRS = [
      %w[tls.crt ca.crt],
      %w[client_cert.pem ca.crt],
      %w[tomcat.crt candlepin-ca.crt]
    ].freeze

    def initialize(minimum_validity_seconds: DEFAULT_MINIMUM_VALIDITY_SECONDS, clock: -> { Time.now.utc })
      raise ArgumentError, 'certificate minimum validity must be non-negative' if minimum_validity_seconds.negative?

      @minimum_validity_seconds = minimum_validity_seconds
      @clock = clock
    end

    def validate_secret!(namespace, name, secret, required_keys, required_identities: {})
      data = secret.fetch('data', {})
      certificate_keys = Array(required_keys).grep(CERTIFICATE_KEY)
      return nil if certificate_keys.empty?

      now = @clock.call.utc
      decoded = {}
      certificates = certificate_keys.to_h do |key|
        pem = decode(data.fetch(key), namespace, name, key)
        decoded[key] = pem
        [key, parse_certificates(pem, namespace, name, key)]
      end
      earliest_expiry = validate_validity!(certificates, required_keys, namespace, name, now)
      validate_key_pairs!(data, decoded, certificates, required_keys, namespace, name)
      trust_expiry = validate_trust_pairs!(certificates, namespace, name, now)
      validate_dns_names!(certificates, required_identities, namespace, name)
      [earliest_expiry, trust_expiry].compact.min
    rescue KeyError => error
      raise InvalidRelease, "Secret #{namespace}/#{name} is missing key #{error.key}"
    end

    private

    def decode(value, namespace, name, key)
      Base64.strict_decode64(value)
    rescue ArgumentError
      raise InvalidRelease, "Secret #{namespace}/#{name} key #{key} is not valid base64"
    end

    def parse_certificates(pem, namespace, name, key)
      blocks = pem.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
      raise InvalidRelease, "Secret #{namespace}/#{name} key #{key} contains no PEM certificate" if blocks.empty?

      blocks.map { |block| OpenSSL::X509::Certificate.new(block) }
    rescue OpenSSL::X509::CertificateError => error
      raise InvalidRelease, "Secret #{namespace}/#{name} key #{key} contains an invalid certificate: #{error.message}"
    end

    def validate_validity!(certificates, required_keys, namespace, name, now)
      required_until = now + @minimum_validity_seconds
      expirations = certificates.map do |key, chain|
        if trust_bundle?(key, required_keys)
          usable = chain.select do |certificate|
            certificate.not_before <= now && certificate.not_after > required_until
          end
          next usable.map(&:not_after).max unless usable.empty?

          raise InvalidRelease,
                "Secret #{namespace}/#{name} key #{key} has no certificate valid through " \
                "the #{@minimum_validity_seconds}-second safety window"
        end

        chain.each do |certificate|
          if certificate.not_before > now
            raise InvalidRelease,
                  "Secret #{namespace}/#{name} key #{key} is not valid before #{certificate.not_before.utc.iso8601}"
          end
          next if certificate.not_after > required_until

          raise InvalidRelease,
                "Secret #{namespace}/#{name} key #{key} expires at #{certificate.not_after.utc.iso8601}, " \
                "before the #{@minimum_validity_seconds}-second safety window"
        end
        chain.map(&:not_after).min
      end
      expirations.min
    end

    def trust_bundle?(key, required_keys)
      return false unless key.match?(CA_BUNDLE_KEY)

      key_pair = KEY_PAIRS.find { |certificate_key, _private_key_key| certificate_key == key }
      !key_pair || !Array(required_keys).include?(key_pair.last)
    end

    def validate_key_pairs!(data, decoded, certificates, required_keys, namespace, name)
      KEY_PAIRS.each do |certificate_key, private_key_key|
        next unless certificates.key?(certificate_key) && Array(required_keys).include?(private_key_key)

        private_key_pem = decoded[private_key_key] ||= decode(
          data.fetch(private_key_key), namespace, name, private_key_key
        )
        private_key = OpenSSL::PKey.read(private_key_pem)
        certificate_key_der = certificates.fetch(certificate_key).first.public_key.to_der
        next if certificate_key_der == private_key.public_key.to_der

        raise InvalidRelease,
              "Secret #{namespace}/#{name} keys #{certificate_key} and #{private_key_key} do not match"
      rescue OpenSSL::PKey::PKeyError => error
        raise InvalidRelease,
              "Secret #{namespace}/#{name} key #{private_key_key} contains an invalid private key: #{error.message}"
      end
    end

    def validate_trust_pairs!(certificates, namespace, name, now)
      expirations = TRUST_PAIRS.each_with_object([]) do |(leaf_key, ca_key), found|
        next unless certificates.key?(leaf_key) && certificates.key?(ca_key)

        leaf_chain = certificates.fetch(leaf_key)
        trust_chain = verified_chain(leaf_chain, certificates.fetch(ca_key), now)
        unless trust_chain
          raise InvalidRelease,
                "Secret #{namespace}/#{name} key #{leaf_key} is not trusted by #{ca_key}"
        end
        unless verified_chain(leaf_chain, certificates.fetch(ca_key), now + @minimum_validity_seconds)
          raise InvalidRelease,
                "Secret #{namespace}/#{name} key #{leaf_key} will not remain trusted by #{ca_key} " \
                "through the #{@minimum_validity_seconds}-second safety window"
        end

        found << trust_chain.map(&:not_after).min
      end
      expirations.min
    end

    def validate_dns_names!(certificates, required_identities, namespace, name)
      required_identities.each do |key, required_dns_names|
        names = Array(required_dns_names).map(&:to_s).reject(&:empty?).uniq.sort
        next if names.empty?

        leaf = certificates.fetch(key).first
        names.each do |dns_name|
          next if OpenSSL::SSL.verify_certificate_identity(leaf, dns_name)

          raise InvalidRelease,
                "Secret #{namespace}/#{name} key #{key} does not cover DNS name #{dns_name}"
        end
      end
    rescue KeyError => error
      raise InvalidRelease,
            "Secret #{namespace}/#{name} must provide #{error.key} for DNS-name validation"
    end

    def verified_chain(leaf_chain, trust_anchors, time)
      store = OpenSSL::X509::Store.new
      store.time = time
      trust_anchors.each { |certificate| store.add_cert(certificate) }
      context = OpenSSL::X509::StoreContext.new(store, leaf_chain.first, leaf_chain.drop(1))
      context.verify ? context.chain : nil
    end
  end
end
