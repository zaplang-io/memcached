@test
def _key_boundaries():
    _validate_key(b"!")
    _validate_key(b"with:punctuation~")
    auto longest = b""
    for index in range(250):
        longest = longest + b"k"
    _validate_key(longest)

    list[bytes] invalid = [
        b"",
        longest + b"k",
        b"space here",
        b"\n",
        b"\r",
        b"\t",
        bytes([0]),
        bytes([31]),
        bytes([127]),
        bytes([255]),
        bytes("é"),
    ]
    for key in invalid:
        auto rejected = False
        try:
            _validate_key(key)
        except MemcacheIllegalInputError:
            rejected = True
        assert rejected

@test
def _coalesced_frames():
    auto reader = _Reader(
        b"",
        b"FIRST\r\n\r\nVALUE k 0 4\r\n" + bytes([0, 13, 10, 255]) + b"\r\nEND\r\n",
    )
    assert reader._read_line() == b"FIRST"
    assert reader._read_line() == b""
    assert reader._read_line() == b"VALUE k 0 4"
    assert reader._read_block(4) == bytes([0, 13, 10, 255])
    assert reader._read_line() == b"END"

    auto empty = _Reader(b"", b"\r\nEND\r\n")
    assert empty._read_block(0) == b""
    assert empty._read_line() == b"END"

@test
def _invalid_frames():
    auto line_limit = b"01234567"
    for index in range(10):
        line_limit = line_limit + line_limit
    auto maximum = _Reader(b"", line_limit + b"\r\n")
    assert maximum._read_line() == line_limit
    for wire in [b"bare\n", b"wrong\rX", line_limit + b"X\r\n"]:
        auto reader = _Reader(b"", wire)
        auto rejected = False
        try:
            reader._read_line()
        except MemcacheUnknownError:
            rejected = True
        assert rejected

    auto block = _Reader(b"", b"x\rX")
    auto malformed = False
    try:
        block._read_block(1)
    except MemcacheUnknownError:
        malformed = True
    assert malformed
    auto negative = False
    try:
        block._read_block(-1)
    except MemcacheUnknownError:
        negative = True
    assert negative

@test
def _server_errors():
    auto reader = _Reader(
        b"",
        b"ERROR\r\nCLIENT_ERROR invalid argument\r\nSERVER_ERROR \r\nSERVER_ERROR " + bytes([255]) + b"\r\nCLIENT_ERROR\r\nSERVER_ERROR\r\nERROR_LIKE\r\n",
    )
    auto command = False
    try:
        reader._read_line()
    except MemcacheUnknownCommandError:
        command = True
    assert command
    auto client = False
    try:
        reader._read_line()
    except MemcacheClientError as message:
        client = message == "invalid argument"
    assert client
    auto empty = False
    try:
        reader._read_line()
    except MemcacheServerError as message:
        empty = message == ""
    assert empty
    auto binary = False
    try:
        reader._read_line()
    except MemcacheServerError as message:
        binary = message == "Non-UTF-8 server error (hex): ff"
    assert binary
    auto empty_client = False
    try:
        reader._read_line()
    except MemcacheClientError as message:
        empty_client = message == ""
    assert empty_client
    auto empty_server = False
    try:
        reader._read_line()
    except MemcacheServerError as message:
        empty_server = message == ""
    assert empty_server
    assert reader._read_line() == b"ERROR_LIKE"

def _fake_server(bytes listener, bytes value):
    auto socket = net.accept(listener)
    try:
        net.set_read_deadline(socket, 3000)
        auto reader = _Reader(socket, b"")
        assert reader._read_line() == b"version"
        net.send(socket, b"VERSION 1.6\r\n" + value + b"\r\nEND\r\n")
        net.send(socket, b"partial")
    finally:
        net.close_conn(socket)

@test
def _loopback_protocol():
    auto listener = net.listen("127.0.0.1", 0)
    auto value = bytes([0, 13, 10, 255])
    for index in range(15):
        value = value + value
    try:
        scope(timeout=5000):
            spawn _fake_server(listener, value)
            auto socket = _dial("localhost", net.port(listener), 3.0)
            try:
                net.set_read_deadline(socket, 3000)
                auto rejected = False
                try:
                    _send_line(socket, b"version\r\n")
                except MemcacheIllegalInputError:
                    rejected = True
                assert rejected
                _send_line(socket, b"version")
                auto reader = _Reader(socket, b"")
                # Preload through CR to exercise a split delimiter regardless
                # of how the OS segments the fake server's response.
                reader._pending = reader._take(len(b"VERSION 1.6\r"))
                assert reader._read_line() == b"VERSION 1.6"
                assert reader._read_block(len(value)) == value
                assert reader._read_line() == b"END"
                auto closed = False
                try:
                    reader._read_line()
                except MemcacheUnexpectedCloseError:
                    closed = True
                assert closed
            finally:
                net.close_conn(socket)
    finally:
        net.close_listener(listener)

def _wait_for_close(bytes listener):
    auto socket = net.accept(listener)
    try:
        net.set_read_deadline(socket, 3000)
        assert net.recv(socket, 1) == ""
    finally:
        net.close_conn(socket)

@test
def _read_timeout():
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _wait_for_close(listener)
            auto socket = _dial("127.0.0.1", net.port(listener), 0.0)
            try:
                net.set_read_deadline(socket, 30)
                auto reader = _Reader(socket, b"VERSION 1.6\r")
                auto timed_out = False
                try:
                    reader._read_line()
                except MemcacheTimeoutError:
                    timed_out = True
                assert timed_out
            finally:
                net.close_conn(socket)
    finally:
        net.close_listener(listener)

@test
def _connect_errors():
    for seconds in [-1.0, math.inf, math.nan, 9223372037.0]:
        auto rejected = False
        try:
            _dial("localhost", 11211, seconds)
        except MemcacheIllegalInputError:
            rejected = True
        assert rejected
    for port in [-1, 0, 65536]:
        auto rejected = False
        try:
            _dial("localhost", port, 1.0)
        except MemcacheIllegalInputError:
            rejected = True
        assert rejected
    auto missing_host = False
    try:
        _dial("", 11211, 1.0)
    except MemcacheIllegalInputError:
        missing_host = True
    assert missing_host

    # A one-nanosecond deadline expires before the hostname can resolve.
    auto expired = False
    try:
        auto socket = _dial("localhost", 11211, 0.000000001)
        net.close_conn(socket)
    except MemcacheTimeoutError:
        expired = True
    assert expired

    auto listener = net.listen("127.0.0.1", 0)
    auto port = net.port(listener)
    net.close_listener(listener)
    auto refused = False
    try:
        auto socket = _dial("127.0.0.1", port, 3.0)
        net.close_conn(socket)
    except MemcacheConnectionError:
        refused = True
    assert refused

def _lifecycle_peer(bytes listener):
    for attempt in range(3):
        auto socket = net.accept(listener)
        try:
            net.set_deadline_ns(socket, _deadline_after(3.0))
            auto reader = _Reader(socket, b"")
            assert reader._read_line() == b"version"
            if attempt == 1:
                net.send(socket, b"SERVER_ERROR test failure\r\n")
            else:
                net.send(socket, b"VERSION fake\r\n")
            assert net.recv(socket, 1) == ""
        finally:
            net.close_conn(socket)

