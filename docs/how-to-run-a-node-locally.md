# Run a node locally

**The question:** How do I start one Atanor node on my machine over a local S3 store, deploy a worker to it and call the worker?

This guide stands alone. It is for trying Atanor on one machine, not for production: see [run it in production](how-to-run-in-production.md).

## Prerequisites

- Docker, `git`, `curl` and `openssl`, on Linux or macOS.
- An empty directory. Everything here runs in it.
- Ports 4000, 4001 and 8333 free on `127.0.0.1`.
- Run the blocks in order, in one shell. `IMAGE` is set in step 1 and used in steps 4 and 5, so a new
  shell needs the `export` again.

The containers are named `atanor-*`. Step 7 removes them.

## Steps

1. Name the image and fetch the example worker: a manifest and a compiled WASM component. The image is
   the latest release, published under the tag `latest`, and pulls without a login. The clone is the
   source of the same release: `TAG` is the tag that the latest release page redirects to.

   ```sh
   export IMAGE=ghcr.io/this-is-npc/atanor:latest
   TAG=$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/This-Is-NPC/atanor/releases/latest | sed 's#.*/##')
   git clone --depth 1 --branch "$TAG" https://github.com/This-Is-NPC/atanor.git atanor-src
   ```

   Then copy the example worker out of the clone:

   ```sh
   mkdir atanor-hello atanor-secrets
   cp atanor-src/examples/hello-wasm/atanor.json atanor-src/test/fixtures/wasm/hello.wasm atanor-hello/
   ```

   Expected: the directories `atanor-hello` and `atanor-secrets` exist, and `atanor-hello` holds
   `atanor.json` and `hello.wasm`.

2. Make the secrets: S3 keys, the admin token and the cookie that lets nodes join each other. The node
   reads them from files, so they do not show in `docker inspect`. The container runs as a user that
   is not you, so the files must be readable by everyone.

   ```sh
   for f in access_key secret_key admin_token cookie; do openssl rand -hex 24 | tr -d '\n' > atanor-secrets/$f; done
   chmod 755 atanor-secrets && chmod 644 atanor-secrets/*
   ```

   Expected: `atanor-secrets` holds four files, `access_key`, `secret_key`, `admin_token` and `cookie`.

3. Start SeaweedFS as the S3 store and create the bucket `atanor`.

   ```sh
   docker network create atanor-net
   docker run -d --name atanor-store --network atanor-net -p 127.0.0.1:8333:8333 \
     -v "$PWD/atanor-secrets:/run/secrets:ro" --entrypoint /bin/sh chrislusf/seaweedfs:4.48 -c \
     'export AWS_ACCESS_KEY_ID="$(cat /run/secrets/access_key)" AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/secret_key)"; \
      exec /entrypoint.sh mini -dir=/data -ip=atanor-store -ip.bind=0.0.0.0 -s3.port=8333 -admin.ui=false'
   until curl -s -o /dev/null http://127.0.0.1:8333/; do sleep 1; done
   curl -sS -o /dev/null -w 'create bucket: HTTP %{http_code}\n' --aws-sigv4 aws:amz:us-east-1:s3 \
     --user "$(cat atanor-secrets/access_key):$(cat atanor-secrets/secret_key)" -X PUT http://127.0.0.1:8333/atanor
   ```

   ```text
   create bucket: HTTP 200
   ```

