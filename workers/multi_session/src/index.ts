export interface Env {
  ROOMS: DurableObjectNamespace<SpotubeRoom>;
}

type Permission = "controlPlayback" | "editQueue" | "invite" | "manageMembers";

type Member = {
  id: string;
  name: string;
  role: "host" | "guest";
  permissions: Record<Permission, boolean>;
};

type RoomState = {
  roomId: string;
  code: string;
  sequence: number;
  hostToken: string;
  queue: unknown[];
  activeTrackId: string | null;
  positionMs: number;
  playing: boolean;
  members: Record<string, Member>;
};

const guestPermissions = {
  controlPlayback: false,
  editQueue: false,
  invite: false,
  manageMembers: false,
} satisfies Record<Permission, boolean>;

const hostPermissions = {
  controlPlayback: true,
  editQueue: true,
  invite: true,
  manageMembers: true,
} satisfies Record<Permission, boolean>;

function json(data: unknown, init: ResponseInit = {}) {
  return new Response(JSON.stringify(data), {
    ...init,
    headers: {
      "content-type": "application/json",
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type",
      ...init.headers,
    },
  });
}

function token(size = 24) {
  let value = "";
  while (value.length < size) {
    const bytes = crypto.getRandomValues(new Uint8Array(size));
    value += btoa(String.fromCharCode(...bytes)).replace(/[+/=]/g, "");
  }

  return value.slice(0, size);
}

function roomCode(size = 6) {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(size));
  return [...bytes].map((byte) => alphabet[byte % alphabet.length]).join("");
}

async function readJson<T>(request: Request): Promise<T | null> {
  try {
    return (await request.json()) as T;
  } catch {
    return null;
  }
}

function forwardRequest(url: URL, request: Request) {
  return new Request(url, {
    method: request.method,
    headers: request.headers,
    body: request.body,
  });
}

export default {
  async fetch(request: Request, env: Env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return json({});

    if (url.pathname === "/rooms" && request.method === "POST") {
      const body = await request.text();
      for (let attempt = 0; attempt < 5; attempt += 1) {
        const code = roomCode();
        const id = env.ROOMS.idFromName(code);
        const stub = env.ROOMS.get(id);
        const createUrl = new URL(`/create`, url);
        createUrl.searchParams.set("code", code);
        const response = await stub.fetch(
          new Request(createUrl, {
            method: request.method,
            headers: request.headers,
            body,
          }),
        );
        if (response.status !== 409) {
          return response;
        }
      }

      return json(
        { error: "Failed to allocate a unique room code. Please try again." },
        { status: 500 },
      );
    }

    const match = url.pathname.match(/^\/rooms\/([A-Z0-9]{6})(?:\/(join|ws))?$/i);
    if (!match) return json({ error: "Not found" }, { status: 404 });

    const code = match[1].toUpperCase();
    const stub = env.ROOMS.get(env.ROOMS.idFromName(code));
    const action = match[2] ?? "metadata";
    return stub.fetch(
      forwardRequest(new URL(`/${action}${url.search}`, url), request),
    );
  },
};

export class SpotubeRoom {
  private stateValue: RoomState | null = null;
  private sockets = new Map<WebSocket, string>();
  private readonly idleCleanupMs = 2 * 60 * 60 * 1000;

  constructor(private state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    await this.load();

    if (url.pathname === "/create" && request.method === "POST") {
      if (this.stateValue) {
        return json({ error: "Room already exists" }, { status: 409 });
      }

      const body = (await readJson<{ name?: string }>(request)) ?? {};
      const roomId = this.state.id.toString();
      const code = url.searchParams.get("code") ?? roomCode();
      const hostToken = token();
      const hostId = token(12);
      this.stateValue = {
        roomId,
        code,
        sequence: 0,
        hostToken,
        queue: [],
        activeTrackId: null,
        positionMs: 0,
        playing: false,
        members: {
          [hostId]: {
            id: hostId,
            name: body.name ?? "Host",
            role: "host",
            permissions: hostPermissions,
          },
        },
      };
      await this.persist();
      await this.scheduleIdleCleanup();
      return json({ roomId, code, token: hostToken, memberId: hostId, ownerToken: hostToken });
    }

    if (!this.stateValue) return json({ error: "Room not found" }, { status: 404 });

    if (url.pathname === "/metadata" && request.method === "GET") {
      return json({
        roomId: this.stateValue.roomId,
        code: this.stateValue.code,
        members: Object.values(this.stateValue.members).length,
      });
    }

    if (url.pathname === "/join" && request.method === "POST") {
      const body = (await readJson<{ name?: string }>(request)) ?? {};
      const memberId = token(12);
      const memberToken = token();
      this.stateValue.members[memberId] = {
        id: memberId,
        name: body.name ?? "Guest",
        role: "guest",
        permissions: guestPermissions,
      };
      await this.state.storage.put(`token:${memberToken}`, memberId);
      await this.bump();
      await this.scheduleIdleCleanup();
      return json({ roomId: this.stateValue.roomId, code: this.stateValue.code, token: memberToken, memberId });
    }

    if (url.pathname === "/ws") {
      if (request.headers.get("upgrade") !== "websocket") {
        return json({ error: "Expected WebSocket" }, { status: 426 });
      }

      const memberId = await this.memberIdForToken(url.searchParams.get("token"));
      if (!memberId) return json({ error: "Invalid token" }, { status: 403 });

      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.connect(server, memberId);
      return new Response(null, { status: 101, webSocket: client });
    }

    return json({ error: "Not found" }, { status: 404 });
  }