@test
def _client_lifecycle():
    auto defaults = Client(host="localhost")
    assert defaults.port == 11211
    assert defaults.connect_timeout == 0.0
    assert defaults.timeout == 0.0
    assert defaults._reader == None
    defaults.disconnect()

    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _lifecycle_peer(listener)
            auto client = Client(
                host="localhost",
                port=net.port(listener),
                connect_timeout=3.0,
                timeout=3.0,
            )
            try:
                client.connect()
                client.connect()
                assert client._request_line(b"version") == b"VERSION fake"
                client.disconnect()
                client.disconnect()

                auto failed = False
                try:
                    client._request_line(b"version")
                except MemcacheServerError as message:
                    failed = message == "test failure"
                assert failed
                assert client._reader == None
                assert client._request_line(b"version") == b"VERSION fake"
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

def _busy_peer(bytes listener, channel[bool] started, channel[bool] proceed):
    auto socket = net.accept(listener)
    try:
        net.set_deadline_ns(socket, _deadline_after(3.0))
        auto reader = _Reader(socket, b"")
        assert reader._read_line() == b"version"
        started <- True
        assert <-proceed
        net.send(socket, b"VERSION fake\r\n")
    finally:
        net.close_conn(socket)

def _client_request(Client client):
    assert client._request_line(b"version") == b"VERSION fake"

@test
def _client_rejects_concurrent_use():
    auto listener = net.listen("127.0.0.1", 0)
    auto client = Client("localhost", port=net.port(listener), timeout=3.0)
    auto idle = Client("localhost")
    auto started = channel[bool]()
    auto proceed = channel[bool]()
    try:
        try:
            scope(timeout=5000):
                spawn _busy_peer(listener, started, proceed)
                spawn _client_request(client)
                assert <-started
                auto disconnect_rejected = False
                try:
                    client.disconnect()
                except MemcacheConnectionError:
                    disconnect_rejected = True
                assert disconnect_rejected

                auto command_rejected = False
                try:
                    client._request_line(b"version")
                except MemcacheConnectionError:
                    command_rejected = True
                assert command_rejected
                idle.disconnect()
                proceed <- True
        finally:
            client.disconnect()
    finally:
        net.close_listener(listener)

def _timeout_peer(bytes listener):
    auto first = net.accept(listener)
    try:
        net.set_deadline_ns(first, _deadline_after(3.0))
        auto reader = _Reader(first, b"")
        assert reader._read_line() == b"version"
        net.send(first, b"VERSION partial")
        assert net.recv(first, 1) == ""
    finally:
        net.close_conn(first)
    auto second = net.accept(listener)
    try:
        net.set_deadline_ns(second, _deadline_after(3.0))
        auto reader = _Reader(second, b"")
        assert reader._read_line() == b"version"
        net.send(second, b"VERSION recovered\r\n")
        assert net.recv(second, 1) == ""
    finally:
        net.close_conn(second)

@test
def _client_timeout_reconnects():
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _timeout_peer(listener)
            auto client = Client("localhost", port=net.port(listener), timeout=0.1)
            try:
                auto timed_out = False
                try:
                    client._request_line(b"version")
                except MemcacheTimeoutError:
                    timed_out = True
                assert timed_out
                assert client._reader == None
                client.timeout = 3.0
                assert client._request_line(b"version") == b"VERSION recovered"
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

@test
def _client_failed_connect_releases_ownership():
    auto client = Client("localhost", port=0)
    for index in range(2):
        auto rejected = False
        try:
            client.connect()
        except MemcacheIllegalInputError:
            rejected = True
        assert rejected
        assert client._reader == None
    client.disconnect()

@test
def _storage_headers():
    assert _storage_header(b"set", b"k", 0, 0, 0, False) == b"set k 0 0 0\r\n"
    assert _storage_header(b"add", b"k", 2592000, 17, 1, True) == b"add k 17 2592000 1 noreply\r\n"
    assert _storage_header(b"replace", b"k", 2592001, 1, 1, False) == b"replace k 1 2592001 1\r\n"
    assert _storage_header(b"replace", b"k", 2147483647, 4294967295, 2147483645, False) == b"replace k 4294967295 2147483647 2147483645\r\n"
    assert _storage_header(b"append", b"k", -2147483648, 0, 0, False) == b"append k 0 -2147483648 0\r\n"
    assert _storage_header(b"prepend", b"k", -1, 0, 4, True) == b"prepend k 0 -1 4 noreply\r\n"

@test
def _storage_invalid_inputs():
    for flags in [-1, 4294967296]:
        auto rejected = False
        try:
            _storage_header(b"set", b"k", 0, flags, 0, True)
        except MemcacheIllegalInputError:
            rejected = True
        assert rejected
    for expire in [-2147483649, 2147483648]:
        auto rejected = False
        try:
            _storage_header(b"set", b"k", expire, 0, 0, True)
        except MemcacheIllegalInputError:
            rejected = True
        assert rejected
    for size in [-1, 2147483646]:
        auto rejected = False
        try:
            _storage_header(b"set", b"k", 0, 0, size, True)
        except MemcacheIllegalInputError:
            rejected = True
        assert rejected
    for command in [b"", b"cas", b"SET", b"set\r\n"]:
        auto rejected = False
        try:
            _storage_header(command, b"k", 0, 0, 0, True)
        except MemcacheIllegalInputError:
            rejected = True
        assert rejected

    auto invalid_key = False
    auto client = Client(host="localhost", port=0)
    try:
        # An invalid key must raise before any I/O even for noreply.
        client.set_value(b"k\r\n", b"", noreply=True)
    except MemcacheIllegalInputError as message:
        invalid_key = message == "A memcached key must use printable ASCII without spaces"
    assert invalid_key

def _expect_storage(_Reader reader, bytes header, bytes value):
    assert reader._read_line() == header
    assert reader._read_block(len(value)) == value

def _storage_peer(bytes listener, bytes large_value):
    auto socket = net.accept(listener)
    try:
        net.set_deadline_ns(socket, _deadline_after(3.0))
        auto reader = _Reader(socket, b"")
        _expect_storage(reader, b"set cache 51 1800000000 131072 noreply", large_value)
        # Withhold all replies until the first acknowledged request arrives.
        _expect_storage(reader, b"add cache 0 0 0", b"")
        net.send(socket, b"NOT_STORED\r\n")
        _expect_storage(reader, b"replace cache 9 60 4", bytes([0, 13, 10, 255]))
        net.send(socket, b"STORED\r\n")
        _expect_storage(reader, b"append cache 0 0 1", b"a")
        net.send(socket, b"STORED\r\n")
        _expect_storage(reader, b"prepend missing 0 0 1", b"b")
        net.send(socket, b"NOT_STORED\r\n")
        _expect_storage(reader, b"set missing 0 0 0", b"")
        net.send(socket, b"CLIENT_ERROR bad value\r\n")
        assert net.recv(socket, 1) == ""
    finally:
        net.close_conn(socket)
    auto next_socket = net.accept(listener)
    try:
        net.set_deadline_ns(next_socket, _deadline_after(3.0))
        auto reader = _Reader(next_socket, b"")
        _expect_storage(reader, b"set missing 0 0 0", b"")
        net.send(next_socket, b"EXISTS\r\n")
        assert net.recv(next_socket, 1) == ""
    finally:
        net.close_conn(next_socket)