4. Start one node and wait until it is ready. Port 4000 serves your workers; port 4001 is the admin
   API, which `/health/ready` answers with the admin token. `--stop-timeout 90` lets `docker stop` wait
   for the node to hand its cells back. It must exceed `stop.shutdown_ms` (75 s); Docker's default is
   10 s ([why](configuration.md#the-stop-grace-period)).

   ```sh
   docker run -d --name atanor-node --network atanor-net --stop-timeout 90 \
     -p 127.0.0.1:4000:4000 -p 127.0.0.1:4001:4001 -v "$PWD/atanor-secrets:/run/secrets:ro" \
     -e ATANOR_STORE=s3://atanor -e ATANOR_S3_ENDPOINT=http://atanor-store:8333 \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     -e ATANOR_ADMIN_TOKEN_FILE=/run/secrets/admin_token -e ATANOR_COOKIE_FILE=/run/secrets/cookie \
     -e ATANOR_ADVERTISE=atanor-node.local "$IMAGE"
   until [ "$(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $(cat atanor-secrets/admin_token)" \
     http://127.0.0.1:4001/health/ready)" = 200 ]; do
     [ "$(docker inspect -f '{{.State.Running}}' atanor-node 2>/dev/null)" = true ] \
       || { docker logs atanor-node; echo "atanor-node is not running" >&2; break; }
     sleep 1
   done; docker ps -q -f name=atanor-node | grep -q . && echo ready
   ```

   ```text
   ready
   ```

   If the loop prints `atanor-node is not running` instead, see [troubleshooting](#troubleshooting).

5. Deploy the worker. The image holds the `atanor` command; `--bucket` writes the package into the
   bucket, and the node applies it at its next poll (at most 5 seconds).

   ```sh
   docker run --rm --network atanor-net -v "$PWD/atanor-secrets:/run/secrets:ro" -v "$PWD/atanor-hello:/w:ro" \
     -e ATANOR_S3_ENDPOINT=http://atanor-store:8333 \
     -e AWS_ACCESS_KEY_ID_FILE=/run/secrets/access_key -e AWS_SECRET_ACCESS_KEY_FILE=/run/secrets/secret_key \
     "$IMAGE" deploy /w --bucket s3://atanor --activate
   ```

   ```text
   package 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77 (hello, wasm, 181410 bytes)
   hello: active 6f30c05f11f17db48d1819431b7ff92087d4343f9f248c5ae35d04d5c62a3c77, revision 1, previous none
   stored in s3://atanor; the nodes apply it at their next poll
   ```

   The `package` id and the byte count in your output may differ.

6. Call the worker. The route of the manifest is the host `localhost` and the path `/hello`. The loop
   retries until the node has applied the package.

   ```sh
   until curl -sf -H 'Host: localhost' http://127.0.0.1:4000/hello/world; do sleep 1; done
   ```

   ```text
   hello GET /hello/world? authority=localhost body=
   ```

7. Clean up. Remove everything this guide created, the images included. The commands are separate so
   you can run them again after a partial install: one that finds nothing to remove prints an error
   and the next still runs. If you use the SeaweedFS image for something else, leave out its line.
   `-v` also removes the anonymous volumes that the containers used. The node's local copies of cells
   live in the container's `/var/lib/atanor/cells` and go with it.

   ```sh
   docker rm -fv atanor-node atanor-store
   docker network rm atanor-net
   docker rmi "$IMAGE"
   docker rmi chrislusf/seaweedfs:4.48
   rm -rf atanor-src atanor-hello atanor-secrets
   ```

   If you also followed the [backup example](how-to-operate-atanor.md#back-up-and-restore), remove the
   aws-cli image (`docker rmi amazon/aws-cli`) and the `backup/` directory.

## Troubleshooting

- **Step 4 prints `atanor-node is not running`.** Read the log above that line. A failed pull or a wrong
  `IMAGE` leaves no container to wait for. If a container was created, remove it with
  `docker rm -f atanor-node` before you run step 4 again.
- **A `docker run` failed.** Its container may be gone while its volume is not. Run `docker volume ls`
  and remove any leftover with `docker volume rm <name>`.
- **Step 7 prints an error.** A command that finds nothing to remove prints an error, and the next
  command still runs. Check what is left with `docker ps -a`, `docker network ls` and `docker image ls`.

## Next steps

- [Deploy changes and roll back](how-to-deploy-a-worker.md).
- [Write your own WASM worker](how-to-write-a-wasm-worker.md).
- [Run it in production](how-to-run-in-production.md).
