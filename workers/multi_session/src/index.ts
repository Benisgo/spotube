export interface Env {
  ROOMS: DurableObjectNamespace<SpotubeRoom>;
}

type Permission =
  | "controlPlayback"
  | "editQueue"
  | "invite"
  | "manageMembers"
  | "suggestTracks"
  | "voteTracks";

type Preset = "listener" | "dj" | "coHost" | "custom";

type Member = {
  id: string;
  name: string;
  role: "host" | "guest";
  preset: Preset;
  permissions: Record<Permission, boolean>;
};

type Suggestion = {
  id: string;
  track: Record<string, unknown>;
  suggestedBy: string;
  createdAt: number;
  voteCount: number;
  voterIds: string[];
};

type RoomState = {
  roomId: string;
  code: string;
  sequence: number;
  hostToken: string;
  queue: Record<string, unknown>[];
  activeTrackId: string | null;
  activeSource: Record<string, unknown> | null;
  positionMs: number;
  playing: boolean;
  loopMode: string;
  shuffle: boolean;
  members: Record<string, Member>;
  suggestions: Suggestion[];
  communityQueueEnabled: boolean;
  autoAcceptSuggestedTracks: boolean;
  discordJoinEnabled: boolean;
  lastQueueUpdateBy: string | null;
  /** Member whose playback/queue update most recently changed state (for echo detection). */
  lastPlaybackUpdateBy: string | null;
  /** Client-clock (epoch ms) of the last applied ACTIVE playback/queue change. */
  lastPlaybackChangeAt: number;
  /** Server-receive time of the last ACTIVE change, for passive-tick protection. */
  lastActiveChangeAt: number;
};

const customPermissions = {
  controlPlayback: false,
  editQueue: false,
  invite: false,
  manageMembers: false,
  suggestTracks: false,
  voteTracks: false,
} satisfies Record<Permission, boolean>;

const listenerPermissions = {
  ...customPermissions,
  suggestTracks: true,
  voteTracks: true,
} satisfies Record<Permission, boolean>;

const djPermissions = {
  ...listenerPermissions,
  controlPlayback: true,
} satisfies Record<Permission, boolean>;

const coHostPermissions = {
  ...djPermissions,
  editQueue: true,
  invite: true,
  manageMembers: true,
} satisfies Record<Permission, boolean>;

const hostPermissions = {
  controlPlayback: true,
  editQueue: true,
  invite: true,
  manageMembers: true,
  suggestTracks: true,
  voteTracks: true,
} satisfies Record<Permission, boolean>;