@test
def _storage_exchange():
    auto large_value = bytes([0, 13, 10, 255])
    for index in range(15):
        large_value = large_value + large_value
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _storage_peer(listener, large_value)
            auto client = Client(
                "localhost",
                port=net.port(listener),
                connect_timeout=3.0,
                timeout=3.0,
            )
            try:
                assert client.set_value(
                    b"cache",
                    large_value,
                    expire=1800000000,
                    flags=51,
                    noreply=True,
                )
                assert not client.add(b"cache", b"")
                assert client.replace(
                    b"cache",
                    bytes([0, 13, 10, 255]),
                    expire=60,
                    flags=9,
                )
                assert client.append(b"cache", b"a")
                assert not client.prepend(b"missing", b"b")

                auto client_error = False
                try:
                    client.set_value(b"missing", b"")
                except MemcacheClientError as message:
                    client_error = message == "bad value"
                assert client_error

                auto unknown = False
                try:
                    client.set_value(b"missing", b"")
                except MemcacheUnknownError:
                    unknown = True
                assert unknown
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

def _expect_live_value(Client client, bytes key, int64 flags, bytes value):
    auto hits = client._retrieve([key], True)
    assert len(hits) == 1
    auto hit = hits[key]
    assert hit.flags == flags
    assert hit.data == value
    assert len(hit.cas) > 0

@test
def _live_storage():
    auto host = os.getenv("MEMCACHED_TEST_HOST")
    if host == "":
        return
    auto client = Client(host=host, connect_timeout=3.0, timeout=3.0)
    try:
        auto binary = bytes([0, 13, 10, 255])
        assert client.set_value(b"storage-binary", binary, expire=60, flags=4294967295)
        _expect_live_value(client, b"storage-binary", 4294967295, binary)
        assert not client.add(b"storage-binary", b"ignored")
        assert client.append(b"storage-binary", b"tail", flags=7)
        assert client.prepend(b"storage-binary", b"head", expire=-1)
        _expect_live_value(
            client,
            b"storage-binary",
            4294967295,
            b"head" + binary + b"tail",
        )

        assert not client.replace(b"storage-missing", b"miss")
        assert not client.append(b"storage-missing", b"miss")
        assert not client.prepend(b"storage-missing", b"miss")
        assert client.add(b"storage-empty", b"")
        _expect_live_value(client, b"storage-empty", 0, b"")
        auto unix_seconds = time.time_ns() // 1000000000
        assert client.replace(
            b"storage-empty",
            b"updated",
            expire=unix_seconds + 60,
            flags=11,
        )
        _expect_live_value(client, b"storage-empty", 11, b"updated")
        assert client.set_value(b"storage-expired", b"old", expire=unix_seconds - 60)
        assert client._request_line(b"get storage-expired") == b"END"

        auto large_value = binary
        for index in range(15):
            large_value = large_value + large_value
        assert client.set_value(b"storage-large", large_value, flags=19, noreply=True)
        _expect_live_value(client, b"storage-large", 19, large_value)
        assert client.replace(b"storage-large", binary)
        _expect_live_value(client, b"storage-large", 0, binary)
    finally:
        client.disconnect()

def _retrieval_peer(bytes listener, bytes binary):
    auto socket = net.accept(listener)
    try:
        net.set_deadline_ns(socket, _deadline_after(3.0))
        auto reader = _Reader(socket, b"")
        assert reader._read_line() == b"get binary"
        net.send(socket, b"VALUE binary 7 4\r")
        net.send(socket, b"\n" + binary + b"\r\nEND\r\n")
        for index in range(2):
            assert reader._read_line() == b"get missing"
            net.send(socket, b"END\r\n")
        assert reader._read_line() == b"gets binary"
        net.send(
            socket,
            b"VALUE binary 7 4 18446744073709551615\r\n" + binary + b"\r\nEND\r\n",
        )
        assert reader._read_line() == b"gets missing"
        net.send(socket, b"END\r\n")
        assert reader._read_line() == b"get binary missing empty"
        net.send(
            socket,
            b"VALUE empty 0 0\r\n\r\nVALUE binary 7 4\r\n" + binary + b"\r\nEND\r\n",
        )
        assert reader._read_line() == b"get missing"
        net.send(socket, b"END\r\n")
        assert reader._read_line() == b"gets empty missing binary"
        net.send(
            socket,
            b"VALUE binary 7 4 222\r\n" + binary + b"\r\nVALUE empty 4294967295 0 333\r\n\r\nEND\r\n",
        )
        assert reader._read_line() == b"gets empty"
        net.send(socket, b"VALUE empty 4294967295 0 333\r\n\r\nEND\r\n")
        assert net.recv(socket, 1) == ""
    finally:
        net.close_conn(socket)

@test
def _retrieval_exchange():
    auto binary = bytes([0, 13, 10, 255])
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _retrieval_peer(listener, binary)
            auto client = Client("localhost", port=net.port(listener), timeout=3.0)
            try:
                assert len(client.get_many([])) == 0
                assert len(client.gets_many([])) == 0
                assert client._reader == None
                assert client.get(b"binary").unwrap() == binary
                assert client.get(b"missing").is_none()
                assert client.get(b"missing", default=Optional.Some(b"fallback")).unwrap() == b"fallback"
                auto value, cas = client.gets(b"binary")
                assert value.unwrap() == binary
                assert cas.unwrap() == b"18446744073709551615"
                auto absent, absent_cas = client.gets(b"missing")
                assert absent.is_none()
                assert absent_cas.is_none()

                auto hits = client.get_many(
                    [b"binary", b"missing", b"empty", b"binary"],
                )
                assert len(hits) == 2
                assert hits[b"binary"] == binary
                assert hits[b"empty"] == b""
                assert not b"missing" in hits
                assert len(client.get_multi([b"missing", b"missing"])) == 0

                auto cas_hits = client.gets_many([b"empty", b"missing", b"binary"])
                assert len(cas_hits) == 2
                auto got, token = cas_hits[b"binary"]
                assert got == binary and token == b"222"
                auto empty, empty_cas = cas_hits[b"empty"]
                assert empty == b"" and empty_cas == b"333"
                auto flagged = client._retrieve([b"empty"], True)
                assert flagged[b"empty"].flags == 4294967295
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

def _retrieval_invalid_peer(bytes listener, list[bytes] replies):
    for reply in replies:
        auto socket = net.accept(listener)
        try:
            net.set_deadline_ns(socket, _deadline_after(3.0))
            auto reader = _Reader(socket, b"")
            assert reader._read_line() == b"gets x"
            net.send(socket, reply)
            assert net.recv(socket, 1) == ""
        finally:
            net.close_conn(socket)

