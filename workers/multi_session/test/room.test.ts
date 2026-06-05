import { describe, expect, it } from "vitest";
import { SELF } from "cloudflare:test";

async function openSocket(code: string, token: string) {
  const ws = new WebSocket(`wss://spotube.test/rooms/${code}/ws?token=${token}`);

  const openPromise = new Promise<void>((resolve, reject) => {
    ws.addEventListener("open", () => resolve(), { once: true });
    ws.addEventListener("error", () => reject(new Error("websocket failed")), {
      once: true,
    });
  });

  const firstSnapshotPromise = new Promise<any>((resolve) => {
    ws.addEventListener(
      "message",
      (event) => {
        const payload = JSON.parse(String(event.data));
        if (payload.type !== "snapshot") return;
        resolve(payload.data);
      },
      { once: true },
    );
  });

  await openPromise;
  const firstSnapshot = await firstSnapshotPromise;
  return { ws, firstSnapshot };
}

async function nextSnapshot(ws: WebSocket) {
  return await new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout waiting for snapshot")), 3000);
    ws.addEventListener(
      "message",
      (event) => {
        const payload = JSON.parse(String(event.data));
        if (payload.type !== "snapshot") return;
        clearTimeout(timer);
        resolve(payload.data);
      },
      { once: true },
    );
  });
}

const demoTrack = {
  id: "track-1",
  name: "Demo Track",
  externalUri: "spotify:track:1",
  artists: [],
  album: {
    albumType: "album",
    id: "album-1",
    name: "Demo Album",
    externalUri: "spotify:album:1",
    artists: [],
    releaseDate: "2024-01-01",
    images: [],
  },
  durationMs: 120000,
  isrc: "TEST12345678",
  explicit: false,
};

describe("multi-session room contract", () => {
  it("creates a room and exposes public metadata", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Host" }),
    });

    expect(create.status).toBe(200);
    const room = await create.json<{
      roomId: string;
      code: string;
      token: string;
      ownerToken: string;
      memberId: string;
    }>();

    expect(room.roomId).toBeTruthy();
    expect(room.code).toMatch(/^[A-Z0-9]{6}$/);
    expect(room.token).toBe(room.ownerToken);
    expect(room.memberId).toBeTruthy();

    const metadata = await SELF.fetch(`https://spotube.test/rooms/${room.code}`);
    expect(metadata.status).toBe(200);
    await expect(metadata.json()).resolves.toMatchObject({
      roomId: room.roomId,
      code: room.code,
      members: 1,
    });
  });

  it("joins guests with separate member tokens and listener defaults", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      body: JSON.stringify({ name: "Host" }),
    });
    const room = await create.json<{ code: string; memberId: string; token: string }>();

    const join = await SELF.fetch(`https://spotube.test/rooms/${room.code}/join`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Guest" }),
    });
    expect(join.status).toBe(200);

    const guest = await join.json<{ token: string; memberId: string }>();
    expect(guest.token).toBeTruthy();
    expect(guest.memberId).not.toBe(room.memberId);

    const hostSocket = await openSocket(room.code, room.token);
    const guestSocket = await openSocket(room.code, guest.token);

    const snapshot = hostSocket.firstSnapshot;
    const guestMember = snapshot.members.find((member: any) => member.id === guest.memberId);

    expect(guestMember.preset).toBe("listener");
    expect(guestMember.permissions.suggestTracks).toBe(true);
    expect(guestMember.permissions.voteTracks).toBe(true);
    expect(guestMember.permissions.editQueue).toBe(false);

    hostSocket.ws.close();
    guestSocket.ws.close();
  });

  it("does not leave ghost members after an explicit leave event", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Host" }),
    });
    const room = await create.json<{ code: string }>();

    const join = await SELF.fetch(`https://spotube.test/rooms/${room.code}/join`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Guest" }),
    });
    const guest = await join.json<{ token: string }>();

    const socket = await openSocket(room.code, guest.token);
    socket.ws.send(JSON.stringify({ type: "leave", data: null }));
    socket.ws.close();

    await new Promise((resolve) => setTimeout(resolve, 0));

    const metadata = await SELF.fetch(`https://spotube.test/rooms/${room.code}`);
    await expect(metadata.json()).resolves.toMatchObject({ members: 1 });
  });

  it("supports suggestions, deduplicated votes, and top-voted promotion", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Host" }),
    });
    const room = await create.json<{ code: string; token: string }>();

    const joinA = await SELF.fetch(`https://spotube.test/rooms/${room.code}/join`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Guest A" }),
    });
    const joinB = await SELF.fetch(`https://spotube.test/rooms/${room.code}/join`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Guest B" }),
    });

    const guestA = await joinA.json<{ token: string }>();
    const guestB = await joinB.json<{ token: string }>();

    const hostSocket = await openSocket(room.code, room.token);
    const guestASocket = await openSocket(room.code, guestA.token);
    const guestBSocket = await openSocket(room.code, guestB.token);

    guestASocket.ws.send(JSON.stringify({ type: "suggestion:add", data: { track: demoTrack } }));
    const afterSuggest = await nextSnapshot(hostSocket.ws);
    expect(afterSuggest.suggestions).toHaveLength(0);
    expect(afterSuggest.queue[0].id).toBe(demoTrack.id);

    hostSocket.ws.send(
      JSON.stringify({
        type: "suggestion:add",
        data: {
          track: { ...demoTrack, id: "track-2", name: "Second Track", externalUri: "spotify:track:2" },
        },
      }),
    );
    const afterSecondSuggestion = await nextSnapshot(hostSocket.ws);
    const secondSuggestionId = afterSecondSuggestion.suggestions[0]?.id;
    expect(secondSuggestionId).toBeTruthy();

    guestASocket.ws.send(JSON.stringify({ type: "suggestion:vote", data: { suggestionId: secondSuggestionId } }));
    const afterVote = await nextSnapshot(hostSocket.ws);
    expect(afterVote.suggestions[0].voteCount).toBe(2);

    guestASocket.ws.send(JSON.stringify({ type: "suggestion:vote", data: { suggestionId: secondSuggestionId } }));
    await new Promise((resolve) => setTimeout(resolve, 10));

    guestBSocket.ws.send(JSON.stringify({ type: "suggestion:vote", data: { suggestionId: secondSuggestionId } }));
    const afterThirdVote = await nextSnapshot(hostSocket.ws);
    expect(afterThirdVote.suggestions[0].voteCount).toBe(3);

    hostSocket.ws.close();
    guestASocket.ws.close();
    guestBSocket.ws.close();
  });

  it("updates member presets and broadcasts permissions", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Host" }),
    });
    const room = await create.json<{ code: string; token: string }>();

    const join = await SELF.fetch(`https://spotube.test/rooms/${room.code}/join`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Guest" }),
    });
    const guest = await join.json<{ token: string; memberId: string }>();

    const hostSocket = await openSocket(room.code, room.token);

    hostSocket.ws.send(
      JSON.stringify({
        type: "permissions",
        data: { memberId: guest.memberId, preset: "dj" },
      }),
    );

    const afterPreset = await nextSnapshot(hostSocket.ws);
    const updatedMember = afterPreset.members.find((member: any) => member.id === guest.memberId);
    expect(updatedMember.preset).toBe("dj");
    expect(updatedMember.permissions.controlPlayback).toBe(true);
    expect(updatedMember.permissions.manageMembers).toBe(false);

    hostSocket.ws.close();
  });
});
