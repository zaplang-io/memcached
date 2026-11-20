# The server rejected a command or its arguments.
struct MemcacheClientError:
    str message

# The server could not process a command.
struct MemcacheServerError:
    str message

# The server did not recognize a command.
struct MemcacheUnknownCommandError:
    str message

# The caller supplied an invalid argument.
struct MemcacheIllegalInputError:
    str message

# The peer sent a malformed or unexpected protocol response.
struct MemcacheUnknownError:
    str message

# The peer closed the connection before a complete reply arrived.
struct MemcacheUnexpectedCloseError:
    str message

# The underlying TCP operation failed.
struct MemcacheConnectionError:
    str message

# The underlying TCP operation exceeded its deadline.
struct MemcacheTimeoutError:
    str message

def _deadline_after(f64 seconds) -> int64:
    if not (seconds >= 0.0 and seconds <= 9223372036.0):
        raise MemcacheIllegalInputError(
            "Timeout must be finite and between 0 and 9223372036 seconds",
        )
    if seconds == 0.0:
        return 0
    auto budget = int64(math.ceil(seconds * 1000000000.0))
    auto now = time.monotonic_ns()
    if budget > 9223372036854775807 - now:
        return 9223372036854775807
    return now + budget

def _dial(str host, int64 port, f64 connect_timeout) -> bytes:
    if len(host) == 0 or port < 1 or port > 65535:
        raise MemcacheIllegalInputError(
            "TCP connect requires a host and a port from 1 to 65535",
        )
    auto deadline = _deadline_after(connect_timeout)
    try:
        if deadline == 0:
            return net.connect(host, port)
        return net.connect_deadline(host, port, deadline)
    except TimeoutError as message:
        raise MemcacheTimeoutError(message)
    except Exception as message:
        raise MemcacheConnectionError(message)

def _validate_key(bytes key):
    if len(key) == 0 or len(key) > 250:
        raise MemcacheIllegalInputError("A memcached key must contain 1 to 250 bytes")
    for index in range(len(key)):
        if key[index] < 33 or key[index] > 126:
            raise MemcacheIllegalInputError(
                "A memcached key must use printable ASCII without spaces",
            )

def _error_message(bytes line, int64 start) -> str:
    auto raw = line[start:len(line)]
    try:
        return str(raw)
    except Exception:
        return "Non-UTF-8 server error (hex): " + hex.encode(raw)

def _raise_server_error(bytes line):
    if line == b"ERROR":
        raise MemcacheUnknownCommandError("The server did not recognize the command")
    if line == b"CLIENT_ERROR":
        raise MemcacheClientError("")
    if len(line) >= 13 and line[0:13] == b"CLIENT_ERROR ":
        raise MemcacheClientError(_error_message(line, 13))
    if line == b"SERVER_ERROR":
        raise MemcacheServerError("")
    if len(line) >= 13 and line[0:13] == b"SERVER_ERROR ":
        raise MemcacheServerError(_error_message(line, 13))

def _send_wire(bytes socket, bytes wire):
    auto written = 0
    try:
        written = net.send(socket, wire)
    except TimeoutError as message:
        raise MemcacheTimeoutError(message)
    except Exception as message:
        raise MemcacheConnectionError(message)
    if written != len(wire):
        raise MemcacheConnectionError("Incomplete memcached command write")

def _send_line(bytes socket, bytes line):
    for index in range(len(line)):
        if line[index] == 13 or line[index] == 10:
            raise MemcacheIllegalInputError(
                "A memcached command line cannot contain CR or LF",
            )
    _send_wire(socket, line + b"\r\n")

def _storage_header(
    bytes command,
    bytes key,
    int64 expire,
    int64 flags,
    int64 size,
    bool noreply,
) -> bytes:
    if command != b"set" and command != b"add" and command != b"replace" and command != b"append" and command != b"prepend":
        raise MemcacheIllegalInputError("Invalid memcached storage command")
    _validate_key(key)
    if expire < -2147483648 or expire > 2147483647:
        raise MemcacheIllegalInputError(
            "Expiration must fit in a signed 32-bit integer",
        )
    if flags < 0 or flags > 4294967295:
        raise MemcacheIllegalInputError("Flags must fit in an unsigned 32-bit integer")
    # The server counts the two trailing delimiter bytes in its stored length.
    if size < 0 or size > 2147483645:
        raise MemcacheIllegalInputError(
            "Value length is outside the text protocol range",
        )
    auto header = command + b" " + key + bytes(" " + str(flags) + " " + str(expire) + " " + str(size))
    if noreply:
        header = header + b" noreply"
    return header + b"\r\n"