@test
def _retrieval_rejects_invalid_replies():
    auto listener = net.listen("127.0.0.1", 0)
    list[bytes] replies = [
        b"NOT_FOUND\r\n",
        b"VALUE x 0 0\r\n",
        b"VALUE y 0 0 1\r\n",
        b"VALUE x -1 0 1\r\n",
        b"VALUE x 4294967296 0 1\r\n",
        b"VALUE x 0 2147483646 1\r\n",
        b"VALUE x 0 0 18446744073709551616\r\n",
        b"VALUE x 0 0 a\r\n",
        b"VALUE x 0 0 1\r\nx\n",
        b"VALUE x 0 0 1\r\n\r\nVALUE x 0 0 1\r\n\r\nEND\r\n",
    ]
    try:
        scope(timeout=5000):
            spawn _retrieval_invalid_peer(listener, replies)
            auto client = Client("localhost", port=net.port(listener), timeout=3.0)
            try:
                for index in range(len(replies)):
                    auto invalid = False
                    try:
                        client.gets(b"x")
                    except MemcacheUnknownError:
                        invalid = True
                    assert invalid
                    assert client._reader == None
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

@test
def _live_retrieval():
    auto host = os.getenv("MEMCACHED_TEST_HOST")
    if host == "":
        return
    auto client = Client(host=host, connect_timeout=3.0, timeout=3.0)
    try:
        auto binary = bytes([0, 13, 10, 255])
        assert client.set_value(b"retrieval:binary", binary, flags=4294967295)
        assert client.set_value(b"retrieval:empty", b"")
        assert client.get(b"retrieval:binary").unwrap() == binary
        assert client.get(b"retrieval:missing").is_none()
        assert client.get(b"retrieval:missing", default=Optional.Some(b"fallback")).unwrap() == b"fallback"
        auto value, token = client.gets(b"retrieval:binary")
        assert value.unwrap() == binary
        auto hits = client.get_many(
            [
                b"retrieval:empty",
                b"retrieval:missing",
                b"retrieval:binary",
                b"retrieval:empty",
            ],
        )
        assert len(hits) == 2
        assert hits[b"retrieval:empty"] == b""
        assert hits[b"retrieval:binary"] == binary
        auto with_cas = client.gets_many([b"retrieval:missing", b"retrieval:binary"])
        assert len(with_cas) == 1
        auto batch_value, batch_token = with_cas[b"retrieval:binary"]
        assert batch_value == binary
        assert batch_token == token.unwrap()
        assert client.set_value(b"retrieval:binary", b"updated", flags=21)
        auto updated, new_token = client.gets(b"retrieval:binary")
        assert updated.unwrap() == b"updated"
        assert new_token.unwrap() != batch_token
        _expect_live_value(client, b"retrieval:binary", 21, b"updated")
    finally:
        client.disconnect()

def _delete_touch_peer(bytes listener):
    auto socket = net.accept(listener)
    try:
        net.set_deadline_ns(socket, _deadline_after(3.0))
        auto reader = _Reader(socket, b"")
        assert reader._read_line() == b"delete hit"
        net.send(socket, b"DELETED\r\n")
        assert reader._read_line() == b"delete miss"
        net.send(socket, b"NOT_FOUND\r\n")
        assert reader._read_line() == b"delete first"
        net.send(socket, b"DELETED\r\n")
        assert reader._read_line() == b"delete first"
        net.send(socket, b"NOT_FOUND\r\n")
        assert reader._read_line() == b"delete second"
        net.send(socket, b"DELETED\r\n")

        assert reader._read_line() == b"delete quiet noreply"
        assert reader._read_line() == b"delete a noreply"
        assert reader._read_line() == b"delete b noreply"
        assert reader._read_line() == b"touch quiet 2592001 noreply"
        assert reader._read_line() == b"touch hit 0"
        net.send(socket, b"TOUCHED\r\n")
        assert reader._read_line() == b"touch miss -2147483648"
        net.send(socket, b"NOT_FOUND\r\n")
        assert reader._read_line() == b"touch malformed 2147483647"
        net.send(socket, b"DELETED\r\n")
        assert net.recv(socket, 1) == ""
    finally:
        net.close_conn(socket)

@test
def _delete_touch_exchange():
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _delete_touch_peer(listener)
            auto client = Client(host="localhost", port=net.port(listener), timeout=3.0)
            try:
                assert client.delete_many([])
                assert client.delete_multi([], noreply=True)
                assert client._reader == None
                assert client.delete(b"hit")
                assert not client.delete(b"miss")
                assert client.delete_many([b"first", b"first", b"second"])
                assert client.delete(b"quiet", noreply=True)
                assert client.delete_multi([b"a", b"b"], noreply=True)
                assert client.touch(b"quiet", expire=2592001, noreply=True)
                assert client.touch(b"hit")
                assert not client.touch(b"miss", expire=-2147483648)

                auto malformed = False
                try:
                    client.touch(b"malformed", expire=2147483647)
                except MemcacheUnknownError:
                    malformed = True
                assert malformed
                assert client._reader == None
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

@test
def _delete_touch_validates_before_dial():
    auto client = Client(host="localhost", port=0)
    auto invalid_batch = False
    try:
        client.delete_many([b"valid", b"bad key"], noreply=True)
    except MemcacheIllegalInputError as message:
        invalid_batch = message == "A memcached key must use printable ASCII without spaces"
    assert invalid_batch
    for expire in [-2147483649, 2147483648]:
        auto invalid_expire = False
        try:
            client.touch(b"key", expire=expire, noreply=True)
        except MemcacheIllegalInputError as message:
            invalid_expire = message == "Expiration must fit in a signed 32-bit integer"
        assert invalid_expire
    assert client._reader == None

@test
def _live_delete_touch():
    auto host = os.getenv("MEMCACHED_TEST_HOST")
    if host == "":
        return
    auto client = Client(host=host, connect_timeout=3.0, timeout=3.0)
    try:
        assert client.set_value(b"delete:one", b"data")
        assert client.delete(b"delete:one")
        assert not client.delete(b"delete:one")
        assert client.delete(b"delete:one", noreply=True)
        assert client.set_value(b"delete:first", b"data")
        assert client.set_value(b"delete:second", b"data")
        assert client.delete_many([b"delete:first", b"delete:absent", b"delete:second"])
        assert len(client.get_many([b"delete:first", b"delete:second"])) == 0
        assert client.set_value(b"delete:quiet", b"data")
        assert client.delete_multi([b"delete:quiet"], noreply=True)
        assert client.get(b"delete:quiet").is_none()

        assert client.set_value(b"touch:value", b"data", expire=60, flags=19)
        assert client.touch(b"touch:value", expire=0)
        _expect_live_value(client, b"touch:value", 19, b"data")
        auto past = time.time_ns() // 1000000000 - 60
        assert client.touch(b"touch:value", expire=past, noreply=True)
        assert client.get(b"touch:value").is_none()
        assert not client.touch(b"touch:value", expire=60)
        assert client.touch(b"touch:value", noreply=True)
        assert client.get(b"touch:value").is_none()
    finally:
        client.disconnect()

