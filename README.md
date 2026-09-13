# agentmemory-docker

Đóng gói [`@agentmemory/agentmemory`](https://www.npmjs.com/package/@agentmemory/agentmemory) chạy trên nền [iii](https://github.com/iiidev/iii), triển khai bằng Docker Compose. Server expose 2 port:

- `3111` — HTTP API / MCP server chính (agentmemory)
- `3113` — Viewer (web UI)

## Quick Start

### 1. Tạo file `.env` từ `.env.example`

```bash
cp .env.example .env
```

Mở `.env` và cập nhật `OPENAI_API_KEY` bằng API key thật (agentmemory dùng key này để gọi LLM cho graph extraction, compress, v.v.):

```env
OPENAI_API_KEY=sk-XXXX
```

Các biến khác trong `.env.example` (base URL, model, embedding model...) giữ nguyên mặc định trừ khi bạn có endpoint LLM/embedding riêng.

### 2. Tạo Docker network `service_main`

`docker-compose.yaml` khai báo network `service_main` là `external`, nên phải tạo trước khi `up`:

```bash
docker network create service_main
```

> Nếu network đã tồn tại (do service khác tạo), bỏ qua bước này.

### 3. Chạy Docker Compose

```bash
docker compose up -d
```

Lệnh này sẽ build image (nếu chưa có) và start container `agentmemory` với healthcheck trên `http://127.0.0.1:3111/agentmemory/livez`.

### 4. Lấy `AGENTMEMORY_SECRET` từ log container

Ở lần khởi động đầu tiên, entrypoint sinh một HMAC secret ngẫu nhiên và **chỉ in ra log một lần duy nhất**:

```bash
docker logs -f agentmemory
```

Tìm đoạn log dạng:

```
================================================================
agentmemory: generated HMAC secret on first boot
AGENTMEMORY_SECRET=<secret_value>
Copy this value now. It will not be printed again.
Stored at: /data/.hmac (chmod 600)
To rotate: delete /data/.hmac on the persistent volume and restart.
================================================================
```

**Copy giá trị `AGENTMEMORY_SECRET` này lại ngay** — nó không được in lại ở các lần restart sau (được lưu tại `./data/.hmac` trên volume, chmod 600). Giá trị này dùng để authenticate các client (opencode, MCP client...) kết nối tới agentmemory.

> Muốn rotate secret: xóa file `./data/.hmac` rồi restart container (`docker compose restart agentmemory`), secret mới sẽ được sinh và in lại ở log.

### 5. Set biến môi trường trước khi start opencode

Trước khi chạy opencode (hoặc bất kỳ client MCP nào kết nối agentmemory), export 2 biến môi trường sau trong shell/session của bạn:

```bash
export AGENTMEMORY_SECRET=<secret_value_từ_bước_4>
export NTMEMORY_URL=http://127.0.0.1:3111
```

Sau đó start opencode như bình thường — nó sẽ tự kết nối tới agentmemory qua các biến này.

## Commands

| Command | Mô tả |
|---|---|
| `docker compose up -d` | Build (nếu cần) và start container ở background |
| `docker compose up -d --build` | Force rebuild image rồi start |
| `docker logs -f agentmemory` | Theo dõi log, dùng để lấy secret ở lần đầu boot |
| `docker compose restart agentmemory` | Restart container (dùng để rotate secret sau khi xóa `.hmac`) |
| `docker compose down` | Stop và remove container (data trong `./data` vẫn giữ nguyên) |
| `curl http://127.0.0.1:3111/agentmemory/livez` | Kiểm tra healthcheck |

## Architecture

- **Dockerfile**: base image `node:22-trixie-slim`, copy binary `iii` từ image `iiidev/iii`, cài `@agentmemory/agentmemory` qua npm vào prefix riêng (`/opt/agentmemory`) để pin đúng version `iii-sdk` (xem comment trong Dockerfile).
- **entrypoint.sh**: chạy với quyền root để (1) ghi đè `iii-config.yaml` bind `0.0.0.0` + đường dẫn tuyệt đối `/data`, (2) `chown` volume `/data` cho user `node`, (3) sinh và persist HMAC secret vào `/data/.hmac` ở lần boot đầu, sau đó exec CLI `agentmemory` dưới quyền user `node` qua `gosu`.
- **docker-compose.yaml**: mount `./data` vào `/data` (persist state, stream store, secret), attach vào external network `service_main`, healthcheck qua endpoint `livez`.
- **Data**: toàn bộ state (KV store, stream store, HMAC secret) nằm trong `./data` trên host — xóa thư mục này tương đương reset toàn bộ agentmemory (mất luôn cả secret, cần lấy lại từ log ở lần boot tiếp theo).

## Lưu ý

- `.env` và `data/` đã được gitignore — không commit secret/API key hoặc data thật.
- Secret sinh ra chỉ in ra log **một lần** khi `/data/.hmac` chưa tồn tại. Nếu bỏ lỡ, xóa file `.hmac` và restart để sinh lại (sẽ mất secret cũ, các client dùng secret cũ sẽ mất quyền auth).
