import memcached

@test
def _installed_package():
    auto client = memcached.Client(host="localhost")
    assert client.port == 11211
    client.disconnect()
    assert len(client.get_many([])) == 0
    assert len(client.gets_many([])) == 0
    auto typed = memcached.SerdeClient[str, memcached.TextSerde](
        client,
        memcached.TextSerde(),
    )
    assert len(typed.get_many([])) == 0
    auto invalid_key = False
    try:
        client.set_value(b"", b"value", expire=60, flags=3, noreply=True)
    except memcached.MemcacheIllegalInputError:
        invalid_key = True
    assert invalid_key
    auto invalid_token = False
    try:
        client.cas(b"key", b"value", cas=b"bad", expire=60, flags=3, noreply=True)
    except memcached.MemcacheIllegalInputError:
        invalid_token = True
    assert invalid_token
    auto invalid_stat_arg = False
    try:
        client.stats(b"settings", b"invalid token")
    except memcached.MemcacheIllegalInputError:
        invalid_stat_arg = True
    assert invalid_stat_arg
    try:
        raise memcached.MemcacheServerError("unavailable")
    except memcached.MemcacheServerError as message:
        assert message == "unavailable"