def _counter_peer(bytes listener):
    auto socket = net.accept(listener)
    try:
        net.set_deadline_ns(socket, _deadline_after(3.0))
        auto reader = _Reader(socket, b"")
        assert reader._read_line() == b"incr count 18446744073709551615"
        net.send(socket, b"18446744073709551615\r\n")
        assert reader._read_line() == b"decr count 0"
        net.send(socket, b"9223372036854775808\r\n")
        assert reader._read_line() == b"incr missing 1"
        net.send(socket, b"NOT_FOUND\r\n")
        assert reader._read_line() == b"incr count 1 noreply"
        assert reader._read_line() == b"decr count 1 noreply"
        assert reader._read_line() == b"decr count 2"
        net.send(socket, b"0   \r\n")
        assert reader._read_line() == b"incr text 1"
        net.send(socket, b"CLIENT_ERROR cannot increment non-numeric value\r\n")
        assert net.recv(socket, 1) == ""
    finally:
        net.close_conn(socket)

    for reply in [b"18446744073709551616", b"-1", b"1 2", b"   "]:
        auto next_socket = net.accept(listener)
        try:
            net.set_deadline_ns(next_socket, _deadline_after(3.0))
            auto reader = _Reader(next_socket, b"")
            assert reader._read_line() == b"decr count 3"
            net.send(next_socket, reply + b"\r\n")
            assert net.recv(next_socket, 1) == ""
        finally:
            net.close_conn(next_socket)

@test
def _counter_exchange():
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _counter_peer(listener)
            auto client = Client(host="localhost", port=net.port(listener), timeout=3.0)
            try:
                assert client.incr(b"count", uint64(-1)).unwrap() == uint64(-1)
                assert client.decr(b"count", uint64(0)).unwrap() == uint64(9223372036854775807) + uint64(1)
                assert client.incr(b"missing", uint64(1)).is_none()
                assert client.incr(b"count", uint64(1), noreply=True).is_none()
                assert client.decr(b"count", uint64(1), noreply=True).is_none()
                assert client.decr(b"count", uint64(2)).unwrap() == uint64(0)

                auto nonnumeric = False
                try:
                    client.incr(b"text", uint64(1))
                except MemcacheClientError as message:
                    nonnumeric = message == "cannot increment non-numeric value"
                assert nonnumeric
                assert client._reader == None
                for index in range(4):
                    auto malformed = False
                    try:
                        client.decr(b"count", uint64(3))
                    except MemcacheUnknownError:
                        malformed = True
                    assert malformed
                    assert client._reader == None
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

@test
def _live_counters():
    auto host = os.getenv("MEMCACHED_TEST_HOST")
    if host == "":
        return
    auto client = Client(host=host, connect_timeout=3.0, timeout=3.0)
    try:
        assert client.incr(b"counter:missing", uint64(1)).is_none()
        assert client.decr(b"counter:missing", uint64(1)).is_none()
        assert client.set_value(b"counter:num", b"9223372036854775807")
        assert client.incr(b"counter:num", uint64(1)).unwrap() == uint64(9223372036854775807) + uint64(1)
        assert client.set_value(b"counter:num", b"18446744073709551615")
        assert client.incr(b"counter:num", uint64(1)).unwrap() == uint64(0)
        assert client.decr(b"counter:num", uint64(-1)).unwrap() == uint64(0)
        assert client.incr(b"counter:num", uint64(-1), noreply=True).is_none()
        assert client.decr(b"counter:num", uint64(1), noreply=True).is_none()
        assert client.incr(b"counter:num", uint64(0)).unwrap() == uint64(-1) - uint64(1)
        assert client.decr(b"counter:num", uint64(-1)).unwrap() == uint64(0)

        assert client.set_value(b"counter:text", b"cat")
        auto nonnumeric = False
        try:
            client.incr(b"counter:text", uint64(1))
        except MemcacheClientError:
            nonnumeric = True
        assert nonnumeric
        assert client.get(b"counter:text").unwrap() == b"cat"
    finally:
        client.disconnect()

@test
def _cas_validates_before_dial():
    auto client = Client(host="localhost", port=0)
    for token in [b"", b"-1", b"+1", b" 1", b"1 ", b"1\r\n", b"18446744073709551616", b"000000000000000000000", bytes([255])]:
        auto invalid = False
        try:
            client.cas(b"key", b"value", token, noreply=True)
        except MemcacheIllegalInputError as message:
            invalid = message == "CAS token must be an unsigned 64-bit decimal"
        assert invalid
    assert client._reader == None

def _cas_peer(bytes listener, bytes binary):
    auto socket = net.accept(listener)
    try:
        net.set_deadline_ns(socket, _deadline_after(3.0))
        auto reader = _Reader(socket, b"")
        _expect_storage(reader, b"cas key 4294967295 60 4 18446744073709551615", binary)
        net.send(socket, b"STORED\r\n")
        _expect_storage(reader, b"cas key 0 0 0 18446744073709551615", b"")
        net.send(socket, b"EXISTS\r\n")
        _expect_storage(reader, b"cas missing 0 0 0 0", b"")
        net.send(socket, b"NOT_FOUND\r\n")
        _expect_storage(reader, b"cas key 7 1800000000 4 21 noreply", binary)
        _expect_storage(reader, b"cas key 0 0 0 21", b"")
        net.send(socket, b"EXISTS\r\n")
        _expect_storage(reader, b"cas key 0 0 0 22", b"")
        net.send(socket, b"NOT_STORED\r\n")
        assert net.recv(socket, 1) == ""
    finally:
        net.close_conn(socket)

@test
def _cas_exchange():
    auto binary = bytes([0, 13, 10, 255])
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _cas_peer(listener, binary)
            auto client = Client(host="localhost", port=net.port(listener), timeout=3.0)
            try:
                assert client.cas(b"key", binary, b"18446744073709551615", expire=60, flags=4294967295).unwrap()
                assert not client.cas(b"key", b"", b"18446744073709551615").unwrap()
                assert client.cas(b"missing", b"", b"0").is_none()
                assert client.cas(b"key", binary, cas=b"21", expire=1800000000, flags=7, noreply=True).unwrap()
                assert not client.cas(b"key", b"", b"21").unwrap()
                auto unexpected = False
                try:
                    client.cas(b"key", b"", b"22")
                except MemcacheUnknownError:
                    unexpected = True
                assert unexpected
                assert client._reader == None
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

@test
def _live_cas():
    auto host = os.getenv("MEMCACHED_TEST_HOST")
    if host == "":
        return
    auto client = Client(host=host, connect_timeout=3.0, timeout=3.0)
    auto other = Client(host=host, connect_timeout=3.0, timeout=3.0)
    try:
        auto binary = bytes([0, 13, 10, 255])
        assert client.set_value(b"cas:key", b"original")
        auto original, token = client.gets(b"cas:key")
        assert original.unwrap() == b"original"
        assert client.cas(b"cas:key", binary, cas=token.unwrap(), expire=60, flags=71).unwrap()
        _expect_live_value(client, b"cas:key", 71, binary)
        auto updated, new_token = client.gets(b"cas:key")
        assert updated.unwrap() == binary
        assert new_token.unwrap() != token.unwrap()
        assert not client.cas(b"cas:key", b"ignored", token.unwrap()).unwrap()

        assert other.set_value(b"cas:key", b"other writer")
        assert not client.cas(b"cas:key", b"ignored", new_token.unwrap()).unwrap()
        assert client.get(b"cas:key").unwrap() == b"other writer"
        assert other.delete(b"cas:key")
        assert client.cas(b"cas:key", b"ignored", new_token.unwrap()).is_none()

        assert other.set_value(b"cas:key", b"new")
        auto batch = client.gets_many([b"cas:key", b"cas:absent"])
        auto before_quiet, quiet_token = batch[b"cas:key"]
        assert before_quiet == b"new"
        assert client.cas(b"cas:key", b"", quiet_token, flags=23, noreply=True).unwrap()
        _expect_live_value(client, b"cas:key", 23, b"")
        assert client.cas(b"cas:key", b"ignored", quiet_token, noreply=True).unwrap()
        assert client.cas(b"cas:absent", b"ignored", quiet_token, noreply=True).unwrap()
        assert client.get(b"cas:key").unwrap() == b""
        assert client.get(b"cas:absent").is_none()

        auto final_value, expire_token = client.gets(b"cas:key")
        assert final_value.unwrap() == b""
        auto past = time.time_ns() // 1000000000 - 60
        assert client.cas(b"cas:key", b"expired", expire_token.unwrap(), expire=past).unwrap()
        assert client.get(b"cas:key").is_none()
    finally:
        other.disconnect()
        client.disconnect()

