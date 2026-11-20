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

def _validate_timeout(f64 seconds):
    if not (seconds >= 0.0 and seconds <= 9223372036.0):
        raise MemcacheIllegalInputError(
            "Timeout must be finite and between 0 and 9223372036 seconds",
        )

def _deadline_after(f64 seconds) -> int64:
    _validate_timeout(seconds)
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

def _validate_expire(int64 expire):
    if expire < -2147483648 or expire > 2147483647:
        raise MemcacheIllegalInputError(
            "Expiration must fit in a signed 32-bit integer",
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
    return _finish_storage_header(
        _storage_fields(command, key, expire, flags, size),
        noreply,
    )

def _storage_fields(
    bytes command,
    bytes key,
    int64 expire,
    int64 flags,
    int64 size,
) -> bytes:
    _validate_key(key)
    _validate_expire(expire)
    if flags < 0 or flags > 4294967295:
        raise MemcacheIllegalInputError("Flags must fit in an unsigned 32-bit integer")
    # The server counts the two trailing delimiter bytes in its stored length.
    if size < 0 or size > 2147483645:
        raise MemcacheIllegalInputError(
            "Value length is outside the text protocol range",
        )
    return command + b" " + key + bytes(" " + str(flags) + " " + str(expire) + " " + str(size))

def _finish_storage_header(bytes header, bool noreply) -> bytes:
    if noreply:
        header = header + b" noreply"
    return header + b"\r\n"

struct _RetrievedValue:
    bytes data
    int64 flags
    bytes cas

def _reply_uint(bytes field, uint64 maximum) -> uint64:
    if len(field) == 0:
        raise MemcacheUnknownError("Empty unsigned number in memcached reply")
    uint64 result = 0
    for index in range(len(field)):
        auto digit = field[index] - 48
        if digit < 0 or digit > 9:
            raise MemcacheUnknownError("Invalid unsigned number in memcached reply")
        auto unsigned_digit = uint64(digit)
        if result > (maximum - unsigned_digit) // uint64(10):
            raise MemcacheUnknownError(
                "Unsigned number out of range in memcached reply",
            )
        result = result * uint64(10) + unsigned_digit
    return result

def _cas_header(
    bytes key,
    bytes cas,
    int64 expire,
    int64 flags,
    int64 size,
    bool noreply,
) -> bytes:
    auto fields = _storage_fields(b"cas", key, expire, flags, size)
    if len(cas) > 20:
        raise MemcacheIllegalInputError("CAS token must be an unsigned 64-bit decimal")
    try:
        _reply_uint(cas, uint64(-1))
    except MemcacheUnknownError:
        raise MemcacheIllegalInputError("CAS token must be an unsigned 64-bit decimal")
    return _finish_storage_header(fields + b" " + cas, noreply)

def _value_fields(bytes header, bool with_cas) -> list[bytes]:
    list[bytes] fields = []
    auto start = 0
    for index in range(len(header)):
        if header[index] == 32:
            fields.append(header[start:index])
            start = index + 1
    fields.append(header[start:len(header)])
    auto expected = 4
    if with_cas:
        expected = 5
    if len(fields) != expected or fields[0] != b"VALUE":
        raise MemcacheUnknownError("Unexpected memcached VALUE header")
    return fields

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

    def _send_storage(self, bytes header, bytes value):
        _send_wire(self._socket, header + value + b"\r\n")

    def _write_storage(self, bytes header, bytes value, bool noreply) -> bool:
        self._send_storage(header, value)
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

    def _send_command(self, bytes line, bool noreply):
        if noreply:
            line = line + b" noreply"
        _send_line(self._socket, line)

    def _write_status(self, bytes line, bytes success, bool noreply) -> bool:
        self._send_command(line, noreply)
        if noreply:
            return True
        auto reply = self._read_line()
        if reply == success:
            return True
        if reply == b"NOT_FOUND":
            return False
        raise MemcacheUnknownError(
            "Unexpected memcached status reply: " + _error_message(reply, 0),
        )

struct Client:
    str host
    int64 port = 11211
    f64 connect_timeout = 0.0
    f64 timeout = 0.0
    Atomic[int64] _busy = Atomic(0)
    _Reader _reader = None

    def connect(self):
        "Open the configured TCP connection. Reuse it if already open."
        self._acquire()
        try:
            self._open()
        finally:
            self._busy.store(0)

    def disconnect(self):
        "Close the idle connection. The next command reconnects lazily."
        self._acquire()
        self._finish(False)

    def set_value(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Store bytes under a key. With noreply, True confirms only the write."
        return self._store(b"set", key, value, expire, flags, noreply)

    def add(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Store a new key and return False if the key already exists."
        return self._store(b"add", key, value, expire, flags, noreply)

    def replace(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Replace an existing value and return False if the key is absent."
        return self._store(b"replace", key, value, expire, flags, noreply)

    def append(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Add bytes after an existing value while preserving its flags and expiration."
        return self._store(b"append", key, value, expire, flags, noreply)

    def prepend(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Add bytes before an existing value while preserving its flags and expiration."
        return self._store(b"prepend", key, value, expire, flags, noreply)

    def cas(
        self,
        bytes key,
        bytes value,
        bytes cas,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> Optional[bool]:
        "Store when the token matches. Return False for a stale token and None for a missing key. With noreply, True confirms only the write."
        auto header = _cas_header(key, cas, expire, flags, len(value), noreply)
        auto reader = self._begin()
        auto keep = False
        try:
            reader._send_storage(header, value)
            if noreply:
                keep = True
                return Optional.Some(True)

            auto reply = reader._read_line()
            Optional[bool] stored = None
            if reply == b"STORED":
                stored = Optional.Some(True)
            elif reply == b"EXISTS":
                stored = Optional.Some(False)
            elif reply != b"NOT_FOUND":
                raise MemcacheUnknownError(
                    "Unexpected memcached CAS reply: " + _error_message(reply, 0),
                )
            keep = True
            return stored
        finally:
            self._finish(keep)

    def _store(
        self,
        bytes command,
        bytes key,
        bytes value,
        int64 expire,
        int64 flags,
        bool noreply,
    ) -> bool:
        auto header = _storage_header(command, key, expire, flags, len(value), noreply)
        auto reader = self._begin()
        auto keep = False
        try:
            auto stored = reader._write_storage(header, value, noreply)
            keep = True
            return stored
        finally:
            self._finish(keep)

    def get(self, bytes key, Optional[bytes] default = None) -> Optional[bytes]:
        "Return the stored bytes, or default when the key is absent."
        auto hits = self._retrieve([key], False)
        if key in hits:
            return Optional.Some(hits[key].data)
        return default

    def gets(self, bytes key) -> (Optional[bytes], Optional[bytes]):
        "Return the stored bytes and CAS token, or two None values on a miss."
        auto hits = self._retrieve([key], True)
        if key in hits:
            auto hit = hits[key]
            return (Optional.Some(hit.data), Optional.Some(hit.cas))
        return (None, None)

    def get_many(self, list[bytes] keys) -> dict[bytes, bytes]:
        "Return stored bytes for the requested keys that exist."
        auto hits = self._retrieve(keys, False)
        dict[bytes, bytes] values = {}
        for key in hits:
            values[key] = hits[key].data
        return values

    def get_multi(self, list[bytes] keys) -> dict[bytes, bytes]:
        "Return stored bytes for the requested keys that exist. Alias of get_many."
        return self.get_many(keys)

    def gets_many(self, list[bytes] keys) -> dict[bytes, (bytes, bytes)]:
        "Return a value and CAS token for each requested key that exists."
        auto hits = self._retrieve(keys, True)
        dict[bytes, (bytes, bytes)] values = {}
        for key in hits:
            auto hit = hits[key]
            values[key] = (hit.data, hit.cas)
        return values

    def delete(self, bytes key, bool noreply = False) -> bool:
        "Delete a key. Return False for a miss when replies are enabled."
        _validate_key(key)
        return self._change_status(b"delete " + key, b"DELETED", noreply)

    def delete_many(self, list[bytes] keys, bool noreply = False) -> bool:
        "Attempt every deletion. Return True after all commands complete."
        if len(keys) == 0:
            return True
        list[bytes] commands = []
        for key in keys:
            _validate_key(key)
            commands.append(b"delete " + key)

        auto reader = self._begin()
        auto keep = False
        try:
            for command in commands:
                reader._write_status(command, b"DELETED", noreply)
            keep = True
            return True
        finally:
            self._finish(keep)

    def delete_multi(self, list[bytes] keys, bool noreply = False) -> bool:
        "Alias for delete_many."
        return self.delete_many(keys, noreply)

    def incr(self, bytes key, uint64 value, bool noreply = False) -> Optional[uint64]:
        "Increment a counter. Return its new value, or None on a miss or silent write."
        return self._change_counter(b"incr", key, value, noreply)

    def decr(self, bytes key, uint64 value, bool noreply = False) -> Optional[uint64]:
        "Decrement a counter with a floor of zero. Return None on a miss or silent write."
        return self._change_counter(b"decr", key, value, noreply)

    def _change_counter(
        self,
        bytes command,
        bytes key,
        uint64 value,
        bool noreply,
    ) -> Optional[uint64]:
        _validate_key(key)
        auto line = command + b" " + key + bytes(" " + str(value))
        auto reader = self._begin()
        auto keep = False
        try:
            reader._send_command(line, noreply)
            if noreply:
                keep = True
                return None
            auto reply = reader._read_line()
            if reply == b"NOT_FOUND":
                keep = True
                return None
            auto end = len(reply)
            while end > 0 and reply[end - 1] == 32:
                end = end - 1
            auto count = _reply_uint(reply[0:end], uint64(-1))
            keep = True
            return Optional.Some(count)
        finally:
            self._finish(keep)

    def touch(self, bytes key, int64 expire = 0, bool noreply = False) -> bool:
        "Update a key's expiration. Zero clears expiration."
        _validate_key(key)
        _validate_expire(expire)
        return self._change_status(
            b"touch " + key + bytes(" " + str(expire)),
            b"TOUCHED",
            noreply,
        )

    def _change_status(self, bytes line, bytes success, bool noreply) -> bool:
        auto reader = self._begin()
        auto keep = False
        try:
            auto changed = reader._write_status(line, success, noreply)
            keep = True
            return changed
        finally:
            self._finish(keep)

    def _retrieve(
        self,
        list[bytes] keys,
        bool with_cas,
    ) -> dict[bytes, _RetrievedValue]:
        dict[bytes, _RetrievedValue] hits = {}
        if len(keys) == 0:
            return hits

        dict[bytes, bool] requested = {}
        list[bytes] parts = [b"get"]
        if with_cas:
            parts[0] = b"gets"
        for key in keys:
            _validate_key(key)
            if not key in requested:
                requested[key] = True
                parts.append(b" ")
                parts.append(key)
        auto command = _join_fragments(parts, 0, len(parts))
        auto reader = self._begin()
        auto keep = False
        try:
            _send_line(reader._socket, command)
            while True:
                auto header = reader._read_line()
                if header == b"END":
                    keep = True
                    return hits
                auto fields = _value_fields(header, with_cas)
                auto key = fields[1]
                if not key in requested or key in hits:
                    raise MemcacheUnknownError(
                        "Unrequested or duplicate key in memcached reply",
                    )
                auto flags = int64(_reply_uint(fields[2], uint64(4294967295)))
                auto size = int64(_reply_uint(fields[3], uint64(2147483645)))
                auto cas = b""
                if with_cas:
                    cas = fields[4]
                    _reply_uint(cas, uint64(-1))
                hits[key] = _RetrievedValue(reader._read_block(size), flags, cas)
        finally:
            self._finish(keep)

    def _acquire(self):
        if not self._busy.compare_and_swap(0, 1):
            raise MemcacheConnectionError("Memcached client is already in use")

    def _open(self):
        if self._reader == None:
            _validate_timeout(self.timeout)
            auto socket = _dial(self.host, self.port, self.connect_timeout)
            self._reader = _Reader(socket, b"")

    # A successful begin transfers exclusive ownership to the caller until finish.
    def _begin(self) -> _Reader:
        self._acquire()
        auto started = False
        try:
            self._open()
            net.set_deadline_ns(self._reader._socket, _deadline_after(self.timeout))
            started = True
            return self._reader
        finally:
            if not started:
                self._finish(False)

    def _finish(self, bool keep):
        try:
            if keep:
                net.set_deadline_ns(self._reader._socket, 0)
            elif self._reader != None:
                auto socket = self._reader._socket
                self._reader = None
                net.close_conn(socket)
        finally:
            self._busy.store(0)

    def _request_line(self, bytes line) -> bytes:
        auto reader = self._begin()
        auto keep = False
        try:
            _send_line(reader._socket, line)
            auto reply = reader._read_line()
            keep = True
            return reply
        finally:
            self._finish(keep)

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