  private async load() {
    if (this.stateValue) return;
    this.stateValue = await this.state.storage.get<RoomState>("state") ?? null;
  }

  private async persist() {
    await this.state.storage.put("state", this.stateValue);
    if (this.stateValue) await this.state.storage.put(`token:${this.stateValue.hostToken}`, this.hostMemberId());
  }

  private hostMemberId() {
    return Object.values(this.stateValue?.members ?? {}).find((member) => member.role === "host")?.id ?? "";
  }

  private async memberIdForToken(value: string | null) {
    if (!value) return null;
    const memberId = await this.state.storage.get<string>(`token:${value}`) ?? null;
    if (!memberId || !this.stateValue?.members[memberId]) {
      return null;
    }

    return memberId;
  }

  private connect(socket: WebSocket, memberId: string) {
    socket.accept();
    this.sockets.set(socket, memberId);
    this.scheduleIdleCleanup();
    socket.send(JSON.stringify({ type: "snapshot", data: this.publicState() }));

    socket.addEventListener("message", async (event) => {
      let message: { type?: string; data?: unknown };
      try {
        message = JSON.parse(String(event.data)) as {
          type?: string;
          data?: unknown;
        };
      } catch {
        socket.send(JSON.stringify({ type: "error", data: "Invalid JSON payload" }));
        return;
      }

      if (!message.type) {
        socket.send(JSON.stringify({ type: "error", data: "Missing message type" }));
        return;
      }

      await this.handle(memberId, message);
    });
    socket.addEventListener("close", () => {
      this.sockets.delete(socket);
      this.scheduleIdleCleanup();
    });
    socket.addEventListener("error", () => {
      this.sockets.delete(socket);
      this.scheduleIdleCleanup();
    });
  }

  async alarm() {
    if (this.sockets.size > 0) {
      await this.scheduleIdleCleanup();
      return;
    }

    await this.state.storage.deleteAll();
    this.stateValue = null;
  }

  private async scheduleIdleCleanup() {
    await this.state.storage.setAlarm(Date.now() + this.idleCleanupMs);
  }

  private publicState() {
    return {
      ...this.stateValue,
      hostToken: undefined,
      members: Object.values(this.stateValue?.members ?? {}),
    };
  }

  private async bump() {
    if (!this.stateValue) return;
    this.stateValue.sequence += 1;
    await this.persist();
    this.broadcast({ type: "snapshot", data: this.publicState() });
  }

  private allowed(memberId: string, permission: Permission) {
    const member = this.stateValue?.members[memberId];
    return member?.role === "host" || member?.permissions[permission] === true;
  }

  private async handle(
    memberId: string,
    message: { type: string; data?: unknown },
  ) {
    if (!this.stateValue) return;

    if (
      message.type === "playback" &&
      this.allowed(memberId, "controlPlayback") &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as {
        playing?: boolean;
        positionMs?: number;
        activeTrackId?: string | null;
      };
      this.stateValue.playing = data.playing ?? this.stateValue.playing;
      this.stateValue.positionMs = data.positionMs ?? this.stateValue.positionMs;
      this.stateValue.activeTrackId =
        data.activeTrackId ?? this.stateValue.activeTrackId;
      await this.bump();
    }

    if (
      message.type === "queue" &&
      this.allowed(memberId, "editQueue") &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as {
        queue?: unknown[];
        activeTrackId?: string | null;
      };
      this.stateValue.queue = Array.isArray(data.queue)
        ? data.queue
        : this.stateValue.queue;
      this.stateValue.activeTrackId =
        data.activeTrackId ?? this.stateValue.activeTrackId;
      await this.bump();
    }

    if (
      message.type === "permissions" &&
      this.allowed(memberId, "manageMembers") &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as {
        memberId?: string;
        permissions?: Partial<Record<Permission, boolean>>;
      };
      if (!data.memberId || !data.permissions) {
        return;
      }

      const member = this.stateValue.members[data.memberId];
      if (member && member.role !== "host") {
        member.permissions = { ...member.permissions, ...data.permissions };
        await this.bump();
      }
    }

    if (message.type === "leave") {
      const member = this.stateValue.members[memberId];
      if (member?.role === "guest") {
        delete this.stateValue.members[memberId];
        await this.bump();
      }
    }

    if (
      message.type === "end" &&
      this.stateValue.members[memberId]?.role === "host"
    ) {
      this.broadcast({ type: "ended" });
      for (const socket of this.sockets.keys()) {
        socket.close(1000, "Room ended");
      }
      this.sockets.clear();
      this.stateValue = null;
      await this.state.storage.deleteAll();
    }
  }

  private broadcast(message: unknown) {
    const payload = JSON.stringify(message);
    for (const socket of this.sockets.keys()) {
      socket.send(payload);
    }
  }
}