def _admin_peer(bytes listener):
    auto socket = net.accept(listener)
    try:
        net.set_deadline_ns(socket, _deadline_after(3.0))
        auto reader = _Reader(socket, b"")
        assert reader._read_line() == b"stats"
        net.send(socket, b"STAT count 7\r\nSTAT words more than one ")
        net.send(
            socket,
            b"word\r\nSTAT empty\r\nSTAT count 8\r\nSTAT blank \r\nEND\r\n",
        )
        assert reader._read_line() == b"stats settings"
        net.send(socket, b"END\r\n")
        assert reader._read_line() == b"stats slabs extra"
        net.send(socket, b"STAT slab:1 " + bytes([255, 0]) + b"\r\nEND\r\n")
        assert reader._read_line() == b"flush_all 0"
        net.send(socket, b"OK\r\n")
        assert reader._read_line() == b"flush_all 30 noreply"
        assert reader._read_line() == b"version"
        net.send(socket, b"VERSION 1.6-test\r\n")
        assert reader._read_line() == b"quit"
        # Neither side should wait for a reply to quit.
        assert net.recv(socket, 1) == ""
    finally:
        net.close_conn(socket)
    auto next_socket = net.accept(listener)
    try:
        net.set_deadline_ns(next_socket, _deadline_after(3.0))
        auto reader = _Reader(next_socket, b"")
        assert reader._read_line() == b"version"
        net.send(next_socket, b"VERSION 1.6-reconnected\r\n")
        assert net.recv(next_socket, 1) == ""
    finally:
        net.close_conn(next_socket)

@test
def _admin_exchange():
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _admin_peer(listener)
            auto client = Client(host="localhost", port=net.port(listener), timeout=3.0)
            try:
                auto general = client.stats()
                assert len(general) == 4
                assert general[b"count"] == b"8"
                assert general[b"words"] == b"more than one word"
                assert general[b"empty"] == b""
                assert general[b"blank"] == b""
                assert len(client.stats(b"settings")) == 0
                auto slabs = client.stats(b"slabs", b"extra")
                assert slabs[b"slab:1"] == bytes([255, 0])
                assert client.flush_all()
                assert client.flush_all(delay=30, noreply=True)
                assert client.version() == b"1.6-test"
                client.quit()
                assert client._reader == None
                assert client.version() == b"1.6-reconnected"
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

def _admin_bad_peer(bytes listener, list[bytes] commands, list[bytes] replies):
    for index in range(len(commands)):
        auto socket = net.accept(listener)
        try:
            net.set_deadline_ns(socket, _deadline_after(3.0))
            auto reader = _Reader(socket, b"")
            assert reader._read_line() == commands[index]
            net.send(socket, replies[index])
            assert net.recv(socket, 1) == ""
        finally:
            net.close_conn(socket)

@test
def _admin_rejects_malformed_replies():
    auto listener = net.listen("127.0.0.1", 0)
    list[bytes] commands = [
        b"stats",
        b"stats",
        b"stats",
        b"version",
        b"version",
        b"version",
        b"flush_all 0",
    ]
    list[bytes] replies = [
        b"ITEM key 7\r\n",
        b"STAT  value\r\n",
        b"STAT bad\tname x\r\n",
        b"VERSION \r\n",
        b"VERSION bad token\r\n",
        b"INVALID 1.6\r\n",
        b"NOT_FOUND\r\n",
    ]
    try:
        scope(timeout=5000):
            spawn _admin_bad_peer(listener, commands, replies)
            auto client = Client(host="localhost", port=net.port(listener), timeout=3.0)
            try:
                for command in commands:
                    auto rejected = False
                    try:
                        if command == b"stats":
                            client.stats()
                        elif command == b"version":
                            client.version()
                        else:
                            client.flush_all()
                    except MemcacheUnknownError:
                        rejected = True
                    assert rejected
                    assert client._reader == None
            finally:
                client.disconnect()
    finally:
        net.close_listener(listener)

@test
def _admin_validates_before_dial():
    auto client = Client(host="localhost", port=0)
    for arg in [b"", b"two words", b"bad\r\n", bytes([127])]:
        auto rejected = False
        try:
            client.stats(b"valid", arg)
        except MemcacheIllegalInputError as message:
            rejected = message == "A memcached key must use printable ASCII without spaces" or message == "A memcached key must contain 1 to 250 bytes"
        assert rejected
    for delay in [-2147483649, 2147483648]:
        auto out_of_range = False
        try:
            client.flush_all(delay=delay, noreply=True)
        except MemcacheIllegalInputError as message:
            out_of_range = message == "Expiration must fit in a signed 32-bit integer"
        assert out_of_range
    assert client._reader == None

@test
def _live_admin():
    auto host = os.getenv("MEMCACHED_TEST_HOST")
    if host == "":
        return
    auto client = Client(host=host, connect_timeout=3.0, timeout=3.0)
    try:
        auto server_version = client.version()
        assert len(server_version) > 0
        auto general = client.stats()
        assert general[b"version"] == server_version
        auto settings = client.stats(b"settings")
        assert b"maxconns" in settings
        assert client.set_value(b"admin:stats", b"eligible")
        assert len(client.stats(b"items")) > 0
        assert len(client.stats(b"slabs")) > 0
        assert client.flush_all()
        assert client.get(b"admin:stats").is_none()

        assert client.set_value(b"admin:delayed", b"eligible")
        auto delay = 1
        assert client.flush_all(delay=delay, noreply=True)
        # The next command observes the clock after the silent flush was queued.
        # Later tests share this server and must write past the flush's time window.
        auto flush_time = int(str(client.stats()[b"time"]))
        auto settled = False
        for attempt in range(20):
            if int(str(client.stats()[b"time"])) > flush_time + delay:
                settled = True
                break
            time.sleep(0.25)
        assert settled
        assert client.get(b"admin:delayed").is_none()
        client.quit()
        assert client._reader == None
        assert client.version() == server_version
    finally:
        client.disconnect()

@test
def _bytes_serde_preserves_payload():
    auto serde = BytesSerde()
    for payload in [b"", bytes([0, 13, 10, 255])]:
        auto encoded, flags = serde.serialize(b"bytes", payload)
        assert encoded == payload
        assert flags == 0
        assert serde.deserialize(b"bytes", encoded, flags) == payload
        assert serde.deserialize(b"bytes", encoded, 4294967295) == payload

