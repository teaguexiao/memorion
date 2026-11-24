# Developer API

The API exposes conversations, audio upload, memories and related user data to authorized clients. A developer key scopes requests to a developer tenant. Use a synthetic external user ID when trying out a local instance.

Set `MEMORION_API_KEY` to a key issued by your instance. The conversation routes expect the raw key in the `Authorization` header.

```sh
curl -fsS \
  -H "Authorization: ${MEMORION_API_KEY:?Set a Developer API key}" \
  "http://127.0.0.1:8000/v1/conversations?external_user_id=demo-user"
```

The interactive API reference is at `/docs` on the running server. See [developer setup](../development.md) to run an instance and [CLI setup](../../cli/README.md) for a command-line client.
