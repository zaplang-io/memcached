# The server rejected a command or its arguments.
@exception
struct MemcacheClientError:
    str message

# The server could not process a command.
@exception
struct MemcacheServerError:
    str message

# The server did not recognize a command.
@exception
struct MemcacheUnknownCommandError:
    str message

# The caller supplied an invalid argument.
@exception
struct MemcacheIllegalInputError:
    str message

# The peer sent a malformed or unexpected protocol response.
@exception
struct MemcacheUnknownError:
    str message

# The peer closed the connection before a complete reply arrived.
@exception
struct MemcacheUnexpectedCloseError:
    str message

# The underlying TCP operation failed.
@exception
struct MemcacheConnectionError:
    str message

# The underlying TCP operation exceeded its deadline.
@exception
struct MemcacheTimeoutError:
    str message

# A serializer rejected a value or a deserializer rejected stored data.
@exception
struct MemcacheSerdeError:
    str message

interface Serde[T]:
    def serialize(self, bytes key, T value) -> (bytes, int64)
    def deserialize(self, bytes key, bytes value, int64 flags) -> T

struct BytesSerde:
    def serialize(self, bytes key, bytes value) -> (bytes, int64):
        "Store the bytes unchanged with the default flag zero."
        return (value, 0)

    def deserialize(self, bytes key, bytes value, int64 flags) -> bytes:
        "Return stored bytes unchanged for every flag."
        return value

struct TextSerde:
    def serialize(self, bytes key, str value) -> (bytes, int64):
        "Encode a UTF-8 string with pymemcache's text flag."
        return (bytes(value), 16)

    def deserialize(self, bytes key, bytes value, int64 flags) -> str:
        "Decode a UTF-8 string tagged with the text flag."
        if flags != 16:
            raise MemcacheSerdeError("Expected memcached text flag 16")
        try:
            return str(value)
        except Exception as message:
            raise MemcacheSerdeError("Invalid memcached UTF-8 text: " + message)

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

    def stats(self, bytes... args) -> dict[bytes, bytes]:
        "Return raw STAT names and values. Pass subcommands as separate byte tokens."
        list[bytes] parts = [b"stats"]
        for arg in args:
            _validate_key(arg)
            parts.append(b" ")
            parts.append(arg)
        auto command = _join_fragments(parts, 0, len(parts))
        auto reader = self._begin()
        auto keep = False
        try:
            _send_line(reader._socket, command)
            dict[bytes, bytes] result = {}
            while True:
                auto line = reader._read_line()
                if line == b"END":
                    keep = True
                    return result
                if len(line) <= 5 or line[0:5] != b"STAT ":
                    raise MemcacheUnknownError("Unexpected memcached stats reply")
                auto end = 5
                while end < len(line) and line[end] != 32:
                    if line[end] < 33 or line[end] > 126:
                        raise MemcacheUnknownError("Invalid memcached statistic name")
                    end = end + 1
                if end == 5:
                    raise MemcacheUnknownError("Missing memcached statistic name")
                auto name = line[5:end]
                auto value = b""
                if end < len(line):
                    value = line[end + 1:len(line)]
                result[name] = value
        finally:
            self._finish(keep)

    def flush_all(self, int64 delay = 0, bool noreply = False) -> bool:
        "Invalidate all items on this server immediately or after a delay."
        _validate_expire(delay)
        auto reader = self._begin()
        auto keep = False
        try:
            reader._send_command(b"flush_all " + bytes(str(delay)), noreply)
            if not noreply and reader._read_line() != b"OK":
                raise MemcacheUnknownError("Unexpected memcached flush_all reply")
            keep = True
            return True
        finally:
            self._finish(keep)

    def version(self) -> bytes:
        "Return the server version token."
        auto reader = self._begin()
        auto keep = False
        try:
            _send_line(reader._socket, b"version")
            auto line = reader._read_line()
            if len(line) <= 8 or line[0:8] != b"VERSION ":
                raise MemcacheUnknownError("Unexpected memcached version reply")
            for index in range(8, len(line)):
                if line[index] < 33 or line[index] > 126:
                    raise MemcacheUnknownError("Invalid memcached version token")
            keep = True
            return line[8:len(line)]
        finally:
            self._finish(keep)

    def quit(self):
        "Send quit and close the connection. A later command reconnects."
        auto reader = self._begin()
        try:
            _send_line(reader._socket, b"quit")
        finally:
            self._finish(False)

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