@test
def _typed_serde_flags():
    auto text_codec = TextSerde()
    for value in ["", "café\r\n"]:
        auto encoded, flags = text_codec.serialize(b"text", value)
        assert encoded == bytes(value) and flags == 16
        assert text_codec.deserialize(b"text", encoded, flags) == value

    auto bad_text = False
    try:
        text_codec.deserialize(b"text", bytes([255]), 16)
    except MemcacheSerdeError:
        bad_text = True
    assert bad_text

struct _KeySerde:
    def serialize(self, bytes key, str value) -> (bytes, int64):
        if value == "reject":
            raise ValueError("custom serialization error")
        return (key + b":" + bytes(value), 888)

    def deserialize(self, bytes key, bytes value, int64 flags) -> str:
        auto prefix = key + b":"
        if flags != 888 or len(value) < len(prefix) or value[0:len(prefix)] != prefix:
            raise ValueError("custom deserialization error")
        return str(value[len(prefix):len(value)])

def _serde_peer(bytes listener):
    auto socket = net.accept(listener)
    try:
        net.set_deadline_ns(socket, _deadline_after(3.0))
        auto reader = _Reader(socket, b"")
        _expect_storage(reader, b"set use-key 888 0 13", b"use-key:value")
        net.send(socket, b"STORED\r\n")
        assert reader._read_line() == b"get use-key"
        net.send(socket, b"VALUE use-key 888 13\r\nuse-key:value\r\nEND\r\n")
        assert reader._read_line() == b"get bad"
        net.send(socket, b"VALUE bad 889 3\r\nbad\r\nEND\r\n")
        assert reader._read_line() == b"get absent"
        net.send(socket, b"END\r\n")
        for index in range(2):
            assert reader._read_line() == b"get absent use-key"
            net.send(socket, b"VALUE use-key 888 13\r\nuse-key:value\r\nEND\r\n")
        assert reader._read_line() == b"gets use-key"
        net.send(socket, b"VALUE use-key 888 13 9\r\nuse-key:value\r\nEND\r\n")
        assert net.recv(socket, 1) == ""
    finally:
        net.close_conn(socket)

@test
def _custom_serde_dispatch():
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _serde_peer(listener)
            auto client = Client(host="localhost", port=net.port(listener), timeout=3.0)
            auto typed = SerdeClient[str, _KeySerde](client, _KeySerde())
            try:
                auto encode_failed = False
                try:
                    typed.set_value(b"use-key", "reject")
                except MemcacheSerdeError as message:
                    encode_failed = message == "Memcached serialization failed: custom serialization error"
                assert encode_failed
                assert client._reader == None
                assert typed.set_value(b"use-key", "value")
                assert typed.get(b"use-key").unwrap() == "value"
                auto decode_failed = False
                try:
                    typed.get(b"bad")
                except MemcacheSerdeError as message:
                    decode_failed = message == "Memcached deserialization failed: custom deserialization error"
                assert decode_failed
                assert typed.get(b"absent", default=Optional.Some("default")).unwrap() == "default"
                auto keys = [b"absent", b"use-key"]
                auto hits = typed.get_many(keys)
                assert len(hits) == 1 and hits[b"use-key"] == "value"
                auto alias_hits = typed.get_multi([b"absent", b"use-key"])
                assert len(alias_hits) == 1 and alias_hits[b"use-key"] == "value"
                auto cas_hits = typed.gets_many([b"use-key"])
                assert len(cas_hits) == 1
                auto value, token = cas_hits[b"use-key"]
                assert value == "value" and token == b"9"
            finally:
                typed.disconnect()
    finally:
        net.close_listener(listener)

@test
def _live_serde():
    auto host = os.getenv("MEMCACHED_TEST_HOST")
    if host == "":
        return
    auto client = Client(host=host, connect_timeout=3.0, timeout=3.0)
    auto text = SerdeClient[str, TextSerde](client, TextSerde())
    auto raw = SerdeClient[bytes, BytesSerde](client, BytesSerde())
    try:
        auto binary = bytes([0, 13, 10, 255])
        assert raw.set_value(b"serde:raw", binary)
        _expect_live_value(client, b"serde:raw", 0, binary)
        auto raw_value = raw.get(b"serde:raw")
        assert raw_value.is_some(), "bytes serde must return a stored hit"
        assert raw_value.unwrap() == binary
        assert text.add(b"serde:text", "")
        auto empty = text.get(b"serde:text")
        assert empty.is_some(), "empty text must be distinguishable from a miss"
        assert empty.unwrap() == ""
        assert text.replace(b"serde:text", "café")
        assert text.append(b"serde:text", "!")
        assert text.prepend(b"serde:text", "hello ")
        _expect_live_value(client, b"serde:text", 16, bytes("hello café!"))
        auto got, token = text.gets(b"serde:text")
        assert got.is_some() and token.is_some(), "typed gets must return the value and token"
        assert got.unwrap() == "hello café!"
        auto replaced = text.cas(b"serde:text", "after", token.unwrap())
        assert replaced.is_some(), "typed CAS must acknowledge the existing key"
        assert replaced.unwrap()
        _expect_live_value(client, b"serde:text", 16, b"after")
        auto raw_hits = client.get_many([b"serde:absent", b"serde:text"])
        assert len(raw_hits) == 1, "the server must return the post-CAS value to a raw batch"
        auto decoded_hits = text.get_many([b"serde:absent", b"serde:text"])
        assert len(decoded_hits) == 1, "the direct typed batch must return the same hit"
        assert decoded_hits[b"serde:text"] == "after"
        auto hits = text.get_multi([b"serde:absent", b"serde:text"])
        assert len(hits) == 1, "the typed alias must return the same hit"
        assert hits[b"serde:text"] == "after"
        auto batch = text.gets_many([b"serde:text"])
        auto batch_value, batch_token = batch[b"serde:text"]
        assert batch_value == "after" and batch_token != token.unwrap()
        auto absent, absent_token = text.gets(b"serde:absent")
        assert absent.is_none() and absent_token.is_none()

        assert text.set_value(b"serde:override", "raw", flags=Optional.Some(999))
        _expect_live_value(client, b"serde:override", 999, b"raw")
        assert client.set_value(b"serde:unknown", b"test", flags=999)
        auto unknown_bytes = raw.get(b"serde:unknown")
        assert unknown_bytes.is_some(), "unknown flags must preserve a raw hit"
        assert unknown_bytes.unwrap() == b"test"
        auto unknown_flag = False
        try:
            text.get(b"serde:unknown")
        except MemcacheSerdeError:
            unknown_flag = True
        assert unknown_flag
        auto after = text.get(b"serde:text")
        assert after.is_some(), "a codec failure must leave the next read usable"
        assert after.unwrap() == "after"
    finally:
        text.disconnect()