function permissionsForPreset(preset: Preset) {
  switch (preset) {
    case "listener":
      return listenerPermissions;
    case "dj":
      return djPermissions;
    case "coHost":
      return coHostPermissions;
    case "custom":
      return customPermissions;
  }
}

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

  constructor(private state: DurableObjectState) { }

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
        activeSource: null,
        positionMs: 0,
        playing: false,
        loopMode: "none",
        shuffle: false,
        members: {
          [hostId]: {
            id: hostId,
            name: body.name ?? "Host",
            role: "host",
            preset: "coHost",
            permissions: hostPermissions,
          },
        },
        suggestions: [],
        communityQueueEnabled: true,
        autoAcceptSuggestedTracks: false,
        discordJoinEnabled: false,
        lastQueueUpdateBy: hostId,
        lastPlaybackUpdateBy: hostId,
        lastPlaybackChangeAt: 0,
        lastActiveChangeAt: 0,
      };
      await this.persist();
      await this.scheduleIdleCleanup();
      return json({
        roomId,
        code,
        token: hostToken,
        memberId: hostId,
        ownerToken: hostToken,
      });
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
        preset: "listener",
        permissions: { ...listenerPermissions },
      };
      await this.state.storage.put(`token:${memberToken}`, memberId);
      await this.bump();
      await this.scheduleIdleCleanup();
      return json({
        roomId: this.stateValue.roomId,
        code: this.stateValue.code,
        token: memberToken,
        memberId,
      });
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
    this.stateValue = (await this.state.storage.get<RoomState>("state")) ?? null;
  }

  private async persist() {
    await this.state.storage.put("state", this.stateValue);
    if (this.stateValue) {
      await this.state.storage.put(`token:${this.stateValue.hostToken}`, this.hostMemberId());
    }
  }

  private hostMemberId() {
    return (
      Object.values(this.stateValue?.members ?? {}).find((member) => member.role === "host")
        ?.id ?? ""
    );
  }

  private async memberIdForToken(value: string | null) {
    if (!value) return null;
    const memberId = (await this.state.storage.get<string>(`token:${value}`)) ?? null;
    if (!memberId || !this.stateValue?.members[memberId]) {
      return null;
    }

    return memberId;
  }

  private connect(socket: WebSocket, memberId: string) {
    socket.accept();
    this.sockets.set(socket, memberId);
    void this.scheduleIdleCleanup();
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
      void this.scheduleIdleCleanup();
    });
    socket.addEventListener("error", () => {
      this.sockets.delete(socket);
      void this.scheduleIdleCleanup();
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
      lastPlaybackChangeAt: undefined,
      lastActiveChangeAt: undefined,
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

  private trackId(track: unknown) {
    if (!track || typeof track !== "object") return null;
    const value = (track as { id?: unknown }).id;
    return typeof value === "string" && value.length > 0 ? value : null;
  }

  private sortedSuggestions() {
    return [...(this.stateValue?.suggestions ?? [])].sort((a, b) => {
      const voteOrder = b.voteCount - a.voteCount;
      if (voteOrder !== 0) return voteOrder;
      return a.createdAt - b.createdAt;
    });
  }

  private applyPreset(member: Member, preset: Preset) {
    member.preset = preset;
    member.permissions = { ...permissionsForPreset(preset) };
  }

  private promoteSuggestion(suggestionId?: string) {
    if (!this.stateValue) return;

    const suggestion =
      suggestionId == null
        ? this.sortedSuggestions()[0]
        : this.stateValue.suggestions.find((entry) => entry.id === suggestionId);
    if (!suggestion) return;

    this.stateValue.suggestions = this.stateValue.suggestions.filter(
      (entry) => entry.id !== suggestion.id,
    );

    const nextTrack = suggestion.track;
    const nextTrackId = this.trackId(nextTrack);
    if (nextTrackId) {
      this.stateValue.queue = this.stateValue.queue.filter((track) => {
        const trackId = this.trackId(track);
        return trackId == null || trackId !== nextTrackId;
      });
    }

    if (this.stateValue.queue.length === 0) {
      this.stateValue.queue = [nextTrack];
      this.stateValue.activeTrackId = nextTrackId;
      return;
    }

    const activeIndex = this.stateValue.activeTrackId
      ? this.stateValue.queue.findIndex(
        (track) => this.trackId(track) === this.stateValue?.activeTrackId,
      )
      : -1;
    const insertionIndex = Math.max(activeIndex, 0) + 1;
    this.stateValue.queue.splice(insertionIndex, 0, nextTrack);
    this.stateValue.lastQueueUpdateBy = "worker";
  }

  private reconcileCommunityQueue() {
    if (!this.stateValue?.communityQueueEnabled) return;
    if ((this.stateValue?.suggestions.length ?? 0) === 0) return;
    this.promoteSuggestion();
  }

  private samePermissions(
    left: Record<Permission, boolean>,
    right: Record<Permission, boolean>,
  ) {
    return (Object.keys(left) as Permission[]).every(
      (key) => left[key] === right[key],
    );
  }

  private async handle(memberId: string, message: { type: string; data?: unknown }) {
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
        activeSource?: Record<string, unknown> | null;
        loopMode?: string;
        shuffle?: boolean;
        changeAt?: number;
        passive?: boolean;
      };
      const changeAt = data.changeAt;
      const isPassive = data.passive === true;
      const now = Date.now();
      // Background position syncs (passive, e.g. the host's 1s tick) must not
      // clobber a recent ACTIVE action (seek/play). This prevents the host's
      // stale tick from rubber-banding other members after a seek.
      if (isPassive && now - this.stateValue.lastActiveChangeAt < 2000) {
        return;
      }
      // Reject genuinely stale updates: a message sent BEFORE the last applied
      // active change (per client clock) must not overwrite newer state, even
      // if it arrives at the relay later.
      if (
        typeof changeAt === "number" &&
        changeAt > 0 &&
        changeAt < this.stateValue.lastPlaybackChangeAt
      ) {
        return;
      }
      this.stateValue.playing = data.playing ?? this.stateValue.playing;
      this.stateValue.positionMs =
        data.positionMs ?? this.stateValue.positionMs;
      this.stateValue.loopMode =
        data.loopMode ?? this.stateValue.loopMode;
      this.stateValue.shuffle =
        data.shuffle ?? this.stateValue.shuffle;
      if (!isPassive) {
        // Active updates carry the active track / source; passive ticks
        // deliberately omit them so they never revert the active track.
        this.stateValue.activeTrackId =
          data.activeTrackId ?? this.stateValue.activeTrackId;
        this.stateValue.activeSource =
          data.activeSource === undefined
            ? this.stateValue.activeSource
            : data.activeSource;
        if (typeof changeAt === "number" && changeAt > 0) {
          this.stateValue.lastPlaybackChangeAt = changeAt;
        }
        this.stateValue.lastActiveChangeAt = now;
      }
      this.stateValue.lastPlaybackUpdateBy = memberId;
      await this.bump();
    }

    if (
      message.type === "queue" &&
      this.allowed(memberId, "editQueue") &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as {
        queue?: Record<string, unknown>[];
        activeTrackId?: string | null;
        activeSource?: Record<string, unknown> | null;
        positionMs?: number;
        changeAt?: number;
      };
      const changeAt = data.changeAt;
      // A stale queue push (sent before the last applied active change) must
      // not revert newer playback state (e.g. a play action made moments ago).
      if (
        typeof changeAt === "number" &&
        changeAt > 0 &&
        changeAt < this.stateValue.lastPlaybackChangeAt
      ) {
        return;
      }
      if (Array.isArray(data.queue)) {
        this.stateValue.queue = data.queue.slice(0, 100);
        this.stateValue.lastQueueUpdateBy = memberId;
        // Never lose the active track: if it fell outside the 100-track cap,
        // keep it at the front so members can always map it to an index.
        // Otherwise a >100-track playlist's active track vanishes from the
        // room queue and members map it to index 0 → song restarts at 00:00.
        const activeId =
          data.activeTrackId ?? this.stateValue.activeTrackId;
        if (
          activeId != null &&
          !this.stateValue.queue.some((t) => this.trackId(t) === activeId)
        ) {
          const active = data.queue.find((t) => this.trackId(t) === activeId);
          if (active) {
            this.stateValue.queue = [
              active,
              ...this.stateValue.queue,
            ].slice(0, 100);
          }
        }
      }
      const previousActiveTrackId = this.stateValue.activeTrackId;
      this.stateValue.activeTrackId =
        data.activeTrackId ?? this.stateValue.activeTrackId;
      this.stateValue.activeSource =
        data.activeSource !== undefined
          ? data.activeSource
          : previousActiveTrackId !== this.stateValue.activeTrackId
            ? null
            : this.stateValue.activeSource;
      this.stateValue.positionMs =
        (data as { positionMs?: number }).positionMs ?? this.stateValue.positionMs;
      if (typeof changeAt === "number" && changeAt > 0) {
        this.stateValue.lastPlaybackChangeAt = changeAt;
      }
      this.stateValue.lastActiveChangeAt = Date.now();
      this.stateValue.lastPlaybackUpdateBy = memberId;
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
        preset?: Preset;
        permissions?: Partial<Record<Permission, boolean>>;
      };
      if (!data.memberId) {
        return;
      }

      const member = this.stateValue.members[data.memberId];
      if (member && member.role !== "host") {
        if (data.preset) {
          this.applyPreset(member, data.preset);
        }

        if (data.permissions) {
          member.permissions = { ...member.permissions, ...data.permissions };
          const presetPermissions = permissionsForPreset(member.preset);
          if (
            member.preset !== "custom" &&
            !this.samePermissions(member.permissions, presetPermissions)
          ) {
            member.preset = "custom";
          }
        }

        await this.bump();
      }
    }

    if (
      message.type === "roomSettings" &&
      this.allowed(memberId, "editQueue") &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as {
        communityQueueEnabled?: boolean;
        autoAcceptSuggestedTracks?: boolean;
        discordJoinEnabled?: boolean;
      };
      let changed = false;
      if (typeof data.communityQueueEnabled === "boolean") {
        this.stateValue.communityQueueEnabled = data.communityQueueEnabled;
        changed = true;
      }
      if (typeof data.autoAcceptSuggestedTracks === "boolean") {
        this.stateValue.autoAcceptSuggestedTracks =
          data.autoAcceptSuggestedTracks;
        changed = true;
      }
      if (typeof data.discordJoinEnabled === "boolean") {
        this.stateValue.discordJoinEnabled = data.discordJoinEnabled;
        changed = true;
      }
      if (changed) {
        await this.bump();
      }
    }

    if (
      message.type === "suggestion:add" &&
      this.allowed(memberId, "suggestTracks") &&
      this.stateValue.communityQueueEnabled &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as { track?: Record<string, unknown> };
      if (!data.track || this.trackId(data.track) == null) {
        return;
      }

      this.stateValue.suggestions.push({
        id: token(12),
        track: data.track,
        suggestedBy: memberId,
        createdAt: this.stateValue.sequence + 1,
        voteCount: 1,
        voterIds: [memberId],
      });
      if (this.stateValue.autoAcceptSuggestedTracks) {
        this.promoteSuggestion();
      }
      await this.bump();
    }

    if (
      message.type === "suggestion:vote" &&
      this.allowed(memberId, "voteTracks") &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as { suggestionId?: string };
      if (!data.suggestionId) return;

      const suggestion = this.stateValue.suggestions.find(
        (entry) => entry.id === data.suggestionId,
      );
      if (!suggestion || suggestion.voterIds.includes(memberId)) {
        return;
      }

      suggestion.voterIds = [...suggestion.voterIds, memberId];
      suggestion.voteCount = suggestion.voterIds.length;
      await this.bump();
    }

    if (
      message.type === "suggestion:remove" &&
      this.allowed(memberId, "editQueue") &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as { suggestionId?: string };
      if (!data.suggestionId) return;

      this.stateValue.suggestions = this.stateValue.suggestions.filter(
        (entry) => entry.id !== data.suggestionId,
      );
      await this.bump();
    }

    if (
      message.type === "suggestion:promote" &&
      this.allowed(memberId, "editQueue") &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as { suggestionId?: string };
      this.promoteSuggestion(data.suggestionId);
      await this.bump();
    }

    if (
      message.type === "kick" &&
      this.allowed(memberId, "manageMembers") &&
      message.data &&
      typeof message.data === "object"
    ) {
      const data = message.data as { memberId?: string };
      if (data.memberId && data.memberId !== memberId) {
        const member = this.stateValue.members[data.memberId];
        if (member && member.role !== "host") {
          delete this.stateValue.members[data.memberId];
          this.stateValue.suggestions = this.stateValue.suggestions.filter(
            (entry) => entry.suggestedBy !== data.memberId,
          );

          for (const [socket, id] of this.sockets.entries()) {
            if (id === data.memberId) {
              socket.send(JSON.stringify({ type: "ended" }));
              socket.close(1008, "Kicked");
              this.sockets.delete(socket);
            }
          }
          await this.bump();
        }
      }
    }

    if (message.type === "leave") {
      const member = this.stateValue.members[memberId];
      if (member?.role === "guest") {
        delete this.stateValue.members[memberId];
        this.stateValue.suggestions = this.stateValue.suggestions.filter(
          (entry) => entry.suggestedBy !== memberId,
        );
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
