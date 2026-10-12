# Local sync stack

Couchbase Server and Sync Gateway, set up for ManualBot, on your own machine. Point the app's **Settings → Sync** at it and
every iPad (or simulator) that does the same shares one library: import a manual on one, and it is searchable on the others
without being indexed again.

This is for development and demos. It has no TLS, the Sync Gateway admin interface has no login (it is only published on
`127.0.0.1`), and the passwords are the defaults below. Do not expose it to the internet.

## Run it

You need Docker with Compose. From this folder:

```sh
docker compose up -d --wait     # start, or start again: it creates only what is missing
docker compose down             # stop, keeping the data
docker compose down -v          # stop and delete all data; the next start is from empty
```

The first start pulls two images (Couchbase Server is about 1 GB) and takes a few minutes; later starts take about a
minute. `--wait` returns when the stack is ready. To change a port or a password, copy `.env.example` to `.env` and edit it.

```
couchbase-server  --healthy-->  cb-init  --done-->  sync-gateway  --healthy-->  sgw-init   (the two init steps idle when done)
  cluster, data                  bucket, scope,              :4984 iPads                  database, sync function,
                                 collections, account        :4985 admin (this Mac)       accounts ipad1..ipad3
```

| What | Where | Notes |
|---|---|---|
| Sync Gateway, for the app | `4984` on every interface | what iPads connect to |
| Sync Gateway admin | `127.0.0.1:4985` | this machine only, no login |
| Couchbase Server console | <http://localhost:18091> | `Administrator` / `manualbot-admin`; this machine only |

The console is on 18091 rather than the usual 8091 so that it does not collide with a Couchbase Server you already run. If
another program holds 4984, set `SG_PUBLIC_PORT` in `.env` and use that port in the app.

## Connect the app

On the **Sync** page (Settings, or tap the cloud in the library toolbar) enter:

| | Simulator on this Mac | An iPad on the same network |
|---|---|---|
| Server address | `localhost:4984` | `<this Mac's address>:4984`, for example `192.168.1.20:4984` |
| User name | `ipad1` | `ipad2` (one account per iPad) |
| Password | `manualbot-ipad` | `manualbot-ipad` |

Then turn **Sync the library** on. The address is the Sync Gateway database; `ws://` and the database name `manualbot` are
added for you. Find this Mac's address with `ipconfig getifaddr en0` (Wi-Fi). The first time, iPadOS asks to let ManualBot
find devices on the local network: allow it. The iPad and the Mac must be on the same network, and the Mac's firewall must
let Docker accept connections on 4984.

The accounts are `ipad1`, `ipad2` and `ipad3`, with the password from `IPAD_PASSWORD` in `.env` (`manualbot-ipad` by
default). Every start sets the accounts' password again, so changing it in `.env` and starting the stack is enough. The
Couchbase administrator password (`CB_ADMIN_PASSWORD`) is different: it is set once, when the cluster is created, so changing
it later needs `docker compose down -v` and a fresh start.

## What is stored

Couchbase Server holds one bucket, `manualbot`, with a scope `manualbot` and the three collections the app replicates:

| Collection | Holds |
|---|---|
| `documents` | one record per document, with the original file attached |
| `chunks` | the text of each chunk with its vector |
| `images` | each photo found in a document, with its vector and a display copy |

All three are served in one Sync Gateway channel, `library`, which every account may read and write. Chats and messages
never leave the iPad. Vector and keyword indexes are not stored here at all: each iPad builds its own from the documents it
holds. Look at the data in the console under *Documents*, or ask Sync Gateway:

```sh
curl -s -u ipad1:manualbot-ipad http://localhost:4984/manualbot.manualbot.documents/_all_docs
curl -s http://localhost:4985/manualbot/_user/ipad1          # admin interface, this Mac only
```

## Things to know

- **One embedding model for everyone.** The shared vectors come from one model, the app's default (EmbeddingGemma 2). An
  iPad that uses another embedding model pauses sync until it is back on the default and its library is indexed with it. The
  Sync page says so.
- **Originals up to 20 MB.** That is the largest attachment Sync Gateway accepts, so the app refuses larger files at import.
- **Deleting a document deletes it for everyone** who syncs with the stack.
- **Reset** with `docker compose down -v`. The accounts come back on the next start. Libraries on the iPads are not touched by a
  reset of the server.

## When something is wrong

```sh
docker compose ps -a                     # all four should be "healthy"; cb-init and sgw-init idle once they are done
docker compose logs sync-gateway         # what Sync Gateway sees, including refused logins
docker compose logs cb-init sgw-init     # what the set-up did
```

- **`port is already allocated`**: another program uses the port; change it in `.env`.
- **The app says "credentials refused"**: check the user name (`ipad1`..`ipad3`) and the password in `.env`.
- **The app says "server unreachable"**: check the address, that both are on the same network, and that the stack is up
  (`curl -u ipad1:manualbot-ipad http://localhost:4984/manualbot/` should answer with the database's state).