def _pool_overlap_peer(
    bytes listener,
    channel[bool] first_seen,
    channel[bool] both_seen,
    channel[bool] proceed,
):
    auto first = net.accept(listener)
    try:
        net.set_deadline_ns(first, _deadline_after(3.0))
        auto first_reader = _Reader(first, b"")
        assert first_reader._read_line() == b"version"
        first_seen <- True
        auto second = net.accept(listener)
        try:
            net.set_deadline_ns(second, _deadline_after(3.0))
            auto second_reader = _Reader(second, b"")
            assert second_reader._read_line() == b"version"
            both_seen <- True
            assert <-proceed
            net.send(first, b"VERSION first\r\n")
            net.send(second, b"VERSION second\r\n")
        finally:
            net.close_conn(second)
    finally:
        net.close_conn(first)

def _pooled_version(PooledClient pool, bytes version):
    assert pool.version() == version

@test
def _pool_shares_two_connections_and_enforces_bound():
    auto listener = net.listen("127.0.0.1", 0)
    auto pool = PooledClient(
        "localhost",
        port=net.port(listener),
        timeout=3.0,
        max_pool_size=2,
    )
    auto first_seen = channel[bool]()
    auto both_seen = channel[bool]()
    auto proceed = channel[bool]()
    try:
        scope(timeout=5000):
            spawn _pool_overlap_peer(listener, first_seen, both_seen, proceed)
            spawn _pooled_version(pool, b"first")
            assert <-first_seen
            spawn _pooled_version(pool, b"second")
            assert <-both_seen
            auto full = False
            try:
                pool.version()
            except RuntimeError as message:
                full = message == "Memcached pool exhausted"
            assert full
            proceed <- True
        assert len(pool._idle) == 2
        pool.disconnect()
        assert pool._size == 0
    finally:
        pool.disconnect()
        net.close_listener(listener)

def _pool_error_peer(bytes listener):
    for attempt in range(2):
        auto socket = net.accept(listener)
        try:
            net.set_deadline_ns(socket, _deadline_after(3.0))
            auto reader = _Reader(socket, b"")
            assert reader._read_line() == b"stats settings"
            if attempt == 0:
                net.send(socket, b"SERVER_ERROR test failure\r\n")
            else:
                net.send(socket, b"STAT threads 4\r\nEND\r\n")
            assert net.recv(socket, 1) == ""
        finally:
            net.close_conn(socket)

@test
def _pool_returns_capacity_after_error():
    auto listener = net.listen("127.0.0.1", 0)
    auto pool = PooledClient(
        "localhost",
        port=net.port(listener),
        timeout=3.0,
        max_pool_size=1,
    )
    try:
        scope(timeout=5000):
            spawn _pool_error_peer(listener)
            auto failed = False
            try:
                pool.stats(b"settings")
            except MemcacheServerError:
                failed = True
            assert failed
            assert len(pool._idle) == 1
            assert pool.stats(b"settings")[b"threads"] == b"4"
            pool.disconnect()
        assert pool._size == 0
        auto lease = pool._checkout()
        pool.disconnect()
        pool._return(lease)
        assert pool._size == 0 and len(pool._idle) == 0
    finally:
        pool.disconnect()
        net.close_listener(listener)

@test
def _hash_validates_and_matches_reference_hash():
    assert _murmur32(b"") == uint64(0)
    assert _murmur32(b"hello") == uint64(613153351)
    assert _murmur32(b"foo") == uint64(4138058784)
    assert _hash_key(b"alpha") == b"b'alpha'"
    assert _hash_key(b"x'y") == b"b\"x'y\""
    assert _hash_key(bytes([39, 34, 92])) == bytes([98, 39, 92, 39, 34, 92, 92, 39])

    auto ring = HashClient([])
    auto invalid = False
    try:
        ring.get_many([])
    except MemcacheIllegalInputError:
        invalid = True
    assert invalid

    auto duplicate = HashClient([("localhost", 11211), ("localhost", 11211)])
    auto rejected = False
    try:
        duplicate.get(b"key")
    except MemcacheIllegalInputError:
        rejected = True
    assert rejected

def _keys_for_shards(HashClient ring) -> (bytes, bytes):
    ring._init()
    auto first = b""
    auto second = b""
    for index in range(100):
        auto key = bytes("ring:key:" + str(index))
        if ring._route(key) == 0:
            first = key
        else:
            second = key
        if len(first) > 0 and len(second) > 0:
            return (first, second)
    raise AssertionError("Fixture could not find a key for each shard")

@test
def _live_hash_batches_and_failed_shards():
    auto host = os.getenv("MEMCACHED_TEST_HOST")
    auto second_host = os.getenv("MEMCACHED_TEST_SECOND_HOST")
    if host == "" or second_host == "":
        return
    auto first = Client(host, connect_timeout=3.0, timeout=3.0)
    auto second = Client(second_host, connect_timeout=3.0, timeout=3.0)
    auto ring = HashClient(
        [(host, 11211), (second_host, 11211)],
        connect_timeout=3.0,
        timeout=3.0,
        use_pooling=True,
        max_pool_size=2,
    )
    auto single = HashClient([(host, 11211)], connect_timeout=3.0, timeout=3.0)
    auto closed_listener = net.listen("127.0.0.1", 0)
    auto closed_port = net.port(closed_listener)
    net.close_listener(closed_listener)
    auto failing = HashClient(
        [(host, 11211), ("127.0.0.1", closed_port)],
        connect_timeout=3.0,
        timeout=3.0,
        retry_attempts=1,
        retry_timeout=0.0,
        ignore_exc=True,
    )
    try:
        auto key_a, key_b = _keys_for_shards(ring)
        ring.delete_many([key_a, key_b])
        assert len(ring.set_many({key_a: b"one", key_b: b"two"}, flags=7)) == 0
        assert first.get(key_a).unwrap() == b"one"
        assert second.get(key_b).unwrap() == b"two"
        assert first.get(key_b).is_none() and second.get(key_a).is_none()
        auto hits = ring.get_multi([key_b, key_a, key_b, b"ring:missing"])
        assert len(hits) == 2
        assert hits[key_a] == b"one" and hits[key_b] == b"two"
        auto cas_hits = ring.gets_many([key_a, key_b])
        auto value, token = cas_hits[key_a]
        assert value == b"one"
        assert ring.cas(key_a, b"new", token).unwrap()
        assert ring.delete_multi([key_a, key_b])
        assert len(ring.get_many([key_a, key_b])) == 0

        assert single.set_value(b"ring:single", b"3")
        assert single.incr(b"ring:single", uint64(2)).unwrap() == uint64(5)
        assert first.get(b"ring:single").unwrap() == b"5"
        assert single.touch(b"ring:single", expire=30)
        assert single.delete(b"ring:single")
        assert first.get(b"ring:single").is_none()

        auto good, unavailable = _keys_for_shards(failing)
        first.delete(unavailable)
        assert failing.set_value(good, b"survivor")
        auto partial = failing.get_many([unavailable, good])
        assert len(partial) == 1 and partial[good] == b"survivor"
        auto failed = failing.set_multi({unavailable: b"retry", good: b"updated"})
        assert len(failed) == 1 and failed[0] == unavailable
        assert failing._nodes[1].ejected
        assert failing._route(unavailable) == 0
        assert failing.set_value(unavailable, b"remapped")
        assert first.get(unavailable).unwrap() == b"remapped"
        assert first.get(good).unwrap() == b"updated"
    finally:
        failing.disconnect_all()
        single.disconnect_all()
        ring.disconnect_all()
        second.disconnect()
        first.disconnect()
