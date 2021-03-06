module TLSPretense
module TestHarness

  # TestListener is the real workhorse used by SSLTestCases. It builds on the
  # SSLSmartProxy from PacketThief in order to intercept and forward SSL
  # connections. It uses SSLSmartProxy because SSLSmartProxy provides a default
  # behavior where it grabs the remote certificate from the destination and
  # re-signs it before presenting it to the client.
  #
  # TestListener expands on this by presenting the configured test chain
  # instead of the re-signed remote certificate when the destination
  # corresponds to the hostname the test suite is testing off of.
  class TestListener < PacketThief::Handlers::SSLSmartProxy

    # For all hosts that do not match _hosttotest_, we currently use the
    # _cacert_ and re-sign the original cert provided by the actual host. This
    # will cause issues with certificate revocation.
    #
    # * _cacert_  [OpenSSL::X509::Certificate] A CA that the client should
    #   trust.
    # * _cakey_   [OpenSSL::PKey::PKey] The CA's key, needed for resigning. It
    #   will also be the key used by the resigned certificates.
    # * _hosttotest_  [String] The hostname we want to apply the test chain to.
    # * _chaintotest_ [Array<OpenSSL::X509Certificate>] A chain of certs to
    #   present when the client attempts to connect to hostname.
    # * _keytotest_   [OpenSSL::PKey::PKey] The key corresponding to the leaf
    #   node in _chaintotest_.
    def initialize(tcpsocket, test_manager, logger=nil)
      @test_manager = test_manager

      if @test_manager.paused?
        @paused = true
      else
        @paused = false
        @test = @test_manager.current_test
        @hosttotest = @test.hosttotest
        chain = @test.certchain.dup
        @hostcert = chain.shift
        @hostkey = @test.keychain[0]
        @extrachain = chain
      end
      # Use the goodca for hosts we don't care to test against.
      super(tcpsocket, @test_manager.goodcacert, @test_manager.goodcakey, logger)

      @test_status = :running
      @testing_host = false
    end

    # Checks whether the initial original destination certificate (without SNI
    # hostname) matches the test hostname. We do this with post_init to have
    # the check happen after the parent class already added a re-signed
    # certificate to +@ctx+.
    def post_init
      check_for_hosttotest(@ctx)
    end

    # Checks whether the original destination certificate after we handle the
    # SNI hostname matches the test hostname. Super already replaced the
    # context with a certificate based on the remote host's certificate.
    def servername_cb(sslsock, hostname)
      check_for_hosttotest(super(sslsock, hostname))
    end

    # Replaces the certificates used in the SSLContext with the test
    # certificates if the destination matches the hostname we wish to test
    # against. Otherwise, it leaves the context alone.
    #
    # Additionally, if it matches, it sets @testing_host to true to check
    # whether the test succeeds or not.
    def check_for_hosttotest(actx)
      if @paused
        logdebug "Testing is paused, not checking whether this is the host to test", :certcubject => actx.cert.subject
      elsif TestListener.cert_matches_host(actx.cert, @hosttotest)
        logdebug "Destination matches host-to-test", :hosttotest => @hosttotest, :certsubject => actx.cert.subject, :testname => @test.id
        actx.cert = @hostcert
        actx.key = @hostkey
        actx.extra_chain_cert = @extrachain
        @testing_host = true
      else
        logdebug "Destination does not match host-to-test", :hosttotest => @hosttotest, :certsubject => actx.cert.subject
      end
      actx
    end

    # Return true if _cert_'s CNAME or subjectAltName matches hostname,
    # otherwise return false.
    def self.cert_matches_host(cert, hostname)
      OpenSSL::SSL.verify_certificate_identity(cert, hostname)
    end

    # If the client completes connecting, we might consider that trusting our
    # certificate chain. However, at least Java's SSL client classes don't
    # reject until after completing the handshake.
    def tls_successful_handshake
      super
      logdebug "successful handshake"
      if @testing_host
        @test_status = :connected
        if @test_manager.testing_method == 'tlshandshake'
          @test_manager.test_completed(@test, @test_status)
          @testing_host = false
        end
      end
    end

    # If the handshake failed, then the client rejected our cert chain.
    def tls_failed_handshake(e)
      super
      logdebug "failed handshake"
      if @testing_host
        @test_status = :rejected
        @test_manager.test_completed(@test, @test_status)
        @testing_host = false
      end
    end

    # Report our result.
    def unbind
      super
      logdebug "unbind"
      if @testing_host
        @test_manager.test_completed(@test, @test_status)
        @testing_host = false
      end
    end

    # client_recv means that the client sent data over the TLS connection,
    # meaning they definately trusted our certificate chain.
    def client_recv(data)
      if @testing_host
        @test_status = :sentdata
        if @test_manager.testing_method == 'senddata'
          @test_manager.test_completed(@test, @test_status)
          @testing_host = false
        end
      end
      super(data)
    end

  end
end
end
