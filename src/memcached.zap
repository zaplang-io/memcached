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

struct _StoreRequest:
    bytes key
    bytes header
    bytes value

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

    def set_many(
        self,
        dict[bytes, bytes] values,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> list[bytes]:
        "Store every supplied value. Return keys whose writes were declined."
        list[bytes] failed = []
        if len(values) == 0:
            return failed
        list[_StoreRequest] requests = []
        for key in values:
            auto value = values[key]
            auto header = _storage_header(
                b"set",
                key,
                expire,
                flags,
                len(value),
                noreply,
            )
            requests.append(_StoreRequest(key, header, value))
        auto reader = self._begin()
        auto keep = False
        try:
            for request in requests:
                if not reader._write_storage(request.header, request.value, noreply):
                    failed.append(request.key)
            keep = True
            return failed
        finally:
            self._finish(keep)

    def set_multi(
        self,
        dict[bytes, bytes] values,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> list[bytes]:
        "Alias for set_many."
        return self.set_many(values, expire, flags, noreply)

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

struct _PoolLease:
    Client client
    int64 generation

struct PooledClient:
    str host
    int64 port = 11211
    f64 connect_timeout = 0.0
    f64 timeout = 0.0
    int64 max_pool_size = 8
    bytes _mutex = sync.mutex()
    list[Client] _idle = []
    int64 _size = 0
    int64 _generation = 0

    def set_many(
        self,
        dict[bytes, bytes] values,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> list[bytes]:
        "Store every supplied value. Return keys whose writes were declined."
        auto lease = self._checkout()
        try:
            return lease.client.set_many(values, expire, flags, noreply)
        finally:
            self._return(lease)

    def set_multi(
        self,
        dict[bytes, bytes] values,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> list[bytes]:
        "Alias for set_many."
        return self.set_many(values, expire, flags, noreply)

    def _checkout(self) -> _PoolLease:
        sync.lock(self._mutex)
        try:
            if self.max_pool_size < 1:
                raise MemcacheIllegalInputError("max_pool_size must be positive")
            if len(self._idle) > 0:
                return _PoolLease(self._idle.pop(), self._generation)
            if self._size >= self.max_pool_size:
                raise RuntimeError("Memcached pool exhausted")
            auto client = Client(
                self.host,
                self.port,
                self.connect_timeout,
                self.timeout,
            )
            self._size = self._size + 1
            return _PoolLease(client, self._generation)
        finally:
            sync.unlock(self._mutex)

    def _return(self, _PoolLease lease):
        sync.lock(self._mutex)
        auto reusable = False
        try:
            reusable = lease.generation == self._generation
            if reusable:
                self._idle.append(lease.client)
        finally:
            sync.unlock(self._mutex)
        if not reusable:
            try:
                lease.client.disconnect()
            finally:
                sync.lock(self._mutex)
                self._size = self._size - 1
                sync.unlock(self._mutex)

    def disconnect(self):
        "Close idle connections and retire in-flight connections when returned."
        sync.lock(self._mutex)
        auto idle = self._idle
        list[Client] empty = []
        self._idle = empty
        self._generation = self._generation + 1
        sync.unlock(self._mutex)
        try:
            for client in idle:
                client.disconnect()
        finally:
            sync.lock(self._mutex)
            self._size = self._size - len(idle)
            sync.unlock(self._mutex)

    def connect(self):
        "Open the configured TCP connection. Reuse it if already open."
        auto lease = self._checkout()
        try:
            lease.client.connect()
        finally:
            self._return(lease)

    def set_value(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Store bytes under a key. With noreply, True confirms only the write."
        auto lease = self._checkout()
        try:
            return lease.client.set_value(key, value, expire, flags, noreply)
        finally:
            self._return(lease)

    def add(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Store a new key and return False if the key already exists."
        auto lease = self._checkout()
        try:
            return lease.client.add(key, value, expire, flags, noreply)
        finally:
            self._return(lease)

    def replace(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Replace an existing value and return False if the key is absent."
        auto lease = self._checkout()
        try:
            return lease.client.replace(key, value, expire, flags, noreply)
        finally:
            self._return(lease)

    def append(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Add bytes after an existing value while preserving its flags and expiration."
        auto lease = self._checkout()
        try:
            return lease.client.append(key, value, expire, flags, noreply)
        finally:
            self._return(lease)

    def prepend(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Add bytes before an existing value while preserving its flags and expiration."
        auto lease = self._checkout()
        try:
            return lease.client.prepend(key, value, expire, flags, noreply)
        finally:
            self._return(lease)

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
        auto lease = self._checkout()
        try:
            return lease.client.cas(key, value, cas, expire, flags, noreply)
        finally:
            self._return(lease)

    def get(self, bytes key, Optional[bytes] default = None) -> Optional[bytes]:
        "Return the stored bytes, or default when the key is absent."
        auto lease = self._checkout()
        try:
            return lease.client.get(key, default)
        finally:
            self._return(lease)

    def gets(self, bytes key) -> (Optional[bytes], Optional[bytes]):
        "Return the stored bytes and CAS token, or two None values on a miss."
        auto lease = self._checkout()
        try:
            return lease.client.gets(key)
        finally:
            self._return(lease)

    def get_many(self, list[bytes] keys) -> dict[bytes, bytes]:
        "Return stored bytes for the requested keys that exist."
        auto lease = self._checkout()
        try:
            return lease.client.get_many(keys)
        finally:
            self._return(lease)

    def get_multi(self, list[bytes] keys) -> dict[bytes, bytes]:
        "Return stored bytes for the requested keys that exist. Alias of get_many."
        auto lease = self._checkout()
        try:
            return lease.client.get_multi(keys)
        finally:
            self._return(lease)

    def gets_many(self, list[bytes] keys) -> dict[bytes, (bytes, bytes)]:
        "Return a value and CAS token for each requested key that exists."
        auto lease = self._checkout()
        try:
            return lease.client.gets_many(keys)
        finally:
            self._return(lease)

    def delete(self, bytes key, bool noreply = False) -> bool:
        "Delete a key. Return False for a miss when replies are enabled."
        auto lease = self._checkout()
        try:
            return lease.client.delete(key, noreply)
        finally:
            self._return(lease)

    def delete_many(self, list[bytes] keys, bool noreply = False) -> bool:
        "Attempt every deletion. Return True after all commands complete."
        auto lease = self._checkout()
        try:
            return lease.client.delete_many(keys, noreply)
        finally:
            self._return(lease)

    def delete_multi(self, list[bytes] keys, bool noreply = False) -> bool:
        "Alias for delete_many."
        auto lease = self._checkout()
        try:
            return lease.client.delete_multi(keys, noreply)
        finally:
            self._return(lease)

    def incr(self, bytes key, uint64 value, bool noreply = False) -> Optional[uint64]:
        "Increment a counter. Return its new value, or None on a miss or silent write."
        auto lease = self._checkout()
        try:
            return lease.client.incr(key, value, noreply)
        finally:
            self._return(lease)

    def decr(self, bytes key, uint64 value, bool noreply = False) -> Optional[uint64]:
        "Decrement a counter with a floor of zero. Return None on a miss or silent write."
        auto lease = self._checkout()
        try:
            return lease.client.decr(key, value, noreply)
        finally:
            self._return(lease)

    def touch(self, bytes key, int64 expire = 0, bool noreply = False) -> bool:
        "Update a key's expiration. Zero clears expiration."
        auto lease = self._checkout()
        try:
            return lease.client.touch(key, expire, noreply)
        finally:
            self._return(lease)

    def stats(self, bytes... args) -> dict[bytes, bytes]:
        "Return raw STAT names and values. Pass subcommands as separate byte tokens."
        auto lease = self._checkout()
        try:
            return lease.client.stats(*args)
        finally:
            self._return(lease)

    def flush_all(self, int64 delay = 0, bool noreply = False) -> bool:
        "Invalidate all items on this server immediately or after a delay."
        auto lease = self._checkout()
        try:
            return lease.client.flush_all(delay, noreply)
        finally:
            self._return(lease)

    def version(self) -> bytes:
        "Return the server version token."
        auto lease = self._checkout()
        try:
            return lease.client.version()
        finally:
            self._return(lease)

    def quit(self):
        "Send quit and close the connection. A later command reconnects."
        auto lease = self._checkout()
        try:
            lease.client.quit()
        finally:
            self._return(lease)

# A 32-bit rotation for MurmurHash3 x86_32.
def _rotate32(uint32 value, int64 distance) -> uint32:
    return value << distance | value >> 32 - distance

def _murmur_word(uint32 word) -> uint32:
    return _rotate32(word * uint32(3432918353), 15) * uint32(461845907)

def _murmur32(bytes data) -> uint32:
    uint32 result = 0
    auto start = 0
    while start + 4 <= len(data):
        auto word = uint32(data[start]) | uint32(data[start + 1]) << 8 | uint32(data[start + 2]) << 16 | uint32(data[start + 3]) << 24
        result = _rotate32(result ^ _murmur_word(word), 13) * uint32(5) + uint32(3864292196)
        start = start + 4
    uint32 tail = 0
    for index in range(start, len(data)):
        tail = tail | uint32(data[index]) << (index - start) * 8
    result = result ^ _murmur_word(tail) ^ uint32(len(data))
    result = (result ^ result >> 16) * uint32(2246822507)
    result = (result ^ result >> 13) * uint32(3266489909)
    return result ^ result >> 16

# Pymemcache hashes the Python bytes representation of a byte key.
def _hash_key(bytes key) -> bytes:
    auto quote = 39
    auto has_single = False
    auto has_double = False
    for index in range(len(key)):
        if key[index] == 39:
            has_single = True
        if key[index] == 34:
            has_double = True
    if has_single and not has_double:
        quote = 34
    list[int64] encoded = [98, quote]
    for index in range(len(key)):
        auto ch = key[index]
        if ch == quote or ch == 92:
            encoded.append(92)
        encoded.append(ch)
    encoded.append(quote)
    return bytes(encoded)

struct _HashNode:
    bytes name
    PooledClient pool
    int64 failures = 0
    int64 eligible_at = 0
    bool ejected = False

struct HashClient:
    list[(str, int64)] servers
    f64 connect_timeout = 0.0
    f64 timeout = 0.0
    int64 retry_attempts = 2
    f64 retry_timeout = 1.0
    f64 dead_timeout = 60.0
    bool ignore_exc = False
    bool use_pooling = False
    int64 max_pool_size = 8
    bytes _mutex = sync.mutex()
    list[_HashNode] _nodes = []

    def _init(self):
        sync.lock(self._mutex)
        try:
            if len(self._nodes) > 0:
                return
            if len(self.servers) == 0:
                raise MemcacheIllegalInputError(
                    "HashClient requires at least one server",
                )
            if self.retry_attempts < 0 or self.retry_attempts == 9223372036854775807 or self.max_pool_size < 1:
                raise MemcacheIllegalInputError(
                    "Invalid HashClient retry or pool limit",
                )
            _validate_timeout(self.connect_timeout)
            _validate_timeout(self.timeout)
            _validate_timeout(self.retry_timeout)
            _validate_timeout(self.dead_timeout)
            auto capacity = 1
            if self.use_pooling:
                capacity = self.max_pool_size
            list[_HashNode] nodes = []
            dict[bytes, bool] seen = {}
            for server in self.servers:
                auto host, port = server
                if len(host) == 0 or port < 1 or port > 65535:
                    raise MemcacheIllegalInputError("Invalid HashClient server")
                auto name = bytes(host + ":" + str(port))
                if name in seen:
                    raise MemcacheIllegalInputError("Duplicate HashClient server")
                seen[name] = True
                nodes.append(
                    _HashNode(
                        name,
                        PooledClient(
                            host,
                            port,
                            self.connect_timeout,
                            self.timeout,
                            capacity,
                        ),
                    ),
                )
            self._nodes = nodes
        finally:
            sync.unlock(self._mutex)

    def _route(self, bytes key) -> int64:
        auto encoded = _hash_key(key)
        sync.lock(self._mutex)
        try:
            auto now = time.monotonic_ns()
            auto best = -1
            uint32 best_score = 0
            for index in range(len(self._nodes)):
                auto node = self._nodes[index]
                if not node.ejected or now >= node.eligible_at:
                    auto score = _murmur32(node.name + b"-" + encoded)
                    if best < 0 or score > best_score or score == best_score and node.name > self._nodes[best].name:
                        best = index
                        best_score = score
            return best
        finally:
            sync.unlock(self._mutex)

    def _nominated(self, bytes key) -> int64:
        _validate_key(key)
        self._init()
        auto index = self._route(key)
        if index < 0 and not self.ignore_exc:
            raise MemcacheConnectionError("All memcached servers are ejected")
        return index

    def _ready(self, _HashNode node) -> bool:
        sync.lock(self._mutex)
        try:
            return time.monotonic_ns() >= node.eligible_at
        finally:
            sync.unlock(self._mutex)

    def _healthy(self, _HashNode node):
        sync.lock(self._mutex)
        node.failures = 0
        node.ejected = False
        node.eligible_at = 0
        sync.unlock(self._mutex)

    def _failed(self, _HashNode node):
        sync.lock(self._mutex)
        try:
            if node.ejected or node.failures >= self.retry_attempts:
                node.ejected = True
                node.eligible_at = _deadline_after(self.dead_timeout)
            else:
                node.failures = node.failures + 1
                node.eligible_at = _deadline_after(self.retry_timeout)
        finally:
            sync.unlock(self._mutex)

    def _run[T](self, int64 index, T fallback, fn(PooledClient) -> T action) -> T:
        if index < 0:
            return fallback
        auto node = self._nodes[index]
        if not self._ready(node):
            return fallback
        try:
            auto result = action(node.pool)
            self._healthy(node)
            return result
        except MemcacheIllegalInputError:
            raise
        except MemcacheConnectionError:
            self._failed(node)
            if not self.ignore_exc:
                raise
        except MemcacheTimeoutError:
            self._failed(node)
            if not self.ignore_exc:
                raise
        except MemcacheUnexpectedCloseError:
            self._failed(node)
            if not self.ignore_exc:
                raise
        except Exception:
            if not self.ignore_exc:
                raise
        return fallback

    def disconnect_all(self):
        "Close pooled connections to every configured server."
        self._init()
        for node in self._nodes:
            node.pool.disconnect()

    def disconnect(self):
        "Alias for disconnect_all."
        self.disconnect_all()

    def set_value(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Store bytes under a key. With noreply, True confirms only the write."
        auto index = self._nominated(key)
        return self._run[bool](
            index,
            False,
            lambda pool: pool.set_value(key, value, expire, flags, noreply),
        )

    def add(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Store a new key and return False if the key already exists."
        auto index = self._nominated(key)
        return self._run[bool](
            index,
            False,
            lambda pool: pool.add(key, value, expire, flags, noreply),
        )

    def replace(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Replace an existing value and return False if the key is absent."
        auto index = self._nominated(key)
        return self._run[bool](
            index,
            False,
            lambda pool: pool.replace(key, value, expire, flags, noreply),
        )

    def append(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Add bytes after an existing value while preserving its flags and expiration."
        auto index = self._nominated(key)
        return self._run[bool](
            index,
            False,
            lambda pool: pool.append(key, value, expire, flags, noreply),
        )

    def prepend(
        self,
        bytes key,
        bytes value,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> bool:
        "Add bytes before an existing value while preserving its flags and expiration."
        auto index = self._nominated(key)
        return self._run[bool](
            index,
            False,
            lambda pool: pool.prepend(key, value, expire, flags, noreply),
        )

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
        auto index = self._nominated(key)
        return self._run[Optional[bool]](
            index,
            Optional.Some(False),
            lambda pool: pool.cas(key, value, cas, expire, flags, noreply),
        )

    def get(self, bytes key, Optional[bytes] default = None) -> Optional[bytes]:
        "Return the stored bytes, or default when the key is absent."
        auto index = self._nominated(key)
        return self._run[Optional[bytes]](
            index,
            default,
            lambda pool: pool.get(key, default),
        )

    def gets(self, bytes key) -> (Optional[bytes], Optional[bytes]):
        "Return the stored bytes and CAS token, or two None values on a miss."
        auto index = self._nominated(key)
        return self._run[Optional[bytes], Optional[bytes]](
            index,
            (None, None),
            lambda pool: pool.gets(key),
        )

    def delete(self, bytes key, bool noreply = False) -> bool:
        "Delete a key. Return False for a miss when replies are enabled."
        auto index = self._nominated(key)
        return self._run[bool](index, False, lambda pool: pool.delete(key, noreply))

    def incr(self, bytes key, uint64 value, bool noreply = False) -> Optional[uint64]:
        "Increment a counter. Return its new value, or None on a miss or silent write."
        auto index = self._nominated(key)
        return self._run[Optional[uint64]](
            index,
            None,
            lambda pool: pool.incr(key, value, noreply),
        )

    def decr(self, bytes key, uint64 value, bool noreply = False) -> Optional[uint64]:
        "Decrement a counter with a floor of zero. Return None on a miss or silent write."
        auto index = self._nominated(key)
        return self._run[Optional[uint64]](
            index,
            None,
            lambda pool: pool.decr(key, value, noreply),
        )

    def touch(self, bytes key, int64 expire = 0, bool noreply = False) -> bool:
        "Update a key's expiration. Zero clears expiration."
        auto index = self._nominated(key)
        return self._run[bool](
            index,
            False,
            lambda pool: pool.touch(key, expire, noreply),
        )

    def _groups(self, list[bytes] keys) -> dict[int64, list[bytes]]:
        self._init()
        for key in keys:
            _validate_key(key)
        dict[int64, list[bytes]] groups = {}
        for key in keys:
            auto index = self._route(key)
            if index < 0 and not self.ignore_exc:
                raise MemcacheConnectionError("All memcached servers are ejected")
            if not index in groups:
                list[bytes] empty = []
                groups[index] = empty
            groups[index].append(key)
        return groups

    def get_many(self, list[bytes] keys) -> dict[bytes, bytes]:
        "Fetch each shard's keys and return all hits."
        dict[bytes, bytes] hits = {}
        auto groups = self._groups(keys)
        for index in groups:
            auto group = groups[index]
            dict[bytes, bytes] empty = {}
            auto found = self._run[dict[bytes, bytes]](
                index,
                empty,
                lambda pool: pool.get_many(group),
            )
            for key in found:
                hits[key] = found[key]
        return hits

    def get_multi(self, list[bytes] keys) -> dict[bytes, bytes]:
        "Alias for get_many."
        return self.get_many(keys)

    def gets_many(self, list[bytes] keys) -> dict[bytes, (bytes, bytes)]:
        "Fetch values and CAS tokens from their owning shards."
        dict[bytes, (bytes, bytes)] hits = {}
        auto groups = self._groups(keys)
        for index in groups:
            auto group = groups[index]
            dict[bytes, (bytes, bytes)] empty = {}
            auto found = self._run[dict[bytes, (bytes, bytes)]](
                index,
                empty,
                lambda pool: pool.gets_many(group),
            )
            for key in found:
                hits[key] = found[key]
        return hits

    def gets_multi(self, list[bytes] keys) -> dict[bytes, (bytes, bytes)]:
        "Alias for gets_many."
        return self.gets_many(keys)

    def delete_many(self, list[bytes] keys, bool noreply = False) -> bool:
        "Attempt deletions on every owning shard."
        auto groups = self._groups(keys)
        for index in groups:
            auto group = groups[index]
            self._run[bool](index, False, lambda pool: pool.delete_many(group, noreply))
        return True

    def delete_multi(self, list[bytes] keys, bool noreply = False) -> bool:
        "Alias for delete_many."
        return self.delete_many(keys, noreply)

    def set_many(
        self,
        dict[bytes, bytes] values,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> list[bytes]:
        "Store each value on its owning shard. Return failed or skipped keys."
        list[bytes] keys = []
        for key in values:
            _storage_header(b"set", key, expire, flags, len(values[key]), noreply)
            keys.append(key)
        auto groups = self._groups(keys)
        list[bytes] failed = []
        for index in groups:
            auto group = groups[index]
            dict[bytes, bytes] batch = {}
            for key in group:
                batch[key] = values[key]
            auto rejected = self._run[list[bytes]](
                index,
                group,
                lambda pool: pool.set_many(batch, expire, flags, noreply),
            )
            for key in rejected:
                failed.append(key)
        return failed

    def set_multi(
        self,
        dict[bytes, bytes] values,
        int64 expire = 0,
        int64 flags = 0,
        bool noreply = False,
    ) -> list[bytes]:
        "Alias for set_many."
        return self.set_many(values, expire, flags, noreply)

    def stats(self, bytes... args) -> list[(bytes, dict[bytes, bytes])]:
        "Return raw stats paired with each configured server's address."
        self._init()
        list[(bytes, dict[bytes, bytes])] result = []
        for index in range(len(self._nodes)):
            dict[bytes, bytes] empty = {}
            auto stats = self._run[dict[bytes, bytes]](
                index,
                empty,
                lambda pool: pool.stats(*args),
            )
            result.append((self._nodes[index].name, stats))
        return result

    def flush_all(self, int64 delay = 0, bool noreply = False):
        "Flush each configured server."
        _validate_expire(delay)
        self._init()
        for index in range(len(self._nodes)):
            self._run[bool](index, False, lambda pool: pool.flush_all(delay, noreply))

    def quit(self):
        "Send quit to each configured server and retire its pooled connections."
        self._init()
        for node in self._nodes:
            try:
                if self._ready(node):
                    node.pool.quit()
            finally:
                node.pool.disconnect()