def _read_chunk(bytes socket, int64 size) -> bytes:
    auto data = b""
    try:
        data = bytes(net.recv(socket, size))
    except TimeoutError as message:
        raise MemcacheTimeoutError(message)
    except Exception as message:
        raise MemcacheConnectionError(message)
    if len(data) == 0:
        raise MemcacheUnexpectedCloseError(
            "Memcached closed the connection before completing its reply",
        )
    return data

def _join_fragments(list[bytes] fragments, int64 start, int64 stop) -> bytes:
    if start == stop:
        return b""
    if stop - start == 1:
        return fragments[start]
    auto middle = start + (stop - start) // 2
    return _join_fragments(fragments, start, middle) + _join_fragments(fragments, middle, stop)

# One reader owns the unread bytes for one socket. The caller supplies the
# operation deadline and discards the socket and reader after framing failures.
struct _Reader:
    bytes _socket
    bytes _pending

    def _read_line(self) -> bytes:
        auto scan = 0
        while True:
            while scan < len(self._pending):
                if self._pending[scan] == 10:
                    raise MemcacheUnknownError("Bare LF in memcached reply")
                if self._pending[scan] == 13:
                    if scan + 1 == len(self._pending):
                        break
                    if self._pending[scan + 1] != 10:
                        raise MemcacheUnknownError("CR without LF in memcached reply")
                    auto line = self._pending[0:scan]
                    self._pending = self._pending[scan + 2:len(self._pending)]
                    _raise_server_error(line)
                    return line
                if scan == 8192:
                    raise MemcacheUnknownError(
                        "Memcached reply line exceeds 8192 bytes",
                    )
                scan = scan + 1
            self._pending = self._pending + _read_chunk(self._socket, 4096)

    # Consume exactly size bytes before reading the mandatory block delimiter.
    def _take(self, int64 size) -> bytes:
        if size <= len(self._pending):
            auto data = self._pending[0:size]
            self._pending = self._pending[size:len(self._pending)]
            return data
        list[bytes] fragments = []
        if len(self._pending) > 0:
            fragments.append(self._pending)
        auto remaining = size - len(self._pending)
        self._pending = b""
        while remaining > 0:
            auto chunk_size = remaining
            if chunk_size > 65536:
                chunk_size = 65536
            auto data = _read_chunk(self._socket, chunk_size)
            fragments.append(data)
            remaining = remaining - len(data)
        return _join_fragments(fragments, 0, len(fragments))

    def _read_block(self, int64 size) -> bytes:
        if size < 0:
            raise MemcacheUnknownError("Negative memcached block length")
        auto data = self._take(size)
        if self._take(2) != b"\r\n":
            raise MemcacheUnknownError("Memcached data block must end with CRLF")
        return data

    # Run a storage command on an already exclusively owned connection.
    def _store(
        self,
        bytes command,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        auto header = _storage_header(command, key, expire, flags, len(value), noreply)
        _send_wire(self._socket, header + value + b"\r\n")
        if noreply:
            return True
        auto reply = self._read_line()
        if reply == b"STORED":
            return True
        if reply == b"NOT_STORED":
            return False
        raise MemcacheUnknownError(
            "Unexpected memcached storage reply: " + _error_message(reply, 0),
        )

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
    try:
        # An invalid key must raise before any I/O even for noreply.
        auto reader = _Reader(b"", b"")
        reader._store(b"set", b"k\r\n", b"", noreply=True)
    except MemcacheIllegalInputError:
        invalid_key = True
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
        _expect_storage(reader, b"set missing 0 0 0", b"")
        net.send(socket, b"EXISTS\r\n")
    finally:
        net.close_conn(socket)

@test
def _storage_exchange():
    auto large_value = bytes([0, 13, 10, 255])
    for index in range(15):
        large_value = large_value + large_value
    auto listener = net.listen("127.0.0.1", 0)
    try:
        scope(timeout=5000):
            spawn _storage_peer(listener, large_value)
            auto socket = _dial("localhost", net.port(listener), 3.0)
            try:
                net.set_deadline_ns(socket, _deadline_after(3.0))
                auto reader = _Reader(socket, b"")
                assert reader._store(
                    b"set",
                    b"cache",
                    large_value,
                    expire=1800000000,
                    flags=51,
                    noreply=True,
                )
                assert not reader._store(b"add", b"cache", b"")
                assert reader._store(
                    b"replace",
                    b"cache",
                    bytes([0, 13, 10, 255]),
                    expire=60,
                    flags=9,
                )
                assert reader._store(b"append", b"cache", b"a")
                assert not reader._store(b"prepend", b"missing", b"b")

                auto client_error = False
                try:
                    reader._store(b"set", b"missing", b"")
                except MemcacheClientError as message:
                    client_error = message == "bad value"
                assert client_error

                auto unknown = False
                try:
                    reader._store(b"set", b"missing", b"")
                except MemcacheUnknownError:
                    unknown = True
                assert unknown
            finally:
                net.close_conn(socket)
    finally:
        net.close_listener(listener)