struct SerdeClient[T, S: Serde[T]]:
    Client client
    S serde

    def connect(self):
        "Open the underlying client connection."
        self.client.connect()

    def disconnect(self):
        "Close the underlying client connection."
        self.client.disconnect()

    def set_value(
        self,
        bytes key,
        T value,
        int64 expire = 0,
        Optional[int64] flags = None,
        bool noreply = False,
    ) -> bool:
        "Serialize and store a value, using the codec flags unless explicitly overridden."
        return self._store(b"set", key, value, expire, flags, noreply)

    def add(
        self,
        bytes key,
        T value,
        int64 expire = 0,
        Optional[int64] flags = None,
        bool noreply = False,
    ) -> bool:
        "Serialize and store a value if the key is absent."
        return self._store(b"add", key, value, expire, flags, noreply)

    def replace(
        self,
        bytes key,
        T value,
        int64 expire = 0,
        Optional[int64] flags = None,
        bool noreply = False,
    ) -> bool:
        "Serialize and replace the value if the key exists."
        return self._store(b"replace", key, value, expire, flags, noreply)

    def append(
        self,
        bytes key,
        T value,
        int64 expire = 0,
        Optional[int64] flags = None,
        bool noreply = False,
    ) -> bool:
        "Append the serialized bytes while preserving the stored flags and expiration."
        return self._store(b"append", key, value, expire, flags, noreply)

    def prepend(
        self,
        bytes key,
        T value,
        int64 expire = 0,
        Optional[int64] flags = None,
        bool noreply = False,
    ) -> bool:
        "Prepend the serialized bytes while preserving the stored flags and expiration."
        return self._store(b"prepend", key, value, expire, flags, noreply)

    def cas(
        self,
        bytes key,
        T value,
        bytes cas,
        int64 expire = 0,
        Optional[int64] flags = None,
        bool noreply = False,
    ) -> Optional[bool]:
        "Serialize and conditionally store a value using the token from gets or gets_many."
        auto encoded, codec_flags = self._encode(key, value)
        return self.client.cas(
            key,
            encoded,
            cas,
            expire,
            flags.unwrap_or(codec_flags),
            noreply,
        )

    def get(self, bytes key, Optional[T] default = None) -> Optional[T]:
        "Deserialize a stored value or return default when the key is absent."
        auto hits = self.client._retrieve([key], False)
        if key in hits:
            return Optional.Some(self._decode(key, hits[key]))
        return default

    def gets(self, bytes key) -> (Optional[T], Optional[bytes]):
        "Return the decoded value and CAS token, or two None values on a miss."
        auto hits = self.client._retrieve([key], True)
        if key in hits:
            auto hit = hits[key]
            return (Optional.Some(self._decode(key, hit)), Optional.Some(hit.cas))
        return (None, None)

    def get_many(self, list[bytes] keys) -> dict[bytes, T]:
        "Return decoded values for the requested keys that exist."
        auto hits = self.client._retrieve(keys, False)
        dict[bytes, T] values = {}
        for key in hits:
            values[key] = self._decode(key, hits[key])
        return values

    def get_multi(self, list[bytes] keys) -> dict[bytes, T]:
        "Alias for get_many."
        return self.get_many(keys)

    def gets_many(self, list[bytes] keys) -> dict[bytes, (T, bytes)]:
        "Return a decoded value and CAS token for each requested key that exists."
        auto hits = self.client._retrieve(keys, True)
        dict[bytes, (T, bytes)] values = {}
        for key in hits:
            auto hit = hits[key]
            values[key] = (self._decode(key, hit), hit.cas)
        return values

    def _encode(self, bytes key, T value) -> (bytes, int64):
        _validate_key(key)
        try:
            return self.serde.serialize(key, value)
        except MemcacheSerdeError:
            raise
        except Exception as message:
            raise MemcacheSerdeError("Memcached serialization failed: " + message)

    def _decode(self, bytes key, _RetrievedValue hit) -> T:
        try:
            return self.serde.deserialize(key, hit.data, hit.flags)
        except MemcacheSerdeError:
            raise
        except Exception as message:
            raise MemcacheSerdeError("Memcached deserialization failed: " + message)

    def _store(
        self,
        bytes command,
        bytes key,
        T value,
        int64 expire,
        Optional[int64] flags,
        bool noreply,
    ) -> bool:
        auto encoded, codec_flags = self._encode(key, value)
        return self.client._store(
            command,
            key,
            encoded,
            expire,
            flags.unwrap_or(codec_flags),
            noreply,
        )
