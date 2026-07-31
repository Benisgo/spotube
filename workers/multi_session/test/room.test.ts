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

  it("supports suggestions, deduplicated votes, and explicit promotion", async () => {
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

    // Suggesting adds to the suggestions list; there is no auto-promotion
    // unless autoAcceptSuggestedTracks is enabled (defaults to false).
    guestASocket.ws.send(JSON.stringify({ type: "suggestion:add", data: { track: demoTrack } }));
    const afterSuggest = await nextSnapshot(hostSocket.ws);
    expect(afterSuggest.suggestions).toHaveLength(1);
    expect(afterSuggest.suggestions[0].track.id).toBe(demoTrack.id);
    expect(afterSuggest.queue).toHaveLength(0);

    hostSocket.ws.send(
      JSON.stringify({
        type: "suggestion:add",
        data: {
          track: { ...demoTrack, id: "track-2", name: "Second Track", externalUri: "spotify:track:2" },
        },
      }),
    );
    const afterSecondSuggestion = await nextSnapshot(hostSocket.ws);
    const secondSuggestionId = afterSecondSuggestion.suggestions[1]?.id;
    expect(secondSuggestionId).toBeTruthy();

    // Votes are deduplicated per member (submitter auto-votes: the host's
    // track-2 starts at 1, guestA's vote makes it 2, guestB's makes it 3).
    guestASocket.ws.send(JSON.stringify({ type: "suggestion:vote", data: { suggestionId: secondSuggestionId } }));
    const afterVote = await nextSnapshot(hostSocket.ws);
    expect(afterVote.suggestions[1].voteCount).toBe(2);

    guestASocket.ws.send(JSON.stringify({ type: "suggestion:vote", data: { suggestionId: secondSuggestionId } }));
    await new Promise((resolve) => setTimeout(resolve, 10));

    guestBSocket.ws.send(JSON.stringify({ type: "suggestion:vote", data: { suggestionId: secondSuggestionId } }));
    const afterThirdVote = await nextSnapshot(hostSocket.ws);
    expect(afterThirdVote.suggestions[1].voteCount).toBe(3);

    // Explicit promotion moves the suggestion into the queue (empty queue →
    // becomes the active track).
    hostSocket.ws.send(JSON.stringify({ type: "suggestion:promote", data: { suggestionId: secondSuggestionId } }));
    const afterPromote = await nextSnapshot(hostSocket.ws);
    expect(afterPromote.suggestions).toHaveLength(1);
    expect(afterPromote.queue).toHaveLength(1);
    expect(afterPromote.queue[0].id).toBe("track-2");
    expect(afterPromote.activeTrackId).toBe("track-2");

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

  it("persists and broadcasts the active source with playback updates", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Host" }),
    });
    const room = await create.json<{ code: string; token: string }>();
    const hostSocket = await openSocket(room.code, room.token);

    hostSocket.ws.send(
      JSON.stringify({
        type: "queue",
        data: {
          queue: [demoTrack],
          activeTrackId: demoTrack.id,
          activeSource: {
            id: "video-1",
            title: "Demo Track",
            artists: ["Demo Artist"],
            duration: 120000000,
            externalUri: "https://youtube.com/watch?v=video-1",
          },
        },
      }),
    );

    const snapshot = await nextSnapshot(hostSocket.ws);
    expect(snapshot.activeTrackId).toBe(demoTrack.id);
    expect(snapshot.activeSource.id).toBe("video-1");

    hostSocket.ws.close();
  });

  it("does not reset the room position on a pure queue edit (same active track)", async () => {
    const create = await SELF.fetch("https://spotube.test/rooms", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: "Host" }),
    });
    const room = await create.json<{ code: string; token: string }>();
    const hostSocket = await openSocket(room.code, room.token);

    // Seed the room: a queue push that changes the active track (null → demo)
    // is an ACTIVE change and may set the position.
    hostSocket.ws.send(
      JSON.stringify({
        type: "queue",
        data: {
          queue: [demoTrack],
          activeTrackId: demoTrack.id,
          positionMs: 50000,
        },
      }),
    );
    const seeded = await nextSnapshot(hostSocket.ws);
    expect(seeded.positionMs).toBe(50000);

    // A pure queue edit (same active track) must NOT move the room position —
    // otherwise a member's stale local position would jump everyone (rubber-banding).
    hostSocket.ws.send(
      JSON.stringify({
        type: "queue",
        data: {
          queue: [demoTrack],
          activeTrackId: demoTrack.id,
          positionMs: 99999,
        },
      }),
    );
    const afterEdit = await nextSnapshot(hostSocket.ws);
    expect(afterEdit.positionMs).toBe(50000);
    expect(afterEdit.activeTrackId).toBe(demoTrack.id);

    hostSocket.ws.close();
  });

  it("accepts playback from members with skewed clocks and rejects same-member replays", async () => {
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
    const guestSocket = await openSocket(room.code, guest.token);

    // Grant the guest controlPlayback (DJ) so it can send playback events.
    hostSocket.ws.send(
      JSON.stringify({
        type: "permissions",
        data: { memberId: guest.memberId, preset: "dj" },
      }),
    );
    await nextSnapshot(hostSocket.ws);

    // Host sends an update stamped with changeAt 1_000_000 (normal clock).
    hostSocket.ws.send(
      JSON.stringify({
        type: "playback",
        data: { positionMs: 10000, changeAt: 1_000_000 },
      }),
    );
    const afterHost = await nextSnapshot(hostSocket.ws);
    expect(afterHost.positionMs).toBe(10000);

    // The guest's clock is BEHIND the host (changeAt 500_000 < host's
    // 1_000_000). A cross-client clock gate would reject this as "stale"; the
    // per-member gate only compares against the guest's OWN prior value (0),
    // so it is accepted — this is the clock-skew-proofing being tested.
    guestSocket.ws.send(
      JSON.stringify({
        type: "playback",
        data: { positionMs: 20000, changeAt: 500_000 },
      }),
    );
    const afterGuest = await nextSnapshot(hostSocket.ws);
    expect(afterGuest.positionMs).toBe(20000);
    const acceptedSequence = afterGuest.sequence;

    // Same guest sends an out-of-order (older) message: the per-member gate
    // rejects it (500_000 -> 499_999 is a regression for this member), so the
    // room state must not change.
    guestSocket.ws.send(
      JSON.stringify({
        type: "playback",
        data: { positionMs: 30000, changeAt: 499_999 },
      }),
    );
    await new Promise((resolve) => setTimeout(resolve, 20));

    // A fresh valid host update (changeAt 2_000_000 > host's own 1_000_000)
    // is applied. The sequence must advance by EXACTLY one: had the replay
    // landed, it would have bumped first and the sequence would be +2.
    hostSocket.ws.send(
      JSON.stringify({
        type: "playback",
        data: { positionMs: 40000, changeAt: 2_000_000 },
      }),
    );
    const afterValid = await nextSnapshot(hostSocket.ws);
    expect(afterValid.positionMs).toBe(40000);
    expect(afterValid.sequence).toBe(acceptedSequence + 1);

    hostSocket.ws.close();
    guestSocket.ws.close();
  });
});
